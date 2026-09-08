import AppKit
import UserNotifications
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController!
    private var settingsWindowController: SettingsWindowController?
    private var floatingBar: FloatingBarController?
    private var hotKey: HotKey?
    private var callDetector: CallDetector?

    let settings = AppSettings.shared
    let state = AppState.shared
    lazy var coordinator = RecordingCoordinator(settings: settings, state: state)

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.apply(settings.showDockIcon)
        AppSettings.applyAppearance(settings.appearance)
        statusItemController = StatusItemController(
            state: state,
            onToggleRecording: { [weak self] in self?.toggleRecording() },
            onConfirmStop: { [weak self] in self?.floatingBar?.confirmStop { self?.toggleRecording() } },
            onTogglePause: { [weak self] in self?.coordinator.togglePause() },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        floatingBar = FloatingBarController(state: state, settings: settings)
        FloatingBarController.shared = floatingBar
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.floatingBar?.prepare() }

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.toggleRecording()
        }

        callDetector = CallDetector(settings: settings, state: state) { [weak self] in
            self?.toggleRecording()
        }

        // A UI test instance (`--bar-test`) runs next to the installed app: no login item, model
        // loading, update check or recovery prompt for the other instance's open session.
        let uiTest = CommandLine.arguments.contains("--bar-test")
        if !uiTest {
            ConsentNotice.showIfNeeded(settings: settings)
            LaunchAtLogin.sync(enabled: settings.launchAtLogin)

            Task {
                await ModelManager.shared.refreshStatus()
                ModelSetupPrompt.showIfNeeded(settings: settings) { [weak self] in self?.showSettings(section: .transcription) }
            }
            Task { await ModelCache.shared.preload(settings: settings) }
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // don't compete with launch work
                await UpdateChecker.shared.checkAutomaticallyIfDue()
            }
            Task { await SessionRecovery.checkOnLaunch(settings: settings, state: state) }
        }

        if settings.outputDirectory.isEmpty {
            settings.outputDirectory = AppSettings.defaultOutputDirectory.path
        }
        // Development aid: `Transcriber --settings` opens the Settings window right away.
        if let i = CommandLine.arguments.firstIndex(of: "--settings") {
            let name = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
            showSettings(section: SettingsView.Section.allCases.first { $0.rawValue.lowercased() == name.lowercased() })
        }
        if CommandLine.arguments.contains("--changelog") { ChangelogWindowController.shared.show() }
        // Development aid: `Transcriber --start` begins recording right after launch.
        if CommandLine.arguments.contains("--start") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.toggleRecording() }
        }
        // Development aid: `Transcriber --cycle` records, stops (skipping the title), records again.
        if CommandLine.arguments.contains("--cycle") {
            let t = { (d: Double, f: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + d) { f() } }
            t(1.5) { [weak self] in self?.toggleRecording() }
            t(9) { [weak self] in self?.toggleRecording() }
            t(15) { [weak self] in self?.floatingBar?.skipTitle() }
            t(20) { [weak self] in self?.toggleRecording() }
        }
        // Development aid: `Transcriber --bar-test` shows the floating bar in its paused state
        // without recording anything (combine with `--bar-offset 80` next to a running instance).
        if CommandLine.arguments.contains("--bar-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.state.recordingStartedAt = Date()
                self.state.phase = .recording
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.state.isPaused = true }
            }
        }
        // Development aid: `Transcriber --title-test` shows the bar's save prompt right away.
        if CommandLine.arguments.contains("--title-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                for w in NSApp.windows {
                    AppLog.write("Window: \(type(of: w)) level=\(w.level.rawValue) frame=\(w.frame) visible=\(w.isVisible) alpha=\(w.alphaValue) title=\(w.title) content=\(w.contentView.map { String(describing: type(of: $0)) } ?? "-")")
                }
            }
            Task { @MainActor in
                let answer = await TitlePrompt.ask(defaultTitle: "")
                AppLog.write("Title test: \(answer.title ?? "<none>") openInAI=\(answer.openInAI)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if state.isRecording {
            // Best effort: flush what we have so nothing is lost on quit. The stop runs on the
            // main actor, so keep the run loop turning instead of blocking the main thread.
            var done = false
            Task { @MainActor in
                await coordinator.stop()
                done = true
            }
            let deadline = Date().addingTimeInterval(15)
            while !done, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
        }
    }

    // MARK: - Actions

    func toggleRecording() {
        if case .stopping = state.phase { return }   // finalizing: neither start nor stop again
        Task { @MainActor in
            if state.isRecording {
                await coordinator.stop()
            } else {
                await coordinator.start()
            }
        }
    }

    func showSettings(section: SettingsView.Section? = nil) {
        if let section { SettingsNavigation.shared.section = section }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, state: state)
        }
        settingsWindowController?.show()
    }
}
