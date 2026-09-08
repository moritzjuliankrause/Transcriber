import AppKit
import Foundation
import Combine

/// User preferences persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
    }

    private let defaults = UserDefaults.standard

    // General
    @Published var myName: String { didSet { defaults.set(myName, forKey: "myName") } }
    @Published var otherName: String { didSet { defaults.set(otherName, forKey: "otherName") } }
    @Published var showFloatingBar: Bool { didSet { defaults.set(showFloatingBar, forKey: "showFloatingBar") } }
    /// Show the app icon in the Dock (otherwise menu bar only).
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: "showDockIcon"); let show = showDockIcon; Task { @MainActor in DockIcon.apply(show) } } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); LaunchAtLogin.sync(enabled: launchAtLogin) } }
    /// App-wide sound effects (start, stop, error).
    @Published var soundEffects: Bool { didSet { defaults.set(soundEffects, forKey: "soundEffects") } }
    @Published var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: "detectCalls") } }
    @Published var consentAcknowledged: Bool { didSet { defaults.set(consentAcknowledged, forKey: "consentAcknowledged") } }
    /// never | launch | daily | weekly | monthly
    @Published var updateCheckInterval: String { didSet { defaults.set(updateCheckInterval, forKey: "updateCheckInterval") } }
    @Published var modelsPromptShown: Bool { didSet { defaults.set(modelsPromptShown, forKey: "modelsPromptShown") } }
    @Published var includePreReleases: Bool { didSet { defaults.set(includePreReleases, forKey: "includePreReleases") } }
    /// system | light | dark – applied to every window of the app.
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance"); let a = appearance; Task { @MainActor in AppSettings.applyAppearance(a) } } }

    // AI hand-off
    @Published var aiToolMode: String { didSet { defaults.set(aiToolMode, forKey: "aiToolMode") } }        // website | app
    @Published var aiToolURL: String { didSet { defaults.set(aiToolURL, forKey: "aiToolURL") } }
    @Published var aiToolAppPath: String { didSet { defaults.set(aiToolAppPath, forKey: "aiToolAppPath") } }
    @Published var aiPromptTemplate: String { didSet { defaults.set(aiPromptTemplate, forKey: "aiPromptTemplate") } }
    @Published var aiAutoPaste: Bool { didSet { defaults.set(aiAutoPaste, forKey: "aiAutoPaste") } }
    /// Attach transcript.md as a file and paste only the prompt text (instead of one long text).
    @Published var aiAttachFile: Bool { didSet { defaults.set(aiAttachFile, forKey: "aiAttachFile") } }

    // Audio
    @Published var inputDeviceUID: String { didSet { defaults.set(inputDeviceUID, forKey: "inputDeviceUID") } }
    @Published var echoCancellation: Bool { didSet { defaults.set(echoCancellation, forKey: "echoCancellation") } }
    @Published var echoGate: Bool { didSet { defaults.set(echoGate, forKey: "echoGate") } }
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: "captureMicrophone") } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }

    // Transcription
    @Published var languageCode: String { didSet { defaults.set(languageCode, forKey: "languageCode") } }   // "" = auto
    @Published var encoderPrecision: String { didSet { defaults.set(encoderPrecision, forKey: "encoderPrecision") } } // int8 / int4
    @Published var diarizeRemote: Bool { didSet { defaults.set(diarizeRemote, forKey: "diarizeRemote") } }
    @Published var maxRemoteSpeakers: Int { didSet { defaults.set(maxRemoteSpeakers, forKey: "maxRemoteSpeakers") } }
    /// Guess remote speakers' names from how people address each other ("Speaker 1 [Anna]").
    @Published var guessSpeakerNames: Bool { didSet { defaults.set(guessSpeakerNames, forKey: "guessSpeakerNames") } }
    @Published var vadThreshold: Double { didSet { defaults.set(vadThreshold, forKey: "vadThreshold") } }

    // Output
    @Published var outputDirectory: String { didSet { defaults.set(outputDirectory, forKey: "outputDirectory") } }
    @Published var exportMarkdown: Bool { didSet { defaults.set(exportMarkdown, forKey: "exportMarkdown") } }
    @Published var exportJSON: Bool { didSet { defaults.set(exportJSON, forKey: "exportJSON") } }
    @Published var exportSRT: Bool { didSet { defaults.set(exportSRT, forKey: "exportSRT") } }
    @Published var keepAudio: Bool { didSet { defaults.set(keepAudio, forKey: "keepAudio") } }
    @Published var askForTitle: Bool { didSet { defaults.set(askForTitle, forKey: "askForTitle") } }
    @Published var minFreeDiskGB: Double { didSet { defaults.set(minFreeDiskGB, forKey: "minFreeDiskGB") } }

    private init() {
        let d = UserDefaults.standard
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) == nil ? def : d.integer(forKey: k) }
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }

        myName = str("myName", "Me")
        otherName = str("otherName", "Speaker")
        showFloatingBar = bool("showFloatingBar", true)
        showDockIcon = bool("showDockIcon", false)
        launchAtLogin = bool("launchAtLogin", false)
        soundEffects = bool("soundEffects", true)
        detectCalls = bool("detectCalls", true)
        consentAcknowledged = bool("consentAcknowledged", false)
        // Migration from the old on/off switch (default was daily).
        updateCheckInterval = str("updateCheckInterval", bool("autoCheckUpdates", true) ? "daily" : "never")
        modelsPromptShown = bool("modelsPromptShown", false)
        includePreReleases = bool("includePreReleases", false)
        appearance = str("appearance", "system")

        aiToolMode = str("aiToolMode", "website")
        aiToolURL = str("aiToolURL", "https://claude.ai/new?q={prompt}")
        aiToolAppPath = str("aiToolAppPath", "")
        let storedPrompt = str("aiPromptTemplate", AITool.defaultPrompt)
        aiPromptTemplate = storedPrompt == AITool.legacyDefaultPrompt ? AITool.defaultPrompt : storedPrompt
        aiAutoPaste = bool("aiAutoPaste", true)
        aiAttachFile = bool("aiAttachFile", true)

        inputDeviceUID = str("inputDeviceUID", "")
        echoCancellation = bool("echoCancellation", false)
        echoGate = bool("echoGate", true)
        captureMicrophone = bool("captureMicrophone", true)
        captureSystemAudio = bool("captureSystemAudio", true)

        languageCode = str("languageCode", "")
        encoderPrecision = str("encoderPrecision", "int8")
        diarizeRemote = bool("diarizeRemote", true)
        maxRemoteSpeakers = int("maxRemoteSpeakers", 4)
        guessSpeakerNames = bool("guessSpeakerNames", false)
        vadThreshold = dbl("vadThreshold", 0.6)

        outputDirectory = str("outputDirectory", AppSettings.defaultOutputDirectory.path)
        exportMarkdown = bool("exportMarkdown", true)
        exportJSON = bool("exportJSON", false)
        exportSRT = bool("exportSRT", false)
        keepAudio = bool("keepAudio", true)
        askForTitle = bool("askForTitle", true)
        minFreeDiskGB = dbl("minFreeDiskGB", 2)
    }

    @MainActor
    static func applyAppearance(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }
}
