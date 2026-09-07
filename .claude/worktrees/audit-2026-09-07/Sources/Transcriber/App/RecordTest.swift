import Foundation
import AppKit

/// `Transcriber --record-test [seconds] [--log file]` – runs a complete recording
/// session through RecordingCoordinator (permissions, capture, echo gate, VAD,
/// ASR, store) without any UI interaction and prints what was captured.
enum RecordTest {
    static func run(arguments: [String]) async -> Int32 {
        var seconds = 15.0
        if let i = arguments.firstIndex(of: "--record-test"), i + 1 < arguments.count, let s = Double(arguments[i + 1]) { seconds = s }
        if let li = arguments.firstIndex(of: "--log"), li + 1 < arguments.count {
            freopen(arguments[li + 1], "w", stdout)
            setvbuf(stdout, nil, _IONBF, 0)
            dup2(fileno(stdout), fileno(stderr))
        }

        let result: Int32 = await Task { @MainActor in
            let settings = AppSettings.shared
            let state = AppState.shared
            let savedAskTitle = settings.askForTitle
            let savedDiarize = settings.diarizeRemote
            settings.askForTitle = false
            settings.diarizeRemote = false
            defer {
                settings.askForTitle = savedAskTitle
                settings.diarizeRemote = savedDiarize
            }
            let coordinator = RecordingCoordinator(settings: settings, state: state)
            print("Starting recording (\(Int(seconds)) s)…")
            await coordinator.start()
            if let error = state.lastError {
                print("Start failed: \(error)")
                return 1
            }
            print("Recording into \(state.currentSessionURL?.path ?? "?")")
            let started = Date()
            while Date().timeIntervalSince(started) < seconds {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                print(String(format: "  t=%2.0fs mic=%.2f sys=%.2f lines=%d", Date().timeIntervalSince(started), state.micLevel, state.systemLevel, state.liveLines.count))
            }
            await coordinator.stop()
            guard let url = state.currentSessionURL else { return 1 }
            for name in ["mic.wav", "system.wav"] {
                let file = url.appendingPathComponent(name)
                if let samples = try? WavWriter.readSamples(url: file) {
                    let nonZero = samples.filter { $0 != 0 }.count
                    let peak = samples.map { abs($0) }.max() ?? 0
                    print(String(format: "%@: %.1f s, non-zero %.0f%%, peak %.3f", name, Double(samples.count) / 16_000, 100 * Double(nonZero) / Double(max(1, samples.count)), peak))
                }
            }
            let jsonl = (try? String(contentsOf: url.appendingPathComponent("transcript.jsonl"), encoding: .utf8)) ?? ""
            print("Transcript entries:")
            for line in jsonl.split(separator: "\n") { print("  " + line.prefix(160)) }
            return 0
        }.value
        return result
    }
}
