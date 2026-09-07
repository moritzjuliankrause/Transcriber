import Foundation
import AVFoundation

/// `Transcriber --capture-test [seconds]` – records mic and system audio for a few
/// seconds and prints callback counts and levels. Use it to verify permissions.
enum CaptureTest {
    static func run(arguments: [String]) async -> Int32 {
        if let li = arguments.firstIndex(of: "--log"), li + 1 < arguments.count {
            // Redirect output so the test can be launched via `open … --args` (proper TCC attribution).
            freopen(arguments[li + 1], "w", stdout)
            setvbuf(stdout, nil, _IONBF, 0)
            dup2(fileno(stdout), fileno(stderr))
        }
        var seconds = 6.0
        if let i = arguments.firstIndex(of: "--capture-test"), i + 1 < arguments.count, let s = Double(arguments[i + 1]) { seconds = s }

        print("Microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")
        let granted = await Permissions.requestMicrophone()
        print("Microphone granted: \(granted)")
        print("Default input: \(AudioDevices.defaultInputDevice()?.name ?? "-"), default output: \(AudioDevices.defaultOutputDevice()?.name ?? "-")")

        final class Stats: @unchecked Sendable {
            var calls = 0; var samples = 0; var peak: Float = 0
            let lock = NSLock()
            func add(_ s: [Float]) { lock.lock(); calls += 1; samples += s.count; peak = max(peak, s.map { abs($0) }.max() ?? 0); lock.unlock() }
            var text: String { "callbacks=\(calls) seconds=\(String(format: "%.1f", Double(samples) / 16000)) peak=\(String(format: "%.3f", peak))" }
        }

        for echo in [false, true] {
            let stats = Stats()
            let mic = MicrophoneCapture { s, _ in stats.add(s) }
            do {
                try mic.start(deviceUID: nil, echoCancellation: echo)
                try await Task.sleep(nanoseconds: UInt64(seconds / 2 * 1e9))
                mic.stop()
                print("Mic (echoCancellation=\(echo)): \(stats.text)")
            } catch {
                print("Mic (echoCancellation=\(echo)) failed: \(error)")
            }
        }

        print("System audio permission before: \(Permissions.systemAudioStatus())")
        let sysGranted = await Permissions.requestSystemAudio()
        print("System audio granted: \(sysGranted) (now \(Permissions.systemAudioStatus()))")
        // Isolation: does a plain HAL IOProc on the default output device run at all?
        if let outID = AudioDevices.defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice) {
            final class Counter: @unchecked Sendable { var n = 0 }
            let counter = Counter()
            var procID: AudioDeviceIOProcID?
            let st1 = AudioDeviceCreateIOProcIDWithBlock(&procID, outID, nil) { _, _, _, _, _ in counter.n += 1 }
            let st2 = AudioDeviceStart(outID, procID)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0; var sz = UInt32(4)
            AudioObjectGetPropertyData(outID, &runAddr, 0, nil, &sz, &running)
            AudioDeviceStop(outID, procID)
            if let procID { AudioDeviceDestroyIOProcID(outID, procID) }
            print("Raw HAL IOProc on output device: create=\(st1) start=\(st2) running=\(running) callbacks=\(counter.n)")
        }
        var variants: [(String, SystemAudioCapture.Options)] = [("default", .default)]
        if arguments.contains("--all-variants") {
            var o = SystemAudioCapture.Options(); o.mixdownAllProcesses = false; variants.append(("global tap", o))
            o = .init(); o.mixdownAllProcesses = false; o.excludeSelf = true; variants.append(("global exclude self", o))
        }
        for (name, opts) in variants {
            let sys = Stats()
            let tap = SystemAudioCapture { s, _ in sys.add(s) }
            do {
                try tap.start(options: opts)
                print("  aggregate: \(tap.aggregateDebugDescription)")
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                let running = tap.isAggregateRunning
                tap.stop()
                print("System audio [\(name)]: running=\(running) \(sys.text)")
            } catch {
                print("System audio [\(name)] failed: \(error)")
            }
        }
        return 0
    }
}
