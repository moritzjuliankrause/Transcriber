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
    private var retentionTimer: Timer?

    let settings = AppSettings.shared
    let state = AppState.shared
    lazy var coordinator = RecordingCoordinator(settings: settings, state: state)

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIcon.apply(settings.showDockIcon)
        AppSettings.applyAppearance(settings.appearance)
        NSApp.mainMenu = AppDelegate.makeMainMenu()
        statusItemController = StatusItemController(
            state: state,
            onToggleRecording: { [weak self] in self?.toggleRecording() },
            onConfirmStop: { [weak self] in self?.floatingBar?.confirmStop { self?.toggleRecording() } },
            onTogglePause: { [weak self] in self?.coordinator.togglePause() },
            onToggleMute: { [weak self] in self?.coordinator.toggleMicMute() },
            onReconnectAudio: { [weak self] in self?.coordinator.reconnectAudio() },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenRecordings: { [weak self] in self?.showSettings(section: .recordings) },
            onQuit: { NSApp.terminate(nil) }
        )

        floatingBar = FloatingBarController(state: state, settings: settings)
        floatingBar?.onToggleMute = { [weak self] in self?.coordinator.toggleMicMute() }
        floatingBar?.onTogglePause = { [weak self] in self?.coordinator.togglePause() }
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
        let uiTest = CommandLine.arguments.contains("--bar-test") || CommandLine.arguments.contains("--card-test")
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
            // Delete kept audio past its retention period: shortly after launch, then every 6 hours.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                RecordingHistory.shared.sweepExpiredAudio(settings: self.settings)
                self.retentionTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        RecordingHistory.shared.sweepExpiredAudio(settings: self.settings)
                    }
                }
            }
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
        if CommandLine.arguments.contains("--start"), DiagnosticConsent.confirm("--start", duration: "until you stop it") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.toggleRecording() }
        }
        // Development aid: `Transcriber --cycle` records, stops (skipping the title), records again.
        if CommandLine.arguments.contains("--cycle"), DiagnosticConsent.confirm("--cycle", duration: "for about 20 s and then again until you stop it") {
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
        // Development aid: `Transcriber --card-test` fakes a recording with some transcript, so the
        // pill (and, on hover, the transcript card) can be inspected without recording anything.
        // Add `--card-open` to pin the card open right away (for screenshots).
        if CommandLine.arguments.contains("--card-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let state = self.state
                state.recordingStartedAt = Date()
                state.phase = .recording
                state.sessionClock = { 60 }
                let me = self.settings.myName
                let lines: [(Channel, Int?, String)] = [
                    (.them, 1, "Good morning everyone, let's get started. We have a lot on the agenda today, so I'd suggest we keep the updates short."),
                    (.me, nil, "Sounds good. I can start with the release status if that helps."),
                    (.them, 2, "Yes please, go ahead. And afterwards I'd like to talk about the budget for the next quarter, because the numbers changed quite a bit since last week."),
                    (.me, nil, "Okay. The release candidate is ready, we found two smaller issues in testing and both are fixed now."),
                    (.them, 2, "That's great news. Do we already know when it goes out to customers?"),
                ]
                state.voiceNumbers = [1: 1, 2: 2]
                state.voiceNames = [2: "Anna"]
                state.currentVoice = 2
                for (i, l) in lines.enumerated() {
                    state.appendLive(TranscriptLine(channel: l.0, speaker: l.1 == nil ? me : state.label(forVoice: l.1), text: l.2, voice: l.1, start: Double(i) * 8), channel: l.0)
                }
                // A partial with a long blurred tail; refreshed so it does not time out.
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                    Task { @MainActor in
                        guard state.phase == .recording else { return }
                        state.updatePartial(TranscriptLine(channel: .me, speaker: me, text: "We are planning the rollout for next Tuesday, starting with ten percent of the users and then the rest on Thursday if nothing unexpected shows up in the crash reports", start: 40, stableWords: 9), channel: .me)
                    }
                }.fire()
                if CommandLine.arguments.contains("--card-open") { self.floatingBar?.pinCardForTesting() }
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

    /// A menu-bar (accessory) app has no menu bar, but without a main menu the standard text
    /// editing shortcuts (⌘C/⌘V/⌘X/⌘A/⌘Z) are dead in every text field — Settings, the title
    /// prompt, the speaker-name fields. A minimal App + Edit menu wires those key equivalents to
    /// the first responder (the field editor handles them).
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return main
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
