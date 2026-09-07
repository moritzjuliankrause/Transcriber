import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelManager

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
            case .general: return "gearshape.fill"
            case .audio: return "waveform"
            case .transcription: return "text.bubble.fill"
            case .output: return "folder.fill"
            case .recovery: return "arrow.counterclockwise"
            case .ai: return "sparkles"
            }
        }
        var tint: Color {
            switch self {
            case .general: return Color(nsColor: .systemGray)
            case .audio: return .orange
            case .transcription: return .blue
            case .output: return .green
            case .recovery: return .purple
            case .ai: return .pink
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "Names, behaviour and updates"
            case .audio: return "What is captured and how"
            case .transcription: return "Models, language and speakers"
            case .output: return "Where and how transcripts are saved"
            case .recovery: return "Unfinished recordings"
            case .ai: return "Hand transcripts to your AI tool"
            }
        }
    }

    static let size = CGSize(width: 800, height: 580)
    @State private var selection: Section = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
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
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: SettingsView.size.width, height: SettingsView.size.height)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights (the title bar is transparent).
            Spacer().frame(height: 34)
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Transcriber").font(.system(size: 14, weight: .semibold))
                    Text(UpdateChecker.currentVersion).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                ForEach(Section.allCases) { section in
                    SidebarRow(section: section, selected: selection == section) {
                        withAnimation(.easeOut(duration: 0.15)) { selection = section }
                    }
                }
            }
            .padding(.horizontal, 10)
            Spacer()
            Text("⌃⌥⌘R  start / stop")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.horizontal, 20).padding(.bottom, 14)
        }
        .frame(width: 210)
        .background(.regularMaterial)
    }
}

private struct SidebarRow: View {
    let section: SettingsView.Section
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        LinearGradient(colors: [section.tint.opacity(0.95), section.tint.opacity(0.7)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: section.tint.opacity(0.3), radius: 2, y: 1)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Building blocks

/// A settings page: big title, subtitle, then cards.
struct SettingsPage<Content: View>: View {
    let section: SettingsView.Section
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.rawValue).font(.system(size: 24, weight: .bold))
                    Text(section.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(.top, 30)
                content
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A rounded card with a small caps title; rows are separated by hairlines.
struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                _VariadicView.Tree(CardRows()) { content }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private struct CardRows: _VariadicView_MultiViewRoot {
        @ViewBuilder func body(children: _VariadicView.Children) -> some View {
            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                child
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if index < children.count - 1 {
                    Divider().padding(.leading, 14)
                }
            }
        }
    }
}

/// Label (+ optional caption) on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
        }
    }
}

/// A switch row.
struct ToggleRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        SettingRow(title: title, caption: caption) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// Text on the right, like LabeledContent.
struct ValueRow: View {
    let title: String
    let value: String
    var body: some View {
        SettingRow(title: title) {
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// Free text that spans the row (explanations inside a card).
struct NoteRow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater = UpdateChecker.shared

    var body: some View {
        SettingsPage(section: .general) {
            SettingsCard(title: "Speaker labels", footer: "Remote participants become \"\(settings.otherName) 1\", \"\(settings.otherName) 2\" … when diarization finds several voices.") {
                SettingRow(title: "Your name", caption: "Microphone channel") {
                    TextField("", text: $settings.myName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
                SettingRow(title: "Remote speaker label", caption: "System audio channel") {
                    TextField("", text: $settings.otherName).textFieldStyle(.roundedBorder).frame(width: 200)
                }
            }
            SettingsCard(title: "Behaviour") {
                ToggleRow(title: "Floating live-transcript bar", caption: "Shown at the top of the screen while recording", isOn: $settings.showFloatingBar)
                ToggleRow(title: "Sound effects", caption: "Tones when recording starts, stops or fails", isOn: $settings.soundEffects)
                ToggleRow(title: "Suggest recording when a call starts", caption: "Watches for apps that begin using the microphone", isOn: $settings.detectCalls)
                ToggleRow(title: "Show icon in the Dock", caption: "Off: menu bar only", isOn: $settings.showDockIcon)
                ToggleRow(title: "Launch at login",
                          caption: LaunchAtLogin.isAvailable ? nil : "Available when running from Transcriber.app",
                          isOn: $settings.launchAtLogin, disabled: !LaunchAtLogin.isAvailable)
            }
            SettingsCard(title: "Updates", footer: "Updates come from GitHub releases of moritzjkr/Transcriber. No account needed.") {
                SettingRow(title: "Version \(UpdateChecker.currentVersion)", caption: UpdateChecker.buildInfo) {
                    HStack(spacing: 10) {
                        updateStatusText
                        if case .available(let v, _, _, _) = updater.status {
                            Button("Install \(v)…") { UpdateWindowController.shared.show() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Check Now") { Task { await updater.check(interactive: true) } }
                            .disabled(updater.status == .checking)
                    }
                }
                ToggleRow(title: "Check automatically once a day", isOn: $settings.autoCheckUpdates)
                ToggleRow(title: "Include pre-releases", caption: "Beta versions", isOn: $settings.includePreReleases)
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
                if let last = updater.lastCheck { Text("Checked \(last.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary) }
            case .checking: ProgressView().controlSize(.small)
            case .upToDate: Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .available(let v, _, _, _): Label("\(v) available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
            case .downloading: ProgressView().controlSize(.small)
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.system(size: 11))
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
                    Picker("", selection: $settings.inputDeviceUID) {
                        Text("System default").tag("")
                        ForEach(inputs) { d in Text(d.name).tag(d.uid) }
                    }
                    .labelsHidden().frame(width: 220)
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
    var body: some View {
        SettingRow(title: title) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(level > 0.9 ? Color.red : Color.green)
                        .frame(width: max(0, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(width: 220, height: 6)
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager

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
                HStack {
                    Button("Download All") { Task { await models.downloadAll(); await models.refreshStatus() } }
                        .disabled(isDownloading)
                    Button("Refresh") { Task { await models.refreshStatus() } }
                    Spacer()
                    Button("Delete Models", role: .destructive) { models.deleteAllModels() }
                }
            }
            SettingsCard(title: "Recognition") {
                SettingRow(title: "Language") {
                    Picker("", selection: $settings.languageCode) {
                        ForEach(languages, id: \.0) { code, name in Text(name).tag(code) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                SettingRow(title: "Encoder precision", caption: "int8 for best quality, int4 for a smaller, faster model") {
                    Picker("", selection: $settings.encoderPrecision) {
                        Text("int8").tag("int8")
                        Text("int4").tag("int4")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                    .onChange(of: settings.encoderPrecision) { _, _ in
                        ModelCache.shared.invalidate()
                        Task { await models.refreshStatus(); await ModelCache.shared.preload(settings: settings) }
                    }
                }
                SettingRow(title: "Speech sensitivity", caption: "Lower picks up quieter speech, with more false starts. Current: \(String(format: "%.2f", settings.vadThreshold))") {
                    Slider(value: $settings.vadThreshold, in: 0.3...0.9, step: 0.05).frame(width: 180)
                }
            }
            SettingsCard(title: "Speakers", footer: "Your own voice is identified by the microphone channel and never needs diarization.") {
                ToggleRow(title: "Separate remote speakers", caption: "Diarization runs after the call on the system audio", isOn: $settings.diarizeRemote)
                SettingRow(title: "Max remote speakers") {
                    Stepper("\(settings.maxRemoteSpeakers)", value: $settings.maxRemoteSpeakers, in: 1...8).frame(width: 60)
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
                case .notDownloaded: Text("Not downloaded").foregroundStyle(.secondary)
                case .downloading(let p):
                    HStack { ProgressView(value: p).frame(width: 120); Text("\(Int(p * 100))%") }
                case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.system(size: 12))
        }
    }
}

// MARK: - Output

struct OutputSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPage(section: .output) {
            SettingsCard(title: "Location", footer: "Each recording gets its own folder: transcript.md, transcript.jsonl (written live, crash safe), optional audio.") {
                SettingRow(title: "Transcripts folder", caption: settings.outputDirectory) {
                    Button("Choose…", action: choose)
                }
            }
            SettingsCard(title: "Formats") {
                ToggleRow(title: "Markdown", caption: "Always written live", isOn: $settings.exportMarkdown, disabled: true)
                ToggleRow(title: "JSON", caption: "With timestamps and confidence", isOn: $settings.exportJSON)
                ToggleRow(title: "SRT subtitles", isOn: $settings.exportSRT)
            }
            SettingsCard(title: "Audio") {
                ToggleRow(title: "Keep raw audio after transcription", caption: "mic.wav / system.wav – lets you re-transcribe later with a better model. About 115 MB per hour and channel.", isOn: $settings.keepAudio)
            }
            SettingsCard(title: "After stopping") {
                ToggleRow(title: "Ask for a title", isOn: $settings.askForTitle)
                SettingRow(title: "Stop automatically when disk is low", caption: "Below \(Int(settings.minFreeDiskGB)) GB free") {
                    Stepper("\(Int(settings.minFreeDiskGB)) GB", value: $settings.minFreeDiskGB, in: 1...50).frame(width: 80)
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

    var body: some View {
        SettingsPage(section: .ai) {
            SettingsCard(title: "Where to send transcripts", footer: settings.aiToolMode == "website"
                         ? "Short prompts go into the URL via {prompt}. Real call transcripts are too long for a URL, so the page opens and after a moment ⌘V is sent into its input field – first the transcript file, then the prompt."
                         : "Desktop apps cannot be prefilled directly. The app is brought to front and ⌘V is sent twice: first the transcript file (attached like a drag & drop), then the prompt text. macOS asks once for Accessibility access.") {
                SettingRow(title: "Tool") {
                    Picker("", selection: $settings.aiToolMode) {
                        Text("Website").tag("website")
                        Text("Mac app").tag("app")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                if settings.aiToolMode == "website" {
                    SettingRow(title: "URL", caption: "Use {prompt} where the text should go") {
                        HStack {
                            TextField("", text: $settings.aiToolURL).textFieldStyle(.roundedBorder).frame(width: 260)
                            Menu("Presets") {
                                ForEach(AITool.presets, id: \.url) { p in
                                    Button(p.name) { settings.aiToolURL = p.url }
                                }
                            }
                            .frame(width: 90)
                        }
                    }
                } else {
                    SettingRow(title: "App", caption: settings.aiToolAppPath.isEmpty ? "None chosen" : (settings.aiToolAppPath as NSString).lastPathComponent) {
                        Button("Choose…", action: chooseApp)
                    }
                }
                ToggleRow(title: "Paste automatically", caption: "Needs Accessibility permission", isOn: $settings.aiAutoPaste)
                ToggleRow(title: "Attach transcript as a file", caption: "Pastes transcript.md as an attachment and only the prompt as text", isOn: $settings.aiAttachFile, disabled: !settings.aiAutoPaste)
            }
            SettingsCard(title: "Prompt", footer: "The transcript is attached as a file or appended below the prompt, depending on the options above.") {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $settings.aiPromptTemplate)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 200)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Button("Reset to Default") { settings.aiPromptTemplate = AITool.defaultPrompt }
                }
            }
            SettingsCard(title: "Try it", footer: "After stopping a recording, the title dialog offers “Save & Open in …” as well.") {
                SettingRow(title: "Last recording", caption: state.currentSessionURL?.lastPathComponent ?? "No recording in this session yet") {
                    Button("Open in \(AITool.toolDisplayName)") {
                        if let url = state.currentSessionURL { AITool.open(session: url) }
                    }
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
                    }
                } else {
                    ForEach(state.pendingRecovery) { s in
                        SettingRow(title: SessionStore.dateFormatter.string(from: s.startedAt)) {
                            Button("Finalize") {
                                Task { await SessionRecovery.finalizeAll([s], settings: settings, state: state) }
                            }
                            .disabled(state.phase != .idle)
                        }
                    }
                    HStack { Spacer(); Button("Rescan") { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) } }
                }
            }
            SettingsCard(title: "How crash safety works") {
                NoteRow(text: "Every transcribed segment is appended to transcript.jsonl and flushed to disk immediately. Raw audio is written in 2-second flushes. If the Mac crashes, the transcript up to the last segment is intact and the remaining audio can be transcribed on the next launch.")
            }
        }
        .onAppear { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) }
    }
}
