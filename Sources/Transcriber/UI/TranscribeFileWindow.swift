import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Transcribe Audio File…" from the menu bar menu: a small window to drop an audio file on and
/// copy the finished transcript as plain text, text with timestamps or Markdown. The file becomes
/// a normal recording (Settings › Recordings) through `RecordingHistory.importAudio`.
@MainActor
final class TranscribeFileWindowController {
    static let shared = TranscribeFileWindowController()
    private var window: NSWindow?
    private let model = TranscribeFileModel()

    func show(transcribing file: URL? = nil) {
        if window == nil {
            // Styled like the Settings window: no title bar, its own close button top left.
            let size = NSSize(width: 680, height: 580)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Transcribe Audio File"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(button)?.isHidden = true
            }
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 560, height: 440)
            w.isReleasedWhenClosed = false
            let view = TranscribeFileView(settings: AppSettings.shared, model: model) { [weak w] in w?.close() }
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []          // the window, not the view's ideal size, decides the frame
            w.contentView = host
            w.setFrame(NSRect(origin: .zero, size: size), display: false)
            w.center()
            window = w
        }
        if CommandLine.arguments.contains("--background") {
            window?.orderBack(nil)       // development aid: screenshots without taking the focus
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        if let file { model.transcribe(file, settings: AppSettings.shared) }
    }
}

/// Model of the window: which file is being transcribed and the result.
@MainActor
final class TranscribeFileModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case working(file: String)
        case done(folder: URL)
        case failed(String)
    }

    enum Format: String, CaseIterable, Identifiable {
        case text = "Text"
        case timestamps = "Text with timestamps"
        case markdown = "Markdown"
        var id: String { rawValue }
    }

    @Published var phase: Phase = .empty
    /// Folder of the recording being transcribed (its progress text is in `RecordingHistory.busy`).
    @Published var workingFolder: URL?
    @Published private(set) var outputs: [Format: String] = [:]
    @Published private(set) var title = ""

    func transcribe(_ url: URL, settings: AppSettings) {
        if case .working = phase { return }
        phase = .working(file: url.lastPathComponent)
        workingFolder = nil
        outputs = [:]
        let history = RecordingHistory.shared
        history.lastError = nil
        Task {
            let folder = await history.importAudio(url, settings: settings) { [weak self] dir in self?.workingFolder = dir }
            workingFolder = nil
            guard let folder else {
                phase = .failed(history.lastError ?? "Another file is being imported right now. Try again in a moment.")
                return
            }
            load(folder)
        }
    }

    private func load(_ folder: URL) {
        guard let store = try? SessionStore(existing: folder) else {
            phase = .failed("The transcript could not be read.")
            return
        }
        let meta = store.meta, entries = store.entries
        store.close()
        guard !entries.isEmpty else {
            phase = .failed("No speech was found in this file.")
            return
        }
        title = meta.title
        let markdownFile = folder.appendingPathComponent("transcript.md")
        outputs = [
            .text: TranscriptExporter.plainText(meta: meta, entries: entries, timestamps: false),
            .timestamps: TranscriptExporter.plainText(meta: meta, entries: entries, timestamps: true),
            .markdown: (try? String(contentsOf: markdownFile, encoding: .utf8)) ?? TranscriptExporter.markdown(meta: meta, entries: entries),
        ]
        phase = .done(folder: folder)
    }

    func copy(_ format: Format) {
        guard let text = outputs[format] else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if format == .markdown, case .done(let folder) = phase {
            // Both the text and the transcript.md file: an editor pastes the text, Finder, mail or
            // chat apps attach the file.
            let file = folder.appendingPathComponent("transcript.md")
            if FileManager.default.fileExists(atPath: file.path) {
                pb.writeObjects([file as NSURL])
                pb.addTypes([.string], owner: nil)
            }
        }
        pb.setString(text, forType: .string)
    }

    func reset() {
        if case .working = phase { return }
        phase = .empty
        outputs = [:]
    }
}

struct TranscribeFileView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: TranscribeFileModel
    var onClose: () -> Void = {}
    @ObservedObject private var history = RecordingHistory.shared
    @Environment(\.colorScheme) private var scheme
    @State private var dropTargeted = false
    @State private var format: TranscribeFileModel.Format = .text
    @State private var copied: TranscribeFileModel.Format?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch model.phase {
                case .empty:
                    dropZone
                case .working(let file):
                    working(file)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 14) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        dropZone
                    }
                case .done(let folder):
                    result(folder)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background(scheme))
        .foregroundStyle(Theme.text(scheme))
        .tint(Theme.accent)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
    }

    /// Same header as the Settings window: round close button, big title.
    private var header: some View {
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
            .help("Close")
            Text("Transcribe Audio File").font(.system(size: 22, weight: .semibold)).padding(.leading, 4)
            Spacer()
        }
        .padding(.top, 26)
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.secondary(scheme))
    }

    // MARK: - States

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(dropTargeted ? Theme.accent : Theme.secondary(scheme))
            Text("Drop an audio file here")
                .font(.system(size: 13.5, weight: .medium))
            Text("WAV, M4A, MP3, AIFF or a video's sound. Speakers are separated and remembered voices named. The recording is also saved under Recordings.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button("Choose File…", action: choose).buttonStyle(SoftButtonStyle()).padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Theme.accent.opacity(0.08) : Theme.hover(scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(dropTargeted ? Theme.accent : Theme.border(scheme), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    private func working(_ file: String) -> some View {
        let status = model.workingFolder.flatMap { history.busy[$0] } ?? history.importStatus ?? "Preparing…"
        return VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(file).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(status).font(.system(size: 12)).foregroundStyle(Theme.secondary(scheme))
            Text("Long files take a while. You can close this window; the transcript also lands under Recordings.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary(scheme))
                .multilineTextAlignment(.center).frame(maxWidth: 360)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.hover(scheme), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border(scheme)))
    }

    private func result(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    sectionTitle("Transcript")
                    Text(model.title.isEmpty ? "Transcript" : model.title)
                        .font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder.appendingPathComponent("transcript.md")])
                }
                .buttonStyle(SoftButtonStyle())
                Button("New File…") { model.reset() }.buttonStyle(SoftButtonStyle())
            }

            HStack(spacing: 2) {
                ForEach(TranscribeFileModel.Format.allCases) { f in
                    FormatTab(title: f.rawValue, selected: format == f) {
                        withAnimation(.easeOut(duration: 0.15)) { format = f }
                    }
                }
                Spacer()
            }

            ScrollView {
                Text(model.outputs[format] ?? "")
                    .font(format == .markdown ? .system(size: 12, design: .monospaced) : .system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Theme.fieldBackground(scheme), in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border(scheme)))

            HStack(spacing: 10) {
                Button {
                    model.copy(format)
                    let f = format
                    copied = f
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == f { copied = nil } }
                } label: {
                    Label(copied == format ? "Copied" : "Copy \(format.rawValue)",
                          systemImage: copied == format ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Text(format == .markdown
                     ? "Copies the text and the transcript.md file: an editor pastes the text, Finder, Mail or Slack attach the file."
                     : "Plain text for pasting anywhere. ⇧⌘C copies too.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Input

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if case .working = model.phase { return false }
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            Task { @MainActor in
                guard let url else { return }
                guard RecordingHistory.audioExtensions.contains(url.pathExtension.lowercased()) else {
                    model.phase = .failed("\(url.lastPathComponent) is not an audio or video file Transcriber can read.")
                    return
                }
                model.transcribe(url, settings: settings)
            }
        }
        return true
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = RecordingHistory.audioExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            model.transcribe(url, settings: settings)
        }
    }
}

/// A format choice, drawn like the Settings window's sidebar rows.
private struct FormatTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text(scheme) : Theme.secondary(scheme))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? Theme.sidebarRow(scheme) : (hovering ? Theme.hover(scheme) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
