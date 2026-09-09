import Foundation
import FluidAudio

/// Experimental live (online) speaker diarization for the system-audio channel.
///
/// Each VAD speech segment is one speaker turn, so we extract a single speaker embedding per
/// segment and match it against a running set of speakers, handing back a stable "Speaker N"
/// label in the order speakers first appear. This is inherently less accurate than the
/// end-of-call pass — a turn's speaker is decided with no future context, so early guesses can be
/// wrong — which is why it is opt-in. Past lines are never relabelled; only new turns are judged.
actor LiveDiarizer {
    private let manager = DiarizerManager()
    /// Our own matcher with a tighter threshold than the library default (0.84), which merged
    /// clearly different voices into one. The threshold is the max cosine distance to still count
    /// as the same speaker; lower separates more eagerly (at the risk of splitting one voice).
    private var speakers: SpeakerManager
    private let otherName: String
    /// Cluster id (from the matcher) → the "Speaker N" label we show.
    private var labelForSpeaker: [String: String] = [:]
    private var order = 0
    private var ready = false

    init(otherName: String, threshold: Float = 0.62) {
        self.otherName = otherName
        self.speakers = SpeakerManager(speakerThreshold: threshold, embeddingThreshold: 0.45,
                                       minSpeechDuration: 1.0, minEmbeddingUpdateDuration: 2.0)
    }

    /// Downloads (first time only) and loads the diarization models. Safe to call repeatedly.
    func prepare() async throws {
        guard !ready else { return }
        let models = try await DiarizerModels.downloadIfNeeded()
        manager.initialize(models: models)
        ready = true
    }

    /// The "Speaker N" label for a system segment, or nil to keep the caller's default label
    /// (models not ready, clip too short to embed, or a new speaker below the duration floor).
    func label(for samples: [Float], duration: Double) -> String? {
        guard ready, samples.count >= 8_000 else { return nil }      // < 0.5 s: skip
        guard let embedding = try? manager.extractSpeakerEmbedding(from: samples),
              let speaker = speakers.assignSpeaker(embedding, speechDuration: Float(duration))
        else { return nil }
        if let label = labelForSpeaker[speaker.id] { return label }
        order += 1
        let label = "\(otherName) \(order)"
        labelForSpeaker[speaker.id] = label
        return label
    }
}
