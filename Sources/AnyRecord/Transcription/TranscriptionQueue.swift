import Foundation

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
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    /// Only the newest partial per channel is kept; finals always win.
    private var partials: [Channel: ChannelProcessor.Segment] = [:]

    init(engine: TranscriptionEngine, language: String?,
         onResult: @escaping @Sendable (ChannelProcessor.Segment, TranscribedSegment) async -> Void,
         onPartial: (@Sendable (ChannelProcessor.Segment, TranscribedSegment) async -> Void)? = nil) {
        self.engine = engine
        self.language = language
        self.onResult = onResult
        self.onPartial = onPartial
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
                let result = try await engine.transcribe(segment.samples, language: language)
                if segment.isPartial {
                    // A final for this channel may have arrived meanwhile – then the partial is stale.
                    if !result.text.isEmpty, !queue.contains(where: { $0.channel == segment.channel }) {
                        await onPartial?(segment, result)
                    }
                } else if !result.text.isEmpty {
                    await onResult(segment, result)
                }
            } catch {
                NSLog("Transcription failed for segment at \(segment.start)s: \(error)")
            }
        }
        running = false
        let waiters = drainContinuations
        drainContinuations = []
        waiters.forEach { $0.resume() }
    }

    /// Waits until every queued segment has been processed.
    func drain() async {
        guard running || !queue.isEmpty else { return }
        await withCheckedContinuation { drainContinuations.append($0) }
    }
}
