import AppKit
import ApplicationServices
import Foundation

/// Hands a finished transcript to the user's AI tool of choice together with a
/// prompt, so they only have to press Enter.
///
/// - Website: the prompt is put into the URL (`{prompt}` placeholder), e.g.
///   `https://claude.ai/new?q={prompt}`. Very long transcripts exceed what a URL
///   can carry, then the text goes to the clipboard and the page opens empty.
/// - App: there is no public "prefill" interface for desktop apps, so the text is
///   copied to the clipboard, the app is activated and – with the Accessibility
///   permission – ⌘V is sent automatically.
enum AITool {
    static let maxURLPromptLength = 8_000     // stays well below the ~16 KB URL limit of common CDNs

    struct Preset {
        let name: String
        let url: String
    }
    static let presets: [Preset] = [
        Preset(name: "Claude (web)", url: "https://claude.ai/new?q={prompt}"),
        Preset(name: "ChatGPT (web)", url: "https://chatgpt.com/?q={prompt}"),
        Preset(name: "Perplexity (web)", url: "https://www.perplexity.ai/search?q={prompt}"),
    ]

    static let defaultPrompt = """
    Below is the transcript of a call. Please give me:

    1. A concise summary (5–10 sentences) of what was discussed and decided.
    2. A list of actionable to-dos, each with the responsible person if it was mentioned and any deadline.
    3. Open questions that were raised but not resolved.

    Keep the language of the transcript.

    ---
    {transcript}
    """

    @MainActor
    static var toolDisplayName: String {
        let s = AppSettings.shared
        if s.aiToolMode == "app" {
            let path = s.aiToolAppPath
            return path.isEmpty ? "AI app" : (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        if let host = URL(string: s.aiToolURL)?.host { return host.replacingOccurrences(of: "www.", with: "") }
        return "AI tool"
    }

    @MainActor
    static var isConfigured: Bool {
        let s = AppSettings.shared
        return s.aiToolMode == "app" ? !s.aiToolAppPath.isEmpty : !s.aiToolURL.isEmpty
    }

    /// Builds the prompt for a session folder (uses transcript.md).
    static func prompt(forSession directory: URL) -> String? {
        let md = directory.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: md, encoding: .utf8) else { return nil }
        let template = AppSettings.shared.aiPromptTemplate
        let base = template.isEmpty ? defaultPrompt : template
        return base.contains("{transcript}") ? base.replacingOccurrences(of: "{transcript}", with: transcript) : base + "\n\n" + transcript
    }

    @MainActor
    static func open(session directory: URL) {
        guard let text = prompt(forSession: directory) else {
            alert("No transcript found", "transcript.md is missing in \(directory.lastPathComponent).")
            return
        }
        let settings = AppSettings.shared
        if settings.aiToolMode == "app" {
            openInApp(path: settings.aiToolAppPath, text: text, autoPaste: settings.aiAutoPaste)
        } else {
            openWebsite(template: settings.aiToolURL, text: text)
        }
        AppLog.write("Opened transcript in \(toolDisplayName) (\(text.count) chars)")
    }

    // MARK: - Website

    @MainActor
    private static func openWebsite(template: String, text: String) {
        guard !template.isEmpty else { alert("No AI tool configured", "Choose a website or app in Settings › AI."); return }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        if encoded.count <= maxURLPromptLength, let url = URL(string: template.replacingOccurrences(of: "{prompt}", with: encoded)) {
            NSWorkspace.shared.open(url)
            return
        }
        // Too long for a URL (the normal case for a real call): clipboard, open the page
        // without the query and paste into the focused input once the page is up.
        copy(text)
        let bare = template.components(separatedBy: "?").first ?? template
        if let url = URL(string: bare) { NSWorkspace.shared.open(url) }
        if AppSettings.shared.aiAutoPaste {
            pasteWhenReady(after: 3.0)
        } else {
            notifyPaste()
        }
    }

    /// Sends ⌘V after a delay if Accessibility is granted, otherwise asks for it once.
    private static func pasteWhenReady(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if AXIsProcessTrusted() {
                sendPaste()
            } else {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(options)
                Task { @MainActor in notifyPaste() }
            }
        }
    }

    // MARK: - App

    @MainActor
    private static func openInApp(path: String, text: String, autoPaste: Bool) {
        guard !path.isEmpty else { alert("No AI tool configured", "Choose a website or app in Settings › AI."); return }
        copy(text)
        let appURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                Task { @MainActor in alert("Could not open app", error.localizedDescription) }
                return
            }
            guard autoPaste else { Task { @MainActor in notifyPaste() }; return }
            pasteWhenReady(after: 1.5)
        }
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    private static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @MainActor
    private static func notifyPaste() {
        let alert = NSAlert()
        alert.messageText = "Transcript copied"
        alert.informativeText = "The prompt with the transcript is in your clipboard. Paste it with ⌘V into \(toolDisplayName) and press Enter."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}
