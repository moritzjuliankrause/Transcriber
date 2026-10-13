import AppKit
import SwiftUI

/// The menu bar item: the app glyph, red while recording. Left click starts recording or (while
/// recording) asks to stop; right click opens the menu / settings.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let hostingView: NSHostingView<PillView>
    private let state: AppState
    private let onToggleRecording: () -> Void
    private let onConfirmStop: () -> Void
    private let onTogglePause: () -> Void
    private let onToggleMute: () -> Void
    private let onReconnectAudio: () -> Void
    private let onOpenSettings: () -> Void
    private let onOpenRecordings: () -> Void
    private let onQuit: () -> Void

    static let idleWidth: CGFloat = 32
    /// Status bar items are 24 pt tall although the button itself is only 22 pt; the hosting view
    /// is oversized by 1 pt on each side so the recording pill can use the full item height.
    static let height: CGFloat = 24

    init(state: AppState, onToggleRecording: @escaping () -> Void, onConfirmStop: @escaping () -> Void, onTogglePause: @escaping () -> Void, onToggleMute: @escaping () -> Void, onReconnectAudio: @escaping () -> Void, onOpenSettings: @escaping () -> Void, onOpenRecordings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.state = state
        self.onToggleRecording = onToggleRecording
        self.onConfirmStop = onConfirmStop
        self.onTogglePause = onTogglePause
        self.onToggleMute = onToggleMute
        self.onReconnectAudio = onReconnectAudio
        self.onOpenSettings = onOpenSettings
        self.onOpenRecordings = onOpenRecordings
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
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
        } else if state.isRecording {
            onConfirmStop()
        } else if case .stopping = state.phase {
            return                      // finalizing – wait for it
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
        if case .stopping = state.phase { toggle.isEnabled = false }   // finalizing – neither is possible
        menu.addItem(toggle)
        if case .recording = state.phase {
            let pause = NSMenuItem(title: state.isPaused ? "Resume" : "Pause", action: #selector(menuPause), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
            if AppSettings.shared.captureMicrophone {
                let mute = NSMenuItem(title: state.isMicMuted ? "Unmute Microphone" : "Mute Microphone", action: #selector(menuMute), keyEquivalent: "")
                mute.target = self
                menu.addItem(mute)
            }
            // Manual fallback when a channel stays silent (e.g. after a call app reconfigured
            // the audio devices while the recording started).
            let reconnect = NSMenuItem(title: "Reconnect Audio", action: #selector(menuReconnect), keyEquivalent: "")
            reconnect.target = self
            menu.addItem(reconnect)
        }

        let recordings = NSMenuItem(title: "Recordings…", action: #selector(menuRecordings), keyEquivalent: "")
        recordings.target = self
        menu.addItem(recordings)

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
    @objc private func menuMute() { onToggleMute() }
    @objc private func menuReconnect() { onReconnectAudio() }
    @objc private func menuCheckUpdates() { Task { await UpdateChecker.shared.check(interactive: true) } }
    @objc private func menuSettings() { onOpenSettings() }
    @objc private func menuRecordings() { onOpenRecordings() }
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
}
