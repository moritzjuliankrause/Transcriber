import Foundation
import FluidAudio

/// One per audio channel ("me" = microphone, "them" = system audio).
/// Runs streaming VAD over incoming 16 kHz samples, cuts speech segments and
/// forwards them to the transcription queue with session-relative timestamps.
actor ChannelProcessor {
    struct Segment: Sendable {
        let channel: Channel
        let start: TimeInterval
        let end: TimeInterval
        let samples: [Float]
        var isPartial = false
    }

    let channel: Channel
    private let vad: VadManager
    private let vadConfig: VadSegmentationConfig
    private let onSegment: @Sendable (Segment) async -> Void
    private let onPartial: (@Sendable (Segment) async -> Void)?
    private var lastPartialSample = 0
    private let partialIntervalSamples = 8_000     // re-transcribe the running segment every 0.5 s

    private var vadState: VadStreamState
    private var pending: [Float] = []          // samples not yet fed to VAD (mod chunkSize)
    private var ring: [Float] = []             // audio since current speech start (or lookback)
    private var ringStartSample = 0            // absolute index of ring[0]
    private var totalSamples = 0               // absolute sample counter for this channel
    private var speechStartSample: Int?
    private let lookbackSamples = 4_800        // 0.3 s of pre-roll
    private let hardCapSamples = 16_000 * 20   // never let a segment exceed 20 s
    private let sampleRate = 16_000

    init(channel: Channel, vad: VadManager, threshold: Float,
         onSegment: @escaping @Sendable (Segment) async -> Void,
         onPartial: (@Sendable (Segment) async -> Void)? = nil) async {
        self.channel = channel
        self.vad = vad
        self.onSegment = onSegment
        self.onPartial = onPartial
        self.vadState = await vad.makeStreamState()
        self.vadConfig = VadSegmentationConfig(
            minSpeechDuration: 0.25,
            minSilenceDuration: 0.25,   // state machine fires on the 2nd low chunk (~0.5 s of real silence)
            maxSpeechDuration: 14.0,
            speechPadding: 0.15)
        _ = threshold
    }

    func append(_ samples: [Float]) async {
        guard !samples.isEmpty else { return }
        pending.append(contentsOf: samples)
        ring.append(contentsOf: samples)
        totalSamples += samples.count

        // Keep the ring bounded while idle.
        if speechStartSample == nil, ring.count > lookbackSamples * 2 {
            let drop = ring.count - lookbackSamples
            ring.removeFirst(drop)
            ringStartSample += drop
        }

        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            await process(chunk: chunk)
        }
    }

    private func process(chunk: [Float]) async {
        do {
            let result = try await vad.processStreamingChunk(chunk, state: vadState, config: vadConfig, returnSeconds: false)
            vadState = result.state
            if ProcessInfo.processInfo.environment["ANYRECORD_VAD_DEBUG"] != nil {
                print(String(format: "vad %@ t=%.2f p=%.2f triggered=%d event=%@", channel.rawValue, Double(totalSamples) / 16000, result.probability, result.state.triggered ? 1 : 0, result.event.map { "\($0.kind)@\($0.sampleIndex)" } ?? "-"))
            }
            if let event = result.event {
                switch event.kind {
                case .speechStart:
                    if speechStartSample == nil {
                        speechStartSample = max(ringStartSample, event.sampleIndex - lookbackSamples)
                    }
                case .speechEnd:
                    await emitSegment(endSample: event.sampleIndex + Int(vadConfig.speechPadding * Double(sampleRate)))
                }
            }
            if let start = speechStartSample, totalSamples - start >= hardCapSamples {
                await emitSegment(endSample: totalSamples)
                speechStartSample = totalSamples   // keep going in a new segment
            }
            if let onPartial, let start = speechStartSample,
               totalSamples - lastPartialSample >= partialIntervalSamples,
               totalSamples - start >= sampleRate / 2 {
                lastPartialSample = totalSamples
                let lo = max(0, start - ringStartSample)
                let samples = Array(ring[lo...])
                await onPartial(Segment(channel: channel,
                                        start: Double(start) / Double(sampleRate),
                                        end: Double(totalSamples) / Double(sampleRate),
                                        samples: samples, isPartial: true))
            }
        } catch {
            NSLog("VAD error on \(channel): \(error)")
        }
    }

    private func emitSegment(endSample requestedEnd: Int) async {
        guard let start = speechStartSample else { return }
        let end = min(requestedEnd, ringStartSample + ring.count)
        let lo = max(0, start - ringStartSample)
        let hi = max(lo, end - ringStartSample)
        let samples = Array(ring[lo..<hi])
        speechStartSample = nil
        // Drop consumed audio, keep lookback.
        let keepFrom = max(0, hi - lookbackSamples)
        ring.removeFirst(keepFrom)
        ringStartSample += keepFrom

        guard samples.count >= sampleRate / 4 else { return }  // < 0.25 s → ignore
        let segment = Segment(channel: channel,
                              start: Double(start) / Double(sampleRate),
                              end: Double(end) / Double(sampleRate),
                              samples: samples)
        await onSegment(segment)
    }

    /// Flush any speech in progress (called on stop).
    func finish() async {
        if speechStartSample != nil {
            await emitSegment(endSample: totalSamples)
        }
    }

    var elapsedSeconds: TimeInterval { Double(totalSamples) / Double(sampleRate) }
}

enum Channel: String, Codable, Sendable {
    case me
    case them
}
