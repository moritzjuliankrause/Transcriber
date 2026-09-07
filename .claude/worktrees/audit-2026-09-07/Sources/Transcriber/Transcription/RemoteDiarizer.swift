import Foundation
import FluidAudio

/// Post-processing step: runs offline speaker diarization over the system audio
/// channel so that multiple remote participants get distinct labels. The local
/// user never needs diarization – they are identified by the microphone channel.
enum RemoteDiarizer {
    struct SpeakerSpan {
        let speaker: String
        let start: Double
        let end: Double
    }

    static func diarize(wavURL: URL, maxSpeakers: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> [SpeakerSpan] {
        var config = OfflineDiarizerConfig.default
        config.clustering.maxSpeakers = maxSpeakers
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(wavURL) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        return result.segments.map {
            SpeakerSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// Relabels every remote-channel entry. Entries with word timings are split
    /// at speaker changes; others get the speaker with the largest overlap.
    static func relabel(_ entries: [TranscriptEntry], spans: [SpeakerSpan], names: [String: String]) -> [TranscriptEntry] {
        var out: [TranscriptEntry] = []
        for e in entries {
            guard e.channel == .them else { out.append(e); continue }
            if let words = e.words, words.count > 1 {
                var groups: [(speaker: String, words: [WordStamp])] = []
                var current = speaker(for: e.start, end: e.end, spans: spans) ?? "?"
                for w in words {
                    let s = speaker(for: w.start, end: w.end, spans: spans) ?? current
                    if groups.isEmpty || s != current {
                        groups.append((s, [w]))
                        current = s
                    } else {
                        groups[groups.count - 1].words.append(w)
                    }
                }
                // Diarization boundaries inside continuous speech are noisy: only
                // accept a speaker change if the new part is at least 4 words and 1.5 s.
                var merged: [(speaker: String, words: [WordStamp])] = []
                for g in groups {
                    let duration = (g.words.last?.end ?? 0) - (g.words.first?.start ?? 0)
                    if g.words.count < 4 || duration < 1.5, var last = merged.popLast() {
                        last.words.append(contentsOf: g.words)
                        merged.append(last)
                    } else {
                        merged.append(g)
                    }
                }
                for g in merged {
                    var copy = e
                    copy.speaker = names[g.speaker] ?? e.speaker
                    copy.start = g.words.first!.start
                    copy.end = g.words.last!.end
                    copy.text = g.words.map(\.word).joined(separator: " ")
                    copy.words = g.words
                    out.append(copy)
                }
            } else {
                var copy = e
                if let s = speaker(for: e.start, end: e.end, spans: spans) { copy.speaker = names[s] ?? e.speaker }
                out.append(copy)
            }
        }
        return out
    }

    /// Assigns a speaker label to a transcript entry by maximum overlap.
    static func speaker(for start: Double, end: Double, spans: [SpeakerSpan]) -> String? {
        var best: (String, Double)?
        for span in spans {
            let overlap = min(end, span.end) - max(start, span.start)
            if overlap > 0, overlap > (best?.1 ?? 0) {
                best = (span.speaker, overlap)
            }
        }
        return best?.0
    }
}
