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

    struct Result {
        var spans: [SpeakerSpan]
        /// One embedding per cluster id (when the pipeline provides them).
        var embeddings: [String: [Float]]
    }

    static func diarize(wavURL: URL, maxSpeakers: Int? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        var config = OfflineDiarizerConfig.default
        // Leave maxSpeakers unset so the clustering auto-detects how many people spoke; only cap
        // it when a specific number is asked for.
        if let maxSpeakers { config.clustering.maxSpeakers = maxSpeakers }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let result = try await manager.process(wavURL) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        let spans = result.segments.map {
            SpeakerSpan(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        return Result(spans: spans, embeddings: result.speakerDatabase ?? [:])
    }

    /// The labelled outcome of a diarization run.
    struct Labelled {
        var spans: [SpeakerSpan]
        var summary: String
        /// Voice embedding per final label (averaged when several clusters share a label).
        var embeddings: [String: [Float]]
        /// Talk time per final label, seconds.
        var talkTime: [String: Double]
        /// Labels whose name came from a name typed during the call.
        var namedByTag: Set<String>
        /// Labels whose name came from a remembered voice.
        var namedByVoice: Set<String>
    }

    /// Turns raw clusters into the labels written to the transcript.
    ///
    /// - Clusters with very little talk time are usually one voice split off by the clustering
    ///   (pyannote does this on long 1:1 calls). They are folded into the closest real speaker by
    ///   voice embedding. The bar is absolute (a few seconds), not a share of the call, so that
    ///   in a 20-person meeting everyone who said a sentence or two keeps their own label.
    /// - Clusters the user named during the call (speaker tags) get that name: each tag votes for
    ///   the cluster that dominates its stretch of the call.
    /// - Remaining clusters that sound like a remembered voice get its name.
    /// - All other clusters become "<otherName> 1", "<otherName> 2", … in order of first appearance.
    static func label(_ result: Result, tags: [SpeakerTag], knownVoices: [(name: String, embedding: [Float])] = [],
                      otherName: String, sessionEnd: Double) -> Labelled {
        let spans = result.spans.filter { $0.end > $0.start }
        guard !spans.isEmpty else { return Labelled(spans: [], summary: "no speech", embeddings: [:], talkTime: [:], namedByTag: [], namedByVoice: []) }
        var duration: [String: Double] = [:]
        var firstSeen: [String: Double] = [:]
        for span in spans {
            duration[span.speaker, default: 0] += span.end - span.start
            firstSeen[span.speaker] = min(firstSeen[span.speaker] ?? .infinity, span.start)
        }
        let total = duration.values.reduce(0, +)
        let floor = min(12, max(3, total * 0.05))
        var major = Set(duration.filter { $0.value >= floor }.keys)
        if major.isEmpty, let biggest = duration.max(by: { $0.value < $1.value })?.key { major = [biggest] }

        // Minor cluster → nearest major cluster by embedding (cosine), else the biggest one.
        let biggest = major.max { duration[$0]! < duration[$1]! }!
        var target: [String: String] = [:]
        for cluster in duration.keys {
            if major.contains(cluster) { target[cluster] = cluster; continue }
            var best = (biggest, -Float.infinity)
            if let e = result.embeddings[cluster] {
                for m in major {
                    guard let me = result.embeddings[m] else { continue }
                    let sim = cosine(e, me)
                    if sim > best.1 { best = (m, sim) }
                }
            }
            target[cluster] = best.0
        }
        let merged = spans.map { SpeakerSpan(speaker: target[$0.speaker]!, start: $0.start, end: $0.end) }
        var majorTime: [String: Double] = [:]
        for span in merged { majorTime[span.speaker, default: 0] += span.end - span.start }

        // Names from tags: the cluster holding most of a tag's stretch (and at least 40 % of the
        // speech in it) receives a vote weighted by that overlap.
        var votes: [String: [String: Double]] = [:]
        for tag in tags {
            let end = tag.end ?? sessionEnd
            var overlap: [String: Double] = [:]
            for span in merged {
                let o = min(end, span.end) - max(tag.start, span.start)
                if o > 0 { overlap[span.speaker, default: 0] += o }
            }
            let speech = overlap.values.reduce(0, +)
            guard speech > 0, let (cluster, o) = overlap.max(by: { $0.value < $1.value }), o >= speech * 0.4 else { continue }
            votes[cluster, default: [:]][tag.name, default: 0] += o
        }
        var label: [String: String] = [:]
        var byTag = Set<String>(), byVoice = Set<String>()
        var notes: [String] = []
        for (cluster, byName) in votes {
            let name = byName.max { $0.value < $1.value }!.key
            label[cluster] = name
            byTag.insert(name)
        }
        // Remembered voices, for clusters the tags left unnamed (a name typed in this call wins).
        if !knownVoices.isEmpty {
            for cluster in major where label[cluster] == nil {
                guard let e = result.embeddings[cluster] else { continue }
                let best = knownVoices.map { ($0.name, cosine(e, $0.embedding)) }.max { $0.1 < $1.1 }
                if let (name, sim) = best, sim >= VoiceLibrary.matchThreshold, !byTag.contains(name) {
                    label[cluster] = name
                    byVoice.insert(name)
                    notes.append(String(format: "%@ %.2f", name, sim))
                }
            }
        }
        var n = 0
        for cluster in major.sorted(by: { firstSeen[$0]! < firstSeen[$1]! }) where label[cluster] == nil {
            n += 1
            label[cluster] = "\(otherName) \(n)"
        }
        let out = merged.map { SpeakerSpan(speaker: label[$0.speaker]!, start: $0.start, end: $0.end) }

        var embeddings: [String: [Float]] = [:]
        var talk: [String: Double] = [:]
        for cluster in major {
            let l = label[cluster]!
            talk[l, default: 0] += majorTime[cluster] ?? 0
            guard let e = result.embeddings[cluster] else { continue }
            let unit = VoiceLibrary.normalized(e)
            embeddings[l] = embeddings[l].map { VoiceLibrary.normalized(zip($0, unit).map { $0 + $1 }) } ?? unit
        }
        let summary = "\(duration.count) clusters (\(major.count) kept, floor \(Int(floor)) s, \(Int(total)) s speech); "
            + major.sorted { duration[$0]! > duration[$1]! }.map { "\(label[$0]!)=\(Int(duration[$0]!))s" }.joined(separator: " ")
            + (notes.isEmpty ? "" : "; voice matches: " + notes.joined(separator: ", "))
        return Labelled(spans: out, summary: summary, embeddings: embeddings, talkTime: talk, namedByTag: byTag, namedByVoice: byVoice)
    }

    /// Fallback when there is no diarization: remote entries inside a tag's stretch get its name.
    static func applyTags(_ entries: [TranscriptEntry], tags: [SpeakerTag]) -> [TranscriptEntry] {
        guard !tags.isEmpty else { return entries }
        return entries.map { e in
            guard e.channel == .them else { return e }
            let mid = (e.start + e.end) / 2
            guard let tag = tags.last(where: { mid >= $0.start && mid < ($0.end ?? .infinity) }) else { return e }
            var copy = e
            copy.speaker = tag.name
            return copy
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : -1
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
