import SwiftUI

/// Content of the status item: the app glyph (dot over two transcript lines) when idle,
/// glyph + waveform + pause button inside a pill while recording.
struct PillView: View {
    @ObservedObject var state: AppState
    @State private var pulse = false

    private var isActive: Bool {
        switch state.phase {
        case .idle: return false
        default: return true
        }
    }

    @Environment(\.colorScheme) private var scheme

    /// Colour of the glyph's pill: black like the icon (white on a dark menu bar);
    /// while recording it pulses red.
    private var pillColor: Color {
        switch state.phase {
        case .idle: return scheme == .dark ? .white : .black
        case .starting, .stopping: return .orange
        case .recording: return state.isPaused ? Color(white: 0.45) : GlyphView.red
        }
    }

    private var isRecordingLive: Bool {
        if case .recording = state.phase { return !state.isPaused }
        return false
    }

    var body: some View {
        ZStack {
            if isActive {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .transition(.opacity)
            }
            HStack(spacing: 4) {
                GlyphView(pillColor: pillColor, pulse: pulse && isRecordingLive)
                    .frame(width: GlyphView.width, height: GlyphView.height)
                    .padding(.trailing, isActive ? 4 : 0)
                if isActive {
                    Group {
                        if case .stopping = state.phase {
                            ProgressView().controlSize(.mini)
                        } else {
                            WaveformView(levels: Array(state.levelHistory.suffix(9)))
                                .frame(width: 16, height: 12)
                                .opacity(state.isPaused ? 0.35 : 1)
                        }
                    }
                    .frame(width: 18, height: 16)
                    // Shown together with the waveform from the very first frame of the pill
                    // (phase .starting), not only once recording has actually begun.
                    if case .stopping = state.phase {} else {
                        let ready: Bool = { if case .recording = state.phase { return true }; return false }()
                        Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.primary.opacity(ready ? 0.8 : 0.35))
                            .frame(width: 14, height: 16)
                            .contentShape(Rectangle())
                            .help(state.isPaused ? "Resume" : "Pause")
                    }
                }
            }
            .padding(.horizontal, isActive ? 5 : 0)
        }
        .frame(height: StatusItemController.height)
        .animation(.easeOut(duration: 0.25), value: isActive)
        .animation(.easeOut(duration: 0.25), value: pillColor)
        .onAppear { pulse = true }
    }

    private func elapsed(from start: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// The menu bar glyph: a recording dot above two transcript lines (same motif as the
/// app icon). Only the dot changes color / pulses; the lines stay in the label color.
struct GlyphView: View {
    var pillColor: Color
    var pulse: Bool
    @State private var dimmed = false
    @Environment(\.colorScheme) private var scheme

    static let red = Color(red: 1, green: 0x3b/255, blue: 0x30/255)   // the icon's red
    /// Solid black / white instead of the vibrancy-dimmed label color (transcript lines).
    private var ink: Color { scheme == .dark ? .white : .black }

    static let width: CGFloat = 24
    static let height: CGFloat = 20

    var body: some View {
        // The app icon's silhouette – a solid black pill over two transcript lines – scaled
        // to menu bar size. While recording the whole pill is red and breathes.
        // No animation modifier in here: the outer view animates colour and layout together,
        // so the pill and the lines move as one when the recording pill opens.
        VStack(spacing: 2) {
            ZStack {
                Capsule().fill(pillColor)
                    .opacity(dimmed ? 0.55 : 1)
            }
            .frame(width: GlyphView.width, height: 9)
            Capsule().fill(ink.opacity(0.6)).frame(width: 20, height: 1.8)
            Capsule().fill(ink.opacity(0.3)).frame(width: 15, height: 1.8)
        }
        .frame(width: GlyphView.width, height: GlyphView.height)
        // The pulse is driven by its own state inside an explicit withAnimation, on a later
        // run-loop turn, so the repeating animation does not capture the layout shift of the
        // pill opening in the same transaction.
        .onChange(of: pulse, initial: true) { _, on in
            Task { @MainActor in
                if on {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dimmed = false }
                }
            }
        }
    }
}

/// Bar-style waveform driven by the level history (newest on the right).
struct WaveformView: View {
    let levels: [Float]
    var color: Color = .primary

    var body: some View {
        GeometryReader { geo in
            let count = levels.count
            let spacing: CGFloat = 1.5
            let barWidth = max(1, (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color.opacity(0.85))
                        .frame(width: barWidth, height: max(2, CGFloat(level) * geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.linear(duration: 0.03), value: levels)
        }
    }
}
