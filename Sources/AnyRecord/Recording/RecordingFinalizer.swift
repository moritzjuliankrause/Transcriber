import AppKit
import Foundation

/// Shared end-of-session steps for live stop and crash recovery:
/// diarize the remote channel, relabel, export extras, optional title, cleanup.
enum RecordingFinalizer {
    @MainActor
    static func finish(store: SessionStore, settings: AppSettings, state: AppState, askTitle: Bool) async {
        store.markFinalizing()

        // Text-level echo removal over the whole session (order of arrival does not matter here).
        let deduped = EchoDeduplicator.dedupe(store.entries)
        if deduped.count != store.entries.count {
            NSLog("Removed \(store.entries.count - deduped.count) echo duplicates")
            store.replaceEntries(deduped)
        }

        // Speaker diarization on the remote (system audio) channel.
        if settings.diarizeRemote, FileManager.default.fileExists(atPath: store.systemWavURL.path),
           store.entries.contains(where: { $0.channel == .them }) {
            state.phase = .stopping("Identifying speakers…")
            do {
                let spans = try await RemoteDiarizer.diarize(wavURL: store.systemWavURL, maxSpeakers: settings.maxRemoteSpeakers) { p in
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

        if askTitle {
            state.phase = .stopping("Waiting for title…")
            if let title = TitlePrompt.ask(defaultTitle: "") {
                store.setTitle(title)
            }
        }

        store.exportExtras(json: settings.exportJSON, srt: settings.exportSRT)
        store.markComplete()
        store.close()

        if !settings.keepAudio {
            try? FileManager.default.removeItem(at: store.micWavURL)
            try? FileManager.default.removeItem(at: store.systemWavURL)
        }
        let finalURL = store.renameFolderIfNeeded()
        state.currentSessionURL = finalURL
        NSSound(named: "Glass")?.play()
    }
}

enum TitlePrompt {
    @MainActor
    static func ask(defaultTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Name this recording"
        alert.informativeText = "Optional. Used for the folder name and the transcript heading."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Skip")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. Weekly sync with Anna"
        field.stringValue = defaultTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
