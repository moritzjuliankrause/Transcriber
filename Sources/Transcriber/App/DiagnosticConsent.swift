import AppKit

/// Launch flags that record (`--record-test`, `--capture-test`, `--start`, `--cycle`) run under
/// this app's microphone and system-audio grants. Any program running as the user can launch us
/// with arguments (`open -a … --args`), and TCC attributes the capture to Transcriber, not to
/// that program. Release builds therefore ask the person at the keyboard first; debug builds
/// (development, self-tests) do not.
enum DiagnosticConsent {
    @MainActor
    static func confirm(_ flag: String, duration: String) -> Bool {
        #if DEBUG
        return true
        #else
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start a recording?"
        alert.informativeText = "Transcriber was launched with \(flag) and would record your microphone and system audio \(duration). Only allow this if you started it yourself."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Don't Record")
        alert.addButton(withTitle: "Record")
        let allowed = alert.runModal() == .alertSecondButtonReturn
        AppLog.write("Launch flag \(flag): recording \(allowed ? "allowed" : "refused") by the user")
        return allowed
        #endif
    }
}
