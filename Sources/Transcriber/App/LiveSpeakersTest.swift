import Foundation

/// `--live-speakers <session folder> [--limit seconds]`: replays a recorded session's remote
/// lines through `LiveSpeakers` in call order and compares the live voice ids with the labels
/// of the saved transcript (the after-call diarization). Prints a confusion table per
/// threshold, used to tune live speaker separation.
enum LiveSpeakersTest {
    static func run(arguments: [String]) async -> Int32 {
        guard let i = arguments.firstIndex(of: "--live-speakers"), i + 1 < arguments.count else {
            print("usage: --live-speakers <session folder> [--limit seconds]"); return 2
        }
        let dir = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        let limit = arguments.firstIndex(of: "--limit").flatMap { Double(arguments[$0 + 1]) } ?? .infinity
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let lines = try String(contentsOf: dir.appendingPathComponent("transcript.jsonl"), encoding: .utf8)
                .split(separator: "\n")
                .compactMap { try? decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
                .filter { $0.channel == .them && $0.start < limit }
                .sorted { $0.start < $1.start }
            let audio = try WavWriter.readSamples(url: dir.appendingPathComponent("system.wav"))
            if arguments.contains("--vad") {
                return try await replayLive(audio: Array(audio.prefix(Int(min(limit, Double(audio.count) / 16_000) * 16_000))), reference: lines, verbose: arguments.contains("--verbose"))
            }
            let live = LiveSpeakers()
            try await live.prepare()
            var embedded: [(entry: TranscriptEntry, e: [Float])] = []
            let clock = Date()
            for entry in lines {
                let a = max(0, Int(entry.start * 16_000)), b = min(audio.count, Int(entry.end * 16_000))
                guard b > a, let e = await live.embedding(of: Array(audio[a..<b])) else { continue }
                embedded.append((entry, e))
            }
            print(String(format: "%d of %d remote lines embedded in %.1f s", embedded.count, lines.count, Date().timeIntervalSince(clock)))
            let known = await MainActor.run { VoiceLibrary.shared.voices }
            for threshold: Float in [0.45, 0.5, 0.55] {
                let s = LiveSpeakers(sameThreshold: threshold)
                var table: [String: [Int: Double]] = [:]
                var unjudged = 0.0
                for (entry, e) in embedded {
                    let d = entry.end - entry.start
                    guard let m = await s.assign(embedding: e, duration: d) else { unjudged += d; continue }
                    table[entry.speaker, default: [:]][m.voice, default: 0] += d
                    if arguments.contains("--verbose"), threshold == 0.5 {
                        print(String(format: "  %7.1f %5.1fs %@ → v%d%@ %.2f  %@", entry.start, d, entry.speaker, m.voice, m.isNew ? "*" : " ", m.similarity, String(entry.text.prefix(50))))
                    }
                }
                // Accuracy: each reference label counts the voice id that holds most of its time.
                var correct = 0.0, total = 0.0
                var claimed = Set<Int>()
                for (_, row) in table.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
                    total += row.values.reduce(0, +)
                    if let best = row.filter({ !claimed.contains($0.key) }).max(by: { $0.value < $1.value }) {
                        correct += best.value; claimed.insert(best.key)
                    }
                }
                print(String(format: "\nthreshold %.2f: %d voices, %.0f%% of judged time on the right voice, %.0f s unjudged", threshold, await s.voices.count, total > 0 ? correct / total * 100 : 0, unjudged))
                for (label, row) in table.sorted(by: { $0.key < $1.key }) {
                    print("  \(label): " + row.sorted { $0.key < $1.key }.map { "v\($0.key)=\(Int($0.value))s" }.joined(separator: " "))
                }
                for v in await s.voices where v.seconds > 10 {
                    let matches = known.map { String(format: "%@ %.2f", $0.name, RemoteDiarizer.cosine(v.centroid, $0.embedding)) }
                    print("  v\(v.id) \(Int(v.seconds))s vs remembered: \(matches.joined(separator: ", "))")
                }
            }
            return 0
        } catch {
            print("error: \(error)"); return 1
        }
    }

    /// `--vad`: cuts the audio into segments the way a live recording does (ChannelProcessor) and
    /// assigns voices part by part, as the coordinator does; scored against the saved labels.
    private static func replayLive(audio: [Float], reference: [TranscriptEntry], verbose: Bool) async throws -> Int32 {
        final class Box: @unchecked Sendable { var segments: [ChannelProcessor.Segment] = [] }
        let box = Box()
        let vad = try await VadManagerFactory.make(threshold: 0.6)
        let processor = await ChannelProcessor(channel: .them, vad: vad, threshold: 0.6, onSegment: { box.segments.append($0) })
        var offset = 0
        while offset < audio.count {
            let end = min(audio.count, offset + 1_600)
            await processor.append(Array(audio[offset..<end]))
            offset = end
        }
        await processor.finish()
        let live = LiveSpeakers()
        try await live.prepare()
        var table: [String: [Int: Double]] = [:]
        var split = 0
        let clock = Date()
        for segment in box.segments {
            let parts = await live.assignParts(segment.samples)
            if Set(parts.map(\.match.voice)).count > 1 { split += 1 }
            for part in parts {
                let a = segment.start + part.start, b = segment.start + part.end
                for r in reference {
                    let o = min(b, r.end) - max(a, r.start)
                    if o > 0 { table[r.speaker, default: [:]][part.match.voice, default: 0] += o }
                }
                if verbose {
                    let ref = reference.max { min(b, $0.end) - max(a, $0.start) < min(b, $1.end) - max(a, $1.start) }
                    print(String(format: "  %7.1f–%7.1f v%d%@ %.2f  ref %@", a, b, part.match.voice, part.match.isNew ? "*" : " ", part.match.similarity, ref?.speaker ?? "-"))
                }
            }
        }
        var correct = 0.0, total = 0.0
        var claimed = Set<Int>()
        for (_, row) in table.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
            total += row.values.reduce(0, +)
            if let best = row.filter({ !claimed.contains($0.key) }).max(by: { $0.value < $1.value }) {
                correct += best.value; claimed.insert(best.key)
            }
        }
        print(String(format: "%d live segments (%d split) in %.1f s; %d voices; %.0f%% of speech on the right voice",
                     box.segments.count, split, Date().timeIntervalSince(clock), await live.voices.count, total > 0 ? correct / total * 100 : 0))
        for (label, row) in table.sorted(by: { $0.key < $1.key }) {
            print("  \(label): " + row.sorted { $0.key < $1.key }.map { "v\($0.key)=\(Int($0.value))s" }.joined(separator: " "))
        }
        return 0
    }
}
