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
    private let onConfirmStop: () -> Void
    private let onTogglePause: () -> Void
    private let onOpenSettings: () -> Void
    private let onQuit: () -> Void
    private var cancellables = Set<AnyCancellable>()

    static let idleWidth: CGFloat = 32
    static let pillWidth: CGFloat = 78
    /// Clicks right of this x (inside the pill) hit the pause button.
    static let pauseRegionStart: CGFloat = 58
    /// Status bar items are 24 pt tall although the button itself is only 22 pt; the hosting view
    /// is oversized by 1 pt on each side so the recording pill can use the full item height.
    static let height: CGFloat = 24

    init(state: AppState, onToggleRecording: @escaping () -> Void, onConfirmStop: @escaping () -> Void, onTogglePause: @escaping () -> Void, onOpenSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.state = state
        self.onToggleRecording = onToggleRecording
        self.onConfirmStop = onConfirmStop
        self.onTogglePause = onTogglePause
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: StatusItemController.idleWidth)
        hostingView = NSHostingView(rootView: PillView(state: state))
        hostingView.frame = NSRect(x: 0, y: 0, width: StatusItemController.idleWidth, height: StatusItemController.height)

        if let button = statusItem.button {
            button.addSubview(hostingView)
            hostingView.frame.origin.y = (button.bounds.height - StatusItemController.height) / 2
            hostingView.autoresizingMask = [.width]
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Transcriber – click to record, right-click for settings"
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
        } else if state.isRecording {
            onConfirmStop()
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
            if AITool.isConfigured {
                let ai = NSMenuItem(title: "Open Last Transcript in \(AITool.toolDisplayName)…", action: #selector(menuOpenLastInAI), keyEquivalent: "")
                ai.target = self
                ai.representedObject = url
                menu.addItem(ai)
            }
        }

        menu.addItem(.separator())
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(menuCheckUpdates), keyEquivalent: "")
        update.target = self
        menu.addItem(update)
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Transcriber", action: #selector(menuQuit), keyEquivalent: "q")
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
    @objc private func menuOpenLastInAI(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        AITool.open(session: url)
    }
    @objc private func menuOpenLast(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let md = url.appendingPathComponent("transcript.md")
        guard FileManager.default.fileExists(atPath: md.path) else { NSWorkspace.shared.open(url); return }
        // Show the file selected in its folder and open the Quick Look preview, like pressing Space.
        NSWorkspace.shared.activateFileViewerSelecting([md])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { QuickLook.shared.preview(md) }
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

    private var displayLink: CADisplayLink?
    private var animStart: CGFloat = 0
    private var animTarget: CGFloat = 0
    private var animBegan: CFTimeInterval = 0
    private var animLastTick: CFTimeInterval = 0
    private var animWorstGap: CFTimeInterval = 0
    private var animTicks = 0
    private static let animDuration: CFTimeInterval = 0.25

    /// Drives NSStatusItem.length from a display link (synchronised with the screen refresh,
    /// unlike a Timer), keeping it in step with the SwiftUI content animation of the same length.
    private func animateLength(to target: CGFloat) {
        displayLink?.invalidate(); displayLink = nil
        let start = statusItem.length
        guard abs(start - target) > 0.5 else { return }
        animStart = start; animTarget = target
        animBegan = CACurrentMediaTime(); animLastTick = animBegan
        animWorstGap = 0; animTicks = 0
        let link = hostingView.displayLink(target: self, selector: #selector(animationTick(_:)))
        link.add(to: .main, forMode: .common)   // keeps running while a menu or modal panel is open
        displayLink = link
    }

    @objc private func animationTick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        animWorstGap = max(animWorstGap, now - animLastTick)
        animLastTick = now
        animTicks += 1
        let t = min(1, (now - animBegan) / StatusItemController.animDuration)
        let eased = 1 - pow(1 - t, 3)
        statusItem.length = animStart + (animTarget - animStart) * eased
        hostingView.frame.size.width = statusItem.length
        if t >= 1 {
            link.invalidate()
            displayLink = nil
            if animWorstGap > 0.03 {
                AppLog.write(String(format: "Menu bar animation to %.0f: %d ticks, worst frame gap %.0f ms", animTarget, animTicks, animWorstGap * 1000))
            }
        }
    }
}
