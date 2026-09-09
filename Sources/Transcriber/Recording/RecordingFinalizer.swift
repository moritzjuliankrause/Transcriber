import AppKit
import Foundation

/// Shared end-of-session steps for live stop and crash recovery:
/// diarize the remote channel, relabel, export extras, optional title, cleanup.
enum RecordingFinalizer {
    @MainActor
    static func finish(store: SessionStore, settings: AppSettings, state: AppState, askTitle: Bool) async {
        store.markFinalizing()

        // Offline re-pass: re-transcribe the kept audio in long context windows and replace the
        // live transcript before dedup / diarization run on it. Same model as live, but each word
        // is decoded in the surrounding sentence instead of as an isolated VAD fragment.
        if settings.reTranscribeOffline {
            await reTranscribe(store: store, settings: settings, state: state)
        }

        // Text-level echo removal over the whole session (order of arrival does not matter here).
        let deduped = EchoDeduplicator.dedupe(store.entries)
        if deduped.count != store.entries.count {
            NSLog("Removed \(store.entries.count - deduped.count) echo duplicates")
            store.replaceEntries(deduped)
        }

        // Speaker diarization on the remote (system audio) channel. Skipped when live diarization
        // already labelled speakers during the call, so its labels (and the names mapped to them)
        // are not overwritten by a second, differently-numbered pass.
        if settings.diarizeRemote, !settings.liveDiarization,
           FileManager.default.fileExists(atPath: store.systemWavURL.path),
           store.entries.contains(where: { $0.channel == .them }) {
            state.phase = .stopping("Identifying speakers…")
            do {
                let spans = try await RemoteDiarizer.diarize(wavURL: store.systemWavURL) { p in
                    Task { @MainActor in state.phase = .stopping("Identifying speakers… \(Int(p * 100))%") }
                }
                // Only keep speakers that hold a meaningful share of the talk time; pyannote tends
                // to split one voice into two on long 1:1 calls. Minor speakers merge into the main one.
                var duration: [String: Double] = [:]
                for span in spans { duration[span.speaker, default: 0] += span.end - span.start }
                let total = duration.values.reduce(0, +)
                let major = duration.filter { $0.value >= total * 0.15 }.keys.sorted { duration[$0]! > duration[$1]! }
                if major.count > 1, let dominant = major.first {
                    var names: [String: String] = [:]
                    for (i, speaker) in major.enumerated() { names[speaker] = "\(settings.otherName) \(i + 1)" }
                    for speaker in duration.keys where names[speaker] == nil { names[speaker] = names[dominant]! }
                    let merged = spans.map { RemoteDiarizer.SpeakerSpan(speaker: names[$0.speaker]!, start: $0.start, end: $0.end) }
                    let identity = Dictionary(uniqueKeysWithValues: Set(names.values).map { ($0, $0) })
                    store.replaceEntries(RemoteDiarizer.relabel(store.entries, spans: merged, names: identity))
                }
            } catch {
                NSLog("Diarization skipped: \(error)")
            }
        }

        if settings.guessSpeakerNames {
            let remote = Set(store.entries.filter { $0.channel == .them }.map(\.speaker))
            let names = SpeakerNameGuesser.guess(entries: store.entries, myName: settings.myName, remoteLabels: remote)
            if !names.isEmpty {
                AppLog.write("Guessed speaker names for \(names.count) remote label(s)")
                store.replaceEntries(SpeakerNameGuesser.relabel(store.entries, names: names))
            }
        }

        // Offer the call's remote speakers for naming in the title prompt, in order of appearance.
        var remote: [String] = []
        for e in store.entries where e.channel == .them && !remote.contains(e.speaker) { remote.append(e.speaker) }
        state.remoteSpeakers = remote

        var openInAI = false
        if askTitle {
            state.phase = .stopping("Waiting for title…")
            let answer = await TitlePrompt.ask(defaultTitle: "")
            if let title = answer.title { store.setTitle(title) }
            openInAI = answer.openInAI
        }
        // Persist any names entered live or in the title prompt (coordinator's live mirror is gone by now).
        store.setSpeakerNames(state.speakerNames)

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

    /// Re-runs ASR over each channel's kept WAV with long context windows and replaces the live
    /// entries. Keeps the original transcript if anything fails (the live pass is never worse).
    @MainActor
    private static func reTranscribe(store: SessionStore, settings: AppSettings, state: AppState) async {
        // The remote label must match the live path ("\(otherName) 1"), so a name the user typed
        // during the call (keyed by that base label) still applies after the re-pass replaces entries.
        let channels: [(Channel, URL, String)] = [
            (.me, store.micWavURL, settings.myName),
            (.them, store.systemWavURL, "\(settings.otherName) 1"),
        ].filter { FileManager.default.fileExists(atPath: $0.1.path) }
        guard !channels.isEmpty else { return }
        state.phase = .stopping("Re-transcribing…")
        do {
            let engine = try await ModelCache.shared.engine(precision: ModelManager.shared.precision)
            let language = settings.languageCode.isEmpty ? nil : settings.languageCode
            var entries: [TranscriptEntry] = []
            for (channel, url, speaker) in channels {
                let samples = (try? WavWriter.readSamples(url: url)) ?? []
                guard !samples.isEmpty else { continue }
                entries += try await OfflineRetranscribe.run(samples: samples, channel: channel,
                                                             speaker: speaker, language: language, engine: engine)
            }
            entries.sort { $0.start < $1.start }
            guard !entries.isEmpty else {
                AppLog.write("Offline re-pass produced no entries – keeping the live transcript")
                return
            }
            AppLog.write("Offline re-pass: \(store.entries.count) live → \(entries.count) entries")
            store.replaceEntries(entries)
        } catch {
            AppLog.write("Offline re-pass failed, keeping live transcript: \(error)")
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
