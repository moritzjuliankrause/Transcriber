import AppKit

// Entry point. Transcriber is a menu-bar-only application (LSUIElement), so we
// bootstrap NSApplication manually and use the accessory activation policy.
// `Transcriber --transcribe <file>` runs the transcription pipeline headlessly.

if CommandLine.arguments.contains("--record-test") {
    let code = await RecordTest.run(arguments: CommandLine.arguments)
    exit(code)
}
if CommandLine.arguments.contains("--capture-test") {
    let code = await CaptureTest.run(arguments: CommandLine.arguments)
    exit(code)
}
if CommandLine.arguments.contains("--render-hero") {
    let code = await HeroRender.run(arguments: CommandLine.arguments)
    exit(code)
}
if CommandLine.arguments.contains("--render-bar") {
    let code = await HeroRender.runBar(arguments: CommandLine.arguments)
    exit(code)
}
if CommandLine.arguments.contains("--transcribe") {
    let code = await HeadlessTranscribe.run(arguments: CommandLine.arguments)
    exit(code)
}

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
