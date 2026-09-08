import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Colours of the Settings window (light / dark), independent of the system tints so the
/// window looks the same on every Mac.
enum Theme {
    static let accent = Color(red: 0.17, green: 0.42, blue: 0.80)

    static func background(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.12) : .white }
    static func sidebarRow(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.20) : Color(red: 0.94, green: 0.94, blue: 0.96) }
    static func hover(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.16) : Color(red: 0.97, green: 0.97, blue: 0.98) }
    static func fieldBackground(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.15) : .white }
    static func border(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.26) : Color(red: 0.89, green: 0.89, blue: 0.91) }
    static func separator(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.20) : Color(red: 0.93, green: 0.93, blue: 0.95) }
    static func text(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.95) : Color(white: 0.11) }
    static func secondary(_ s: ColorScheme) -> Color { s == .dark ? Color(white: 0.62) : Color(white: 0.45) }
    static let fieldRadius: CGFloat = 10
    static let fieldHeight: CGFloat = 36
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelManager
    @Environment(\.colorScheme) private var scheme
    var onClose: () -> Void = {}

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case audio = "Audio"
        case transcription = "Transcription"
        case output = "Output"
        case ai = "AI"
        case recovery = "Recovery"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .audio: return "waveform"
            case .transcription: return "text.bubble"
            case .output: return "folder"
            case .recovery: return "arrow.counterclockwise"
            case .ai: return "sparkles"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "Names, behaviour, appearance and updates"
            case .audio: return "What is captured and how"
            case .transcription: return "Models, language and speakers"
            case .output: return "Where and how transcripts are saved"
            case .recovery: return "Unfinished recordings"
            case .ai: return "Hand transcripts to your AI tool"
            }
        }
    }

    static let size = CGSize(width: 860, height: 620)
    @ObservedObject private var navigation = SettingsNavigation.shared
    private var selection: Section {
        get { navigation.section }
        nonmutating set { navigation.section = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .top, spacing: 0) {
                sidebar
                Group {
                    switch selection {
                    case .general: GeneralSettings(settings: settings)
                    case .audio: AudioSettings(settings: settings, state: state)
                    case .transcription: TranscriptionSettings(settings: settings, models: models)
                    case .output: OutputSettings(settings: settings)
                    case .recovery: RecoverySettings(settings: settings, state: state)
                    case .ai: AISettings(settings: settings, state: state)
                    }
                }
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: SettingsView.size.width, maxWidth: .infinity, minHeight: SettingsView.size.height, maxHeight: .infinity)
        .background(Theme.background(scheme))
        .foregroundStyle(Theme.text(scheme))
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Settings").font(.system(size: 22, weight: .semibold))
            Spacer()
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
        }
        .padding(.top, 26)
        .padding(.horizontal, 30)
        .padding(.bottom, 24)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(Section.allCases) { section in
                    SidebarRow(section: section, selected: selection == section) {
                        withAnimation(.easeOut(duration: 0.15)) { selection = section }
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Transcriber \(UpdateChecker.currentVersion)").font(.system(size: 11, weight: .medium))
                    Text("⌃⌥⌘R  start / stop").font(.system(size: 10)).foregroundStyle(Theme.secondary(scheme))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .padding(.leading, 30)
        .padding(.trailing, 14)
        .padding(.bottom, 26)
        .frame(width: 236)
    }
}

private struct SidebarRow: View {
    let section: SettingsView.Section
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(selected ? Theme.text(scheme) : Theme.secondary(scheme))
                    .frame(width: 20, height: 20)
                Text(section.rawValue)
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text(scheme) : Theme.secondary(scheme))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
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

// MARK: - Building blocks

/// A settings page: title + subtitle, then groups of rows.
struct SettingsPage<Content: View>: View {
    let section: SettingsView.Section
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content
            }
            .padding(.leading, 20)
            .padding(.trailing, 30)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Which section the Settings window shows; shared so other parts of the app can open one.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var section: SettingsView.Section = .general
}

/// A group of rows with a small heading and an optional footnote.
struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondary(scheme))
            content
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(Theme.secondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, settingsLabelWidth)
            }
            Rectangle().fill(Theme.separator(scheme)).frame(height: 1).padding(.top, 8)
        }
    }
}

let settingsLabelWidth: CGFloat = 180

/// Label (+ optional caption) on the left, control on the right, like a form.
struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: Control
    @Environment(\.colorScheme) private var scheme

    static var labelWidth: CGFloat { settingsLabelWidth }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5))
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(Theme.secondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: SettingRow.labelWidth - 16, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A switch row: switch first, its explanation next to it.
struct ToggleRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool
    var disabled = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingRow(title: title) {
            HStack(alignment: .center, spacing: 10) {
                Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                if let caption {
                    Text(caption).font(.system(size: 11.5)).foregroundStyle(Theme.secondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// Plain text value on the right.
struct ValueRow: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SettingRow(title: title) {
            Text(value).font(.system(size: 12.5)).foregroundStyle(Theme.secondary(scheme))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// Free text that spans the row (explanations inside a group).
struct NoteRow: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary(scheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rounded, bordered box every input lives in.
struct FieldBox<Content: View>: View {
    var height: CGFloat? = Theme.fieldHeight
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(Theme.fieldBackground(scheme), in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border(scheme)))
    }
}

/// A full-width text field.
struct TextFieldBox: View {
    var placeholder = ""
    @Binding var text: String
    var body: some View {
        FieldBox {
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        }
    }
}

/// A full-width drop-down.
struct ChoiceField<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        FieldBox {
            Menu {
                ForEach(options, id: \.0) { value, name in
                    Button(name) { selection = value }
                }
            } label: {
                HStack {
                    Text(options.first(where: { $0.0 == selection })?.1 ?? "").font(.system(size: 13))
                        .foregroundStyle(Theme.text(scheme))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary(scheme))
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.fieldHeight)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }
}

/// Two or three joined buttons, one of them selected (like a segmented control).
struct SegmentPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String, String)]     // value, symbol, help
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, symbol, help in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = value }
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selection == value ? .white : Theme.secondary(scheme))
                        .frame(width: 44, height: Theme.fieldHeight - 2)
                        .background(selection == value ? Theme.accent : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help)
            }
        }
        .background(Theme.fieldBackground(scheme))
        .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border(scheme)))
    }
}

/// Rounded bordered button (secondary action).
struct SoftButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(configuration.isPressed ? Theme.sidebarRow(scheme) : Theme.fieldBackground(scheme),
                        in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border(scheme)))
            .opacity(enabled ? 1 : 0.45)
    }
}

/// Filled accent button (primary action).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
            .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater = UpdateChecker.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsPage(section: .general) {
            SettingsCard(title: "Appearance") {
                SettingRow(title: "Theme", caption: "Auto follows the system") {
                    HStack(spacing: 12) {
                        SegmentPicker(selection: $settings.appearance, options: [
                            ("system", "circle.lefthalf.filled", "Follow the system"),
                            ("light", "sun.max", "Light"),
                            ("dark", "moon", "Dark"),
                        ])
                        Text(settings.appearance == "system" ? "Auto" : settings.appearance.capitalized)
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary(scheme))
                    }
                }
            }
            SettingsCard(title: "Speaker labels", footer: "Remote participants become \"\(settings.otherName) 1\", \"\(settings.otherName) 2\" … when diarization finds several voices.") {
                SettingRow(title: "Your name", caption: "Microphone channel") {
                    TextFieldBox(text: $settings.myName)
                }
                SettingRow(title: "Remote speaker label", caption: "System audio channel") {
                    TextFieldBox(text: $settings.otherName)
                }
            }
            SettingsCard(title: "Behaviour") {
                ToggleRow(title: "Floating bar", caption: "Live transcript at the top of the screen while recording", isOn: $settings.showFloatingBar)
                ToggleRow(title: "Sound effects", caption: "Tones when recording starts, stops or fails", isOn: $settings.soundEffects)
                ToggleRow(title: "Call detection", caption: "Suggest recording when an app begins using the microphone", isOn: $settings.detectCalls)
                ToggleRow(title: "Dock icon", caption: "Off: menu bar only", isOn: $settings.showDockIcon)
                ToggleRow(title: "Launch at login",
                          caption: LaunchAtLogin.isAvailable ? nil : "Available when running from Transcriber.app",
                          isOn: $settings.launchAtLogin, disabled: !LaunchAtLogin.isAvailable)
            }
            SettingsCard(title: "Updates", footer: "Updates come from GitHub releases of moritzjkr/Transcriber. No account needed.") {
                SettingRow(title: "Version", caption: UpdateChecker.buildInfo) {
                    HStack(spacing: 10) {
                        Text(UpdateChecker.currentVersion).font(.system(size: 13))
                        updateStatusText
                        Spacer()
                        if case .available(let v, _, _, _) = updater.status {
                            Button("Install \(v)…") { UpdateWindowController.shared.show() }
                                .buttonStyle(AccentButtonStyle())
                        }
                        Button("Check Now") { Task { await updater.check(interactive: true) } }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(updater.status == .checking)
                    }
                }
                SettingRow(title: "Check automatically", caption: "When the app has been running for a while and the interval has passed") {
                    ChoiceField(selection: $settings.updateCheckInterval, options: [
                        ("never", "Never"), ("launch", "Every launch"), ("daily", "Daily"), ("weekly", "Weekly"), ("monthly", "Monthly"),
                    ])
                }
                ToggleRow(title: "Pre-releases", caption: "Also offer beta versions", isOn: $settings.includePreReleases)
            }
            SettingsCard(title: "Legal") {
                NoteRow(text: "Inform participants before recording. Recording conversations without consent is illegal in many countries (e.g. § 201 StGB in Germany).")
            }
        }
    }

    @ViewBuilder
    private var updateStatusText: some View {
        Group {
            switch updater.status {
            case .idle:
                if let last = updater.lastCheck { Text("Checked \(last.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(Theme.secondary(scheme)) }
            case .checking: ProgressView().controlSize(.small)
            case .upToDate: Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available(let v, _, _, _): Label("\(v) available", systemImage: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            case .downloading: ProgressView().controlSize(.small)
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.system(size: 11.5))
    }
}

// MARK: - Audio

struct AudioSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @State private var inputs: [AudioDevice] = []
    @State private var defaultOutputName = ""

    var body: some View {
        SettingsPage(section: .audio) {
            SettingsCard(title: "Microphone – your voice") {
                ToggleRow(title: "Capture microphone", isOn: $settings.captureMicrophone)
                SettingRow(title: "Input device") {
                    ChoiceField(selection: $settings.inputDeviceUID,
                                options: [("", "System default")] + inputs.map { ($0.uid, $0.name) })
                }
                ToggleRow(title: "Echo gate", caption: "Mutes the far end's loudspeaker echo in your mic using the system audio as reference. Recommended.", isOn: $settings.echoGate)
                ToggleRow(title: "Apple voice processing", caption: "Experimental. If your microphone channel stays silent, turn this off. Headphones are the safest way to keep the other side out of your microphone.", isOn: $settings.echoCancellation)
            }
            SettingsCard(title: "System audio – the other side", footer: "System audio is tapped globally, so it follows the active output device (speakers, AirPods, …) and works with every app: Zoom, Teams, Meet, WhatsApp, browsers, YouTube.") {
                ToggleRow(title: "Capture system audio", isOn: $settings.captureSystemAudio)
                ValueRow(title: "Current output device", value: defaultOutputName)
            }
            SettingsCard(title: "Levels", footer: state.isRecording ? "Live" : "Meters are active while recording.") {
                LevelMeter(title: "Microphone", level: state.micLevel)
                LevelMeter(title: "System audio", level: state.systemLevel)
            }
            SettingsCard(title: "Permissions") {
                SettingRow(title: "Microphone and System Audio Recording", caption: "Both must be allowed for Transcriber.") {
                    Button("Open Privacy & Security…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }
                    .buttonStyle(SoftButtonStyle())
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private func refresh() {
        inputs = AudioDevices.inputDevices()
        defaultOutputName = AudioDevices.defaultOutputDevice()?.name ?? "–"
    }
}

struct LevelMeter: View {
    let title: String
    let level: Float
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        SettingRow(title: title) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.separator(scheme))
                    Capsule().fill(level > 0.9 ? Color.red : Theme.accent)
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 6)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager
    @Environment(\.colorScheme) private var scheme

    private let languages: [(String, String)] = [
        ("", "Auto-detect"), ("de", "German"), ("en", "English"), ("fr", "French"), ("es", "Spanish"),
        ("it", "Italian"), ("nl", "Dutch"), ("pt", "Portuguese"), ("pl", "Polish"), ("sv", "Swedish"),
    ]

    var body: some View {
        SettingsPage(section: .transcription) {
            SettingsCard(title: "Models", footer: "Parakeet TDT 0.6B v3 via FluidAudio. Downloaded once from Hugging Face, then fully offline on the Neural Engine.") {
                statusRow("Speech recognition", models.asrStatus)
                statusRow("Voice activity detection", models.vadStatus)
                statusRow("Speaker diarization", models.diarizerStatus)
                ValueRow(title: "Disk usage", value: ByteCountFormatter.string(fromByteCount: models.modelsDiskUsage(), countStyle: .file))
                ValueRow(title: "Location", value: models.modelsRootDirectory.path)
                SettingRow(title: "") {
                    HStack(spacing: 8) {
                        Button("Download All") { Task { await models.downloadAll(); await models.refreshStatus() } }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(isDownloading)
                        Button("Refresh") { Task { await models.refreshStatus() } }
                            .buttonStyle(SoftButtonStyle())
                        Spacer()
                        Button("Delete Models") { models.deleteAllModels() }
                            .buttonStyle(SoftButtonStyle())
                            .foregroundStyle(.red)
                    }
                }
            }
            SettingsCard(title: "Recognition") {
                SettingRow(title: "Language") {
                    ChoiceField(selection: $settings.languageCode, options: languages)
                }
                SettingRow(title: "Encoder precision", caption: "int8 for best quality, int4 for a smaller, faster model") {
                    ChoiceField(selection: $settings.encoderPrecision, options: [("int8", "int8 – best quality"), ("int4", "int4 – smaller and faster")])
                        .onChange(of: settings.encoderPrecision) { _, _ in
                            ModelCache.shared.invalidate()
                            Task { await models.refreshStatus(); await ModelCache.shared.preload(settings: settings) }
                        }
                }
                SettingRow(title: "Speech sensitivity", caption: "Lower picks up quieter speech, with more false starts") {
                    HStack(spacing: 12) {
                        Slider(value: $settings.vadThreshold, in: 0.3...0.9, step: 0.05)
                        Text(String(format: "%.2f", settings.vadThreshold))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary(scheme))
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            SettingsCard(title: "Speakers", footer: "Your own voice is identified by the microphone channel and never needs diarization.") {
                ToggleRow(title: "Separate remote speakers", caption: "Diarization runs after the call on the system audio", isOn: $settings.diarizeRemote)
                SettingRow(title: "Max remote speakers") {
                    Stepper("\(settings.maxRemoteSpeakers)", value: $settings.maxRemoteSpeakers, in: 1...8)
                }
                ToggleRow(title: "Guess speaker names", caption: "Experimental. When someone is addressed by name (\"…, Anna?\") or introduces themselves, the remote speaker who answers is labelled \"[Anna]\". Needs at least two matching mentions.", isOn: $settings.guessSpeakerNames)
            }
        }
        .onAppear { Task { await models.refreshStatus() } }
    }

    private var isDownloading: Bool {
        if case .downloading = models.asrStatus { return true }
        if case .downloading = models.vadStatus { return true }
        if case .downloading = models.diarizerStatus { return true }
        return false
    }

    @ViewBuilder
    private func statusRow(_ title: String, _ status: ModelManager.Status) -> some View {
        SettingRow(title: title) {
            Group {
                switch status {
                case .unknown: Text("…")
                case .notDownloaded: Text("Not downloaded").foregroundStyle(Theme.secondary(scheme))
                case .downloading(let p):
                    HStack { ProgressView(value: p).frame(width: 160); Text("\(Int(p * 100))%") }
                case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.system(size: 12.5))
        }
    }
}

// MARK: - Output

struct OutputSettings: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SettingsPage(section: .output) {
            SettingsCard(title: "Location", footer: "Each recording gets its own folder: transcript.md, transcript.jsonl (written live, crash safe), optional audio.") {
                SettingRow(title: "Transcripts folder") {
                    HStack(spacing: 8) {
                        FieldBox {
                            Text(settings.outputDirectory).font(.system(size: 12.5))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Button("Choose…", action: choose).buttonStyle(SoftButtonStyle())
                    }
                }
            }
            SettingsCard(title: "Formats") {
                ToggleRow(title: "Markdown", caption: "Always written live", isOn: $settings.exportMarkdown, disabled: true)
                ToggleRow(title: "JSON", caption: "With timestamps and confidence", isOn: $settings.exportJSON)
                ToggleRow(title: "SRT subtitles", isOn: $settings.exportSRT)
            }
            SettingsCard(title: "Audio") {
                ToggleRow(title: "Keep raw audio", caption: "mic.wav / system.wav – lets you re-transcribe later with a better model. About 115 MB per hour and channel.", isOn: $settings.keepAudio)
            }
            SettingsCard(title: "After stopping") {
                ToggleRow(title: "Ask for a title", caption: "The floating bar asks for a name before the recording is saved", isOn: $settings.askForTitle)
                SettingRow(title: "Low disk stop", caption: "Stop automatically below this much free space") {
                    Stepper("\(Int(settings.minFreeDiskGB)) GB", value: $settings.minFreeDiskGB, in: 1...50)
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputDirectory = url.path
        }
    }
}

// MARK: - AI hand-off

struct AISettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        SettingsPage(section: .ai) {
            SettingsCard(title: "Where to send transcripts", footer: settings.aiToolMode == "website"
                         ? "Short prompts go into the URL via {prompt}. Real call transcripts are too long for a URL, so the page opens and after a moment ⌘V is sent into its input field – first the transcript file, then the prompt."
                         : "Desktop apps cannot be prefilled directly. The app is brought to front and ⌘V is sent twice: first the transcript file (attached like a drag & drop), then the prompt text. macOS asks once for Accessibility access.") {
                SettingRow(title: "Tool") {
                    ChoiceField(selection: $settings.aiToolMode, options: [("website", "Website"), ("app", "Mac app")])
                }
                if settings.aiToolMode == "website" {
                    SettingRow(title: "URL", caption: "Use {prompt} where the text should go") {
                        HStack(spacing: 8) {
                            TextFieldBox(text: $settings.aiToolURL)
                            Menu {
                                ForEach(AITool.presets, id: \.url) { p in
                                    Button(p.name) { settings.aiToolURL = p.url }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text("Presets").font(.system(size: 12.5, weight: .medium))
                                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.secondary(scheme))
                                }
                                .frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Theme.fieldBackground(scheme), in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border(scheme)))
                            .fixedSize()
                        }
                    }
                } else {
                    SettingRow(title: "App") {
                        HStack(spacing: 8) {
                            FieldBox {
                                Text(settings.aiToolAppPath.isEmpty ? "None chosen" : (settings.aiToolAppPath as NSString).lastPathComponent)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(settings.aiToolAppPath.isEmpty ? Theme.secondary(scheme) : Theme.text(scheme))
                            }
                            Button("Choose…", action: chooseApp).buttonStyle(SoftButtonStyle())
                        }
                    }
                }
                ToggleRow(title: "Paste automatically", caption: "Needs Accessibility permission", isOn: $settings.aiAutoPaste)
                ToggleRow(title: "Attach as file", caption: "Pastes transcript.md as an attachment and only the prompt as text", isOn: $settings.aiAttachFile, disabled: !settings.aiAutoPaste)
            }
            SettingsCard(title: "Prompt", footer: "The transcript is attached as a file or appended below the prompt, depending on the options above.") {
                SettingRow(title: "Template") {
                    VStack(alignment: .trailing, spacing: 8) {
                        FieldBox(height: nil) {
                            TextEditor(text: $settings.aiPromptTemplate)
                                .font(.system(size: 12, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(.vertical, 8)
                                .frame(height: 260)
                        }
                        HStack(spacing: 8) {
                            if copied {
                                Label("Prompt copied", systemImage: "checkmark")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .frame(height: 28)
                                    .background(Theme.accent, in: Capsule())
                                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }
                            Button("Copy Prompt") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(settings.aiPromptTemplate, forType: .string)
                                withAnimation(.easeOut(duration: 0.15)) { copied = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation(.easeOut(duration: 0.25)) { copied = false }
                                }
                            }
                            .buttonStyle(SoftButtonStyle())
                            Button("Reset to Default") { settings.aiPromptTemplate = AITool.defaultPrompt }
                                .buttonStyle(SoftButtonStyle())
                        }
                    }
                }
            }
            SettingsCard(title: "Try it", footer: "After stopping a recording, the save prompt offers “Save & Open in …” as well.") {
                SettingRow(title: "Last recording", caption: state.currentSessionURL?.lastPathComponent ?? "No recording in this session yet") {
                    Button("Open in \(AITool.toolDisplayName)") {
                        if let url = state.currentSessionURL { AITool.open(session: url) }
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(state.currentSessionURL == nil || !AITool.isConfigured)
                }
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            settings.aiToolAppPath = url.path
        }
    }
}

// MARK: - Recovery

struct RecoverySettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPage(section: .recovery) {
            SettingsCard(title: "Unfinished recordings") {
                if state.pendingRecovery.isEmpty {
                    SettingRow(title: "None", caption: "Every recording was closed properly.") {
                        Button("Rescan") { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) }
                            .buttonStyle(SoftButtonStyle())
                    }
                } else {
                    ForEach(state.pendingRecovery) { s in
                        SettingRow(title: SessionStore.dateFormatter.string(from: s.startedAt)) {
                            Button("Finalize") {
                                Task { await SessionRecovery.finalizeAll([s], settings: settings, state: state) }
                            }
                            .buttonStyle(AccentButtonStyle())
                            .disabled(state.phase != .idle)
                        }
                    }
                    SettingRow(title: "") {
                        Button("Rescan") { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) }
                            .buttonStyle(SoftButtonStyle())
                    }
                }
            }
            SettingsCard(title: "How crash safety works") {
                NoteRow(text: "Every transcribed segment is appended to transcript.jsonl and flushed to disk immediately. Raw audio is written in 2-second flushes. If the Mac crashes, the transcript up to the last segment is intact and the remaining audio can be transcribed on the next launch.")
            }
        }
        .onAppear { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) }
    }
}
