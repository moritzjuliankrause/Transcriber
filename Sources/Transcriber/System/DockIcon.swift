import AppKit

/// Switches between a menu-bar-only app (accessory) and a regular app with a Dock icon.
enum DockIcon {
    @MainActor
    static func apply(_ show: Bool) {
        let policy: NSApplication.ActivationPolicy = show ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Bring our windows back to front: changing the policy can push the app behind others.
        if NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
