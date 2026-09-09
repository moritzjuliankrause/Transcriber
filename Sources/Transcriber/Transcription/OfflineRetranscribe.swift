import Foundation

/// Re-transcribes a full channel offline using long context windows instead of the live
/// path's short, VAD-cut utterances.
///
/// The live pipeline cuts speech at every ~0.5 s silence and transcribes each 1–3 s fragment
/// on its own, resetting the decoder between fragments. FluidAudio's `AsrManager.transcribe`
/// already slides a ~15 s window with 2 s overlap and carries decoder state *inside a single
/// call*, so handing it large spans (minutes) instead of tiny fragments gives the decoder far
/// more surrounding context. That is the whole quality lever of an end-of-call re-pass: same
/// model, but it now hears each word in its sentence rather than in isolation.
enum OfflineRetranscribe {
    struct Options {
        /// How much audio to hand the engine per call. Bounds peak memory; the engine slides
        /// its own 15 s window within this span.
        var windowSeconds: Double = 600
        /// Overlap between consecutive windows so a word split across a boundary is not lost.
        var windowOverlapSeconds: Double = 2
        /// Start a new transcript entry when the gap between two words exceeds this, so the
        /// long decode is broken back into readable, diarizable lines.
        var entryGapSeconds: Double = 0.8
    }

    /// Transcribe one channel's 16 kHz mono samples into transcript entries.
    static func run(samples: [Float], channel: Channel, speaker: String, language: String?,
                    engine: TranscriptionEngine, options: Options = Options(),
                    progress: (Double) -> Void = { _ in }) async throws -> [TranscriptEntry] {
        guard !samples.isEmpty else { return [] }
        let rate = 16_000.0
        let total = samples.count
        let window = max(Int(options.windowSeconds * rate), Int(rate))
        let overlap = Int(options.windowOverlapSeconds * rate)
        // Collect all words into one absolute-timed stream, cutting the seam between adjacent
        // windows at the middle of their overlap: keep the previous window's words up to the seam
        // (it had full left context there) and the current window's words from the seam on. This
        // avoids both duplicating and dropping words at a boundary.
        var words: [WordStamp] = []
        var confidence: Float = 1
        var textFallback = ""
        var start = 0
        while start < total {
            let end = min(total, start + window)
            let base = Double(start) / rate
            let seg = try await engine.transcribe(Array(samples[start..<end]), language: language)
            confidence = min(confidence, seg.confidence)
            if start == 0 { textFallback = seg.text }
            let chunk = seg.words.map { WordStamp(word: $0.word, start: base + $0.startTime, end: base + $0.endTime) }
            if start > 0 {
                let seam = base + options.windowOverlapSeconds / 2
                while let last = words.last, last.start >= seam { words.removeLast() }
                words.append(contentsOf: chunk.filter { $0.start >= seam })
            } else {
                words.append(contentsOf: chunk)
            }
            progress(Double(end) / Double(total))
            if end == total { break }
            start = end - overlap
        }

        if words.isEmpty {
            guard !textFallback.isEmpty else { return [] }
            return [TranscriptEntry(channel: channel, speaker: speaker, start: 0,
                                    end: Double(total) / rate, text: textFallback,
                                    confidence: confidence, createdAt: Date(), words: nil)]
        }
        return group(words, channel: channel, speaker: speaker, confidence: confidence, gap: options.entryGapSeconds)
    }

    /// Splits an absolute-timed word stream into entries at silence gaps.
    private static func group(_ words: [WordStamp], channel: Channel, speaker: String,
                              confidence: Float, gap: Double) -> [TranscriptEntry] {
        guard !words.isEmpty else { return [] }
        var out: [TranscriptEntry] = []
        var current: [WordStamp] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.word).joined(separator: " ")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: " .", with: ".")
                .replacingOccurrences(of: " ?", with: "?")
                .replacingOccurrences(of: " !", with: "!")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(TranscriptEntry(channel: channel, speaker: speaker, start: first.start,
                                           end: last.end, text: text, confidence: confidence,
                                           createdAt: Date(), words: current))
            }
            current = []
        }
        for w in words {
            if let prev = current.last, w.start - prev.end > gap { flush() }
            current.append(w)
        }
        flush()
        return out
    }
}
