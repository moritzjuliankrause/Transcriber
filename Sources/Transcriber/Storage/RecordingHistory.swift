import AppKit
import Foundation
import FluidAudio

/// One recording folder as shown in Settings › Recordings.
struct RecordingInfo: Identifiable, Equatable {
    var id: String { directory.path }
    let directory: URL
    let title: String
    let startedAt: Date
    let duration: TimeInterval?
    let status: SessionMeta.Status
    /// Bytes of mic.wav + system.wav still on disk (0 = no audio left).
    let audioBytes: Int64
    /// When the kept audio will be deleted automatically, nil = never (or no audio).
    let audioDeletedAt: Date?

    var hasAudio: Bool { audioBytes > 0 }
}

/// The list of past recordings, re-transcribing them, importing audio files, and deleting audio
/// once its retention period is over.
@MainActor
final class RecordingHistory: ObservableObject {
    static let shared = RecordingHistory()

    @Published private(set) var recordings: [RecordingInfo] = []
    /// Recordings being processed right now (folder → status text).
    @Published private(set) var busy: [URL: String] = [:]
    /// An import in progress (status text), shown above the list.
    @Published private(set) var importStatus: String?
    @Published var lastError: String?

    static let audioExtensions = ["wav", "m4a", "mp3", "aiff", "aif", "caf", "aac", "mp4", "mov", "m4v", "flac"]

    // MARK: - Listing

    func reload(settings: AppSettings) {
        let root = settings.outputDirectoryURL
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        recordings = dirs.compactMap { dir in
            guard let meta = SessionStore.readMeta(in: dir) else { return nil }
            let bytes = ["mic.wav", "system.wav"].reduce(Int64(0)) { sum, name in
                let size = (try? dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sum + Int64(size)
            }
            let ended = meta.endedAt ?? meta.startedAt
            let deletesAt = settings.audioRetentionDays.map { ended.addingTimeInterval(Double($0) * 86_400) }
            return RecordingInfo(directory: dir,
                                 title: meta.title,
                                 startedAt: meta.startedAt,
                                 duration: meta.endedAt.map { $0.timeIntervalSince(meta.startedAt) },
                                 status: meta.status,
                                 audioBytes: bytes,
                                 audioDeletedAt: bytes > 0 ? deletesAt : nil)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Re-transcribing

    /// Runs a finished recording through the after-call pipeline again with the current settings:
    /// long-window transcription of the kept audio, echo removal, speaker separation, the names
    /// typed during the call and remembered voices. Names given in the transcript before are
    /// carried over by time, so speakers keep their names although the numbering may change.
    func reTranscribe(_ recording: RecordingInfo, settings: AppSettings) async {
        let dir = recording.directory
        guard busy[dir] == nil, recording.hasAudio, recording.status == .complete else { return }
        busy[dir] = "Preparing…"
        defer { busy[dir] = nil; reload(settings: settings) }
        do {
            let store = try SessionStore(existing: dir)
            let carried = RecordingHistory.namesAsTags(store.entries, names: store.meta.speakerNames ?? [:], otherName: store.meta.otherName)
            store.setSpeakerNames([:])      // old "Speaker N" numbering does not survive a new pass
            try await run(store: store, settings: settings, extraTags: carried)
            AppLog.write("Re-transcribed \(dir.lastPathComponent): \(store.entries.count) entries")
        } catch {
            lastError = "Re-transcribing failed: \(error.localizedDescription)"
            AppLog.write("Re-transcribe failed for \(dir.lastPathComponent): \(error)")
        }
    }

    /// Imports an audio file as a new recording (its own folder, the audio kept as system.wav so
    /// every voice in it is separated) and transcribes it.
    func importAudio(_ url: URL, settings: AppSettings, root: URL? = nil) async {
        guard importStatus == nil else { return }
        importStatus = "Reading \(url.lastPathComponent)…"
        defer { importStatus = nil; reload(settings: settings) }
        do {
            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioConverter().resampleAudioFile(url)
            }.value
            guard samples.count > 16_000 else { throw NSError(domain: "Transcriber", code: 10, userInfo: [NSLocalizedDescriptionKey: "The file contains less than a second of audio."]) }
            let store = try SessionStore(root: root ?? settings.outputDirectoryURL, myName: settings.myName,
                                         otherName: settings.otherName, language: settings.languageCode)
            let wav = try WavWriter(url: store.systemWavURL)
            wav.append(samples)
            wav.close()
            store.registerAudioFiles(mic: false, system: true)
            store.setTitle(url.deletingPathExtension().lastPathComponent)
            store.setDuration(Double(samples.count) / 16_000)
            reload(settings: settings)
            busy[store.directory] = "Transcribing…"
            importStatus = nil
            defer { busy[store.directory] = nil }
            try await run(store: store, settings: settings, extraTags: [])
            let final = store.renameFolderIfNeeded()
            AppLog.write("Imported \(url.lastPathComponent) → \(final.lastPathComponent): \(store.entries.count) entries")
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
            AppLog.write("Import of \(url.lastPathComponent) failed: \(error)")
        }
    }

    private func run(store: SessionStore, settings: AppSettings, extraTags: [SpeakerTag]) async throws {
        let dir = store.directory
        store.markFinalizing()
        // Its own engine instance, so this can run next to a live recording without sharing a
        // decoder with it.
        busy[dir] = "Loading models…"
        await ModelManager.shared.refreshStatus()
        if !ModelManager.shared.asrStatus.isReady { await ModelManager.shared.downloadASR() }
        let engine = FluidAudioEngine(precision: ModelManager.shared.precision)
        try await engine.prepare()
        let labelled = await RecordingFinalizer.process(store: store, settings: settings, retranscribe: true,
                                                        engine: engine, extraTags: extraTags) { [weak self] status in
            self?.busy[dir] = status
        }
        RecordingFinalizer.learnVoices(labelled, names: [:], settings: settings)
        store.exportExtras(json: settings.exportJSON, srt: settings.exportSRT)
        store.markComplete()
        store.close()
    }

    /// Remote lines that already carry a real name (typed, remembered, or given when saving)
    /// become name tags for the new pass, so the names follow the voices.
    static func namesAsTags(_ entries: [TranscriptEntry], names: [String: String], otherName: String) -> [SpeakerTag] {
        entries.compactMap { e in
            guard e.channel == .them else { return nil }
            let name = names[e.speaker].flatMap { $0.isEmpty ? nil : $0 } ?? e.speaker
            let generic = name == otherName || name.hasPrefix(otherName + " ") && Int(name.dropFirst(otherName.count + 1)) != nil
            guard !generic, !name.contains("[") else { return nil }
            return SpeakerTag(name: name, start: e.start, end: e.end)
        }
    }

    // MARK: - Audio

    func deleteAudio(_ recording: RecordingInfo, settings: AppSettings) {
        guard busy[recording.directory] == nil else { return }
        RecordingHistory.removeAudio(in: recording.directory)
        reload(settings: settings)
    }

    private static func removeAudio(in dir: URL) {
        for name in ["mic.wav", "system.wav"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        SessionStore.updateMeta(in: dir) { $0.micWav = nil; $0.systemWav = nil }
    }

    /// Deletes the audio of finished recordings older than the retention period. Never touches a
    /// recording that is still running or being finalized.
    @discardableResult
    func sweepExpiredAudio(settings: AppSettings) -> Int {
        guard let days = settings.audioRetentionDays else { return 0 }
        let root = settings.outputDirectoryURL
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for dir in dirs where busy[dir] == nil {
            guard let meta = SessionStore.readMeta(in: dir), meta.status == .complete,
                  (meta.endedAt ?? meta.startedAt) < cutoff else { continue }
            let hasAudio = ["mic.wav", "system.wav"].contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
            guard hasAudio else { continue }
            RecordingHistory.removeAudio(in: dir)
            removed += 1
        }
        if removed > 0 {
            AppLog.write("Audio retention: deleted the audio of \(removed) recording(s) older than \(days) days")
            reload(settings: settings)
        }
        return removed
    }
}
