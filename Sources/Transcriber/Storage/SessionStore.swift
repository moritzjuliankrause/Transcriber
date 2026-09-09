import Foundation

/// A transcript entry as persisted to transcript.jsonl (one JSON object per line).
struct TranscriptEntry: Codable, Sendable {
    var channel: Channel
    var speaker: String          // resolved display label
    var start: Double
    var end: Double
    var text: String
    var confidence: Float
    var createdAt: Date
    /// Word-level timings (absolute session seconds), used to split an entry
    /// when diarization finds a speaker change inside it.
    var words: [WordStamp]?
}

struct WordStamp: Codable, Sendable {
    var word: String
    var start: Double
    var end: Double
}

struct SessionMeta: Codable {
    enum Status: String, Codable { case recording, finalizing, complete }
    var id: String
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var status: Status
    var myName: String
    var otherName: String
    var language: String
    var micWav: String?
    var systemWav: String?
    var appVersion: String
    /// Custom display names entered for remote speakers, keyed by base label ("Speaker 1", …).
    /// Optional for backward compatibility with sessions written before this existed.
    var speakerNames: [String: String]?
}

/// Owns one recording session folder:
///   session.json      – metadata + status (recording / complete)
///   transcript.jsonl  – append-only, fsync'ed per entry (crash safe)
///   transcript.md     – re-rendered after every entry
///   mic.wav / system.wav – raw 16 kHz audio (deleted later if "keep audio" is off)
final class SessionStore {
    let directory: URL
    private(set) var meta: SessionMeta
    private(set) var entries: [TranscriptEntry] = []
    private let jsonlHandle: FileHandle
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let lock = NSLock()

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    /// Creates a new session folder inside `root`.
    init(root: URL, myName: String, otherName: String, language: String) throws {
        let start = Date()
        let folderName = SessionStore.dateFormatter.string(from: start)
        var dir = root.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = root.appendingPathComponent("\(folderName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        meta = SessionMeta(id: UUID().uuidString, title: "", startedAt: start, endedAt: nil, status: .recording,
                           myName: myName, otherName: otherName, language: language,
                           micWav: nil, systemWav: nil,
                           appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        let jsonl = dir.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: jsonl.path, contents: nil)
        jsonlHandle = try FileHandle(forWritingTo: jsonl)
        try writeMeta()
    }

    /// Re-opens an existing session folder (recovery).
    init(existing directory: URL) throws {
        self.directory = directory
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        meta = try decoder.decode(SessionMeta.self, from: Data(contentsOf: directory.appendingPathComponent("session.json")))
        let jsonl = directory.appendingPathComponent("transcript.jsonl")
        if !FileManager.default.fileExists(atPath: jsonl.path) {
            FileManager.default.createFile(atPath: jsonl.path, contents: nil)
        }
        let text = (try? String(contentsOf: jsonl, encoding: .utf8)) ?? ""
        entries = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(TranscriptEntry.self, from: Data(line.utf8))
        }
        jsonlHandle = try FileHandle(forWritingTo: jsonl)
        try jsonlHandle.seekToEnd()
    }

    var micWavURL: URL { directory.appendingPathComponent("mic.wav") }
    var systemWavURL: URL { directory.appendingPathComponent("system.wav") }

    func registerAudioFiles(mic: Bool, system: Bool) {
        meta.micWav = mic ? "mic.wav" : nil
        meta.systemWav = system ? "system.wav" : nil
        try? writeMeta()
    }

    /// Appends an entry, fsyncs the JSONL file and re-renders the Markdown.
    func append(_ entry: TranscriptEntry) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
        if let data = try? encoder.encode(entry) {
            try? jsonlHandle.write(contentsOf: data + Data("\n".utf8))
            try? jsonlHandle.synchronize()
        }
        renderMarkdownLocked()
    }

    /// Replaces every entry (after diarization relabelling) and rewrites files.
    func replaceEntries(_ newEntries: [TranscriptEntry]) {
        lock.lock(); defer { lock.unlock() }
        entries = newEntries.sorted { $0.start < $1.start }
        var blob = Data()
        for e in entries {
            if let d = try? encoder.encode(e) { blob.append(d); blob.append(Data("\n".utf8)) }
        }
        let jsonl = directory.appendingPathComponent("transcript.jsonl")
        try? blob.write(to: jsonl, options: .atomic)
        try? jsonlHandle.seekToEnd()
        renderMarkdownLocked()
    }

    func setTitle(_ title: String) {
        meta.title = title
        try? writeMeta()
        lock.lock(); renderMarkdownLocked(); lock.unlock()
    }

    /// Stores the custom speaker names for this recording and re-renders the Markdown so the
    /// saved transcript shows them. Keys are base labels ("Speaker 1", …); blank values are dropped.
    func setSpeakerNames(_ names: [String: String]) {
        let cleaned = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        meta.speakerNames = cleaned.isEmpty ? nil : cleaned
        try? writeMeta()
        lock.lock(); renderMarkdownLocked(); lock.unlock()
    }

    func markFinalizing() {
        meta.status = .finalizing
        try? writeMeta()
    }

    func markComplete() {
        meta.status = .complete
        meta.endedAt = meta.endedAt ?? Date()
        try? writeMeta()
        lock.lock(); renderMarkdownLocked(); lock.unlock()
    }

    func close() {
        try? jsonlHandle.synchronize()
        try? jsonlHandle.close()
    }

    /// Latest transcribed timestamp per channel – used by recovery to know where to resume.
    func lastEnd(for channel: Channel) -> Double {
        entries.filter { $0.channel == channel }.map(\.end).max() ?? 0
    }

    // MARK: - Files

    private func writeMeta() throws {
        let data = try encoder.encode(meta)
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func renderMarkdownLocked() {
        let md = TranscriptExporter.markdown(meta: meta, entries: entries.sorted { $0.start < $1.start })
        try? md.data(using: .utf8)?.write(to: directory.appendingPathComponent("transcript.md"), options: .atomic)
    }

    func exportExtras(json: Bool, srt: Bool) {
        let sorted = entries.sorted { $0.start < $1.start }
        if json {
            let payload = TranscriptExporter.JSONDocument(session: meta, entries: sorted)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(payload).write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
        }
        if srt {
            try? TranscriptExporter.srt(entries: sorted, names: meta.speakerNames).data(using: .utf8)?
                .write(to: directory.appendingPathComponent("transcript.srt"), options: .atomic)
        }
    }

    /// Renames the folder to include the title (called at the very end).
    func renameFolderIfNeeded() -> URL {
        let title = meta.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return directory }
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*|\"<>")).joined(separator: "-")
        let base = SessionStore.dateFormatter.string(from: meta.startedAt)
        let target = directory.deletingLastPathComponent().appendingPathComponent("\(base) \(safe)", isDirectory: true)
        guard target != directory, !FileManager.default.fileExists(atPath: target.path) else { return directory }
        do {
            try FileManager.default.moveItem(at: directory, to: target)
            return target
        } catch {
            return directory
        }
    }
}
