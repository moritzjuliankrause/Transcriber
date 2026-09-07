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
    @Published var lastTranscriptUpdate: Date = .distantPast
    @Published var lastError: String?
    @Published var currentSessionURL: URL?
    @Published var pendingRecovery: [SessionRecovery.IncompleteSession] = []

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
    }
}

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: String
    let text: String
    let start: TimeInterval
    /// For partial lines: how many leading words are considered settled. nil = all.
    var stableWords: Int? = nil
}
