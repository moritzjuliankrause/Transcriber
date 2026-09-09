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

    // MARK: - Manual speaker naming (this recording only)

    /// Custom display names for remote speakers, keyed by their base label ("Speaker 1", …).
    /// Applied to the floating bar and the saved transcript; reset when a new session starts.
    @Published var speakerNames: [String: String] = [:]
    /// The remote speakers currently offered for naming, in order ("Speaker 1", "Speaker 2", …).
    /// Populated live as remote speech arrives, and from the finished transcript at save time.
    @Published var remoteSpeakers: [String] = []

    /// The label to show for a base speaker label: its custom name if one was entered, else itself.
    func displayName(for base: String) -> String {
        if let custom = speakerNames[base], !custom.isEmpty { return custom }
        return base
    }

    /// Sets (or, with an empty/blank name, clears) the custom name for a speaker. The first letter
    /// is always capitalised.
    func setSpeakerName(_ name: String, for base: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames[base] = nil
        } else {
            speakerNames[base] = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
    }

    /// Notes that a remote speaker exists so the bar can offer to name it.
    func noteRemoteSpeaker(_ base: String) {
        guard !remoteSpeakers.contains(base) else { return }
        remoteSpeakers.append(base)
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
        if liveLines.count > 40 { liveLines.removeFirst(liveLines.count - 40) }
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
        micLevel = 0
        systemLevel = 0
        levelHistory = Array(repeating: 0, count: 24)
        liveLines = []
        partialLines = [:]
        lastUpdatedChannel = nil
        retractions = []
        speakerNames = [:]
        remoteSpeakers = []
    }
}

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    var channel: Channel? = nil
    let speaker: String
    let text: String
    let start: TimeInterval
    /// For partial lines: how many leading words are considered settled. nil = all.
    var stableWords: Int? = nil
    let createdAt = Date()
}
