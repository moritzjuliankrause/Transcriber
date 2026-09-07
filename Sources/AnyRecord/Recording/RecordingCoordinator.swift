import AppKit
import AVFoundation
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
    private var levelTimer: Timer?
    private var micPeak: Float = 0
    private var systemPeak: Float = 0
    private let levelLock = NSLock()
    private var diskTimer: Timer?
    private var echoGate: EchoGate?
    /// Mirror of state.isPaused readable from audio threads.
    private let pausedLock = NSLock()
    private var _paused = false
    private var pausedFlag: Bool { pausedLock.lock(); defer { pausedLock.unlock() }; return _paused }
    private var sessionStartHostTime: UInt64 = 0
    private var silentMicCallbacks = 0
    private var micRestartAttempts = 0
    private var statsTimer: Timer?
    /// Recent partial word lists per channel, used to decide when a displayed word is settled.
    private var partialHistory: [Channel: [[String]]] = [:]

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
        guard !state.isRecording else { return }
        state.lastError = nil
        state.phase = .starting

        do {
            if settings.captureMicrophone, !(await Permissions.requestMicrophone()) {
                Permissions.openMicrophoneSettings()
                throw NSError(domain: "AnyRecord", code: 3, userInfo: [NSLocalizedDescriptionKey: "Microphone access denied. Allow AnyRecord under Privacy & Security › Microphone."])
            }
            if settings.captureSystemAudio, !(await Permissions.requestSystemAudio()) {
                Permissions.openSystemAudioSettings()
                throw NSError(domain: "AnyRecord", code: 4, userInfo: [NSLocalizedDescriptionKey: "System audio access denied. Allow AnyRecord under Privacy & Security › Screen & System Audio Recording."])
            }
            try checkDiskSpace()
            let root = settings.outputDirectoryURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            // Models first – downloads on first run.
            let engine = FluidAudioEngine(precision: ModelManager.shared.precision)
            await ModelManager.shared.refreshStatus()
            if !ModelManager.shared.asrStatus.isReady { await ModelManager.shared.downloadASR() }
            try await engine.prepare()
            let vad = try await VadManagerFactory.make(threshold: Float(settings.vadThreshold))
            await ModelManager.shared.refreshStatus()
            self.engine = engine

            let store = try SessionStore(root: root, myName: settings.myName, otherName: settings.otherName, language: settings.languageCode)
            self.store = store
            store.registerAudioFiles(mic: settings.captureMicrophone, system: settings.captureSystemAudio)
            let language = settings.languageCode.isEmpty ? nil : settings.languageCode
            let myName = settings.myName
            let otherName = settings.otherName
            let state = self.state

            let queue = TranscriptionQueue(engine: engine, language: language) { segment, result in
                let label = segment.channel == .me ? myName : otherName
                let entry = TranscriptEntry(channel: segment.channel, speaker: label,
                                            start: segment.start, end: segment.end,
                                            text: result.text, confidence: result.confidence, createdAt: Date(),
                                            words: result.words.map { WordStamp(word: $0.word, start: segment.start + $0.startTime, end: segment.start + $0.endTime) })
                // Residual echo: drop a mic entry that repeats what the far end just said.
                if entry.channel == .me, store.entries.suffix(12).contains(where: { EchoDeduplicator.isEcho(entry, of: $0) }) {
                    NSLog("Dropped echo duplicate at \(entry.start)s: \(entry.text)")
                    return
                }
                store.append(entry)
                await MainActor.run {
                    self.partialHistory[segment.channel] = nil
                    state.appendLive(TranscriptLine(speaker: label, text: result.text, start: segment.start), channel: segment.channel)
                }
            } onPartial: { segment, result in
                let label = segment.channel == .me ? myName : otherName
                await MainActor.run {
                    // Display-only decision (the transcript file always uses the final pass):
                    // a word counts as settled once it was identical in the last three partial
                    // passes (1.5 s) *and* ended at least 2 s before the end of the audio.
                    let words = result.text.split(separator: " ").map(String.init)
                    var history = self.partialHistory[segment.channel] ?? []
                    if let first = history.first, first.isEmpty || segment.start != (state.partialLines[segment.channel]?.start ?? segment.start) { history = [] }
                    if state.partialLines[segment.channel]?.start != segment.start { history = [] }
                    history.append(words)
                    if history.count > 3 { history.removeFirst(history.count - 3) }
                    self.partialHistory[segment.channel] = history
                    var stable = 0
                    if history.count == 3 {
                        let audioEnd = segment.end - segment.start
                        while stable < words.count,
                              history.allSatisfy({ stable < $0.count && $0[stable] == words[stable] }),
                              stable < result.words.count, audioEnd - result.words[stable].endTime >= 2.0 {
                            stable += 1
                        }
                    }
                    state.updatePartial(TranscriptLine(speaker: label, text: result.text, start: segment.start, stableWords: stable), channel: segment.channel)
                }
            }
            self.queue = queue

            let gate = (settings.captureMicrophone && settings.captureSystemAudio && settings.echoGate) ? EchoGate() : nil
            echoGate = gate
            sessionStartHostTime = mach_absolute_time()
            pausedLock.lock(); _paused = false; pausedLock.unlock()
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
                    guard let self, !self.pausedFlag else { return }
                    self.watchMicSilence(rawSamples)
                    let t = self.seconds(fromHostTime: hostTime, sampleCount: 0)
                    let samples = gate?.processMic(rawSamples, at: t) ?? rawSamples
                    wav.append(samples)
                    self.notePeak(mic: AudioResampler.rms(samples))
                    Task { await processor.append(samples) }
                }
                try capture.start(deviceUID: settings.inputDeviceUID, echoCancellation: settings.echoCancellation)
                mic = capture
            }

            if settings.captureSystemAudio {
                let processor = await ChannelProcessor(channel: .them, vad: vad, threshold: Float(settings.vadThreshold),
                                                       onSegment: { await queue.submit($0) },
                                                       onPartial: { await queue.submit($0) })
                systemProcessor = processor
                let wav = try WavWriter(url: store.systemWavURL)
                systemWav = wav
                let capture = SystemAudioCapture { [weak self] samples, hostTime in
                    guard let self, !self.pausedFlag else { return }
                    gate?.pushSystem(samples, at: self.seconds(fromHostTime: hostTime, sampleCount: samples.count))
                    wav.append(samples)
                    self.notePeak(system: AudioResampler.rms(samples))
                    Task { await processor.append(samples) }
                }
                try capture.start()
                system = capture
            }

            power = PowerAssertion(reason: "AnyRecord is recording a call")
            installDeviceListeners()
            startTimers()

            if settings.playStartTone { NSSound(named: "Tink")?.play() }
            state.recordingStartedAt = Date()
            state.currentSessionURL = store.directory
            state.phase = .recording
        } catch {
            AppLog.write("Recording start failed: \(error)")
            state.lastError = error.localizedDescription
            teardownCapture()
            store?.markComplete()
            store?.close()
            store = nil
            state.reset()
            NSSound(named: "Basso")?.play()
        }
    }

    // MARK: - Pause

    /// Pausing keeps the audio engines running but drops their output, so resuming is
    /// instant. Paused time is not part of the transcript timeline.
    func togglePause() {
        guard case .recording = state.phase else { return }
        state.isPaused.toggle()
        pausedLock.lock(); _paused = state.isPaused; pausedLock.unlock()
        AppLog.write(state.isPaused ? "Paused" : "Resumed")
        if state.isPaused { state.pushLevel(mic: 0, system: 0) }
    }

    private var isPaused: Bool { state.isPaused }

    // MARK: - Stop

    func stop() async {
        guard state.isRecording, let store else { return }
        state.phase = .stopping("Finishing transcription…")
        AppLog.write("Recording stop: mic=\(Int(micWav?.durationSeconds ?? 0))s system=\(Int(systemWav?.durationSeconds ?? 0))s")
        teardownCapture()

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
        state.reset()
    }

    private func teardownCapture() {
        levelTimer?.invalidate(); levelTimer = nil
        statsTimer?.invalidate(); statsTimer = nil
        diskTimer?.invalidate(); diskTimer = nil
        deviceListeners = []
        mic?.stop(); mic = nil
        system?.stop(); system = nil
        micWav?.close(); micWav = nil
        systemWav?.close(); systemWav = nil
        power = nil
    }

    // MARK: - Microphone watchdog

    /// Counts consecutive all-zero microphone buffers; after ~5 s the engine is restarted
    /// (a device switch or voice-processing hiccup can leave AVAudioEngine delivering silence).
    private func watchMicSilence(_ samples: [Float]) {
        let silent = !samples.contains { $0 != 0 }
        if !silent { silentMicCallbacks = 0; return }
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

    // MARK: - Levels

    private func notePeak(mic: Float? = nil, system: Float? = nil) {
        levelLock.lock()
        if let mic { micPeak = max(micPeak, mic) }
        if let system { systemPeak = max(systemPeak, system) }
        levelLock.unlock()
    }

    private func startTimers() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, !self.state.isPaused else { return }
            self.levelLock.lock()
            let m = self.micPeak, s = self.systemPeak
            self.micPeak = 0; self.systemPeak = 0
            self.levelLock.unlock()
            self.state.pushLevel(mic: AudioResampler.displayLevel(rms: m), system: AudioResampler.displayLevel(rms: s))
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
                AppLog.write("Microphone restarted on \(uid.isEmpty ? "default input (\(AudioDevices.defaultInputDevice()?.name ?? "-"))" : uid)")
            } catch {
                AppLog.write("Microphone restart failed: \(error)")
                self.state.lastError = "Microphone restart failed: \(error.localizedDescription)"
            }
        }
    }

    private func restartSystemAudio() {
        guard let system, state.isRecording else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.state.isRecording else { return }
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
            throw NSError(domain: "AnyRecord", code: 2, userInfo: [NSLocalizedDescriptionKey: "Less than \(Int(settings.minFreeDiskGB)) GB free on the transcript volume."])
        }
    }
}
