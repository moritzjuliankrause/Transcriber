import AppKit
import AVFoundation
import Combine
import FluidAudio

/// Orchestrates a recording session: audio capture → WAV + VAD → ASR → store.
@MainActor
final class RecordingCoordinator {
    private let settings: AppSettings
    private let state: AppState

    private var store: SessionStore?
    private var mic: MicrophoneCapture?
    private var system: SystemAudioCapture?
    private var micWav: WavWriter?
    private var systemWav: WavWriter?
    private var micProcessor: ChannelProcessor?
    private var systemProcessor: ChannelProcessor?
    private var queue: TranscriptionQueue?
    private var engine: FluidAudioEngine?
    private var power: PowerAssertion?
    private var deviceListeners: [AudioPropertyListener] = []
    /// Persists speaker names / name tags entered in the floating pill into the current session.
    private var speakerTagCancellable: AnyCancellable?
    private var muteCancellable: AnyCancellable?
    private var levelTimer: Timer?
    /// Loudest level since the last meter tick; nil = no buffer arrived in between.
    private var micPeak: Float?
    private var systemPeak: Float?
    /// Display levels last pushed to the meter (main thread).
    private var shownMic: Float = 0
    private var shownSystem: Float = 0
    private let levelLock = NSLock()
    private var diskTimer: Timer?
    private var echoGate: EchoGate?
    /// Mirror of state.isPaused readable from audio threads.
    private let pausedLock = NSLock()
    private var _paused = false
    private var pausedFlag: Bool { pausedLock.lock(); defer { pausedLock.unlock() }; return _paused }
    /// Mirror of state.isMicMuted readable from the microphone thread.
    private var _micMuted = false
    private var micMutedFlag: Bool { pausedLock.lock(); defer { pausedLock.unlock() }; return _micMuted }
    /// Paused time so far (pausedLock): it is not part of the timeline.
    private var pausedSeconds: Double = 0
    private var pauseStartedHost: UInt64 = 0
    /// Samples written per channel so far; each is touched only by its own audio thread.
    private var micWritten = 0
    private var systemWritten = 0
    private var sessionStartHostTime: UInt64 = 0
    private var silentMicCallbacks = 0
    private var micRestartAttempts = 0
    /// Wall-clock time of the last microphone buffer (levelLock-guarded). Used by the
    /// stall watchdog to notice when the input engine stops delivering buffers entirely –
    /// a case the per-buffer silence watchdog cannot see because it never runs then.
    private var micBufferAt: Date?
    private var micStallRestarting = false
    /// Same for the system tap: on a call that starts while the recording does, the tap can come
    /// up without ever delivering a buffer (FaceTime reconfigures the output device). It is then
    /// rebuilt until audio flows.
    private var systemBufferAt: Date?
    /// When the tap was last (re)built; the stall clock counts from the later of the two.
    private var systemStartedAt = Date()
    private var systemPlaybackCheckedAt = Date.distantPast
    private var systemStallRestarting = false
    private var systemRestartAttempts = 0
    private var statsTimer: Timer?
    /// Recent partial word lists per channel, used to decide when a displayed word is settled.
    private var partialHistory: [Channel: [[String]]] = [:]
    /// Live separation of the far-end voices (nil when diarization is off).
    private var liveSpeakers: LiveSpeakers?
    /// Every far-end line with its voice, in call order (for the speaker tags).
    private var remoteVoiceSegments: [(voice: Int, start: Double, end: Double)] = []
    /// Voice guessed for far-end speech still in progress, by segment start.
    private var partialVoice: [Double: Int] = [:]
    private var peekedSegments: Set<Double> = []
    private var voiceNamesCancellable: AnyCancellable?

    private static let hostTimeToSeconds: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    private func seconds(fromHostTime hostTime: UInt64, sampleCount: Int) -> Double {
        // Host time refers to the *end* of a delivered buffer for the mic (AVAudioTime of the
        // buffer start) – close enough; subtract the buffer duration to get the start.
        let t = Double(Int64(hostTime) - Int64(sessionStartHostTime)) * RecordingCoordinator.hostTimeToSeconds
        return max(0, t - Double(sampleCount) / 16_000)
    }

    init(settings: AppSettings, state: AppState) {
        self.settings = settings
        self.state = state
    }

    // MARK: - Start

    func start() async {
        // Only from idle: while a stop is finalizing (title dialog, diarization) the state is
        // not "recording" either, and a second session would run into the first one's cleanup.
        guard state.phase == .idle else { return }
        state.lastError = nil
        state.phase = .starting
        // Let the menu bar pill expand on an idle main thread before the setup work starts.
        try? await Task.sleep(for: .milliseconds(300))

        do {
            if settings.captureMicrophone, !(await Permissions.requestMicrophone()) {
                Permissions.openMicrophoneSettings()
                throw NSError(domain: "Transcriber", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied. Allow Transcriber under Privacy & Security › Microphone."])
            }
            if settings.captureSystemAudio, !(await Permissions.requestSystemAudio()) {
                Permissions.openSystemAudioSettings()
                throw NSError(domain: "Transcriber", code: 4, userInfo: [NSLocalizedDescriptionKey: "System audio access denied. Allow Transcriber under Privacy & Security › Screen & System Audio Recording."])
            }
            try checkDiskSpace()
            let root = settings.outputDirectoryURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            // Models first – downloads on first run; normally already loaded by ModelCache at launch.
            await ModelManager.shared.refreshStatus()
            if !ModelManager.shared.asrStatus.isReady { await ModelManager.shared.downloadASR() }
            let engine = try await ModelCache.shared.engine(precision: ModelManager.shared.precision)
            let vad = try await ModelCache.shared.vad(threshold: Float(settings.vadThreshold))
            await ModelManager.shared.refreshStatus()
            self.engine = engine

            let store = try SessionStore(root: root, myName: settings.myName, otherName: settings.otherName, language: settings.languageCode)
            self.store = store
            store.registerAudioFiles(mic: settings.captureMicrophone, system: settings.captureSystemAudio)
            // A name typed into the floating bar lands in AppState; mirror it into the saved transcript.
            // Names typed for the current remote speaker are stored right away (crash recovery
            // finalizes with them too).
            speakerTagCancellable = state.$speakerTags
                .dropFirst()
                .sink { [weak store] tags in store?.setSpeakerTags(tags) }
            // A name typed for a voice covers all of its lines, the earlier ones too.
            voiceNamesCancellable = state.$voiceNames
                .dropFirst()
                .sink { [weak self] names in self?.refreshSpeakerTags(names: names) }
            muteCancellable = state.$muteIntervals
                .dropFirst()
                .sink { [weak store] spans in store?.setMuteIntervals(spans) }
            let language = settings.languageCode.isEmpty ? nil : settings.languageCode
            let myName = settings.myName
            let otherName = settings.otherName
            // The remote side is stored as "Speaker 1" (or the name typed for that voice); the
            // after-call diarization splits it into "Speaker 1", "Speaker 2", … Live, the voices
            // are told apart by `LiveSpeakers` and shown as "Speaker N" or their name.
            let remoteBase = "\(otherName) 1"
            let state = self.state
            state.otherName = otherName
            remoteVoiceSegments = []
            partialVoice = [:]
            peekedSegments = []
            let live: LiveSpeakers? = settings.captureSystemAudio && settings.diarizeRemote ? LiveSpeakers() : nil
            liveSpeakers = live
            if let live {
                Task.detached(priority: .utility) {
                    do { try await live.prepare() } catch { AppLog.write("Live speaker separation unavailable: \(error)") }
                }
            }

            let queue = TranscriptionQueue(engine: engine, language: language) { segment, result in
                if segment.channel == .them {
                    // One line per voice: a segment holding two far-end people is split at the change.
                    let parts = await live?.assignParts(segment.samples) ?? []
                    let lines = await MainActor.run { self.voiceLines(segment, result, parts: parts, remoteBase: remoteBase) }
                    for (entry, _) in lines { store.append(entry) }
                    await MainActor.run {
                        self.partialHistory[segment.channel] = nil
                        for (entry, voice) in lines {
                            state.appendLive(TranscriptLine(channel: .them, speaker: entry.speaker, text: entry.text, voice: voice, start: entry.start), channel: .them)
                        }
                    }
                    return
                }
                let label = myName
                let entry = TranscriptEntry(channel: segment.channel, speaker: label,
                                            start: segment.start, end: segment.end,
                                            text: result.text, confidence: result.confidence, createdAt: Date(),
                                            words: result.words.map { WordStamp(word: $0.word, start: segment.start + $0.startTime, end: segment.start + $0.endTime) })
                // Residual echo: drop a mic entry that repeats what the far end just said.
                if entry.channel == .me, store.entries.suffix(12).contains(where: { EchoDeduplicator.isEcho(entry, of: $0) }) {
                    NSLog("Dropped echo duplicate at \(entry.start)s (\(entry.text.count) chars)")
                    await MainActor.run {
                        self.partialHistory[segment.channel] = nil
                        state.clearPartial(channel: segment.channel)
                        state.retract(channel: segment.channel, start: segment.start)   // also words already shown sharp
                    }
                    return
                }
                store.append(entry)
                await MainActor.run {
                    self.partialHistory[segment.channel] = nil
                    state.appendLive(TranscriptLine(channel: segment.channel, speaker: label, text: result.text, start: segment.start), channel: segment.channel)
                }
            } onPartial: { segment, result in
                let recentThem = store.entries.suffix(12).filter { $0.channel == .them }
                // Once per far-end segment, after a few seconds of it: whose voice is this?
                var peeked: Int?
                if segment.channel == .them, let live, segment.samples.count >= 40_000,
                   await MainActor.run(body: { self.peekedSegments.insert(segment.start).inserted }) {
                    peeked = await live.peek(segment.samples)
                }
                await MainActor.run {
                    if let peeked {
                        self.partialVoice[segment.start] = peeked
                        state.currentVoice = peeked
                    }
                    let voice = segment.channel == .them ? self.partialVoice[segment.start] : nil
                    let label = segment.channel == .me ? myName : state.label(forVoice: voice)
                    // Residual echo shows up on the mic while the far end talks. Do not show such
                    // a partial at all (the final is dropped anyway) – otherwise the user's name
                    // keeps popping up although they are silent.
                    if segment.channel == .me {
                        let themPartial = state.partialLines[.them]
                        let echo = recentThem.contains { EchoDeduplicator.isEcho(meText: result.text, meStart: segment.start, themText: $0.text, themStart: $0.start, themEnd: $0.end) }
                            || themPartial.map { EchoDeduplicator.isEcho(meText: result.text, meStart: segment.start, themText: $0.text, themStart: $0.start, themEnd: nil) } == true
                        // While the far end is talking, wait until the mic text is long enough to be judged.
                        let farEndActive = themPartial != nil || recentThem.contains { segment.start <= $0.end + 1.5 && segment.start >= $0.start - 1.5 }
                        let tooShort = farEndActive && EchoDeduplicator.tokens(result.text).count < 3
                        if echo || tooShort {
                            self.partialHistory[.me] = nil
                            state.clearPartial(channel: .me)
                            return
                        }
                    }
                    // Display-only decision (the transcript file always uses the final pass).
                    // Accuracy over speed: a word turns sharp once it ended at least 2.5 s before
                    // the end of the audio and was identical (ignoring case / punctuation) in the
                    // last three partial passes – or once it ended 7 s before the end, whatever the
                    // history says. Everything newer stays blurred, often several lines, until the
                    // model has heard enough of the sentence (or the final pass arrives).
                    let words = result.text.split(separator: " ").map(String.init)
                    let normalized = words.map { $0.lowercased().filter(\.isLetter) }
                    var history = self.partialHistory[segment.channel] ?? []
                    if state.partialLines[segment.channel]?.start != segment.start { history = [] }
                    history.append(normalized)
                    if history.count > 3 { history.removeFirst(history.count - 3) }
                    self.partialHistory[segment.channel] = history
                    var stable = 0
                    let audioEnd = segment.end - segment.start
                    // Mic words stay blurred while the far end is talking: they may still turn out
                    // to be echo, and blurred words can simply vanish. They settle with the final.
                    let holdBack = segment.channel == .me && (state.partialLines[.them] != nil
                        || recentThem.contains { segment.start <= $0.end + 1.5 && segment.start >= $0.start - 1.5 })
                    while !holdBack, stable < min(words.count, result.words.count) {
                        let age = audioEnd - result.words[stable].endTime
                        let agreed = history.count == 3 && history.allSatisfy { stable < $0.count && $0[stable] == normalized[stable] }
                        guard age >= 7.0 || (age >= 2.5 && agreed) else { break }
                        stable += 1
                    }
                    state.updatePartial(TranscriptLine(channel: segment.channel, speaker: label, text: result.text, voice: voice, start: segment.start, stableWords: stable), channel: segment.channel)
                }
            } onEmptyFinal: { segment in
                // The segment ended without text – whatever partial was shown for it is stale.
                await MainActor.run {
                    self.partialHistory[segment.channel] = nil
                    state.clearPartial(channel: segment.channel)
                    state.retract(channel: segment.channel, start: segment.start)
                }
            }
            self.queue = queue

            let gate = (settings.captureMicrophone && settings.captureSystemAudio && settings.echoGate) ? EchoGate() : nil
            echoGate = gate
            sessionStartHostTime = mach_absolute_time()
            pausedLock.lock(); _paused = false; _micMuted = false; pausedSeconds = 0; pausedLock.unlock()
            micWritten = 0
            systemWritten = 0
            silentMicCallbacks = 0
            micRestartAttempts = 0
            AppLog.write("Recording start: mic=\(settings.captureMicrophone) system=\(settings.captureSystemAudio) gate=\(gate != nil) input=\(settings.inputDeviceUID.isEmpty ? "default (\(AudioDevices.defaultInputDevice()?.name ?? "-"))" : settings.inputDeviceUID) output=\(AudioDevices.defaultOutputDevice()?.name ?? "-")")

            if settings.captureMicrophone {
                let processor = await ChannelProcessor(channel: .me, vad: vad, threshold: Float(settings.vadThreshold),
                                                       onSegment: { await queue.submit($0) },
                                                       onPartial: { await queue.submit($0) })
                micProcessor = processor
                let wav = try WavWriter(url: store.micWavURL)
                micWav = wav
                let capture = MicrophoneCapture { [weak self] rawSamples, hostTime in
                    guard let self else { return }
                    self.noteMicBuffer()   // also while paused, so resuming does not look like a stall
                    guard !self.pausedFlag else { return }
                    self.watchMicSilence(rawSamples)
                    let t = self.seconds(fromHostTime: hostTime, sampleCount: 0)
                    // Muted: keep the channel's timeline running with silence, so mic and system
                    // audio stay aligned (echo removal, re-transcription, timestamps).
                    let muted = self.micMutedFlag
                    let input = muted ? [Float](repeating: 0, count: rawSamples.count) : rawSamples
                    let gap = self.gapFill(.me, written: &self.micWritten, bufferStart: t)
                    if !gap.isEmpty { wav.append(gap); Task { await processor.append(gap) } }
                    // The gate runs on the written-sample timeline, the one mic.wav and system.wav
                    // share. Host times of the two capture paths can be offset by more than the
                    // gate's delay search covers, which left it disabled for whole calls.
                    let samples = muted ? input : (gate?.processMic(input, at: Double(self.micWritten) / 16_000) ?? input)
                    self.micWritten += samples.count
                    wav.append(samples)
                    self.notePeak(mic: AudioResampler.peakRMS(samples))
                    Task { await processor.append(samples) }
                }
                let uid = settings.inputDeviceUID, aec = settings.echoCancellation
                try await offMain { try capture.start(deviceUID: uid, echoCancellation: aec) }
                mic = capture
                noteMicBuffer()   // baseline so the stall watchdog waits for the first buffer, not forever
                micStallRestarting = false
            }

            if settings.captureSystemAudio {
                let processor = await ChannelProcessor(channel: .them, vad: vad, threshold: Float(settings.vadThreshold),
                                                       onSegment: { await queue.submit($0) },
                                                       onPartial: { await queue.submit($0) })
                systemProcessor = processor
                let wav = try WavWriter(url: store.systemWavURL)
                systemWav = wav
                #if DEBUG
                // Debug aid: TRANSCRIBER_MUTE_TAP=8 swallows the tap's buffers for 8 s, as when a
                // call app's device switch leaves the tap dead, to exercise the stall watchdog.
                let deadUntil = Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["TRANSCRIBER_MUTE_TAP"] ?? "") ?? 0)
                #endif
                let capture = SystemAudioCapture { [weak self] samples, hostTime in
                    guard let self else { return }
                    #if DEBUG
                    if Date() < deadUntil { return }
                    #endif
                    self.noteSystemBuffer()
                    guard !self.pausedFlag else { return }
                    let t = self.seconds(fromHostTime: hostTime, sampleCount: 0)   // host time of the buffer's first frame
                    let gap = self.gapFill(.them, written: &self.systemWritten, bufferStart: t)
                    if !gap.isEmpty { wav.append(gap); Task { await processor.append(gap) } }
                    gate?.pushSystem(samples, at: Double(self.systemWritten) / 16_000)
                    self.systemWritten += samples.count
                    wav.append(samples)
                    self.notePeak(system: AudioResampler.peakRMS(samples))
                    Task { await processor.append(samples) }
                }
                try await offMain { try capture.start() }
                system = capture
                systemStartedAt = Date()   // the first buffer normally arrives within milliseconds
                systemStallRestarting = false
                systemRestartAttempts = 0
            }

            power = PowerAssertion(reason: "Transcriber is recording a call")
            installDeviceListeners()
            startTimers()

            if settings.soundEffects { NSSound(named: "Tink")?.play() }
            state.recordingStartedAt = Date()
            state.currentSessionURL = store.directory
            state.sessionClock = { [weak self] in
                guard let self else { return 0 }
                return self.systemWav?.durationSeconds ?? self.micWav?.durationSeconds ?? 0
            }
            state.phase = .recording
        } catch {
            AppLog.write("Recording start failed: \(error)")
            state.lastError = error.localizedDescription
            teardownCapture()
            store?.markComplete()
            store?.close()
            store = nil
            state.reset()
            if settings.soundEffects { NSSound(named: "Basso")?.play() }
        }
    }

    // MARK: - Pause

    /// Pausing keeps the audio engines running but drops their output, so resuming is
    /// instant. Paused time is not part of the transcript timeline.
    func togglePause() {
        guard case .recording = state.phase else { return }
        state.isPaused.toggle()
        let now = mach_absolute_time()
        pausedLock.lock()
        _paused = state.isPaused
        if state.isPaused {
            pauseStartedHost = now
        } else if pauseStartedHost != 0 {
            pausedSeconds += Double(now - pauseStartedHost) * RecordingCoordinator.hostTimeToSeconds
        }
        pausedLock.unlock()
        AppLog.write(state.isPaused ? "Paused" : "Resumed")
        if state.isPaused { state.pushLevel(mic: 0, system: 0) }
    }

    private var isPaused: Bool { state.isPaused }

    /// Silence for audio a channel failed to deliver: the system tap starts late or is rebuilt,
    /// a microphone restart takes a moment. Without it the channel's timeline (sample count) falls
    /// behind the clock and the other channel – echo removal, names typed in the pill and mute
    /// phases would then point at the wrong moment. Called on that channel's audio thread.
    private func gapFill(_ channel: Channel, written: inout Int, bufferStart: Double) -> [Float] {
        pausedLock.lock(); let paused = pausedSeconds; pausedLock.unlock()
        let missing = Int(((bufferStart - paused) - Double(written) / 16_000) * 16_000)
        guard missing > 4_800 else { return [] }           // tolerate < 0.3 s of jitter
        let gap = min(missing, 16_000 * 600)
        written += gap
        if gap >= 16_000 { AppLog.write(String(format: "%@ delivered no audio for %.1f s – filled with silence", channel == .me ? "Microphone" : "System audio", Double(gap) / 16_000)) }
        return [Float](repeating: 0, count: gap)
    }

    // MARK: - Mute

    /// Mutes the microphone channel: it keeps recording silence (so both channels stay aligned),
    /// and only the system audio is transcribed until it is unmuted.
    func toggleMicMute() {
        guard state.isRecording, settings.captureMicrophone else { return }
        state.isMicMuted.toggle()
        pausedLock.lock(); _micMuted = state.isMicMuted; pausedLock.unlock()
        AppLog.write(state.isMicMuted ? "Microphone muted" : "Microphone unmuted")
        let now = state.sessionClock?() ?? 0
        if state.isMicMuted {
            state.muteIntervals.append(TimeSpan(start: now, end: nil))
        } else if let i = state.muteIntervals.indices.last, state.muteIntervals[i].end == nil {
            state.muteIntervals[i].end = now
        }
        if state.isMicMuted {
            partialHistory[.me] = nil
            state.clearPartial(channel: .me)
        }
    }

    // MARK: - Far-end voices

    /// Turns a finished far-end segment into transcript entries, one per voice part, and records
    /// the voices. Words go to the part their middle falls into; a part with fewer than three
    /// words joins its neighbour (boundaries are not that exact).
    private func voiceLines(_ segment: ChannelProcessor.Segment, _ result: TranscribedSegment, parts: [LiveSpeakers.Part],
                            remoteBase: String) -> [(TranscriptEntry, Int?)] {
        let guessed = partialVoice.removeValue(forKey: segment.start)
        peekedSegments.remove(segment.start)
        let words = result.words.map { WordStamp(word: $0.word, start: segment.start + $0.startTime, end: segment.start + $0.endTime) }
        var groups: [(match: LiveSpeakers.Match?, words: [WordStamp])] = []
        if parts.count > 1, !words.isEmpty {
            for w in words {
                let mid = (w.start + w.end) / 2 - segment.start
                let part = parts.first { mid < $0.end } ?? parts.last!
                if let last = groups.last, last.match?.voice == part.match.voice {
                    groups[groups.count - 1].words.append(w)
                } else {
                    groups.append((part.match, [w]))
                }
            }
            var merged: [(match: LiveSpeakers.Match?, words: [WordStamp])] = []
            for g in groups {
                if g.words.count < 3, !merged.isEmpty { merged[merged.count - 1].words += g.words; continue }
                if let last = merged.last, last.match?.voice == g.match?.voice { merged[merged.count - 1].words += g.words; continue }
                merged.append(g)
            }
            if merged.count > 1, merged[0].words.count < 3 { merged[1].words.insert(contentsOf: merged[0].words, at: 0); merged.removeFirst() }
            groups = merged
        }
        if groups.count <= 1 {
            let main = parts.max { $0.end - $0.start < $1.end - $1.start }?.match
            groups = [(main, words)]
        }
        var out: [(TranscriptEntry, Int?)] = []
        for g in groups {
            let single = groups.count == 1
            let start = single ? segment.start : g.words.first!.start
            let end = single ? segment.end : g.words.last!.end
            let voice = noteVoice(g.match, guessed: guessed, start: start, end: end)
            let text = single ? result.text : WordText.join(g.words.map(\.word))
            let label = voice.flatMap { state.voiceNames[$0] } ?? remoteBase
            out.append((TranscriptEntry(channel: .them, speaker: label, start: start, end: end, text: text,
                                        confidence: result.confidence, createdAt: Date(), words: g.words.isEmpty ? nil : g.words), voice))
        }
        return out
    }

    /// Records the voice of a finished far-end line (main actor). Without a confident match the
    /// line goes to the voice guessed while it was spoken, else to the previous far-end voice.
    private func noteVoice(_ match: LiveSpeakers.Match?, guessed: Int?, start: Double, end: Double) -> Int? {
        guard let voice = match?.voice ?? guessed ?? state.currentVoice ?? (liveSpeakers == nil ? 1 : nil) else { return nil }
        state.currentVoice = voice
        remoteVoiceSegments.append((voice, start, end))
        if let match, match.isNew { AppLog.write(String(format: "Live voice %d heard first at %.0f s", voice, start)) }
        if let match, match.seconds >= 6, state.voiceNumbers[voice] == nil {
            state.voiceNumbers[voice] = (state.voiceNumbers.values.max() ?? 0) + 1
        }
        if let match, match.seconds >= 8, state.voiceNames[voice] == nil, let live = liveSpeakers {
            Task { await self.matchRememberedVoice(voice, live: live) }
        }
        if state.voiceNames[voice] != nil { refreshSpeakerTags(names: state.voiceNames) }
        return voice
    }

    /// Names a voice after a remembered one (Settings › Transcription › voices) when it sounds
    /// like it. The after-call pass decides again with the whole call.
    private func matchRememberedVoice(_ voice: Int, live: LiveSpeakers) async {
        guard let centroid = await live.centroid(of: voice), state.voiceNames[voice] == nil else { return }
        let taken = Set(state.voiceNames.values)
        let best = VoiceLibrary.shared.voices
            .filter { !taken.contains($0.name) }
            .map { ($0.name, RemoteDiarizer.cosine(centroid, $0.embedding)) }
            .max { $0.1 < $1.1 }
        guard let (name, sim) = best, sim >= VoiceLibrary.matchThreshold, state.isRecording else { return }
        AppLog.write(String(format: "Live voice %d sounds like %@ (%.2f)", voice, name, sim))
        state.autoNamedVoices.insert(voice)
        state.voiceNames[voice] = name
    }

    /// One speaker tag per run of lines of a voice the user named (names that only came from a
    /// remembered voice are left out, so they are never learned back).
    private func refreshSpeakerTags(names: [Int: String]) {
        var tags: [SpeakerTag] = []
        var lastVoice: Int?
        for seg in remoteVoiceSegments {
            defer { lastVoice = seg.voice }
            guard let name = names[seg.voice], !state.autoNamedVoices.contains(seg.voice) else { continue }
            if lastVoice == seg.voice, let i = tags.indices.last, tags[i].name == name {
                tags[i].end = seg.end
            } else {
                tags.append(SpeakerTag(name: name, start: seg.start, end: seg.end))
            }
        }
        if tags != state.speakerTags { state.speakerTags = tags }
    }

    // MARK: - Stop

    func stop() async {
        guard state.isRecording, let store else { return }
        state.phase = .stopping("Finishing transcription…")
        if let i = state.muteIntervals.indices.last, state.muteIntervals[i].end == nil {
            state.muteIntervals[i].end = state.sessionClock?() ?? 0
        }
        AppLog.write("Recording stop: mic=\(Int(micWav?.durationSeconds ?? 0))s system=\(Int(systemWav?.durationSeconds ?? 0))s")
        await teardownCaptureAsync()

        await micProcessor?.finish()
        await systemProcessor?.finish()
        await queue?.drain()
        micProcessor = nil
        systemProcessor = nil
        queue = nil

        if let echoGate { AppLog.write("EchoGate final: \(echoGate.stats)") }
        echoGate = nil
        AppLog.write("Transcription drained: \(store.entries.count) entries")
        await RecordingFinalizer.finish(store: store, settings: settings, state: state, askTitle: settings.askForTitle)
        self.store = nil
        engine = nil
        liveSpeakers = nil
        // Same at the end: nothing else should run on the main thread while the pill shrinks.
        await Task.yield()
        state.reset()
    }

    /// Like teardownCapture, but stops the audio engines off the main thread – AVAudioEngine
    /// and the Core Audio tap block for a noticeable moment, which would stutter the UI.
    private func teardownCaptureAsync() async {
        let mic = self.mic, system = self.system
        self.mic = nil; self.system = nil
        await offMain { mic?.stop(); system?.stop() }
        teardownCapture()
    }

    private func teardownCapture() {
        levelTimer?.invalidate(); levelTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        diskTimer?.invalidate(); diskTimer = nil
        speakerTagCancellable = nil
        voiceNamesCancellable = nil
        muteCancellable = nil
        deviceListeners = []
        mic?.stop(); mic = nil
        system?.stop(); system = nil
        micWav?.close(); micWav = nil
        systemWav?.close(); systemWav = nil
        power = nil
    }

    /// Runs blocking audio setup / teardown on a background thread.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
    private func offMain(_ work: @escaping @Sendable () -> Void) async {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    // MARK: - Microphone watchdog

    /// Counts consecutive all-zero microphone buffers; after ~5 s the engine is restarted
    /// (a device switch or voice-processing hiccup can leave AVAudioEngine delivering silence).
    private func watchMicSilence(_ samples: [Float]) {
        let silent = !samples.contains { $0 != 0 }
        if !silent {
            silentMicCallbacks = 0
            // The mic is delivering real audio again; give any future glitch a fresh set of
            // restart attempts instead of exhausting the lifetime budget on one recovered hiccup.
            if micRestartAttempts != 0 {
                DispatchQueue.main.async { [weak self] in self?.micRestartAttempts = 0 }
            }
            return
        }
        silentMicCallbacks += 1
        guard silentMicCallbacks == 50 else { return }   // ~5 s of buffers at 100 ms
        silentMicCallbacks = 0
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state.isRecording else { return }
            self.micRestartAttempts += 1
            AppLog.write("Microphone delivered only silence for 5 s (attempt \(self.micRestartAttempts)) – restarting input engine")
            if self.micRestartAttempts <= 3 {
                self.restartMicrophone(useDefault: self.micRestartAttempts >= 2)
            } else if self.micRestartAttempts == 4 {
                self.state.lastError = "Microphone delivers silence. Check the input device in Settings › Audio and the system microphone permission."
            }
        }
    }

    /// Records that the microphone just delivered a buffer (any content). Thread-safe:
    /// called from the Core Audio thread.
    private func noteMicBuffer() {
        levelLock.lock(); micBufferAt = Date(); levelLock.unlock()
    }

    /// Detects the input engine going completely silent at the *transport* level – no buffers
    /// arriving at all (device reconfigured, aggregate torn down, voice-processing unit stalled).
    /// The per-buffer `watchMicSilence` cannot see this because it only runs when a buffer is
    /// delivered. Runs on the main thread from the level timer.
    private func checkMicStall() {
        guard settings.captureMicrophone, state.isRecording, !state.isPaused,
              let mic, mic.isRunning, !micStallRestarting else { return }
        levelLock.lock(); let last = micBufferAt; levelLock.unlock()
        guard let last, Date().timeIntervalSince(last) > 4.0 else { return }
        micStallRestarting = true
        noteMicBuffer()   // reset the clock so we wait out the restart before judging again
        micRestartAttempts += 1
        AppLog.write("Microphone stopped delivering buffers for 4 s (attempt \(micRestartAttempts)) – restarting input engine")
        if micRestartAttempts <= 3 {
            restartMicrophone(useDefault: micRestartAttempts >= 2)
        } else if micRestartAttempts == 4 {
            state.lastError = "Microphone stopped delivering audio. Check the input device in Settings › Audio and the system microphone permission."
        }
    }

    private func noteSystemBuffer() {
        levelLock.lock(); systemBufferAt = Date(); levelLock.unlock()
    }

    /// Rebuilds the system tap when something plays but no buffers arrive: after 3 s, then every
    /// 3 s for the first attempts and every 10 s after that, for as long as the recording runs.
    /// The tap is silent (no buffers at all) whenever nothing plays, so silence alone means
    /// nothing.
    private func checkSystemStall() {
        guard settings.captureSystemAudio, state.isRecording, !state.isPaused,
              let system, !systemStallRestarting else { return }
        levelLock.lock(); let buffer = systemBufferAt; levelLock.unlock()
        let now = Date()
        let silent = now.timeIntervalSince(max(buffer ?? .distantPast, systemStartedAt))
        if systemRestartAttempts > 0, let buffer, buffer > systemStartedAt {
            AppLog.write("System audio is coming through again")
            systemRestartAttempts = 0
            if state.lastError?.hasPrefix("System audio") == true { state.lastError = nil }
            return
        }
        guard silent > (systemRestartAttempts < 3 ? 3.0 : 10.0),
              now.timeIntervalSince(systemPlaybackCheckedAt) >= 1 else { return }
        systemPlaybackCheckedAt = now
        let playback = system.playbackState()
        guard !playback.playing.isEmpty else {
            // Nothing plays: the silence is real. A later failure starts with fresh attempts.
            systemRestartAttempts = 0
            return
        }
        systemRestartAttempts += 1
        let names = (playback.untapped.isEmpty ? playback.playing : playback.untapped).prefix(4).map { SystemAudioCapture.processName($0) }.joined(separator: ", ")
        AppLog.write(String(format: "System audio: %@ playing (%@) but no buffers for %.0f s (attempt %d) – rebuilding the tap",
                            playback.untapped.isEmpty ? "tapped process" : "untapped process", names, silent, systemRestartAttempts))
        if systemRestartAttempts == 3 {
            state.lastError = "System audio is not coming through – retrying. Reconnect Audio in the menu bar menu tries again right away."
        }
        restartSystemAudio(delay: 0)
    }

    /// Manual "Reconnect Audio": restarts the microphone and rebuilds the system tap.
    func reconnectAudio() {
        guard state.isRecording else { return }
        AppLog.write("Reconnect Audio requested")
        if settings.captureMicrophone, mic != nil {
            micStallRestarting = true
            restartMicrophone()
        }
        if settings.captureSystemAudio, system != nil { restartSystemAudio(delay: 0) }
    }

    // MARK: - Levels

    private func notePeak(mic: Float? = nil, system: Float? = nil) {
        levelLock.lock()
        if let mic { micPeak = max(micPeak ?? 0, mic) }
        if let system { systemPeak = max(systemPeak ?? 0, system) }
        levelLock.unlock()
    }

    private func startTimers() {
        shownMic = 0; shownSystem = 0
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, !self.state.isPaused else { return }
            self.levelLock.lock()
            let m = self.micPeak, s = self.systemPeak
            self.micPeak = nil; self.systemPeak = nil
            self.levelLock.unlock()
            // The mic delivers a buffer only every ~100 ms, i.e. every third tick: between buffers
            // the meter holds and decays instead of dropping to zero (which made the user's
            // voice look like a flicker next to the far end's continuous system audio).
            self.shownMic = m.map { AudioResampler.displayLevel(rms: $0) } ?? self.shownMic * 0.8
            self.shownSystem = s.map { AudioResampler.displayLevel(rms: $0) } ?? self.shownSystem * 0.8
            self.state.pushLevel(mic: self.shownMic, system: self.shownSystem)
            self.checkMicStall()
            self.checkSystemStall()
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            AppLog.write("Status: mic=\(Int(self.micWav?.durationSeconds ?? 0))s system=\(Int(self.systemWav?.durationSeconds ?? 0))s levels mic=\(String(format: "%.2f", self.state.micLevel)) sys=\(String(format: "%.2f", self.state.systemLevel)) gate=\(self.echoGate?.stats ?? "off")")
        }
        diskTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if (try? self.checkDiskSpace()) == nil {
                self.state.lastError = "Disk almost full – stopping recording."
                Task { await self.stop() }
            }
        }
    }

    // MARK: - Device changes (AirPods connect, headset unplugged, …)

    private func installDeviceListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        deviceListeners = [
            AudioPropertyListener(objectID: systemObject, selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                self?.restartMicrophone()
            },
            AudioPropertyListener(objectID: systemObject, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.restartSystemAudio()
            },
            AudioPropertyListener(objectID: systemObject, selector: kAudioHardwarePropertyDevices) { [weak self] in
                // A device came or went; if our chosen input vanished fall back to default.
                guard let self, let mic = self.mic, mic.isRunning else { return }
                if !self.settings.inputDeviceUID.isEmpty, AudioDevices.device(forUID: self.settings.inputDeviceUID) == nil {
                    self.restartMicrophone(useDefault: true)
                }
            },
        ]
    }

    private func restartMicrophone(useDefault: Bool = false) {
        guard let mic, state.isRecording else { return }
        // Only follow the system default when the user has not pinned a device.
        let uid = useDefault || settings.inputDeviceUID.isEmpty ? "" : settings.inputDeviceUID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.state.isRecording else { return }
            do {
                try mic.start(deviceUID: uid, echoCancellation: self.settings.echoCancellation)
                self.noteMicBuffer()   // give the fresh engine a full grace window to produce its first buffer
                self.micStallRestarting = false
                AppLog.write("Microphone restarted on \(uid.isEmpty ? "default input (\(AudioDevices.defaultInputDevice()?.name ?? "-"))" : uid)")
            } catch {
                self.micStallRestarting = false
                AppLog.write("Microphone restart failed: \(error)")
                self.state.lastError = "Microphone restart failed: \(error.localizedDescription)"
            }
        }
    }

    private func restartSystemAudio(delay: TimeInterval = 0.5) {
        guard let system, state.isRecording else { return }
        systemStallRestarting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            defer {
                self.systemStartedAt = Date()   // a full grace window for the rebuilt tap
                self.systemStallRestarting = false
            }
            guard self.state.isRecording else { return }
            do {
                try system.start()
                AppLog.write("System audio restarted on \(AudioDevices.defaultOutputDevice()?.name ?? "-")")
            } catch {
                AppLog.write("System audio restart failed: \(error)")
                self.state.lastError = "System audio restart failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Disk

    private func checkDiskSpace() throws {
        let url = settings.outputDirectoryURL
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, Double(free) < settings.minFreeDiskGB * 1e9 {
            throw NSError(domain: "Transcriber", code: 2, userInfo: [NSLocalizedDescriptionKey: "Less than \(Int(settings.minFreeDiskGB)) GB free on the transcript volume."])
        }
    }
}
