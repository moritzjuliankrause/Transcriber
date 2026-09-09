import AppKit
import ApplicationServices
import Foundation

/// Hands a finished transcript to the user's AI tool of choice together with a
/// prompt, so they only have to press Enter.
///
/// - Website: the prompt is put into the URL (`{prompt}` placeholder), e.g.
///   `https://claude.ai/new?q={prompt}`. Very long transcripts exceed what a URL
///   can carry, then the text goes to the clipboard and the page opens empty.
/// - App: there is no public "prefill" interface for desktop apps, so the app is
///   activated and – with the Accessibility permission – ⌘V is sent automatically.
///   With "attach file" on, two pastes are sent: first transcript.md as a file (the
///   chat apps treat a pasted file like a dropped attachment), then the prompt text.
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

    /// Previous default, replaced automatically when a user still has it stored.
    static let legacyDefaultPrompt = """
    Below is the transcript of a call. Please give me:

    1. A concise summary (5–10 sentences) of what was discussed and decided.
    2. A list of actionable to-dos, each with the responsible person if it was mentioned and any deadline.
    3. Open questions that were raised but not resolved.

    Keep the language of the transcript.

    ---
    {transcript}
    """

    static let defaultPrompt = """
    Below is the transcript of a call or video meeting. It was recorded and transcribed automatically, so speaker labels and some words may be wrong – use the context to make sense of it.

    Please give me:

    1. What this was: work out what kind of meeting it was (e.g. 1:1, team sync, customer call, interview, planning session, casual chat), who took part and what it was about. One or two sentences.
    2. Summary: what was discussed and decided, concise (5–10 sentences), in the order the topics came up.
    3. To-dos: if any tasks, commitments or follow-ups came up, list them as actionable items grouped by the responsible person, most urgent first, with deadlines where mentioned. If there are none, say so.
    4. Open questions that were raised but not resolved.

    Keep the language of the transcript.
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

    static func transcriptURL(forSession directory: URL) -> URL { directory.appendingPathComponent("transcript.md") }

    /// Builds the prompt for a session folder (uses transcript.md).
    static func prompt(forSession directory: URL) -> String? {
        guard let transcript = try? String(contentsOf: transcriptURL(forSession: directory), encoding: .utf8) else { return nil }
        let base = template
        return base.contains("{transcript}") ? base.replacingOccurrences(of: "{transcript}", with: transcript) : base + "\n\n" + transcript
    }

    /// The prompt when the transcript travels as an attached file: the placeholder (and a
    /// separator line right before it) is replaced by a short pointer to the attachment.
    static func promptForAttachment() -> String {
        let note = "The transcript is attached as transcript.md."
        var base = template
        if let range = base.range(of: "---\n{transcript}") { base.replaceSubrange(range, with: note) }
        else if base.contains("{transcript}") { base = base.replacingOccurrences(of: "{transcript}", with: note) }
        else { base += "\n\n" + note }
        return base.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var template: String {
        let t = AppSettings.shared.aiPromptTemplate
        return t.isEmpty ? defaultPrompt : t
    }

    /// What ends up in the tool: one long text, or the file plus a short prompt.
    enum Payload {
        case text(String)
        case file(URL, prompt: String)
    }

    /// We ask the system to show its Accessibility grant dialog at most once per launch. Without
    /// this a stale or denied grant (e.g. an entry left over from the AnyRecord-era signature)
    /// would make `AXIsProcessTrusted()` return false and pop the dialog on *every* paste.
    private static var didRequestAccessibility = false

    @MainActor
    static func open(session directory: URL) {
        guard let text = prompt(forSession: directory) else {
            alert("No transcript found", "transcript.md is missing in \(directory.lastPathComponent).")
            return
        }
        let settings = AppSettings.shared
        let attach = settings.aiAutoPaste && settings.aiAttachFile
        let payload: Payload = attach ? .file(transcriptURL(forSession: directory), prompt: promptForAttachment()) : .text(text)
        if settings.aiToolMode == "app" {
            openInApp(path: settings.aiToolAppPath, payload: payload, autoPaste: settings.aiAutoPaste)
        } else {
            openWebsite(template: settings.aiToolURL, text: text, payload: payload)
        }
        AppLog.write("Opened transcript in \(toolDisplayName) (\(text.count) chars, \(attach ? "file + prompt" : "text"))")
    }

    // MARK: - Website

    @MainActor
    private static func openWebsite(template: String, text: String, payload: Payload) {
        guard !template.isEmpty else { alert("No AI tool configured", "Choose a website or app in Settings › AI."); return }
        if case .text = payload {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            if encoded.count <= maxURLPromptLength, let url = URL(string: template.replacingOccurrences(of: "{prompt}", with: encoded)) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        // Too long for a URL (the normal case for a real call): open the page without the
        // query and paste into the focused input once the page is up.
        let bare = template.components(separatedBy: "?").first ?? template
        if let url = URL(string: bare) { NSWorkspace.shared.open(url) }
        if AppSettings.shared.aiAutoPaste {
            pasteWhenReady(payload, after: 3.0)
        } else {
            copy(text)
            notifyPaste()
        }
    }

    /// Sends the payload as ⌘V (twice for file + prompt) after a delay if Accessibility is
    /// granted, otherwise asks for it once and falls back to the clipboard.
    @MainActor
    private static func pasteWhenReady(_ payload: Payload, after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard AXIsProcessTrusted() else {
                // Show the system grant dialog only the first time this launch; after that just
                // fall back to manual paste so we never nag on every paste.
                if !didRequestAccessibility {
                    didRequestAccessibility = true
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                }
                if case .text(let t) = payload { copy(t) } else if case .file(_, let p) = payload { copy(p) }
                notifyPaste()
                return
            }
            switch payload {
            case .text(let t):
                copy(t)
                sendPaste()
            case .file(let url, let prompt):
                copyFile(url)
                sendPaste()
                // Give the app a moment to pick up the attachment before the text arrives.
                try? await Task.sleep(for: .seconds(1.5))
                copy(prompt)
                sendPaste()
            }
            // The transcript has been delivered; do not leave it on the clipboard where every
            // app, clipboard managers and Universal Clipboard could pick it up later.
            try? await Task.sleep(for: .seconds(2))
            clearClipboardIfOurs()
        }
    }

    // MARK: - App

    @MainActor
    private static func openInApp(path: String, payload: Payload, autoPaste: Bool) {
        guard !path.isEmpty else { alert("No AI tool configured", "Choose a website or app in Settings › AI."); return }
        let appURL = URL(fileURLWithPath: path)
        // A cold launch needs noticeably longer before its input field accepts a paste.
        let bundleID = Bundle(url: appURL)?.bundleIdentifier
        let alreadyRunning = bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error { alert("Could not open app", error.localizedDescription); return }
                guard autoPaste else {
                    if case .text(let t) = payload { copy(t) } else if case .file(_, let p) = payload { copy(p) }
                    notifyPaste(); return
                }
                pasteWhenReady(payload, after: alreadyRunning ? 1.0 : 4.0)
            }
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

    // Pasteboard markers understood by clipboard managers and by the system:
    // concealed = do not record (like password managers), transient = not kept in history,
    // autogenerated = not offered to Universal Clipboard / other devices.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    /// Change count of the last clipboard write we made, so we only ever clear our own content.
    private static var lastChangeCount = -1

    private static func markSensitive(_ pb: NSPasteboard) {
        for type in [concealedType, transientType, autoGeneratedType] { pb.setString("", forType: type) }
        lastChangeCount = pb.changeCount
    }

    private static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, concealedType, transientType, autoGeneratedType], owner: nil)
        pb.setString(text, forType: .string)
        markSensitive(pb)
    }

    /// Puts a file on the clipboard the way Finder's "Copy" does, so a paste attaches it.
    private static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        pb.addTypes([concealedType, transientType, autoGeneratedType], owner: nil)
        markSensitive(pb)
    }

    /// Empties the clipboard, but only if nobody else has written to it since our paste.
    private static func clearClipboardIfOurs() {
        let pb = NSPasteboard.general
        guard pb.changeCount == lastChangeCount else { return }
        pb.clearContents()
        lastChangeCount = -1
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
