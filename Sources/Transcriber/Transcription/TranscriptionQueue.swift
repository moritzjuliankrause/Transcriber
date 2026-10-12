import Foundation
import FluidAudio

/// Serializes ASR work so segments from both channels are transcribed one at a
/// time (the Neural Engine does not benefit from parallel requests) and results
/// are delivered in submission order.
actor TranscriptionQueue {
    private let engine: TranscriptionEngine
    private let language: String?
    private var queue: [ChannelProcessor.Segment] = []
    private var running = false
    private let onResult: @Sendable (ChannelProcessor.Segment, TranscribedSegment) async -> Void
    private let onPartial: (@Sendable (ChannelProcessor.Segment, TranscribedSegment) async -> Void)?
    /// Called for a final segment that produced no text, so a partial shown for it can be cleared.
    private let onEmptyFinal: (@Sendable (ChannelProcessor.Segment) async -> Void)?
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    /// Only the newest partial per channel is kept; finals always win.
    private var partials: [Channel: ChannelProcessor.Segment] = [:]

    init(engine: TranscriptionEngine, language: String?,
         onResult: @escaping @Sendable (ChannelProcessor.Segment, TranscribedSegment) async -> Void,
         onPartial: (@Sendable (ChannelProcessor.Segment, TranscribedSegment) async -> Void)? = nil,
         onEmptyFinal: (@Sendable (ChannelProcessor.Segment) async -> Void)? = nil) {
        self.engine = engine
        self.language = language
        self.onResult = onResult
        self.onPartial = onPartial
        self.onEmptyFinal = onEmptyFinal
    }

    func submit(_ segment: ChannelProcessor.Segment) {
        if segment.isPartial {
            partials[segment.channel] = segment
        } else {
            partials[segment.channel] = nil
            queue.append(segment)
        }
        if !running { Task { await run() } }
    }

    var backlog: Int { queue.count + (running ? 1 : 0) }

    private func run() async {
        running = true
        while !queue.isEmpty || !partials.isEmpty {
            let segment: ChannelProcessor.Segment
            if !queue.isEmpty {
                segment = queue.removeFirst()
            } else {
                let (channel, partial) = partials.first!
                partials[channel] = nil
                segment = partial
            }
            do {
                let result = try await transcribe(segment)
                if segment.isPartial {
                    // A final for this channel may have arrived meanwhile – then the partial is stale.
                    if !result.text.isEmpty, !queue.contains(where: { $0.channel == segment.channel }) {
                        await onPartial?(segment, result)
                    }
                } else if !result.text.isEmpty {
                    await onResult(segment, result)
                } else {
                    await onEmptyFinal?(segment)
                }
            } catch {
                NSLog("Transcription failed for segment at \(segment.start)s: \(error)")
                if !segment.isPartial { await onEmptyFinal?(segment) }
            }
        }
        running = false
        let waiters = drainContinuations
        drainContinuations = []
        waiters.forEach { $0.resume() }
    }

    /// Decodes the segment together with the audio before it, then keeps only the words whose
    /// centre lies inside the segment (timings shifted back to the segment start). Hearing the
    /// preceding sentence fixes the typical errors of short fragments: a wrong language for "ja" or
    /// "genau", names split into nonsense, missing first words. Without word timings there is no
    /// safe cut, so the segment is decoded on its own.
    private func transcribe(_ segment: ChannelProcessor.Segment) async throws -> TranscribedSegment {
        let contextSeconds = Double(segment.context.count) / 16_000
        guard contextSeconds >= 0.5 else { return try await engine.transcribe(segment.samples, language: language) }
        let full = try await engine.transcribe(segment.context + segment.samples, language: language)
        let kept = full.words
            .filter { ($0.startTime + $0.endTime) / 2 >= contextSeconds }
            .map { WordTiming(word: $0.word, startTime: max(0, $0.startTime - contextSeconds), endTime: max(0, $0.endTime - contextSeconds)) }
        guard !full.words.isEmpty, !kept.isEmpty else {
            return try await engine.transcribe(segment.samples, language: language)
        }
        return TranscribedSegment(text: WordText.join(kept.map(\.word)), confidence: full.confidence, words: kept)
    }

    /// Waits until every queued segment has been processed.
    func drain() async {
        guard running || !queue.isEmpty else { return }
        await withCheckedContinuation { drainContinuations.append($0) }
    }
}

/// Joins recognised words back into text, without spaces before punctuation tokens.
enum WordText {
    static func join(_ words: [String]) -> String {
        words.joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
