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
        statusItemController = StatusItemController(
            state: state,
            onToggleRecording: { [weak self] in self?.toggleRecording() },
            onConfirmStop: { [weak self] in self?.floatingBar?.confirmStop { self?.toggleRecording() } },
            onTogglePause: { [weak self] in self?.coordinator.togglePause() },
            onOpenSettings: { [weak self] in self?.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )

        floatingBar = FloatingBarController(state: state, settings: settings)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.floatingBar?.prepare() }

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.toggleRecording()
        }

        callDetector = CallDetector(settings: settings, state: state) { [weak self] in
            self?.toggleRecording()
        }

        ConsentNotice.showIfNeeded(settings: settings)
        LaunchAtLogin.sync(enabled: settings.launchAtLogin)

        Task { await ModelManager.shared.refreshStatus() }
        Task { await ModelCache.shared.preload(settings: settings) }
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)   // don't compete with launch work
            await UpdateChecker.shared.checkAutomaticallyIfDue()
        }
        Task { await SessionRecovery.checkOnLaunch(settings: settings, state: state) }

        if settings.outputDirectory.isEmpty {
            settings.outputDirectory = AppSettings.defaultOutputDirectory.path
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

    func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, state: state)
        }
        settingsWindowController?.show()
    }
}
