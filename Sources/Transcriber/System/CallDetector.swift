import AppKit
import CoreAudio
import UserNotifications

/// Watches whether some other process starts using the default microphone –
/// a strong hint that a call began. Shows a notification offering to record.
final class CallDetector: NSObject, UNUserNotificationCenterDelegate {
    private let settings: AppSettings
    private let state: AppState
    private let onStart: () -> Void
    private var listener: AudioPropertyListener?
    private var defaultListener: AudioPropertyListener?
    private var wasRunning = false
    private var lastPrompt = Date.distantPast
    private let notificationsAvailable = Bundle.main.bundleURL.pathExtension == "app"

    init(settings: AppSettings, state: AppState, onStart: @escaping () -> Void) {
        self.settings = settings
        self.state = state
        self.onStart = onStart
        super.init()
        if notificationsAvailable {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            let action = UNNotificationAction(identifier: "record", title: "Start recording", options: [.foreground])
            let category = UNNotificationCategory(identifier: "call", actions: [action], intentIdentifiers: [])
            center.setNotificationCategories([category])
        }
        attach()
        defaultListener = AudioPropertyListener(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
            self?.attach()
        }
    }

    private func attach() {
        guard let device = AudioDevices.defaultInputDevice() else { listener = nil; return }
        wasRunning = AudioDevices.isRunningSomewhere(device.id)
        listener = AudioPropertyListener(objectID: device.id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in
            self?.evaluate(deviceID: device.id)
        }
    }

    private func evaluate(deviceID: AudioDeviceID) {
        let running = AudioDevices.isRunningSomewhere(deviceID)
        defer { wasRunning = running }
        guard running, !wasRunning, settings.detectCalls else { return }
        Task { @MainActor in
            guard !state.isRecording, Date().timeIntervalSince(lastPrompt) > 30 else { return }
            lastPrompt = Date()
            prompt()
        }
    }

    private func prompt() {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Call detected"
        content.body = "An app started using the microphone. Record and transcribe it?"
        content.categoryIdentifier = "call"
        content.sound = nil
        let request = UNNotificationRequest(identifier: "call-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "record" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onStart() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
