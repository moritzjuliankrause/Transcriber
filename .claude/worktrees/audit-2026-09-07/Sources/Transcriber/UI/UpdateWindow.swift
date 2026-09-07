import AppKit
import SwiftUI

/// The update window: same look as Settings (transparent title bar, material sidebar with
/// the app icon, cards on the right). Shows every state of the checker – checking, up to
/// date, available with release notes, downloading, failed – in place of modal alerts.
@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: UpdateView.size),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Transcriber Update"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.contentView = NSHostingView(rootView: UpdateView(updater: UpdateChecker.shared, close: { [weak self] in self?.window?.close() }))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct UpdateView: View {
    @ObservedObject var updater: UpdateChecker
    let close: () -> Void

    static let size = CGSize(width: 640, height: 460)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: UpdateView.size.width, height: UpdateView.size.height)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 34)          // room for the traffic lights
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .padding(.horizontal, 14)
            Text("Transcriber").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 22).padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                versionLine("Installed", UpdateChecker.currentVersion, highlighted: false)
                if case .available(let v, _, _, _) = updater.status {
                    versionLine("Available", v, highlighted: true)
                }
            }
            .padding(.horizontal, 22).padding(.top, 14)
            Spacer()
            Text(UpdateChecker.buildInfo)
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 22).padding(.bottom, 14)
        }
        .frame(width: 200)
        .background(.regularMaterial)
    }

    private func versionLine(_ label: String, _ version: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(version).font(.system(size: 13, weight: highlighted ? .semibold : .regular))
                .foregroundStyle(highlighted ? Color.accentColor : .primary)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch updater.status {
        case .available(let version, let notes, _, _):
            VStack(alignment: .leading, spacing: 14) {
                header("Transcriber \(version) is available",
                       "Read what changed, then install. The app relaunches by itself.")
                ScrollView {
                    ReleaseNotes(markdown: notes)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
            }
            .padding(.top, 40).padding(.horizontal, 28).padding(.bottom, 20)
        case .checking:
            status(icon: nil, "Checking for updates…", "Asking GitHub for the latest release.")
        case .upToDate:
            status(icon: ("checkmark.circle.fill", .green), "You're up to date",
                   "Transcriber \(UpdateChecker.currentVersion) is the latest release.")
        case .downloading(let p):
            status(icon: ("arrow.down.circle.fill", .blue), "Downloading update…",
                   p > 0 ? "\(Int(p * 100))%" : "This takes a moment.")
        case .failed(let message):
            status(icon: ("exclamationmark.triangle.fill", .red), "Update check failed", message)
        case .idle:
            status(icon: nil, "Updates", "Check for a newer release on GitHub.")
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func status(icon: (String, Color)?, _ title: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            if let (name, tint) = icon {
                Image(systemName: name).font(.system(size: 40)).foregroundStyle(tint)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let blocker = updater.installBlocker {
                Label(blocker, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if case .downloading = updater.status {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch updater.status {
            case .available:
                Button("Later") { close() }.keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { Task { await updater.installAvailableUpdate() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .downloading:
                Button("Close") { close() }.disabled(true)
            case .checking:
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            default:
                Button("Check Again") { Task { await updater.check(interactive: true) } }
                Button("Close") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

/// Lightweight renderer for GitHub release notes: headings, bullet lists and paragraphs
/// with inline Markdown (bold, code, links). Enough for release.sh's notes without WebKit.
struct ReleaseNotes: View {
    let markdown: String

    private enum Block { case heading(String), bullet(String), paragraph(String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush(); result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); result.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No release notes.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    inline(text).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(text)
                    }
                case .paragraph(let text):
                    inline(text)
                }
            }
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
