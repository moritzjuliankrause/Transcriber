import Foundation

/// Headless access to Settings › Recordings, for testing the same code paths:
/// `Transcriber --import <audio-file> --out <folder>` imports a file as a new recording;
/// `Transcriber --reprocess <recording-folder>` re-transcribes a finished recording.
/// Both use the real settings and remembered voices.
enum HeadlessHistory {
    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        let settings = AppSettings.shared
        let history = RecordingHistory.shared
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let file = value("--import") {
            guard let out = value("--out") else { print("usage: --import <file> --out <folder>"); return 2 }
            let root = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            await history.importAudio(URL(fileURLWithPath: file), settings: settings, root: root)
        } else if let dir = value("--reprocess") {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            guard let meta = SessionStore.readMeta(in: url) else { print("no session.json in \(dir)"); return 2 }
            let info = RecordingInfo(directory: url, title: meta.title, startedAt: meta.startedAt, duration: nil,
                                     status: meta.status, audioBytes: 1, audioDeletedAt: nil)
            await history.reTranscribe(info, settings: settings)
        }
        if let error = history.lastError { print("Error: \(error)"); return 1 }
        print("Remembered voices: \(VoiceLibrary.shared.voices.map(\.name))")
        return 0
    }
}
