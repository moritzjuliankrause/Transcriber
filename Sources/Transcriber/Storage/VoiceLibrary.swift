import Foundation
import Combine

/// A voice the user named in an earlier recording.
struct RememberedVoice: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// Running average of the voice's speaker embeddings (one per recording it was named in).
    var embedding: [Float]
    /// How many recordings contributed to the embedding.
    var recordings: Int
    var firstHeard: Date
    var lastHeard: Date
}

/// Voices remembered across recordings, so a speaker named once is recognised in later calls.
///
/// Only voices the user named themselves are learned (a name typed in the pill, or given in the
/// save prompt); automatic matches are never fed back, so one wrong match cannot spread. Only the
/// embedding is stored – a few hundred numbers describing the voice, not audio – in
/// `~/Library/Application Support/Transcriber/voices.json`. Every voice can be forgotten in
/// Settings › Transcription.
@MainActor
final class VoiceLibrary: ObservableObject {
    static let shared = VoiceLibrary()

    @Published private(set) var voices: [RememberedVoice] = []

    /// Minimum cosine similarity between a call's cluster and a remembered voice to reuse its name.
    /// Same-speaker centroids from the diarizer typically land well above this, different people
    /// well below; set conservatively because a wrong name is worse than a "Speaker 3".
    nonisolated static let matchThreshold: Float = 0.72

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voices.json")
    }()

    private init() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([RememberedVoice].self, from: data) {
            voices = saved
        }
    }

    /// Learns (or refines) the voice for a name the user gave.
    func learn(name: String, embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        let unit = VoiceLibrary.normalized(embedding)
        if let i = voices.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
           voices[i].embedding.count == unit.count {
            // Weighted running average, capped so the voice can still follow slow changes
            // (another microphone, a cold).
            let w = Float(min(voices[i].recordings, 9))
            voices[i].embedding = VoiceLibrary.normalized(zip(voices[i].embedding, unit).map { ($0 * w + $1) / (w + 1) })
            voices[i].recordings += 1
            voices[i].lastHeard = Date()
        } else {
            voices.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            voices.append(RememberedVoice(name: name, embedding: unit, recordings: 1, firstHeard: Date(), lastHeard: Date()))
        }
        save()
    }

    func forget(_ voice: RememberedVoice) {
        voices.removeAll { $0.id == voice.id }
        save()
    }

    func forgetAll() {
        voices = []
        save()
    }

    /// Notes that remembered voices were recognised in a recording.
    func markHeard(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        for i in voices.indices where names.contains(voices[i].name) { voices[i].lastHeard = Date() }
        save()
    }

    private func save() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(voices) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    nonisolated static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}
