import AppKit
import SwiftUI
import Combine

/// The menu bar item: a small black dot when idle, a red dot that expands into
/// a pill with a live waveform while recording. Left click toggles recording,
/// right click opens the menu / settings.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let hostingView: NSHostingView<PillView>
    private let state: AppState
    private let onToggleRecording: () -> Void
    private let onTogglePause: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var lengthAnimator: Timer?

    static let idleWidth: CGFloat = 26
    static let pillWidth: CGFloat = 64
    /// Clicks right of this x (inside the pill) hit the pause button.
    static let pauseRegionStart: CGFloat = 44
    static let height: CGFloat = 22

    init(state: AppState, onToggleRecording: @escaping () -> Void, onTogglePause: @escaping () -> Void, onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.state = state
        self.onToggleRecording = onToggleRecording
        self.onTogglePause = onTogglePause
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: StatusItemController.idleWidth)
        hostingView = NSHostingView(rootView: PillView(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: StatusItemController.idleWidth, height: StatusItemController.height)

        if let button = statusItem.button {
            button.addSubview(hostingView)
            hostingView.autoresizingMask = [.width, .height]
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "AnyRecord – click to record, right-click for settings"
        }

        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.updateWidth(for: phase) }
            .store(in: &cancellables)
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else if case .recording = state.phase, let button = statusItem.button,
                  button.convert(event.locationInWindow, from: nil).x >= StatusItemController.pauseRegionStart {
            onTogglePause()
        } else {
            onToggleRecording()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let statusTitle: String
        switch state.phase {
        case .idle: statusTitle = "Ready"
        case .starting: statusTitle = "Starting…"
        case .recording: statusTitle = state.isPaused ? "Paused" : "Recording"
        case .stopping(let msg): statusTitle = msg
        }
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        if let error = state.lastError {
            let item = NSMenuItem(title: "⚠︎ \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: state.isRecording ? "Stop & Save" : "Start Recording", action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        if case .recording = state.phase {
            let pause = NSMenuItem(title: state.isPaused ? "Resume" : "Pause", action: #selector(menuPause), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
        }

        let openFolder = NSMenuItem(title: "Open Transcripts Folder", action: #selector(menuOpenFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        if let url = state.currentSessionURL {
            let openLast = NSMenuItem(title: "Open Last Transcript", action: #selector(menuOpenLast), keyEquivalent: "")
            openLast.target = self
            openLast.representedObject = url
            menu.addItem(openLast)
        }

        menu.addItem(.separator())
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit AnyRecord", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuToggle() { onToggleRecording() }
    @objc private func menuPause() { onTogglePause() }
    @objc private func menuCheckUpdates() { Task { await UpdateChecker.shared.check(interactive: true) } }
    @objc private func menuSettings() { onOpenSettings() }
    @objc private func menuQuit() { onQuit() }
    @objc private func menuOpenFolder() {
        let url = AppSettings.shared.outputDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    @objc private func menuOpenLast(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let md = url.appendingPathComponent("transcript.md")
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: md.path) ? md : url)
    }

    // MARK: - Width animation (NSStatusItem.length is not animatable)

    private func updateWidth(for phase: AppState.Phase) {
        let target: CGFloat
        switch phase {
        case .idle: target = StatusItemController.idleWidth
        case .starting, .recording, .stopping: target = StatusItemController.pillWidth
        }
        animateLength(to: target)
    }

    private func animateLength(to target: CGFloat) {
        lengthAnimator?.invalidate()
        let start = statusItem.length
        guard abs(start - target) > 0.5 else { return }
        let duration: TimeInterval = 0.25
        let began = Date()
        lengthAnimator = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(began) / duration)
            let eased = 1 - pow(1 - t, 3)
            self.statusItem.length = start + (target - start) * eased
            self.hostingView.frame.size.width = self.statusItem.length
            if t >= 1 { timer.invalidate() }
        }
    }
}
