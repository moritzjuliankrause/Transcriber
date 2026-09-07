import Foundation
import AppKit
import FluidAudio

/// Finds sessions left in "recording" state (app crash, power loss) and offers to
/// finalize them: transcribe any audio that had not been processed yet, render
/// the Markdown and mark the session complete.
enum SessionRecovery {
    struct IncompleteSession: Identifiable, Equatable {
        let id: String
        let directory: URL
        let startedAt: Date
    }

    static func findIncomplete(in root: URL) -> [IncompleteSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return items.compactMap { dir in
            let metaURL = dir.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(SessionMeta.self, from: data),
                  meta.status != .complete else { return nil }
            return IncompleteSession(id: meta.id, directory: dir, startedAt: meta.startedAt)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    @MainActor
    static func checkOnLaunch(settings: AppSettings, state: AppState) async {
        let found = findIncomplete(in: settings.outputDirectoryURL)
        state.pendingRecovery = found
        guard !found.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Unfinished recording found"
        alert.informativeText = "\(found.count) recording(s) were not closed properly (crash or forced quit). The transcript up to that point is already saved. Finalize now to transcribe any remaining audio and render the final files?"
        alert.addButton(withTitle: "Finalize")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            await finalizeAll(found, settings: settings, state: state)
        }
    }

    @MainActor
    static func finalizeAll(_ sessions: [IncompleteSession], settings: AppSettings, state: AppState) async {
        for session in sessions {
            state.phase = .stopping("Recovering \(SessionStore.dateFormatter.string(from: session.startedAt))…")
            do {
                try await finalize(session, settings: settings, state: state)
            } catch {
                state.lastError = "Recovery failed: \(error.localizedDescription)"
            }
        }
        state.phase = .idle
        state.pendingRecovery = findIncomplete(in: settings.outputDirectoryURL)
    }

    @MainActor
    static func finalize(_ session: IncompleteSession, settings: AppSettings, state: AppState) async throws {
        let store = try SessionStore(existing: session.directory)
        store.markFinalizing()

        let engine = FluidAudioEngine(precision: ModelManager.shared.precision)
        try await engine.prepare()
        let vad = try await VadManagerFactory.make(threshold: Float(settings.vadThreshold))
        let language = settings.languageCode.isEmpty ? nil : settings.languageCode

        // Transcribe the tail of each channel that has no entries yet.
        for (channel, url, label) in [(Channel.me, store.micWavURL, store.meta.myName), (Channel.them, store.systemWavURL, store.meta.otherName)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let samples = try WavWriter.readSamples(url: url)
            let resumeAt = store.lastEnd(for: channel)
            let startIndex = min(samples.count, Int(resumeAt * 16_000))
            let tail = Array(samples[startIndex...])
            guard tail.count > 16_000 / 2 else { continue }

            let queue = TranscriptionQueue(engine: engine, language: language) { segment, result in
                store.append(TranscriptEntry(channel: channel, speaker: label,
                                             start: segment.start + resumeAt, end: segment.end + resumeAt,
                                             text: result.text, confidence: result.confidence, createdAt: Date(),
                                            words: result.words.map { WordStamp(word: $0.word, start: segment.start + $0.startTime, end: segment.start + $0.endTime) }))
            }
            let processor = await ChannelProcessor(channel: channel, vad: vad, threshold: Float(settings.vadThreshold)) { seg in
                await queue.submit(seg)
            }
            var offset = 0
            while offset < tail.count {
                let end = min(tail.count, offset + 16_000)
                await processor.append(Array(tail[offset..<end]))
                offset = end
            }
            await processor.finish()
            await queue.drain()
        }

        await RecordingFinalizer.finish(store: store, settings: settings, state: state, askTitle: false)
    }
}

enum VadManagerFactory {
    static func make(threshold: Float) async throws -> VadManager {
        try await VadManager(config: VadConfig(defaultThreshold: threshold))
    }
}
