import AppKit
import SwiftUI
import Combine

/// The floating pill pinned to the top edge of the main screen (below the menu bar / notch)
/// while recording: mute button, live waveform, pause button. Hovering it unfolds the live
/// transcript card *below* the pill – the pill itself never moves or resizes on hover, so its
/// buttons stay exactly where the pointer expects them. For prompts (stop confirmation, title)
/// and status messages the pill morphs into a wider capsule.
@MainActor
final class FloatingBarController {
    /// The app's one bar, so the recording finaliser can ask for a title inside it.
    static weak var shared: FloatingBarController?

    private var panel: NSPanel?
    private let state: AppState
    private let settings: AppSettings
    private let model = FloatingBarModel()
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var scrollMonitor: Any?

    var onToggleMute: (() -> Void)?
    var onTogglePause: (() -> Void)?
    /// Where a name typed for the current remote speaker should start (session seconds).
    var speakerTagStart: (() -> Double)?

    /// Duration of the capsule morph (size and content changes).
    static let resizeDuration: TimeInterval = 0.35
    /// Transparent margin around the capsule so its shadow is not clipped by the panel.
    static let shadowPadding: CGFloat = 24
    /// Development aid: `--bar-offset 80` moves the bar down, so a test build's bar can sit
    /// below the installed app's bar for comparison.
    static let devOffset: CGFloat = {
        guard let i = CommandLine.arguments.firstIndex(of: "--bar-offset"), i + 1 < CommandLine.arguments.count else { return 0 }
        return CGFloat(Double(CommandLine.arguments[i + 1]) ?? 0)
    }()

    /// The panel never changes size: it is as large as the largest content (pill + transcript
    /// card, or the save prompt) plus shadow margin, and fully transparent.
    /// Only the SwiftUI content inside it morphs; the empty area clicks through.
    static let panelSize = NSSize(
        width: max(FloatingBarView.titleSize.width, FloatingBarView.confirmSize.width, FloatingBarView.cardSize.width) + 2 * shadowPadding,
        height: max(FloatingBarView.titleSize.height,
                    FloatingBarView.pillHeight + FloatingBarView.cardGap + FloatingBarView.cardSize.height) + 2 * shadowPadding)

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
            .sink { [weak self] _, _, phase, _ in
                if phase != .recording { self?.collapseCard() }
                self?.relayout()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
        configureModelCallbacks()
    }

    /// Creates the (hidden) panel. Called once at launch so the first recording start does not
    /// pay for window + SwiftUI setup while the menu bar icon is animating.
    private func makePanel() -> NSPanel {
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: FloatingBarController.panelSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.askingTitle { self.model.onSkipTitle?() }
            else if self.model.tagFieldFocused { self.endTagEditing() }
            else { self.cancelStopConfirmation() }
        }
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false        // drawn by the capsule itself so it morphs along
        p.hidesOnDeactivate = false
        // Clicking a button (mute, pause) must not take the keyboard away from the call app;
        // only clicking into a text field makes the panel key.
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = false
        p.acceptsMouseMovedEvents = true
        p.alphaValue = 0
        let host = CapsuleHostingView(rootView: FloatingBarView(state: state, settings: settings, model: model), model: model)
        // Make the transparent margin explicit on every layer: some systems / displays otherwise
        // composite the (fixed-size, rectangular) panel with a faint opaque backing.
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        p.contentView = host
        p.invalidateShadow()
        // Clicking into another app while the name field is open: drop the half-typed name and let
        // the card close if the pointer is no longer over it (no exit event would come otherwise).
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: p)
            .sink { [weak self, weak p] _ in
                guard let self, self.model.tagFieldFocused else { return }
                self.endTagEditing()
                if p != nil, !self.pointerOverPanel, !self.model.pinned { self.setExpanded(false) }
            }
            .store(in: &cancellables)
        return p
    }

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
        // Snap to the initial size without animation while still invisible, then order the
        // panel on screen and commit the fade-in right now, in this run-loop pass – a slow
        // recording start (cold model load) must not delay the appearance.
        model.animated = false
        relayout()
        model.animated = true
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        model.animated = false
        collapseCard()
        refreshTimer?.invalidate()
        refreshTimer = nil
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
        collapseCard()
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
        collapseCard()
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

    /// Recomputes what the pill / card shows; the SwiftUI content animates on its own.
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
        let y = visible.maxY - size.height - 8 + FloatingBarController.shadowPadding - FloatingBarController.devOffset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Transcript card (hover)

    private var openWork: DispatchWorkItem?
    /// After Enter / Escape in the name field the keyboard goes back to the app in front, and
    /// hovering does not grab it again until the pointer has left the card once.
    private var autoFocusSuspended = false
    private var closeWork: DispatchWorkItem?

    private func configureModelCallbacks() {
        model.onHover = { [weak self] inside in self?.handleHover(inside) }
        model.onToggleMute = { [weak self] in self?.onToggleMute?() }
        model.onTogglePause = { [weak self] in self?.onTogglePause?() }
        model.onTogglePin = { [weak self] in self?.togglePin() }
        model.onTagSubmit = { [weak self] in self?.submitTag() }
        model.onTagChip = { [weak self] name in self?.tag(name) }
        model.onEndTag = { [weak self] in
            guard let self else { return }
            self.state.endSpeakerTag(at: self.state.sessionClock?() ?? 0)
        }
        model.onTagFocus = { [weak self] in self?.beginTagEditing() }
        model.onTagCancel = { [weak self] in
            guard let self else { return }
            self.autoFocusSuspended = true
            self.endTagEditing()
            if !self.model.pinned, !self.pointerOverPanel { self.setExpanded(false) }
        }
    }

    /// The card is offered while recording, when the bar is not morphed into a prompt.
    private var cardAvailable: Bool {
        state.phase == .recording && !model.askingTitle && !model.confirmingStop && model.message == nil
    }

    /// The card offers the "Who's speaking?" field.
    private var namingAvailable: Bool { settings.nameSpeakersLive && settings.captureSystemAudio }

    /// The pointer is over the visible pill / card (not the transparent rest of the panel).
    private var pointerOverPanel: Bool { (panel?.contentView as? CapsuleHostingView)?.containsMouse ?? false }

    /// Hovering the open card puts the cursor into the name field, so a name can be typed right
    /// away (Enter confirms). Leaving the card with the field empty gives the keyboard back to the
    /// app in front; a half-typed name keeps the card open until Enter or Escape.
    private func handleHover(_ inside: Bool) {
        if inside {
            closeWork?.cancel(); closeWork = nil
            if model.expanded {
                if namingAvailable, !model.tagFieldFocused, !autoFocusSuspended { beginTagEditing() }
                return
            }
            guard openWork == nil, cardAvailable else { return }
            // A short dwell, so sweeping the pointer across the top of the screen does not
            // flash the card open.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.openWork = nil
                if self.cardAvailable { self.setExpanded(true) }
            }
            openWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            openWork?.cancel(); openWork = nil
            autoFocusSuspended = false
            guard model.expanded, model.tagDraft.isEmpty else { return }
            if model.tagFieldFocused { endTagEditing() }
            guard !model.pinned, closeWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.closeWork = nil
                if !self.model.pinned, self.model.tagDraft.isEmpty, !self.pointerOverPanel || !self.cardAvailable { self.setExpanded(false) }
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    /// Development aid (`--card-test --card-open`): pins the transcript card open.
    func pinCardForTesting() { togglePin() }

    private func togglePin() {
        guard cardAvailable || model.expanded else { return }
        model.pinned.toggle()
        if model.pinned { setExpanded(true) }
    }

    private func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }
        model.animated = true
        model.expanded = expanded
        if expanded {
            model.followLatest = true
            (panel as? FloatingPanel)?.allowsKey = true
            installScrollMonitor()
            relayout()
            // Opened by hovering: ready to type a name. (Pinned by a click while the pointer is
            // elsewhere – e.g. --card-open – it stays out of the keyboard's way.)
            autoFocusSuspended = false
            if namingAvailable, pointerOverPanel { beginTagEditing() }
        } else {
            removeScrollMonitor()
            if model.tagFieldFocused { endTagEditing() }
            if !model.askingTitle, !model.confirmingStop {
                (panel as? FloatingPanel)?.allowsKey = false
            }
        }
    }

    private func collapseCard() {
        openWork?.cancel(); openWork = nil
        closeWork?.cancel(); closeWork = nil
        model.pinned = false
        setExpanded(false)
    }

    /// Scrolling up in the transcript stops following new lines; the card shows a "Latest"
    /// button (or the user scrolls back down) to resume.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, event.window === self.panel, event.scrollingDeltaY > 0.5 {
                self.model.followLatest = false
            }
            return event
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    // MARK: Naming the current speaker

    private func beginTagEditing() {
        model.tagFieldFocused = true
        (panel as? FloatingPanel)?.allowsKey = true
        // The field may only just be entering the window (card transition); retry briefly.
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.model.tagFieldFocused, self.model.expanded else { return }
                self.panel?.makeKey()
            }
        }
    }

    private func endTagEditing() {
        model.tagFieldFocused = false
        model.tagDraft = ""
        if !model.askingTitle, !model.confirmingStop, panel?.isKeyWindow == true { panel?.resignKey() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FloatingBarController.dismissTextInputHelperWindows() }
    }

    private func submitTag() {
        let name = model.tagDraft
        autoFocusSuspended = true
        endTagEditing()
        tag(name)
        if !model.pinned, !pointerOverPanel { setExpanded(false) }
    }

    private func tag(_ name: String) {
        guard state.phase == .recording else { return }
        let start = speakerTagStart?() ?? state.sessionClock?() ?? 0
        state.tagSpeaker(name, from: start)
        if let tag = state.activeSpeakerTag { AppLog.write("Speaker tag: \(tag.name) from \(Int(tag.start)) s") }
    }
}

/// The bar's panel: never activates the app; takes keyboard focus only for its text fields and
/// the stop confirmation (Enter / Escape).
private final class FloatingPanel: NSPanel {
    var allowsKey = false
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { allowsKey }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Hosting view that only reacts to mouse events inside the visible content, so the
/// transparent margin of the fixed-size panel does not swallow clicks.
@MainActor
private final class CapsuleHostingView: NSHostingView<FloatingBarView> {
    private let model: FloatingBarModel

    init(rootView: FloatingBarView, model: FloatingBarModel) {
        self.model = model
        super.init(rootView: rootView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @available(*, unavailable) required init(rootView: FloatingBarView) { fatalError() }

    /// The visible region: the capsule at the top, plus the transcript card
    /// below it (view coords). The content is top-aligned; `NSHostingView` is flipped, so the top
    /// edge is at y = padding.
    private var contentRect: NSRect {
        let size = FloatingBarView.size(for: model)
        var w = size.width, h = size.height
        if model.showsCard {
            w = max(w, FloatingBarView.cardSize.width)
            h += FloatingBarView.cardGap + FloatingBarView.cardSize.height
        }
        let y = isFlipped ? FloatingBarController.shadowPadding
                          : bounds.maxY - FloatingBarController.shadowPadding - h
        return NSRect(x: bounds.midX - w / 2, y: y, width: w, height: h)
    }

    var containsMouse: Bool {
        guard let window else { return false }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return contentRect.contains(convert(inWindow, from: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Points outside the visible region fall through the transparent panel to what's underneath.
        contentRect.contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }

    // Hover tracking. SwiftUI's `.onHover` only fires while the app is active, but the bar is a
    // background, non-activating panel — so hover is tracked with an `.activeAlways` tracking area.
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    private func reportHover(_ event: NSEvent) {
        model.onHover?(contentRect.contains(convert(event.locationInWindow, from: nil)))
    }
    override func mouseEntered(with event: NSEvent) { reportHover(event) }
    override func mouseMoved(with event: NSEvent) { reportHover(event) }
    override func mouseExited(with event: NSEvent) { model.onHover?(false) }
}

/// Display state of the floating pill and its transcript card.
///
/// The card shows the session's transcript as paragraphs (one per speaker turn). Final lines are
/// sharp; the in-flight partials of both channels follow, ordered by when the speech started,
/// with their not-yet-settled words blurred. Which words count as settled is decided by the
/// coordinator (display only – the files always use the final pass).
@MainActor
final class FloatingBarModel: ObservableObject {
    struct Paragraph: Identifiable, Equatable {
        let id: Int
        var speaker: String
        var isMe: Bool
        /// Sharp words.
        var text: String
        /// Blurred words at the end (not settled yet).
        var tail: [String]
    }

    @Published var message: String?           // shown instead of the controls (status / loading)
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

    // MARK: Pill controls and transcript card

    @Published var expanded = false
    /// Opened by clicking the waveform: stays open without hovering.
    @Published var pinned = false
    @Published var paragraphs: [Paragraph] = []
    /// Auto-scroll to new text; off once the user scrolls up.
    @Published var followLatest = true
    @Published var tagDraft = ""
    @Published var tagFieldFocused = false
    /// Marketing renders (`--render-hero`): ImageRenderer cannot draw scroll views or AppKit
    /// fields, so the card shows its lines in a plain stack, sized to fit.
    var renderStatic = false
    var onHover: ((Bool) -> Void)?
    var onToggleMute: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onTagSubmit: (() -> Void)?
    var onTagChip: ((String) -> Void)?
    var onEndTag: (() -> Void)?
    var onTagFocus: (() -> Void)?
    var onTagCancel: (() -> Void)?

    var showsCard: Bool { expanded && !confirmingStop && !askingTitle && message == nil }

    /// A partial that has not been refreshed for this long belongs to a segment that ended
    /// without a final (dropped, empty, failed) – it is hidden.
    private static let partialTimeout: TimeInterval = 8

    func update(state: AppState, settings: AppSettings) {
        switch state.phase {
        case .stopping(let msg): message = msg
        case .starting: message = "Loading models…"
        default: message = nil
        }
        // The text is only needed while the card is open.
        guard expanded else { return }
        let built = FloatingBarModel.paragraphs(state: state)
        if built != paragraphs { paragraphs = built }
    }

    static func paragraphs(state: AppState) -> [Paragraph] {
        var out: [Paragraph] = []
        func add(_ speaker: String, isMe: Bool, text: String, tail: [String]) {
            guard !text.isEmpty || !tail.isEmpty else { return }
            if var last = out.last, last.speaker == speaker, last.tail.isEmpty {
                last.text = [last.text, text].filter { !$0.isEmpty }.joined(separator: " ")
                last.tail = tail
                out[out.count - 1] = last
            } else {
                out.append(Paragraph(id: out.count, speaker: speaker, isMe: isMe, text: text, tail: tail))
            }
        }
        for line in state.liveLines {
            add(line.speaker, isMe: line.channel == .me, text: line.text, tail: [])
        }
        let now = Date()
        for (channel, partial) in state.partialLines.sorted(by: { $0.value.start < $1.value.start })
        where now.timeIntervalSince(partial.createdAt) <= partialTimeout {
            let words = partial.text.split(separator: " ").map(String.init)
            let stable = min(words.count, partial.stableWords ?? words.count)
            add(partial.speaker, isMe: channel == .me, text: words[..<stable].joined(separator: " "), tail: Array(words[stable...]))
        }
        return out
    }
}

struct FloatingBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: FloatingBarModel

    static let font = NSFont.systemFont(ofSize: 11)
    /// The recording pill: mute · waveform · pause.
    static let pillWidth: CGFloat = 156
    static let pillHeight: CGFloat = 36
    static let controlSize: CGFloat = 28
    /// The transcript card below the pill.
    static let cardSize = CGSize(width: 400, height: 380)
    static let cardGap: CGFloat = 8
    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 16


    /// A compact capsule around a status message (spinner + text).
    static func width(forMessage message: String) -> CGFloat {
        let text = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        return leadingPadding + 12 + 8 + text + trailingPadding
    }

    /// Size of the bar when morphed into the stop confirmation.
    static let confirmSize = CGSize(width: 470, height: 58)
    /// Size of the bar when morphed into the title prompt.
    static let titleSize = CGSize(width: 640, height: confirmSize.height)

    static func size(for model: FloatingBarModel) -> CGSize {
        if model.askingTitle { return titleSize }
        if model.confirmingStop { return confirmSize }
        if let message = model.message { return CGSize(width: width(forMessage: message), height: pillHeight) }
        return CGSize(width: pillWidth, height: pillHeight)
    }

    private var spring: Animation? {
        model.animated ? .spring(duration: FloatingBarController.resizeDuration, bounce: 0) : nil
    }

    var body: some View {
        VStack(spacing: FloatingBarView.cardGap) {
            capsule
            if model.showsCard {
                TranscriptCard(state: state, settings: settings, model: model)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .animation(model.animated ? .spring(duration: 0.3, bounce: 0.15) : nil, value: model.showsCard)
        .padding(FloatingBarController.shadowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var capsule: some View {
        let size = FloatingBarView.size(for: model)
        let confirming = model.confirmingStop
        let asking = model.askingTitle
        let shape = Capsule()
        return HStack(alignment: .center, spacing: 8) {
            if asking {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                TitleField(text: $model.title, placeholder: "Name this recording (optional)",
                           focused: .constant(true),
                           onSubmit: { model.onSaveTitle?(false) },
                           onCancel: { model.onSkipTitle?() })
                    .frame(height: 17)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.35)))
                    .padding(.leading, 4)
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
                Circle().fill(Color.red).frame(width: 7, height: 7)
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
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                Text(message)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
                Spacer(minLength: 0)
            } else {
                controls
                    .transition(.opacity)
            }
        }
        .font(.system(size: 11))
        .padding(.leading, (confirming || asking) ? 20 : (model.message != nil ? FloatingBarView.leadingPadding : 4))
        .padding(.trailing, (confirming || asking) ? 12 : (model.message != nil ? FloatingBarView.trailingPadding : 4))
        .frame(width: size.width, height: size.height, alignment: .leading)
        .environment(\.colorScheme, .dark)
        // Clip the content first, then put the fill *with its shadow* behind it. The shadow of a
        // plain shape is rendered from its path; a shadow on the composited group was
        // re-rasterised once the size animation ended and showed a faint rectangle (macOS 26).
        .clipShape(shape)
        .background(shape.fill(.black.opacity(0.85)).shadow(color: .black.opacity(0.35), radius: 10, y: 4))
        .overlay(shape.strokeBorder(.white.opacity(0.15)))
        .animation(spring, value: size)
        .animation(spring, value: model.message == nil)
        .animation(spring, value: confirming)
        .animation(spring, value: asking)
    }

    /// Mute (left) · recording dot + waveform (centre, click pins the transcript open) · pause (right).
    private var controls: some View {
        let micAvailable = settings.captureMicrophone
        let live = state.phase == .recording
        return HStack(spacing: 0) {
            PillIconButton(systemName: state.isMicMuted ? "mic.slash.fill" : "mic.fill",
                           tint: state.isMicMuted ? Color(red: 1, green: 0.38, blue: 0.35) : .white,
                           highlighted: state.isMicMuted,
                           help: state.isMicMuted ? "Unmute your microphone" : "Mute your microphone (only the computer's audio is transcribed)") {
                model.onToggleMute?()
            }
            .disabled(!micAvailable || !live)
            .opacity(micAvailable ? 1 : 0.35)

            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle()
                    .fill(state.isPaused ? Color(white: 0.55) : Color.red)
                    .frame(width: 7, height: 7)
                if state.isPaused {
                    Text("Paused")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 58, height: 14, alignment: .leading)
                } else {
                    WaveformView(levels: Array(state.levelHistory.suffix(14)), color: .white)
                        .frame(width: 58, height: 14)
                }
            }
            .frame(height: FloatingBarView.pillHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.onTogglePin?() }
            .help(model.pinned ? "Unpin the live transcript" : "Hover for the live transcript, click to keep it open")
            Spacer(minLength: 0)

            PillIconButton(systemName: state.isPaused ? "play.fill" : "pause.fill",
                           tint: .white,
                           highlighted: state.isPaused,
                           help: state.isPaused ? "Resume" : "Pause the whole recording") {
                model.onTogglePause?()
            }
            .disabled(!live)
        }
    }
}

/// A round icon button inside the pill.
private struct PillIconButton: View {
    let systemName: String
    var tint: Color
    var highlighted: Bool
    var help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.92))
                .frame(width: FloatingBarView.controlSize, height: FloatingBarView.controlSize)
                .background(Circle().fill(.white.opacity(highlighted ? 0.16 : (hovering ? 0.12 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

/// The live transcript card that unfolds below the pill: scrollable history, blurred tail,
/// and the "Who's speaking?" field.
private struct TranscriptCard: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: FloatingBarModel

    private static let bottomID = "bottom"
    private static let scrollSpace = "transcriptScroll"
    /// The end of the transcript is inside the visible area (raw, updated on every layout).
    @State private var atBottom = true
    /// Shown state of "not at the end": set only after it lasted a moment, so the button does
    /// not flash while an auto-scroll to a new line is still under way.
    @State private var awayFromBottom = false
    @State private var scrollToLatest: (() -> Void)?
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }
    private var showsNaming: Bool { settings.nameSpeakersLive && settings.captureSystemAudio }

    var body: some View {
        if model.renderStatic {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(model.paragraphs) { ParagraphView(paragraph: $0) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .frame(width: FloatingBarView.cardSize.width)
            .environment(\.colorScheme, .dark)
            .background(shape.fill(.black.opacity(0.85)))
            .overlay(shape.strokeBorder(.white.opacity(0.15)))
        } else {
            interactive
        }
    }

    private var interactive: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .bottomTrailing) {
                transcript
                if !model.followLatest || awayFromBottom {
                    Button {
                        model.followLatest = true
                        scrollToLatest?()
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .frame(height: 22)
                            // Opaque, so the transcript text scrolling underneath cannot bleed through.
                            .background(Capsule().fill(Color(white: 0.2)).shadow(color: .black.opacity(0.6), radius: 6, y: 2))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.2)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.opacity)
                }
            }
            if showsNaming {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                SpeakerTagBar(state: state, model: model)
            }
        }
        .frame(width: FloatingBarView.cardSize.width, height: FloatingBarView.cardSize.height)
        .environment(\.colorScheme, .dark)
        .clipShape(shape)
        .background(shape.fill(.black.opacity(0.85)).shadow(color: .black.opacity(0.35), radius: 12, y: 5))
        .overlay(shape.strokeBorder(.white.opacity(0.15)))
        .animation(.easeOut(duration: 0.2), value: model.followLatest)
        .animation(.easeOut(duration: 0.2), value: awayFromBottom)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Live transcript")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            if state.isMicMuted {
                Label("Mic muted", systemImage: "mic.slash.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42))
            }
            Spacer()
            Button { model.onTogglePin?() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(model.pinned ? 0.9 : 0.4))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.pinned ? "Unpin (close when the pointer leaves)" : "Keep open")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 34)
    }

    private var transcript: some View {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                // Not lazy: the end marker must always exist so its position tells whether the
                // end of the transcript is in view, and scrollTo lands exactly on it.
                VStack(alignment: .leading, spacing: 11) {
                    if model.paragraphs.isEmpty {
                        Text(state.isPaused ? "Paused" : "Listening…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.paragraphs) { p in
                        ParagraphView(paragraph: p)
                    }
                    Color.clear.frame(height: 1).id(TranscriptCard.bottomID)
                        .background(GeometryReader { marker in
                            Color.clear.preference(key: BottomMarkerKey.self,
                                                   value: marker.frame(in: .named(TranscriptCard.scrollSpace)).minY)
                        })
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: TranscriptCard.scrollSpace)
            // Opens already showing the end – no visible scroll down from the top.
            .defaultScrollAnchor(.bottom)
            // Text scrolling out at the top fades instead of being cut off under the header.
            .mask(VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                Color.black
            })
            .onPreferenceChange(BottomMarkerKey.self) { markerY in
                // 12 pt bottom padding below the marker, plus some slack.
                atBottom = markerY <= viewport.size.height + 4
            }
            .onAppear {
                // The card is inserted inside the open animation; jump without inheriting it.
                var instant = Transaction(); instant.disablesAnimations = true
                withTransaction(instant) { proxy.scrollTo(TranscriptCard.bottomID, anchor: .bottom) }
                scrollToLatest = {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(TranscriptCard.bottomID, anchor: .bottom) }
                }
            }
            .onChange(of: model.paragraphs) { _, _ in
                guard model.followLatest else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(TranscriptCard.bottomID, anchor: .bottom) }
            }
            .onChange(of: model.followLatest) { _, follow in
                if follow {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(TranscriptCard.bottomID, anchor: .bottom) }
                } else {
                    // A scroll-up gesture with nowhere to go (short transcript) leaves the end in view.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if atBottom, !model.followLatest { model.followLatest = true }
                    }
                }
            }
            .task(id: atBottom) {
                if atBottom {
                    awayFromBottom = false
                    model.followLatest = true     // scrolled back down to the end
                } else {
                    // Away from the end for longer than an auto-scroll takes: offer "Latest".
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled, !atBottom { awayFromBottom = true }
                }
            }
        }
        }
    }
}

/// Vertical position of the transcript's end marker inside the scroll view.
private struct BottomMarkerKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One speaker turn: the name, then the text. The blurred words of a partial flow inline after
/// the sharp ones and lose their blur in place as they settle.
private struct ParagraphView: View {
    let paragraph: FloatingBarModel.Paragraph

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(paragraph.speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(paragraph.isMe ? Color.cyan : Color.orange)
            if paragraph.tail.isEmpty {
                Text(paragraph.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let sharp = paragraph.text.split(separator: " ").map(String.init)
                let words = sharp + paragraph.tail
                FlowLayout(spacing: 3.5, lineSpacing: 3) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                        let settled = i < sharp.count
                        Text(word)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(settled ? 0.92 : 0.7))
                            .blur(radius: settled ? 0 : 2.4)
                            .animation(.easeOut(duration: 0.35), value: settled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Lays out words left to right, wrapping into lines (like text, but each word is its own view
/// so it can be blurred on its own).
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                y += lineHeight + lineSpacing
                x = 0; lineHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Bottom of the card: who is speaking right now (named by the user), a field to name them,
/// and one-click chips for names used earlier in this call.
private struct SpeakerTagBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var model: FloatingBarModel

    var body: some View {
        let active = state.activeSpeakerTag?.name
        let others = state.usedSpeakerNames.filter { $0 != active }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
                if let active {
                    HStack(spacing: 4) {
                        Text(active)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.orange)
                        Button { model.onEndTag?() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(active) stopped speaking")
                    }
                    .padding(.leading, 9).padding(.trailing, 3)
                    .frame(height: 24)
                    .background(.orange.opacity(0.18), in: Capsule())
                }
                TagField(text: $model.tagDraft,
                         placeholder: active == nil ? "Who's speaking? Type a name ⏎" : "Someone else? ⏎",
                         focused: model.tagFieldFocused,
                         onSubmit: { model.onTagSubmit?() },
                         onCancel: { model.onTagCancel?() },
                         onFocus: { model.onTagFocus?() })
                    .frame(height: 17)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.white.opacity(model.tagFieldFocused ? 0.14 : 0.08), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(model.tagFieldFocused ? 0.35 : 0.12)))
            }
            if !others.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(others, id: \.self) { name in
                            Button { model.onTagChip?(name) } label: {
                                Text(name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(.horizontal, 9)
                                    .frame(height: 22)
                                    .background(.white.opacity(0.1), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("\(name) is speaking again")
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The "Who's speaking?" field: like TitleField, but capitalises the first letter and reports
/// when it is clicked into (the panel only becomes key then).
private struct TagField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focused: Bool
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onFocus: () -> Void

    /// Takes the focus itself on a click and when it enters the window while it should have it –
    /// a click into a field of a background, non-activating panel is otherwise not enough.
    final class FocusingField: NSTextField {
        var wantsFocus = false
        var onClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            onClick?()
            window?.makeKey()
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if wantsFocus { DispatchQueue.main.async { [weak self] in self?.focusIfWanted() } }
        }
        func focusIfWanted() {
            guard wantsFocus, let window else { return }
            if window.firstResponder !== currentEditor() { window.makeFirstResponder(self) }
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingField()
        field.onClick = onFocus
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 11.5, weight: .medium)
        field.textColor = .white
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
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 11.5)])
        }
        if let field = field as? FocusingField {
            field.onClick = onFocus
            field.wantsFocus = focused
            // The window becomes key a moment after the card opens; try again then.
            if focused { for delay in [0.0, 0.2, 0.45] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { field.focusIfWanted() } } }
        }
        if !focused, field.currentEditor() != nil, field.window?.firstResponder === field.currentEditor() {
            field.window?.makeFirstResponder(nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TagField
        init(_ parent: TagField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
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
            parent.onFocus()
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            var s = field.stringValue
            if let first = s.first, first.isLowercase {      // always start with a capital letter
                s = first.uppercased() + s.dropFirst()
                field.stringValue = s
                field.currentEditor()?.selectedRange = NSRange(location: (s as NSString).length, length: 0)
            }
            parent.text = s
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
    var onTab: (() -> Void)? = nil

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
            case #selector(NSResponder.insertTab(_:)):
                if let onTab = parent.onTab { onTab(); return true }
                return false
            default: return false
            }
        }
    }
}
