import AppKit

/// One-time reminder that recording conversations requires consent in most
/// jurisdictions (e.g. § 201 StGB in Germany).
enum ConsentNotice {
    @MainActor
    static func showIfNeeded(settings: AppSettings) {
        guard !settings.consentAcknowledged else { return }
        let alert = NSAlert()
        alert.messageText = "Recording calls requires consent"
        alert.informativeText = "Transcriber records both your microphone and everything your Mac plays. In many countries, including Germany, recording a conversation without informing the other participants is illegal. Please tell people before you record. You can enable a start tone in Settings as a reminder."
        alert.addButton(withTitle: "I understand")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        settings.consentAcknowledged = true
    }
}
