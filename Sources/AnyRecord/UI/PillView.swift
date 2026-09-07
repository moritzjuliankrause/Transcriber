import SwiftUI

/// Content of the status item: dot (idle) or dot + waveform (recording).
struct PillView: View {
    @ObservedObject var state: AppState
    @State private var pulse = false

    private var isActive: Bool {
        switch state.phase {
        case .idle: return false
        default: return true
        }
    }

    private var dotColor: Color {
        switch state.phase {
        case .idle: return .primary
        case .starting: return .orange
        case .recording: return state.isPaused ? Color.secondary : Color(red: 0.93, green: 0.2, blue: 0.2)
        case .stopping: return .orange
        }
    }

    var body: some View {
        ZStack {
            if isActive {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .transition(.opacity)
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse && isActive && !state.isPaused ? 0.85 : 1)
                    .animation(isActive && !state.isPaused ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
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
                    if case .recording = state.phase {
                        Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.8))
                            .frame(width: 14, height: 16)
                            .contentShape(Rectangle())
                            .help(state.isPaused ? "Resume" : "Pause")
                    }
                }
            }
            .padding(.horizontal, isActive ? 5 : 0)
        }
        .frame(height: StatusItemController.height - 4)
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.25), value: isActive)
        .onAppear { pulse = true }
    }

    private func elapsed(from start: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
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
