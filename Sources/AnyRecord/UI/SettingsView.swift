import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelManager

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case audio = "Audio"
        case transcription = "Transcription"
        case output = "Output"
        case recovery = "Recovery"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gear"
            case .audio: return "waveform"
            case .transcription: return "text.bubble"
            case .output: return "folder"
            case .recovery: return "arrow.counterclockwise"
            }
        }
    }

    @State private var selection: Section = .general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Section.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(selection == section ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("AnyRecord \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            }
            .padding(10)
            .frame(width: 170)
            .background(.regularMaterial)

            Divider()

            Group {
                switch selection {
                case .general: GeneralSettings(settings: settings)
                case .audio: AudioSettings(settings: settings, state: state)
                case .transcription: TranscriptionSettings(settings: settings, models: models)
                case .output: OutputSettings(settings: settings)
                case .recovery: RecoverySettings(settings: settings, state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 500)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater = UpdateChecker.shared

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Version", value: "\(UpdateChecker.currentVersion) (\(UpdateChecker.buildInfo))")
                HStack {
                    Button("Check for Updates…") { Task { await updater.check(interactive: true) } }
                        .disabled(updater.status == .checking)
                    if case .available(let v, _, _, _) = updater.status {
                        Button("Install \(v)") { Task { await updater.installAvailableUpdate() } }
                    }
                    Spacer()
                    updateStatusText
                }
                Toggle("Check automatically once a day", isOn: $settings.autoCheckUpdates)
                Text("Updates come from GitHub releases of moritzjkr/AnyRecord. No account needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speaker labels") {
                TextField("Your name (microphone)", text: $settings.myName)
                TextField("Remote speaker label (system audio)", text: $settings.otherName)
                Text("Remote participants become \"\(settings.otherName) 1\", \"\(settings.otherName) 2\" … when diarization finds several voices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Show floating live-transcript bar while recording", isOn: $settings.showFloatingBar)
                Toggle("Play a tone when recording starts", isOn: $settings.playStartTone)
                Toggle("Suggest recording when an app starts using the microphone", isOn: $settings.detectCalls)
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
                if !LaunchAtLogin.isAvailable {
                    Text("Available when running from AnyRecord.app (scripts/bundle.sh).").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Shortcut") {
                LabeledContent("Start / stop recording", value: "⌃⌥⌘R")
            }
            Section {
                Text("Reminder: inform participants before recording. Recording conversations without consent is illegal in many countries (e.g. § 201 StGB in Germany).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension GeneralSettings {
    @ViewBuilder
    var updateStatusText: some View {
        switch updater.status {
        case .idle:
            if let last = updater.lastCheck { Text("Last check \(last.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let v, _, _, _): Label("\(v) available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .downloading: ProgressView().controlSize(.small)
        case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
        }
    }
}

// MARK: - Audio

struct AudioSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState
    @State private var inputs: [AudioDevice] = []
    @State private var defaultOutputName = ""

    var body: some View {
        Form {
            Section("Microphone (your voice)") {
                Toggle("Capture microphone", isOn: $settings.captureMicrophone)
                Picker("Input device", selection: $settings.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputs) { d in Text(d.name).tag(d.uid) }
                }
                Toggle("Echo gate: mute the far end's loudspeaker echo in your mic (recommended)", isOn: $settings.echoGate)
                Text("Uses the system audio channel as reference. Mic frames that only contain what the other side said are muted, and duplicated sentences are dropped from the transcript.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Apple voice processing (experimental)", isOn: $settings.echoCancellation)
                Text("Uses Apple voice processing. Currently unreliable on some Macs – if your microphone channel stays silent, turn this off. Headphones are the safest way to keep the other side out of your microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System audio (the other side)") {
                Toggle("Capture system audio", isOn: $settings.captureSystemAudio)
                LabeledContent("Current output device", value: defaultOutputName)
                Text("System audio is tapped globally, so it always follows the active output device (speakers, AirPods, …) and works with every app: Zoom, Teams, Meet, WhatsApp, browsers, YouTube.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Levels") {
                LevelMeter(title: "Microphone", level: state.micLevel)
                LevelMeter(title: "System audio", level: state.systemLevel)
                Text(state.isRecording ? "Live" : "Meters are active while recording.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Button("Open Privacy & Security settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
                Text("Microphone and System Audio Recording must be allowed for AnyRecord.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        LabeledContent(title) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(level > 0.9 ? Color.red : Color.green)
                        .frame(width: geo.size.width * CGFloat(level))
                }
            }
            .frame(width: 200, height: 8)
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
        Form {
            Section("Model: Parakeet TDT 0.6B v3 (FluidAudio, CoreML)") {
                statusRow("Speech recognition", models.asrStatus)
                statusRow("Voice activity detection", models.vadStatus)
                statusRow("Speaker diarization", models.diarizerStatus)
                HStack {
                    Button("Download all models") { Task { await models.downloadAll(); await models.refreshStatus() } }
                        .disabled(isDownloading)
                    Button("Refresh") { Task { await models.refreshStatus() } }
                    Spacer()
                    Button("Delete models", role: .destructive) { models.deleteAllModels() }
                }
                LabeledContent("Disk usage", value: ByteCountFormatter.string(fromByteCount: models.modelsDiskUsage(), countStyle: .file))
                LabeledContent("Location", value: models.modelsRootDirectory.path).font(.caption)
                Text("Models are downloaded once from Hugging Face and then run fully offline on the Neural Engine.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Recognition") {
                Picker("Language", selection: $settings.languageCode) {
                    ForEach(languages, id: \.0) { code, name in Text(name).tag(code) }
                }
                Picker("Encoder precision", selection: $settings.encoderPrecision) {
                    Text("int8 (best quality)").tag("int8")
                    Text("int4 (smaller, faster)").tag("int4")
                }
                .onChange(of: settings.encoderPrecision) { _, _ in Task { await models.refreshStatus() } }
                VStack(alignment: .leading) {
                    Slider(value: $settings.vadThreshold, in: 0.3...0.9, step: 0.05) { Text("Speech sensitivity") }
                    Text("Lower = picks up quieter speech (more false starts). Current: \(String(format: "%.2f", settings.vadThreshold))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Speakers") {
                Toggle("Separate multiple remote speakers after the call (diarization)", isOn: $settings.diarizeRemote)
                Stepper("Max remote speakers: \(settings.maxRemoteSpeakers)", value: $settings.maxRemoteSpeakers, in: 1...8)
                Text("Your own voice is identified by the microphone channel and never needs diarization.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        LabeledContent(title) {
            switch status {
            case .unknown: Text("…")
            case .notDownloaded: Text("Not downloaded").foregroundStyle(.secondary)
            case .downloading(let p):
                HStack { ProgressView(value: p).frame(width: 120); Text("\(Int(p * 100))%") }
            case .ready: Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

// MARK: - Output

struct OutputSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Transcripts folder") {
                    HStack {
                        Text(settings.outputDirectory).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: choose)
                    }
                }
                Text("Each recording gets its own folder: transcript.md, transcript.jsonl (written live, crash safe), optional audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Formats") {
                Toggle("Markdown (always written live)", isOn: $settings.exportMarkdown).disabled(true)
                Toggle("JSON (with timestamps and confidence)", isOn: $settings.exportJSON)
                Toggle("SRT subtitles", isOn: $settings.exportSRT)
            }
            Section("Audio") {
                Toggle("Keep raw audio (mic.wav / system.wav) after transcription", isOn: $settings.keepAudio)
                Text("Keeping audio lets you re-transcribe later with a better model. ~115 MB per hour and channel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("After stopping") {
                Toggle("Ask for a title", isOn: $settings.askForTitle)
                Stepper("Stop automatically below \(Int(settings.minFreeDiskGB)) GB free disk", value: $settings.minFreeDiskGB, in: 1...50)
            }
        }
        .formStyle(.grouped)
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

// MARK: - Recovery

struct RecoverySettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Unfinished recordings") {
                if state.pendingRecovery.isEmpty {
                    Text("None. Every recording was closed properly.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.pendingRecovery) { s in
                        HStack {
                            Text(SessionStore.dateFormatter.string(from: s.startedAt))
                            Spacer()
                            Button("Finalize") {
                                Task { await SessionRecovery.finalizeAll([s], settings: settings, state: state) }
                            }
                            .disabled(state.phase != .idle)
                        }
                    }
                }
                Button("Rescan") { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) }
            }
            Section("How crash safety works") {
                Text("""
                Every transcribed segment is appended to transcript.jsonl and flushed to disk immediately. \
                Raw audio is written in 2-second flushes. If the Mac crashes, the transcript up to the last \
                segment is intact and the remaining audio can be transcribed on the next launch.
                """).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state.pendingRecovery = SessionRecovery.findIncomplete(in: settings.outputDirectoryURL) }
    }
}
