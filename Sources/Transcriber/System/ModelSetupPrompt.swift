import AppKit

/// First launch: offers to download the speech models right away instead of on the
/// first recording, where the download would delay the start by minutes.
enum ModelSetupPrompt {
    @MainActor
    static func showIfNeeded(settings: AppSettings, openSettings: @escaping () -> Void) {
        let models = ModelManager.shared
        var missing: [String] = []
        if !models.asrStatus.isReady { missing.append("speech recognition (about 600 MB)") }
        if !models.vadStatus.isReady { missing.append("voice activity detection") }
        if settings.diarizeRemote, !models.diarizerStatus.isReady { missing.append("speaker diarization") }
        guard !missing.isEmpty, !settings.modelsPromptShown else { return }
        settings.modelsPromptShown = true

        let alert = NSAlert()
        alert.messageText = "Download the speech models?"
        alert.informativeText = "Transcriber runs fully offline, but needs to download its models once from Hugging Face: \(missing.joined(separator: ", ")). Otherwise the download happens at the start of your first recording and delays it by several minutes."
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openSettings()          // Transcription section shows the progress per model
        Task { await models.downloadAll(); await models.refreshStatus() }
    }
}
