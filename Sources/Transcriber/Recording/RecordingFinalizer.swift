import AppKit
import Foundation

/// Shared end-of-session steps for live stop, crash recovery and re-transcribing a recording
/// from the history: re-transcribe, remove echo, diarize the remote channel and name its voices,
/// optional title, exports, cleanup.
enum RecordingFinalizer {
    @MainActor
    static func finish(store: SessionStore, settings: AppSettings, state: AppState, askTitle: Bool) async {
        store.markFinalizing()
        let labelled = await process(store: store, settings: settings, retranscribe: settings.reTranscribeOffline) {
            state.phase = .stopping($0)
        }

        var openInAI = false
        if askTitle {
            state.phase = .stopping("Waiting for title…")
            let answer = await TitlePrompt.ask(defaultTitle: "")
            if let title = answer.title { store.setTitle(title) }
            openInAI = answer.openInAI
        }
        learnVoices(labelled, names: [:], settings: settings)

        store.exportExtras(json: settings.exportJSON, srt: settings.exportSRT)
        store.markComplete()
        store.close()

        if !settings.keepAudio {
            try? FileManager.default.removeItem(at: store.micWavURL)
            try? FileManager.default.removeItem(at: store.systemWavURL)
        }
        let finalURL = store.renameFolderIfNeeded()
        state.currentSessionURL = finalURL
        if settings.soundEffects { NSSound(named: "Glass")?.play() }
        if openInAI { AITool.open(session: finalURL) }
    }

    /// The transcript-improving steps, without any UI: optional long-window re-transcription,
    /// echo removal, diarization + naming (tags, remembered voices), name guessing. Reports
    /// progress as short status texts. Returns the diarization outcome, if it ran.
    @MainActor
    static func process(store: SessionStore, settings: AppSettings, retranscribe: Bool,
                        engine: TranscriptionEngine? = nil, extraTags: [SpeakerTag] = [],
                        progress: @escaping @MainActor (String) -> Void) async -> RemoteDiarizer.Labelled? {
        // Offline re-pass: re-transcribe the kept audio in long context windows and replace the
        // live transcript before dedup / diarization run on it. Same model as live, but each word
        // is decoded in the surrounding sentence instead of as an isolated VAD fragment.
        if retranscribe {
            await reTranscribe(store: store, settings: settings, engine: engine, progress: progress)
        }

        // Text-level echo removal over the whole session (order of arrival does not matter here).
        let deduped = EchoDeduplicator.dedupe(store.entries)
        if deduped.count != store.entries.count {
            NSLog("Removed \(store.entries.count - deduped.count) echo duplicates")
            store.replaceEntries(deduped)
        }

        // Speaker diarization on the remote (system audio) channel, then the names the user gave
        // during the call and the remembered voices are matched to the voices it found.
        let tags = (store.meta.speakerTags ?? []) + extraTags
        var labelled: RemoteDiarizer.Labelled?
        if settings.diarizeRemote,
           FileManager.default.fileExists(atPath: store.systemWavURL.path),
           store.entries.contains(where: { $0.channel == .them }) {
            progress("Identifying speakers…")
            do {
                let result = try await RemoteDiarizer.diarize(wavURL: store.systemWavURL) { p in
                    Task { @MainActor in progress("Identifying speakers… \(Int(p * 100))%") }
                }
                let sessionEnd = store.entries.map(\.end).max() ?? 0
                let known = settings.rememberVoices ? VoiceLibrary.shared.voices.map { (name: $0.name, embedding: $0.embedding) } : []
                let l = RemoteDiarizer.label(result, tags: tags, knownVoices: known, otherName: settings.otherName, sessionEnd: sessionEnd)
                AppLog.write("Diarization: \(l.summary); \(tags.count) name tag(s), \(known.count) remembered voice(s)")
                if !l.spans.isEmpty {
                    let identity = Dictionary(uniqueKeysWithValues: Set(l.spans.map(\.speaker)).map { ($0, $0) })
                    store.replaceEntries(RemoteDiarizer.relabel(store.entries, spans: l.spans, names: identity))
                    VoiceLibrary.shared.markHeard(l.namedByVoice)
                    labelled = l
                }
            } catch {
                AppLog.write("Diarization skipped: \(error)")
            }
        }
        if labelled == nil, !tags.isEmpty {
            store.replaceEntries(RemoteDiarizer.applyTags(store.entries, tags: tags))
        }

        if settings.guessSpeakerNames {
            let remote = Set(store.entries.filter { $0.channel == .them }.map(\.speaker))
            let names = SpeakerNameGuesser.guess(entries: store.entries, myName: settings.myName, remoteLabels: remote)
            if !names.isEmpty {
                AppLog.write("Guessed speaker names for \(names.count) remote label(s)")
                store.replaceEntries(SpeakerNameGuesser.relabel(store.entries, names: names))
            }
        }
        return labelled
    }

    /// Remembers the voices the user named in this recording (typed in the pill, or carried over
    /// when re-transcribing). Needs enough speech for a reliable voice print.
    @MainActor
    static func learnVoices(_ labelled: RemoteDiarizer.Labelled?, names: [String: String], settings: AppSettings) {
        guard settings.rememberVoices, let labelled else { return }
        var learned: [String] = []
        for (label, embedding) in labelled.embeddings where (labelled.talkTime[label] ?? 0) >= 8 {
            let typed = names[label].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            guard let name = typed ?? (labelled.namedByTag.contains(label) ? label : nil) else { continue }
            VoiceLibrary.shared.learn(name: name, embedding: embedding)
            learned.append(name)
        }
        if !learned.isEmpty { AppLog.write("Remembered voices: \(learned.joined(separator: ", "))") }
    }

    /// Re-runs ASR over each channel's kept WAV with long context windows and replaces the live
    /// entries. Keeps the original transcript if anything fails (the live pass is never worse).
    @MainActor
    private static func reTranscribe(store: SessionStore, settings: AppSettings, engine: TranscriptionEngine?,
                                     progress: @escaping @MainActor (String) -> Void) async {
        // The remote label must match the live path ("\(otherName) 1"), so a name the user typed
        // during the call (keyed by that base label) still applies after the re-pass replaces entries.
        let channels: [(Channel, URL, String)] = [
            (.me, store.micWavURL, store.meta.myName),
            (.them, store.systemWavURL, "\(store.meta.otherName) 1"),
        ].filter { FileManager.default.fileExists(atPath: $0.1.path) }
        guard !channels.isEmpty else { return }
        progress("Re-transcribing…")
        do {
            let asr: TranscriptionEngine
            if let engine { asr = engine } else { asr = try await ModelCache.shared.engine(precision: ModelManager.shared.precision) }
            let language = settings.languageCode.isEmpty ? nil : settings.languageCode
            var entries: [TranscriptEntry] = []
            for (index, (channel, url, speaker)) in channels.enumerated() {
                let samples = (try? WavWriter.readSamples(url: url)) ?? []
                guard !samples.isEmpty else { continue }
                entries += try await OfflineRetranscribe.run(samples: samples, channel: channel,
                                                             speaker: speaker, language: language, engine: asr) { p in
                    let overall = (Double(index) + p) / Double(channels.count)
                    Task { @MainActor in progress("Re-transcribing… \(Int(overall * 100))%") }
                }
            }
            entries.sort { $0.start < $1.start }
            guard !entries.isEmpty else {
                AppLog.write("Offline re-pass produced no entries – keeping the transcript")
                return
            }
            AppLog.write("Offline re-pass: \(store.entries.count) → \(entries.count) entries")
            store.replaceEntries(entries)
        } catch {
            AppLog.write("Offline re-pass failed, keeping transcript: \(error)")
        }
    }
}

enum TitlePrompt {
    struct Answer {
        var title: String?
        var openInAI: Bool
    }

    /// Asks inside the floating bar; falls back to an alert when there is no bar (headless runs).
    @MainActor
    static func ask(defaultTitle: String) async -> Answer {
        if let bar = FloatingBarController.shared {
            return await bar.askTitle(defaultTitle: defaultTitle)
        }
        return askWithAlert(defaultTitle: defaultTitle)
    }

    @MainActor
    static func askWithAlert(defaultTitle: String) -> Answer {
        // Never nest modal sessions: a second alert on top of a running one leaves the first
        // unresponsive (and the app must be force-quit). Save without a title instead.
        guard NSApp.modalWindow == nil else {
            AppLog.write("Title prompt skipped: another modal dialog is open")
            return Answer(title: nil, openInAI: false)
        }
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = "Optional. Used for the folder name and the transcript heading."
        alert.addButton(withTitle: "Save")
        if AITool.isConfigured {
            alert.addButton(withTitle: "Save & Open in \(AITool.toolDisplayName)")
        }
        alert.addButton(withTitle: "Skip")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. Weekly sync with Anna"
        field.stringValue = defaultTitle
        alert.accessoryView = field
        alert.layout()                                   // the window exists only after layout
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        // A menu bar app is not active when the dialog appears; activation and the modal
        // session start asynchronously, so claim focus a few times during the first moments.
        for delay in [0.0, 0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Only while this alert is the modal window – never re-show a dismissed one.
                guard NSApp.modalWindow == alert.window else { return }
                alert.window.makeKeyAndOrderFront(nil)
                alert.window.makeFirstResponder(field)
            }
        }
        let response = alert.runModal()
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = text.isEmpty ? nil : text
        switch response {
        case .alertFirstButtonReturn: return Answer(title: title, openInAI: false)
        case .alertSecondButtonReturn where AITool.isConfigured: return Answer(title: title, openInAI: true)
        default: return Answer(title: nil, openInAI: false)
        }
    }
}
