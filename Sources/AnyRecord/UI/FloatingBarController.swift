import AppKit
import SwiftUI
import Combine

/// A slim, non-activating capsule pinned to the top edge of the main screen
/// (below the menu bar / notch) that shows the live transcript while recording.
/// Its height follows the content: one to three lines.
@MainActor
final class FloatingBarController {
    private var panel: NSPanel?
    private let state: AppState
    private let settings: AppSettings
    private let model = FloatingBarModel()
    private var cancellables = Set<AnyCancellable>()
    private var collapseTimer: Timer?

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        Publishers.CombineLatest(state.$phase, settings.$showFloatingBar)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, show in
                let visible = show && phase != .idle
                visible ? self?.show() : self?.hide()
            }
            .store(in: &cancellables)
        // Re-layout whenever the transcript, the phase or the names change.
        Publishers.CombineLatest4(state.$liveLines, state.$partialLines, state.$phase, state.$isPaused)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.relayout() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: FloatingBarView.width + 4, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            p.contentView = NSHostingView(rootView: FloatingBarView(state: state, settings: settings, model: model))
            panel = p
        }
        relayout()
        reposition()
        panel?.orderFrontRegardless()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    /// Recomputes the visible lines and resizes the panel, keeping its top edge in place.
    private func relayout() {
        guard let panel else { return }
        model.update(state: state, settings: settings)
        let height = FloatingBarView.height(forLines: model.visibleLineCount) + 4
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        // visibleFrame excludes the menu bar; on notch Macs that is the area below the notch.
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Display state of the floating bar. Designed to be *calm*: a word that has been
/// shown sharp is never replaced, re-ordered or re-wrapped again – not even by the
/// final recognition pass. Only the blurred tail at the very end may change, and it
/// only ever lives on the last line.
@MainActor
final class FloatingBarModel: ObservableObject {
    struct Token: Equatable {
        var text: String
        var settled: Bool
        var speaker: String?      // set for "Name:" prefixes
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        var tokens: [Token]
    }

    @Published var lines: [Line] = []
    @Published var message: String?           // shown instead of text (status / prompts)
    @Published var visibleLineCount = 1

    static let maxLines = 3

    // Committed (settled) layout – append only.
    private var committed: [Line] = []
    private var nextLineID = 0
    private var lastLineClosed = false        // a blurred tail was started on a new line
    private var lastSpeaker = ""
    private var lastFinalID: UUID?
    private var sessionStart: Date?
    // The partial segment currently being shown and the words of it already frozen.
    private var active: (channel: Channel, start: TimeInterval, frozen: Int)?
    private var tail: [Token] = []

    func update(state: AppState, settings: AppSettings) {
        if state.recordingStartedAt != sessionStart {
            sessionStart = state.recordingStartedAt
            reset()
        }
        switch state.phase {
        case .stopping(let msg): message = msg
        case .starting: message = "Loading models…"
        case .recording where state.isPaused: message = "Paused"
        default: message = nil
        }
        if message != nil {
            lines = []; visibleLineCount = 1
            return
        }

        consumeFinals(state.liveLines)
        consumePartial(state)

        let all = layout()
        if all.isEmpty {
            message = "Listening…"
            lines = []; visibleLineCount = 1
            return
        }
        let count = min(FloatingBarModel.maxLines, all.count)
        lines = Array(all.suffix(count))
        visibleLineCount = count
    }

    private func reset() {
        committed = []; lastLineClosed = false; lastSpeaker = ""; lastFinalID = nil
        active = nil; tail = []
    }

    // MARK: - Consuming transcript updates

    private func consumeFinals(_ finals: [TranscriptLine]) {
        var new = finals
        if let id = lastFinalID, let idx = finals.firstIndex(where: { $0.id == id }) {
            new = Array(finals[(idx + 1)...])
        } else if lastFinalID != nil, !finals.isEmpty {
            // The id scrolled out of the capped history – take the most recent line only.
            new = [finals.last!]
        } else if lastFinalID == nil, !finals.isEmpty, committed.isEmpty, tail.isEmpty {
            new = finals
        }
        for line in new {
            var words = line.text.split(separator: " ").map(String.init)
            if let active, active.start == line.start, isSameSpeaker(line.speaker, channel: active.channel) {
                // Keep what was already shown sharp; only append what came after it.
                words = Array(words.dropFirst(min(active.frozen, words.count)))
                self.active = nil
            } else {
                // A final for a segment we never showed a partial for – flush any tail first.
                if active != nil { active = nil }
                speakerPrefix(line.speaker)
            }
            tail = []
            appendSettled(words.map { Token(text: $0, settled: true, speaker: nil) })
            lastFinalID = line.id
        }
    }

    private func consumePartial(_ state: AppState) {
        guard let ch = state.lastUpdatedChannel, let partial = state.partialLines[ch] else {
            // No partial in flight (e.g. right after a final): nothing blurred to show.
            if active == nil { tail = [] }
            return
        }
        let words = partial.text.split(separator: " ").map(String.init)
        let stable = min(words.count, partial.stableWords ?? words.count)
        if active == nil || active!.channel != ch || active!.start != partial.start {
            active = (ch, partial.start, 0)
            speakerPrefix(partial.speaker)
        }
        var frozen = active!.frozen
        if stable > frozen {
            appendSettled(words[frozen..<stable].map { Token(text: $0, settled: true, speaker: nil) })
            frozen = stable
            active!.frozen = frozen
        }
        tail = words.count > frozen ? words[frozen...].map { Token(text: $0, settled: false, speaker: nil) } : []
    }

    private func isSameSpeaker(_ speaker: String, channel: Channel) -> Bool { true }

    private func speakerPrefix(_ speaker: String) {
        guard speaker != lastSpeaker else { return }
        lastSpeaker = speaker
        appendSettled([Token(text: speaker + ":", settled: true, speaker: speaker)])
    }

    // MARK: - Layout (append only)

    private static let attrs: [NSAttributedString.Key: Any] = [.font: FloatingBarView.font]
    private static let space = (" " as NSString).size(withAttributes: attrs).width
    private static func width(_ t: Token) -> CGFloat { (t.text as NSString).size(withAttributes: attrs).width }
    private static func width(_ line: [Token]) -> CGFloat {
        line.reduce(CGFloat(0)) { $0 + ($0 == 0 ? 0 : space) + width($1) }
    }

    private func appendSettled(_ tokens: [Token]) {
        for token in tokens {
            let tw = FloatingBarModel.width(token)
            if committed.isEmpty {
                committed.append(newLine([token]))
                continue
            }
            let lineWidth = FloatingBarModel.width(committed[committed.count - 1].tokens)
            if lineWidth + FloatingBarModel.space + tw <= FloatingBarView.textWidth {
                committed[committed.count - 1].tokens.append(token)
            } else {
                committed.append(newLine([token]))
            }
        }
        if committed.count > FloatingBarModel.maxLines + 2 {
            committed.removeFirst(committed.count - (FloatingBarModel.maxLines + 2))
        }
    }

    private func newLine(_ tokens: [Token]) -> Line {
        nextLineID += 1
        return Line(id: nextLineID, tokens: tokens)
    }

    /// Committed lines plus the blurred tail, wrapped as one continuous text.
    private var tailLineID = 0
    private func layout() -> [Line] {
        var result = committed
        guard !tail.isEmpty else { return result }
        // The blurred tail simply continues after the settled text and wraps like it –
        // the same greedy rule appendSettled uses, so words do not move when they settle.
        var extraLines = 0
        for token in tail {
            let tw = FloatingBarModel.width(token)
            if let last = result.last,
               FloatingBarModel.width(last.tokens) + FloatingBarModel.space + tw <= FloatingBarView.textWidth {
                result[result.count - 1].tokens.append(token)
            } else {
                extraLines += 1
                result.append(Line(id: 1_000_000 + (committed.last?.id ?? 0) * 10 + extraLines, tokens: [token]))
            }
        }
        return result
    }
}

struct FloatingBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: FloatingBarModel

    static let width: CGFloat = 420
    static let textWidth: CGFloat = 340
    static let font = NSFont.systemFont(ofSize: 11)
    static let lineHeight: CGFloat = 14
    static let verticalPadding: CGFloat = 8

    static func height(forLines n: Int) -> CGFloat {
        CGFloat(max(1, n)) * lineHeight + 2 * verticalPadding + 2
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            WaveformView(levels: Array(state.levelHistory.suffix(10)), color: .white)
                .frame(width: 22, height: 10)

            if let message = model.message {
                Text(message)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: FloatingBarView.textWidth, height: FloatingBarView.lineHeight, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { line in
                        HStack(spacing: 3.5) {
                            ForEach(Array(line.tokens.enumerated()), id: \.offset) { _, token in
                                Text(token.text)
                                    .fontWeight(token.speaker != nil ? .semibold : .regular)
                                    .foregroundStyle(color(for: token))
                                    .blur(radius: token.settled ? 0 : 2.2)
                                    .opacity(token.settled ? 1 : 0.7)
                                    .animation(.easeInOut(duration: 0.45), value: token.settled)
                            }
                        }
                        .frame(height: FloatingBarView.lineHeight)
                        .lineLimit(1)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .frame(width: FloatingBarView.textWidth, alignment: .bottomLeading)
                .clipped()
                .animation(.easeOut(duration: 0.3), value: model.lines.map(\.id))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, FloatingBarView.verticalPadding)
        .frame(width: FloatingBarView.width, height: FloatingBarView.height(forLines: model.visibleLineCount) - 2, alignment: .leading)
        .background(.black.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .padding(2)
        .animation(.easeOut(duration: 0.2), value: model.visibleLineCount)
    }

    private func color(for token: FloatingBarModel.Token) -> Color {
        guard let speaker = token.speaker else { return .white }
        return speaker == settings.myName ? .cyan : .orange
    }
}
