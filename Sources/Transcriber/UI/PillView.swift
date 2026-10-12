import SwiftUI

/// Content of the status item: the app glyph (dot over two transcript lines). Its dot turns red
/// and breathes while recording, grey while paused, orange while loading or finishing. Controls
/// (mute, pause) and the waveform live in the floating pill below the notch.
struct PillView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme

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
        GlyphView(pillColor: pillColor, pulse: isRecordingLive)
            .frame(width: GlyphView.width, height: GlyphView.height)
            .frame(height: StatusItemController.height)
            .animation(.easeOut(duration: 0.25), value: pillColor)
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
