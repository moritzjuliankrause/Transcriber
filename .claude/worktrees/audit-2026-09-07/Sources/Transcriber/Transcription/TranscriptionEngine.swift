import Foundation
import FluidAudio

struct TranscribedSegment: Sendable {
    let text: String
    let confidence: Float
    let words: [WordTiming]
}

/// Abstraction so other engines (WhisperKit, Apple SpeechAnalyzer…) can be
/// plugged in later. Input is always 16 kHz mono Float32.
protocol TranscriptionEngine: AnyObject, Sendable {
    func prepare() async throws
    func transcribe(_ samples: [Float], language: String?) async throws -> TranscribedSegment
}

/// FluidAudio Parakeet TDT v3 (multilingual) running on CoreML / Neural Engine.
final class FluidAudioEngine: TranscriptionEngine, @unchecked Sendable {
    private let manager: AsrManager
    private var loaded = false
    private let precision: ParakeetEncoderPrecision

    init(precision: ParakeetEncoderPrecision) {
        self.precision = precision
        self.manager = AsrManager(config: .default)
    }

    func prepare() async throws {
        guard !loaded else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: precision)
        try await manager.loadModels(models)
        loaded = true
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> TranscribedSegment {
        // Pad very short segments; the model wants at least ~0.5 s.
        var audio = samples
        let minSamples = 8_000
        if audio.count < minSamples {
            audio.append(contentsOf: [Float](repeating: 0, count: minSamples - audio.count))
        }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let lang = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(audio, decoderState: &state, language: lang)
        let words = result.tokenTimings.map { buildWordTimings(from: $0) } ?? []
        return TranscribedSegment(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  confidence: result.confidence,
                                  words: words)
    }
}
