import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: AppSettings, state: AppState) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        let view = SettingsView(settings: settings, state: state, models: ModelManager.shared) { [weak window] in
            window?.close()
        }
        window.title = "Transcriber Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The view draws its own close button (top right), like a sheet.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []          // the window, not the view's ideal size, decides the frame
        window.contentView = host
        window.isReleasedWhenClosed = false
        // fullSizeContentView: the content covers the whole frame, so size the frame itself.
        window.setFrame(NSRect(origin: .zero, size: SettingsView.size), display: false)
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
