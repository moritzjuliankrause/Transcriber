#if DEBUG
import AppKit
import CoreAudio

/// `Transcriber --call-watch [minutes] [--log file]` (debug builds only) – logs which processes
/// start and stop using audio input / output, to learn how FaceTime, phone calls, Zoom, Teams,
/// Meet & co. show up before building per-app call detection. Read-only: records nothing.
enum CallWatch {
    private struct Usage: Equatable {
        var input = false
        var output = false
    }

    static func run(arguments: [String]) async -> Int32 {
        var minutes = 0.0   // 0 = until killed
        if let i = arguments.firstIndex(of: "--call-watch"), i + 1 < arguments.count, let m = Double(arguments[i + 1]) { minutes = m }
        if let li = arguments.firstIndex(of: "--log"), li + 1 < arguments.count {
            freopen(arguments[li + 1], "a", stdout)
            setvbuf(stdout, nil, _IONBF, 0)
            dup2(fileno(stdout), fileno(stderr))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        func log(_ line: String) { print("\(formatter.string(from: Date())) \(line)") }

        log("call-watch started\(minutes > 0 ? " for \(minutes) min" : ""); mic = \(AudioDevices.defaultInputDevice()?.name ?? "-"), output = \(AudioDevices.defaultOutputDevice()?.name ?? "-")")
        let started = Date()
        var known: [AudioObjectID: Usage] = [:]
        var micBusy = false
        while minutes <= 0 || Date().timeIntervalSince(started) < minutes * 60 {
            var current: [AudioObjectID: Usage] = [:]
            for object in SystemAudioCapture.allProcessObjects() {
                current[object] = Usage(input: flag(object, kAudioProcessPropertyIsRunningInput),
                                        output: flag(object, kAudioProcessPropertyIsRunningOutput))
            }
            for (object, now) in current {
                let before = known[object] ?? Usage()
                guard now != before else { continue }
                var changes: [String] = []
                if now.input != before.input { changes.append(now.input ? "+IN" : "-IN") }
                if now.output != before.output { changes.append(now.output ? "+OUT" : "-OUT") }
                log("\(changes.joined(separator: " ").padding(toLength: 9, withPad: " ", startingAt: 0)) \(describe(object))  [now IN=\(now.input ? 1 : 0) OUT=\(now.output ? 1 : 0)]")
            }
            for (object, before) in known where current[object] == nil && (before.input || before.output) {
                log("gone      process object \(object)")
            }
            known = current
            if let mic = AudioDevices.defaultInputDevice() {
                let busy = AudioDevices.isRunningSomewhere(mic.id)
                if busy != micBusy {
                    micBusy = busy
                    let front = await MainActor.run { NSWorkspace.shared.frontmostApplication }
                    log("mic \(busy ? "IN USE" : "idle") (front app: \(front?.bundleIdentifier ?? "-"))")
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log("call-watch finished")
        return 0
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Bundle id from Core Audio, plus pid, process name and – for helper processes such as
    /// "Google Chrome Helper" or WebKit's GPU process – the app that owns them.
    private static func describe(_ object: AudioObjectID) -> String {
        let bundleID = AudioDevices.stringProperty(object, kAudioProcessPropertyBundleID) ?? "?"
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid)
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        let app = NSRunningApplication(processIdentifier: pid)
        var text = "\(bundleID) pid=\(pid) name=\(String(cString: name))"
        if let app, let appName = app.localizedName { text += " app=\(appName)" }
        let path = app?.bundleURL?.path ?? ""
        if let range = path.range(of: ".app/") { text += " owner=\((path[..<range.lowerBound] as Substring).split(separator: "/").last ?? "")" }
        return text
    }
}
#endif
