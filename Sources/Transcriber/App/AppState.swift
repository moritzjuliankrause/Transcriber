import Foundation
import Combine

/// Observable UI state shared between the status item, floating bar and settings.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping(String)   // status message while finalizing
    }

    @Published var phase: Phase = .idle
    @Published var recordingStartedAt: Date?
    @Published var isPaused = false
    /// The microphone channel is muted: it records silence, only the system audio is transcribed.
    @Published var isMicMuted = false
    /// When the microphone was muted during this recording (marked in the transcript).
    @Published var muteIntervals: [TimeSpan] = []
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    /// Rolling history of combined levels for the waveform (newest last).
    @Published var levelHistory: [Float] = Array(repeating: 0, count: 24)
    @Published var liveLines: [TranscriptLine] = []
    /// In-progress (not yet final) text per channel, updated while someone speaks.
    @Published var partialLines: [Channel: TranscriptLine] = [:]
    @Published var lastUpdatedChannel: Channel?
    /// Segments whose shown text turned out to be wrong (echo of the far end, empty final).
    struct Retraction: Equatable { let id = UUID(); let channel: Channel; let start: TimeInterval }
    @Published var retractions: [Retraction] = []
    @Published var lastTranscriptUpdate: Date = .distantPast
    @Published var lastError: String?
    @Published var currentSessionURL: URL?
    @Published var pendingRecovery: [SessionRecovery.IncompleteSession] = []

    // MARK: - Far-end voices (live, this recording only)

    /// Voices told apart live on the system channel (`LiveSpeakers`), with the names typed for
    /// them. A name belongs to a voice, not to a stretch of time: every line of that voice, past
    /// and future, shows it.
    @Published var voiceNames: [Int: String] = [:]
    /// Voices whose name came from a remembered voice rather than from the user.
    @Published var autoNamedVoices: Set<Int> = []
    /// "Speaker N" numbers, given once a voice has spoken for a few seconds (a voice heard only
    /// in one short line is often a stray guess and shows as plain "Speaker").
    @Published var voiceNumbers: [Int: Int] = [:]
    /// The voice of the far end's latest line (or of the speech in progress).
    @Published var currentVoice: Int?
    /// Label base for unnamed voices ("Speaker"); set by the coordinator.
    var otherName = "Speaker"
    /// Speaker tags derived from the named voices (one per line), persisted to session.json so the
    /// after-call diarization can hand each name to the matching cluster.
    @Published var speakerTags: [SpeakerTag] = []
    /// Current position on the session timeline (seconds); set by the coordinator while recording.
    var sessionClock: (() -> Double)?

    /// What a far-end voice is shown as right now.
    func label(forVoice voice: Int?) -> String {
        guard let voice else { return otherName }
        if let name = voiceNames[voice] { return name }
        if let n = voiceNumbers[voice] { return "\(otherName) \(n)" }
        return otherName
    }

    /// Names given in this recording, most recently used first – offered as one-click chips.
    var usedSpeakerNames: [String] {
        var out: [String] = []
        for name in voiceNames.sorted(by: { $0.key > $1.key }).map(\.value) where !out.contains(name) { out.append(name) }
        return out
    }

    /// Names a voice (an empty name removes it). Two voices given the same name are one person
    /// the live separation split in two.
    func nameVoice(_ voice: Int, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        autoNamedVoices.remove(voice)
        guard !trimmed.isEmpty else { voiceNames[voice] = nil; return }
        voiceNames[voice] = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        if case .starting = phase { return true }
        return false
    }

    func pushLevel(mic: Float, system: Float) {
        micLevel = mic
        systemLevel = system
        levelHistory.removeFirst()
        levelHistory.append(max(mic, system))
    }

    func appendLive(_ line: TranscriptLine, channel: Channel) {
        liveLines.append(line)
        if liveLines.count > 600 { liveLines.removeFirst(liveLines.count - 600) }
        partialLines[channel] = nil
        lastUpdatedChannel = channel
        lastTranscriptUpdate = Date()
    }

    func updatePartial(_ line: TranscriptLine, channel: Channel) {
        partialLines[channel] = line
        lastUpdatedChannel = channel
        lastTranscriptUpdate = Date()
    }

    /// Drops the in-progress text of a channel whose segment ended without a final line.
    func clearPartial(channel: Channel) {
        guard let partial = partialLines[channel] else { return }
        retract(channel: channel, start: partial.start)
        partialLines[channel] = nil
        lastTranscriptUpdate = Date()
    }

    /// Tells the floating bar to take back whatever it showed for this segment.
    func retract(channel: Channel, start: TimeInterval) {
        retractions.append(Retraction(channel: channel, start: start))
        if retractions.count > 40 { retractions.removeFirst(retractions.count - 40) }
    }

    /// What the floating bar should show right now: the newest partial, else the last final line.
    var currentLiveLine: TranscriptLine? {
        if let ch = lastUpdatedChannel, let p = partialLines[ch] { return p }
        if let p = partialLines.values.first { return p }
        return liveLines.last
    }

    func reset() {
        phase = .idle
        recordingStartedAt = nil
        isPaused = false
        isMicMuted = false
        muteIntervals = []
        micLevel = 0
        systemLevel = 0
        levelHistory = Array(repeating: 0, count: 24)
        liveLines = []
        partialLines = [:]
        lastUpdatedChannel = nil
        retractions = []
        speakerTags = []
        voiceNames = [:]
        autoNamedVoices = []
        voiceNumbers = [:]
        currentVoice = nil
        sessionClock = nil
    }
}

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    var channel: Channel? = nil
    let speaker: String
    let text: String
    /// Far-end voice id (`LiveSpeakers`); the shown label follows the voice's current name.
    var voice: Int? = nil
    let start: TimeInterval
    /// For partial lines: how many leading words are considered settled. nil = all.
    var stableWords: Int? = nil
    let createdAt = Date()
}
