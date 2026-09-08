import AppKit
import SwiftUI

/// "What's new": every version and its changes, read from CHANGELOG.md in the app bundle.
struct Changelog {
    struct Version: Identifiable {
        let id: String            // version number
        let date: String
        let items: [String]
    }

    static func load() -> [Version] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// `## 1.2.3 (2026-09-08)` headings followed by `- ` bullets; anything before the first heading is skipped.
    static func parse(_ text: String) -> [Version] {
        var versions: [Version] = []
        var current: (id: String, date: String, items: [String])?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if let c = current { versions.append(Version(id: c.id, date: c.date, items: c.items)) }
                let heading = line.dropFirst(3)
                let parts = heading.split(separator: "(", maxSplits: 1)
                let id = parts[0].trimmingCharacters(in: .whitespaces)
                let date = parts.count > 1 ? parts[1].replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces) : ""
                current = (id, date, [])
            } else if line.hasPrefix("- "), current != nil {
                current!.items.append(String(line.dropFirst(2)))
            } else if !line.isEmpty, !line.hasPrefix("#"), current != nil {
                current!.items.append(line)      // plain paragraph counts as one entry
            }
        }
        if let c = current { versions.append(Version(id: c.id, date: c.date, items: c.items)) }
        return versions
    }
}

struct ChangelogView: View {
    let versions: [Changelog.Version]
    var onClose: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    static let size = CGSize(width: 560, height: 620)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                        .frame(width: 30, height: 30)
                        .background(Theme.sidebarRow(scheme), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Text("What’s New").font(.system(size: 22, weight: .semibold)).padding(.leading, 4)
                Spacer()
            }
            .padding(.top, 26).padding(.horizontal, 30).padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if versions.isEmpty {
                        Text("No change log available in this build.").foregroundStyle(Theme.secondary(scheme))
                    }
                    ForEach(versions) { version in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(version.id).font(.system(size: 15, weight: .semibold))
                                if version.id == UpdateChecker.currentVersion {
                                    Text("Installed")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Theme.accent, in: Capsule())
                                }
                                Spacer()
                                Text(version.date).font(.system(size: 12)).foregroundStyle(Theme.secondary(scheme))
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(version.items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle().fill(Theme.secondary(scheme)).frame(width: 4, height: 4).padding(.top, 7)
                                        Text(item).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            Rectangle().fill(Theme.separator(scheme)).frame(height: 1).padding(.top, 8)
                        }
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: ChangelogView.size.width, maxWidth: .infinity, minHeight: ChangelogView.size.height, maxHeight: .infinity)
        .background(Theme.background(scheme))
        .foregroundStyle(Theme.text(scheme))
        .tint(Theme.accent)
    }
}

@MainActor
final class ChangelogWindowController {
    static let shared = ChangelogWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: ChangelogView.size),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "What’s New in Transcriber"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(button)?.isHidden = true
            }
            w.isMovableByWindowBackground = true
            let host = NSHostingView(rootView: ChangelogView(versions: Changelog.load()) { [weak w] in w?.close() })
            host.sizingOptions = []
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.setFrame(NSRect(origin: .zero, size: ChangelogView.size), display: false)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
