import Foundation
import FluidAudio

/// Live separation of the far-end voices on the system channel.
///
/// Every finished remote speech segment gets one voice embedding (the same pyannote/VBx
/// embedding model as the after-call diarization, so it can also be compared with remembered
/// voices) and is matched against the voices heard so far in this call. The result is a stable
/// voice id per segment: names typed in the pill are attached to a voice, not to a stretch of
/// time, so naming one person never names whoever talks next.
///
/// Decisions are made with no future context, so they are less exact than the after-call pass,
/// which still runs and has the final word in the saved transcript.
actor LiveSpeakers {
    struct Voice {
        let id: Int
        var centroid: [Float]
        var seconds: Double
    }

    /// A segment's voice; `similarity` is the cosine to the matched voice (1 for a new one).
    struct Match {
        let voice: Int
        let isNew: Bool
        let similarity: Float
        /// Talk time of the voice so far, this segment included.
        var seconds: Double = 0
    }

    private var manager: OfflineDiarizerManager?
    private(set) var voices: [Voice] = []
    /// Cosine to an existing voice that still counts as the same person.
    private let sameThreshold: Float
    /// Shortest segment that may open a new voice (short clips give noisy embeddings).
    private let minNewSeconds: Double

    init(sameThreshold: Float = 0.45, minNewSeconds: Double = 2.5) {
        self.sameThreshold = sameThreshold
        self.minNewSeconds = minNewSeconds
    }

    /// Loads the diarization models (downloads them the first time). Safe to call repeatedly.
    func prepare() async throws {
        guard manager == nil else { return }
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels()
        manager = m
    }

    /// A stretch of a segment spoken by one voice; times in seconds from the segment start.
    struct Part {
        var start: Double
        var end: Double
        let match: Match
    }

    /// The voices in a 16 kHz clip: per speaker the diarizer finds in it, the time ranges and an
    /// embedding. Empty when the clip is too short or holds no detectable speech.
    private func speakers(in samples: [Float]) async -> [(embedding: [Float], seconds: Double, spans: [(Double, Double)])] {
        guard let manager, samples.count >= 16_000 else { return [] }
        let duration = Double(samples.count) / 16_000
        // The model looks at 10 s windows; a short clip padded with silence comes out sounding
        // like every other short clip (they clustered together whoever spoke). Repeating the
        // clip to fill the window keeps the embedding about the voice.
        var clip = samples
        while clip.count < 160_000 { clip += samples.prefix(160_000 - clip.count) }
        guard let result = try? await manager.process(audio: clip) else { return [] }
        var sums: [String: [Float]] = [:]
        var talk: [String: Double] = [:]
        var spans: [String: [(Double, Double)]] = [:]
        for s in result.segments where !s.embedding.isEmpty {
            let unit = VoiceLibrary.normalized(s.embedding).map { $0 * s.durationSeconds }
            sums[s.speakerId] = sums[s.speakerId].map { zip($0, unit).map { $0 + $1 } } ?? unit
            // Times beyond the real clip belong to the repeats.
            let a = Double(s.startTimeSeconds), b = min(Double(s.endTimeSeconds), duration)
            guard b > a else { continue }
            talk[s.speakerId, default: 0] += b - a
            spans[s.speakerId, default: []].append((a, b))
        }
        return sums.compactMap { id, sum in
            guard let seconds = talk[id], seconds > 0 else { return nil }
            return (VoiceLibrary.normalized(sum), seconds, spans[id] ?? [])
        }.sorted { $0.seconds > $1.seconds }
    }

    /// The embedding of the dominant voice in a clip.
    func embedding(of samples: [Float]) async -> [Float]? {
        await speakers(in: samples).first?.embedding
    }

    /// Assigns a segment to a voice. Returns nil when it cannot be judged (too short or no
    /// embedding and no voice yet) – the caller keeps showing the previous label then.
    func assign(_ samples: [Float]) async -> Match? {
        await assignParts(samples).max { $0.end - $0.start < $1.end - $1.start }?.match
    }

    /// Assigns a segment to voices. A segment normally is one person's turn, but in a quick
    /// exchange the far end's pause detection can cut two people into one segment: when the
    /// diarizer hears a second voice with enough speech (a sentence, not a "ja" over someone
    /// else), the segment is split into parts, each with its own voice.
    func assignParts(_ samples: [Float]) async -> [Part] {
        let duration = Double(samples.count) / 16_000
        let found = await speakers(in: samples)
        guard let main = found.first else { return [] }
        let others = duration >= 5 ? found.dropFirst().filter { $0.seconds >= 2 } : []
        guard !others.isEmpty else {
            return assign(embedding: main.embedding, duration: duration).map { [Part(start: 0, end: duration, match: $0)] } ?? []
        }
        var parts: [Part] = []
        for speaker in [main] + others {
            guard let match = assign(embedding: speaker.embedding, duration: speaker.seconds) else { continue }
            parts += speaker.spans.map { Part(start: $0.0, end: $0.1, match: match) }
        }
        parts.sort { $0.start < $1.start }
        // Merge neighbours of the same voice; the parts then tile the segment without gaps.
        var merged: [Part] = []
        for part in parts {
            if let last = merged.last, part.end <= last.end { continue }   // inside the previous one
            if let last = merged.last, last.match.voice == part.match.voice {
                merged[merged.count - 1].end = max(last.end, part.end)
            } else {
                merged.append(part)
            }
        }
        guard !merged.isEmpty else { return [] }
        merged[0].start = 0
        for i in 1..<merged.count { merged[i].start = merged[i - 1].end }
        merged[merged.count - 1].end = duration
        return merged
    }

    func assign(embedding e: [Float], duration: Double) -> Match? {
        let best = voices.indices.map { ($0, RemoteDiarizer.cosine(e, voices[$0].centroid)) }.max { $0.1 < $1.1 }
        if let (i, sim) = best, sim >= sameThreshold || duration < minNewSeconds {
            // Running mean, weighted by talk time but capped so a voice can still drift a little.
            let w = Float(min(voices[i].seconds, 60))
            let d = Float(duration)
            voices[i].centroid = VoiceLibrary.normalized(zip(voices[i].centroid, e).map { ($0 * w + $1 * d) / (w + d) })
            voices[i].seconds += duration
            return Match(voice: voices[i].id, isNew: false, similarity: sim, seconds: voices[i].seconds)
        }
        guard duration >= minNewSeconds else { return nil }
        let voice = Voice(id: voices.count + 1, centroid: e, seconds: duration)
        voices.append(voice)
        return Match(voice: voice.id, isNew: true, similarity: 1, seconds: duration)
    }

    /// The known voice a clip of speech in progress sounds like, without learning from it
    /// (the final segment does that). Nil for an unclear or new voice.
    func peek(_ samples: [Float]) async -> Int? {
        guard !voices.isEmpty, let e = await embedding(of: samples) else { return nil }
        let best = voices.map { ($0.id, RemoteDiarizer.cosine(e, $0.centroid)) }.max { $0.1 < $1.1 }
        guard let best, best.1 >= sameThreshold else { return nil }
        return best.0
    }

    func centroid(of voice: Int) -> [Float]? {
        voices.first { $0.id == voice }?.centroid
    }
}
