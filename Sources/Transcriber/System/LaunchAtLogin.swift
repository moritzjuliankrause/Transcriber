import Foundation
import ServiceManagement

enum LaunchAtLogin {
    /// Only works when running from a real .app bundle (see scripts/bundle.sh).
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func sync(enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch at login change failed: \(error)")
        }
    }
}
