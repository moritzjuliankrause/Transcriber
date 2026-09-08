import AppKit
import SwiftUI
import Combine

/// A slim, non-activating capsule pinned to the top edge of the main screen
/// (below the menu bar / notch) that shows the live transcript while recording.
/// Its height follows the content (one to three lines) and it shrinks to a small
/// pill around the status text while paused / loading / stopping.
@MainActor
final class FloatingBarController {
    /// The app's one bar, so the recording finaliser can ask for a title inside it.
    static weak var shared: FloatingBarController?

    private var panel: NSPanel?
    private let state: AppState
    private let settings: AppSettings
    private let model = FloatingBarModel()
    private var cancellables = Set<AnyCancellable>()
    private var collapseTimer: Timer?

    /// Duration of the capsule morph (size and content changes).
    static let resizeDuration: TimeInterval = 0.35
    /// Transparent margin around the capsule so its shadow is not clipped by the panel.
    static let shadowPadding: CGFloat = 24

    /// The panel never changes size: it is as large as the widest / tallest capsule plus
    /// shadow margin, and fully transparent. Only the SwiftUI capsule inside it morphs,
    /// so its size, contents and shadow animate as one.
    static let panelSize = NSSize(width: max(FloatingBarView.width, FloatingBarView.confirmSize.width, FloatingBarView.titleSize.width) + 2 * shadowPadding,
                                  height: max(FloatingBarView.height(forLines: FloatingBarModel.maxLines), FloatingBarView.confirmSize.height, FloatingBarView.titleSize.height) + 2 * shadowPadding)

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        Publishers.CombineLatest4(state.$phase, settings.$showFloatingBar, model.$confirmingStop, model.$askingTitle)
            .receive(on: RunLoop.main)
            .map { phase, show, confirming, asking in (show && phase != .idle) || confirming || asking }
            .removeDuplicates()
            .sink { [weak self] visible in visible ? self?.show() : self?.hide() }
            .store(in: &cancellables)
        // Re-layout whenever the transcript, the phase or the pause state changes.
        Publishers.CombineLatest4(state.$liveLines, state.$partialLines, state.$phase, state.$isPaused)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.relayout() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    /// Creates the (hidden) panel. Called once at launch so the first recording start does not
    /// pay for window + SwiftUI setup while the menu bar pill is animating.
    private func makePanel() -> NSPanel {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: FloatingBarController.panelSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.askingTitle { self.model.onSkipTitle?() } else { self.cancelStopConfirmation() }
        }
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false        // drawn by the capsule itself so it morphs along
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.alphaValue = 0
        let host = CapsuleHostingView(rootView: FloatingBarView(state: state, settings: settings, model: model), model: model)
        // Make the transparent margin explicit on every layer: some systems / displays otherwise
        // composite the (fixed-size, rectangular) panel with a faint opaque backing.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        p.contentView = host
        p.invalidateShadow()
        return p
    }

    private var showGeneration = 0

    /// Text input in the save prompt makes the system attach helper windows (prediction /
    /// writing-tools panels, hosted out of process) to the app. They can stay on screen after
    /// the prompt is gone and then sit as a dark rectangle behind the bar – close them.
    static func dismissTextInputHelperWindows() {
        for w in NSApp.windows where w.isVisible && !(w is FloatingPanel) && w.title.isEmpty && w.level.rawValue > NSWindow.Level.floating.rawValue
            && !(w.contentView is NSHostingView<FloatingBarView>) {
            let cls = String(describing: type(of: w))
            let content = w.contentView.map { String(describing: type(of: $0)) } ?? ""
            // Private AppKit classes: SPRoundedWindow / TUINSWindow with an NSRemoteView inside.
            guard cls.hasPrefix("SP") || cls.hasPrefix("TUI") || content.contains("RemoteView") else { continue }
            AppLog.write("Closing stray text input window \(type(of: w)) \(w.frame)")
            w.orderOut(nil)
        }
    }

    private func show() {
        if panel == nil {
            panel = makePanel()
            reposition()
        }
        guard let panel else { return }
        FloatingBarController.dismissTextInputHelperWindows()
        showGeneration += 1
        let generation = showGeneration
        // Snap to the initial size without animation while still invisible.
        model.animated = false
        relayout()
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
        // Appear only after the menu bar pill has finished expanding, with a short fade
        // (alpha is animated by Core Animation, so it stays smooth regardless of main-thread load).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.showGeneration == generation else { return }
            self.model.animated = true
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        showGeneration += 1
        model.animated = false
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.panel?.alphaValue == 0 else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: - Stop confirmation

    private var stopAction: (() -> Void)?
    private var outsideClickMonitor: Any?

    /// Morphs the bar into a "Stop recording?" dialog. A second call while it is shown cancels.
    func confirmStop(onStop: @escaping () -> Void) {
        if model.confirmingStop { cancelStopConfirmation(); return }
        stopAction = onStop
        model.onConfirmStop = { [weak self] in
            guard let self else { return }
            let action = self.stopAction
            self.endStopConfirmation()
            action?()
        }
        model.onCancelStop = { [weak self] in self?.cancelStopConfirmation() }
        model.animated = true
        model.confirmingStop = true      // also makes the bar visible if it was hidden
        (panel as? FloatingPanel)?.allowsKey = true
        panel?.makeKey()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.cancelStopConfirmation() }
        }
    }

    func cancelStopConfirmation() {
        guard model.confirmingStop else { return }
        endStopConfirmation()
    }

    private func endStopConfirmation() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        stopAction = nil
        model.confirmingStop = false
        (panel as? FloatingPanel)?.allowsKey = false
        if panel?.isKeyWindow == true { panel?.resignKey() }
    }

    // MARK: - Title prompt

    /// Morphs the bar into the "Name this recording" prompt and waits for the answer.
    /// Enter saves, Escape skips. The bar is shown even if it is disabled in Settings.
    func askTitle(defaultTitle: String) async -> TitlePrompt.Answer {
        if model.askingTitle { model.onSkipTitle?() }
        cancelStopConfirmation()
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (TitlePrompt.Answer) -> Void = { [weak self] answer in
                guard !finished else { return }
                finished = true
                guard let self else { continuation.resume(returning: answer); return }
                self.model.askingTitle = false
                self.model.onSaveTitle = nil
                self.model.onSkipTitle = nil
                (self.panel as? FloatingPanel)?.allowsKey = false
                if self.panel?.isKeyWindow == true { self.panel?.resignKey() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FloatingBarController.dismissTextInputHelperWindows() }
                continuation.resume(returning: answer)
            }
            model.title = defaultTitle
            model.onSaveTitle = { [weak self] openInAI in
                let text = (self?.model.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                finish(TitlePrompt.Answer(title: text.isEmpty ? nil : text, openInAI: openInAI))
            }
            model.onSkipTitle = { finish(TitlePrompt.Answer(title: nil, openInAI: false)) }
            if panel == nil { prepare() }
            model.animated = panel?.isVisible == true
            model.askingTitle = true
            (panel as? FloatingPanel)?.allowsKey = true
            // The panel does not activate the app; making it key is enough for typing.
            for delay in [0.0, 0.4, 0.8] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.model.askingTitle else { return }
                    self.panel?.makeKey()
                }
            }
        }
    }

    /// Dismisses the title prompt without a title (used by the --cycle development flag).
    func skipTitle() { model.onSkipTitle?() }

    /// Builds the panel ahead of time (see makePanel).
    func prepare() {
        if panel == nil {
            panel = makePanel()
            reposition()
            model.animated = false
            relayout()
        }
    }

    /// Recomputes the visible lines; the capsule animates to the new size on its own.
    private func relayout() {
        guard panel != nil else { return }
        model.update(state: state, settings: settings)
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        // visibleFrame excludes the menu bar; on notch Macs that is the area below the notch.
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 8 + FloatingBarController.shadowPadding
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The bar's panel: never activates the app, takes keyboard focus only while the stop
/// confirmation is shown (Enter / Escape).
private final class FloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { allowsKey }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Hosting view that only reacts to mouse events inside the visible capsule, so the
/// transparent margin of the fixed-size panel does not swallow clicks or drags.
@MainActor
private final class CapsuleHostingView: NSHostingView<FloatingBarView> {
    private let model: FloatingBarModel

    init(rootView: FloatingBarView, model: FloatingBarModel) {
        self.model = model
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @available(*, unavailable) required init(rootView: FloatingBarView) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let size = FloatingBarView.size(for: model)
        let w = size.width, h = size.height
        let capsule = NSRect(x: bounds.midX - w / 2,
                             y: bounds.maxY - FloatingBarController.shadowPadding - h,
                             width: w, height: h)
        return capsule.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
}

/// Display state of the floating bar. Designed to be *calm*: a word that has been
/// shown sharp is never replaced, re-ordered or re-wrapped again – not even by the
/// final recognition pass. Only the blurred tail at the very end may change.
///
/// Both channels can have a partial in flight at the same time. Each channel keeps
/// its own count of words already committed, so alternating partials never repeat
/// words or speaker names. The blurred tails of all in-flight partials are shown
/// after the committed text, ordered by the time the speech started.
///
/// The one exception to "never removed": when a segment turns out to be an echo of
/// the other side (or empty), the words already shown for it are retracted again.
@MainActor
final class FloatingBarModel: ObservableObject {
    /// Which recognised segment a token came from, so it can be retracted later.
    struct Source: Equatable { let channel: Channel?; let start: TimeInterval }

    struct Token: Equatable {
        var text: String
        var settled: Bool
        var speaker: String?      // set for "Name:" prefixes
        var source: Source? = nil
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        var tokens: [Token]
    }

    @Published var lines: [Line] = []
    @Published var message: String?           // shown instead of text (status / prompts)
    @Published var visibleLineCount = 1
    /// False while the bar is hidden, so it snaps to its initial size instead of morphing into view.
    @Published var animated = true
    /// The bar is morphed into the "Stop recording?" dialog.
    @Published var confirmingStop = false
    var onConfirmStop: (() -> Void)?
    var onCancelStop: (() -> Void)?
    /// The bar is morphed into the "Name this recording" prompt.
    @Published var askingTitle = false
    @Published var title = ""
    var onSaveTitle: ((_ openInAI: Bool) -> Void)?
    var onSkipTitle: (() -> Void)?

    static let maxLines = 3

    /// Committed (settled) tokens as one flat run of text. Lines are derived by the same
    /// greedy wrap every time, which is deterministic – so appending never moves a word.
    private var committedTokens: [Token] = []
    /// Id of the first committed line; grows as old lines are trimmed off the top.
    private var firstLineID = 1
    private var lastFinalID: UUID?
    private var lastRetractionID: UUID?
    private var sessionStart: Date?

    /// Per channel: the partial segment being shown and how many of its words are committed.
    private struct Partial { var start: TimeInterval; var frozen: Int }
    private var active: [Channel: Partial] = [:]
    /// Not-yet-settled words of the in-flight partials, ordered by segment start.
    private struct Tail { var start: TimeInterval; var speaker: String; var words: [String] }
    private var tails: [Tail] = []
    /// A partial that has not been refreshed for this long belongs to a segment that ended
    /// without a final (dropped, empty, failed) – its blurred words are hidden.
    private static let partialTimeout: TimeInterval = 6

    private var lastSpeaker: String { committedTokens.last(where: { $0.speaker != nil })?.speaker ?? "" }

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

        consumeRetractions(state.retractions)
        consumeFinals(state.liveLines)
        consumePartials(state.partialLines)

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
        committedTokens = []; firstLineID = 1; lastFinalID = nil; lastRetractionID = nil
        active = [:]; tails = []
    }

    // MARK: - Consuming transcript updates

    /// Removes everything shown for segments that were dropped after the fact (echo, empty).
    private func consumeRetractions(_ retractions: [AppState.Retraction]) {
        var new = retractions
        if let id = lastRetractionID, let idx = retractions.firstIndex(where: { $0.id == id }) {
            new = Array(retractions[(idx + 1)...])
        }
        guard !new.isEmpty else { return }
        for r in new {
            let source = Source(channel: r.channel, start: r.start)
            committedTokens.removeAll { $0.source == source && $0.speaker == nil }
            if active[r.channel]?.start == r.start { active[r.channel] = nil }
            lastRetractionID = r.id
        }
        // Drop speaker prefixes that no longer introduce any words, and merge runs of the
        // same speaker that became adjacent.
        var cleaned: [Token] = []
        for token in committedTokens {
            if token.speaker != nil {
                if let last = cleaned.last, last.speaker != nil { cleaned.removeLast() }   // prefix without words
                if cleaned.last(where: { $0.speaker != nil })?.speaker == token.speaker { continue }   // same speaker again
            }
            cleaned.append(token)
        }
        if let last = cleaned.last, last.speaker != nil { cleaned.removeLast() }
        committedTokens = cleaned
    }

    private func consumeFinals(_ finals: [TranscriptLine]) {
        var new: [TranscriptLine] = []
        if let id = lastFinalID {
            if let idx = finals.firstIndex(where: { $0.id == id }) {
                new = Array(finals[(idx + 1)...])
            } else if let last = finals.last {
                // The id scrolled out of the capped history – take the most recent line only.
                new = [last]
            }
        } else {
            new = finals
        }
        for line in new {
            var words = line.text.split(separator: " ").map(String.init)
            var channel: Channel? = line.channel
            if let (ch, partial) = active.first(where: { $0.value.start == line.start }) {
                // Keep what was already shown sharp; only append what came after it.
                words = Array(words.dropFirst(min(partial.frozen, words.count)))
                active[ch] = nil
                channel = ch
            }
            commit(words, speaker: line.speaker, source: Source(channel: channel, start: line.start))
            lastFinalID = line.id
        }
    }

    private func consumePartials(_ partials: [Channel: TranscriptLine]) {
        tails = []
        for channel in active.keys where partials[channel] == nil { active[channel] = nil }
        let now = Date()
        for (channel, partial) in partials.sorted(by: { $0.value.start < $1.value.start }) {
            if now.timeIntervalSince(partial.createdAt) > FloatingBarModel.partialTimeout {
                active[channel] = nil
                continue
            }
            let words = partial.text.split(separator: " ").map(String.init)
            let stable = min(words.count, partial.stableWords ?? words.count)
            var p = active[channel] ?? Partial(start: partial.start, frozen: 0)
            if p.start != partial.start { p = Partial(start: partial.start, frozen: 0) }
            if stable > p.frozen {
                commit(Array(words[p.frozen..<stable]), speaker: partial.speaker, source: Source(channel: channel, start: partial.start))
                p.frozen = stable
            }
            active[channel] = p
            if words.count > p.frozen {
                tails.append(Tail(start: partial.start, speaker: partial.speaker, words: Array(words[p.frozen...])))
            }
        }
    }

    // MARK: - Layout

    private static let regularFont = FloatingBarView.font
    private static let boldFont = NSFont.systemFont(ofSize: FloatingBarView.font.pointSize, weight: .semibold)
    private static let gap = FloatingBarView.tokenSpacing
    private static func width(_ t: Token) -> CGFloat {
        ceil((t.text as NSString).size(withAttributes: [.font: t.speaker != nil ? boldFont : regularFont]).width)
    }
    private static func width(_ line: [Token]) -> CGFloat {
        line.reduce(CGFloat(0)) { $0 + ($0 == 0 ? 0 : gap) + width($1) }
    }
    private static func fits(_ token: Token, after line: [Token]) -> Bool {
        width(line) + gap + width(token) <= FloatingBarView.textWidth
    }

    /// Appends settled words, preceded by a speaker prefix when the speaker changed.
    private func commit(_ words: [String], speaker: String, source: Source) {
        guard !words.isEmpty else { return }
        if speaker != lastSpeaker {
            committedTokens.append(Token(text: speaker + ":", settled: true, speaker: speaker, source: source))
        }
        committedTokens += words.map { Token(text: $0, settled: true, speaker: nil, source: source) }
        // Trim what can never be shown again (keeps the token list small).
        let wrapped = FloatingBarModel.wrap(committedTokens)
        let excess = wrapped.count - (FloatingBarModel.maxLines + 2)
        if excess > 0 {
            let drop = wrapped.prefix(excess).reduce(0) { $0 + $1.count }
            committedTokens.removeFirst(drop)
            firstLineID += excess
        }
    }

    /// Greedy wrap into lines – the same rule for committed text and blurred tails.
    private static func wrap(_ tokens: [Token]) -> [[Token]] {
        var lines: [[Token]] = []
        for token in tokens {
            if let last = lines.last, fits(token, after: last) {
                lines[lines.count - 1].append(token)
            } else {
                lines.append([token])
            }
        }
        return lines
    }

    /// Committed lines plus the blurred tails, wrapped as one continuous text. Line ids are
    /// positional, so a tail line keeps its id (and position) when its words settle.
    private func layout() -> [Line] {
        var tokens = committedTokens
        var speaker = lastSpeaker
        for tail in tails {
            if tail.speaker != speaker {
                speaker = tail.speaker
                tokens.append(Token(text: tail.speaker + ":", settled: true, speaker: tail.speaker))
            }
            tokens += tail.words.map { Token(text: $0, settled: false, speaker: nil) }
        }
        return FloatingBarModel.wrap(tokens).enumerated().map { Line(id: firstLineID + $0.offset, tokens: $0.element) }
    }
}

struct FloatingBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: FloatingBarModel

    static let width: CGFloat = 420
    static let textWidth: CGFloat = 340
    static let tokenSpacing: CGFloat = 3.5
    static let font = NSFont.systemFont(ofSize: 11)
    static let lineHeight: CGFloat = 14
    static let verticalPadding: CGFloat = 8
    static let leadingPadding: CGFloat = 12
    static let trailingPadding: CGFloat = 14
    /// Dot + waveform + their spacing, left of the text.
    static let indicatorWidth: CGFloat = 7 + 8 + 22 + 8

    static func height(forLines n: Int) -> CGFloat {
        CGFloat(max(1, n)) * lineHeight + 2 * verticalPadding + 2
    }

    /// Full width while showing transcript, a compact pill around the status message otherwise.
    static func width(forMessage message: String?) -> CGFloat {
        guard let message else { return width }
        let text = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        return min(width, leadingPadding + indicatorWidth + text + trailingPadding)
    }

    /// Size of the bar when morphed into the stop confirmation.
    static let confirmSize = CGSize(width: 470, height: height(forLines: FloatingBarModel.maxLines) - 2)   // exactly the 3-line bar
    /// Size of the bar when morphed into the title prompt.
    static let titleSize = CGSize(width: 640, height: confirmSize.height)

    static func size(for model: FloatingBarModel) -> CGSize {
        if model.askingTitle { return titleSize }
        if model.confirmingStop { return confirmSize }
        return CGSize(width: width(forMessage: model.message), height: height(forLines: model.visibleLineCount) - 2)
    }

    @State private var titleFocused = false

    var body: some View {
        let size = FloatingBarView.size(for: model)
        let confirming = model.confirmingStop
        let asking = model.askingTitle
        // Always a capsule – the confirmation is just a taller, wider pill.
        let shape = Capsule()
        HStack(alignment: .center, spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            WaveformView(levels: Array(state.levelHistory.suffix(10)), color: .white)
                .frame(width: 22, height: 10)

            if asking {
                TitleField(text: $model.title, placeholder: "Name this recording (optional)", focused: $titleFocused,
                           onSubmit: { model.onSaveTitle?(false) }, onCancel: { model.onSkipTitle?() })
                    .frame(height: 17)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(titleFocused ? 0.35 : 0.15)))
                    .padding(.leading, 4)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { titleFocused = true } }
                HStack(spacing: 6) {
                    Button("Skip") { model.onSkipTitle?() }
                        .buttonStyle(PillButtonStyle())
                    if AITool.isConfigured {
                        Button("Save & Open in \(AITool.toolDisplayName)") { model.onSaveTitle?(true) }
                            .buttonStyle(PillButtonStyle())
                    }
                    Button("Save") { model.onSaveTitle?(false) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                .fixedSize()
                .transition(.opacity)
            } else if confirming {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop recording?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("The transcript will be finished and saved.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 4)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Button("Cancel") { model.onCancelStop?() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(PillButtonStyle())
                    Button("Stop & Save") { model.onConfirmStop?() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PillButtonStyle(prominent: true))
                }
                .fixedSize()
                .transition(.opacity)
            } else if let message = model.message {
                Text(message)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: FloatingBarView.lineHeight)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { line in
                        HStack(spacing: FloatingBarView.tokenSpacing) {
                            ForEach(Array(line.tokens.enumerated()), id: \.offset) { _, token in
                                Text(token.text)
                                    .fontWeight(token.speaker != nil ? .semibold : .regular)
                                    .foregroundStyle(color(for: token))
                                    .blur(radius: token.settled ? 0 : 2.2)
                                    .opacity(token.settled ? 1 : 0.7)
                                    // Same curve as the line movement: a word whose blur fades in
                                    // the same transaction as a scroll must not lag behind its line.
                                    .animation(.easeOut(duration: 0.3), value: token.settled)
                            }
                        }
                        .frame(height: FloatingBarView.lineHeight)
                        // Children move as one with the line instead of animating individually.
                        .geometryGroup()
                        .lineLimit(1)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                .frame(width: FloatingBarView.textWidth, alignment: .bottomLeading)
                .clipped()
                .animation(model.animated ? .easeOut(duration: 0.3) : nil, value: model.lines.map(\.id))
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.leading, (confirming || asking) ? 20 : FloatingBarView.leadingPadding)
        .padding(.trailing, (confirming || asking) ? 12 : FloatingBarView.trailingPadding)
        .padding(.vertical, FloatingBarView.verticalPadding)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .environment(\.colorScheme, .dark)
        .background(.black.opacity(0.85), in: shape)
        .overlay(shape.stroke(.white.opacity(0.15)))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(model.animated ? .spring(duration: FloatingBarController.resizeDuration, bounce: 0) : nil, value: size)
        .animation(model.animated ? .spring(duration: FloatingBarController.resizeDuration, bounce: 0) : nil, value: model.message == nil)
        .animation(model.animated ? .spring(duration: FloatingBarController.resizeDuration, bounce: 0) : nil, value: confirming)
        .animation(model.animated ? .spring(duration: FloatingBarController.resizeDuration, bounce: 0) : nil, value: asking)
        // Centred at the top of the fixed-size, transparent panel.
        .padding(FloatingBarController.shadowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func color(for token: FloatingBarModel.Token) -> Color {
        guard let speaker = token.speaker else { return .white }
        return speaker == settings.myName ? .cyan : .orange
    }
}

/// Capsule buttons for the floating bar: translucent white, or solid white for the default action.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(prominent ? Color.white.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(configuration.isPressed ? 0.25 : 0.14),
                        in: Capsule())
            .contentShape(Capsule())
    }
}

/// The save prompt's text field: a bare NSTextField with completion, spell checking and inline
/// prediction switched off. Those features open helper windows (candidate lists) below the bar,
/// which showed up as a stray rectangle behind the bar. Return submits, Escape cancels.
private struct TitleField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var focused: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.45), .font: NSFont.systemFont(ofSize: 12)])
        field.isAutomaticTextCompletionEnabled = false
        field.allowsEditingTextAttributes = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if focused, field.window?.firstResponder !== field.currentEditor(), field.window != nil {
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField
        init(_ parent: TitleField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            // The field editor is the window's shared NSTextView; switch off everything that
            // pops up helper windows.
            if let editor = (notification.object as? NSTextField)?.currentEditor() as? NSTextView {
                editor.isAutomaticTextCompletionEnabled = false
                editor.isContinuousSpellCheckingEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isGrammarCheckingEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticDataDetectionEnabled = false
                editor.isAutomaticLinkDetectionEnabled = false
                if #available(macOS 14, *) { editor.inlinePredictionType = .no }
                if #available(macOS 15.2, *) { editor.writingToolsBehavior = .none }
                editor.insertionPointColor = .white
            }
            parent.focused = true
        }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func controlTextDidChange(_ notification: Notification) {
            parent.text = (notification.object as? NSTextField)?.stringValue ?? ""
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}
