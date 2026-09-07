import Foundation
import Combine

/// User preferences persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static var defaultOutputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AnyRecord Transcripts", isDirectory: true)
    }

    private let defaults = UserDefaults.standard

    // General
    @Published var myName: String { didSet { defaults.set(myName, forKey: "myName") } }
    @Published var otherName: String { didSet { defaults.set(otherName, forKey: "otherName") } }
    @Published var showFloatingBar: Bool { didSet { defaults.set(showFloatingBar, forKey: "showFloatingBar") } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); LaunchAtLogin.sync(enabled: launchAtLogin) } }
    @Published var playStartTone: Bool { didSet { defaults.set(playStartTone, forKey: "playStartTone") } }
    @Published var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: "detectCalls") } }
    @Published var consentAcknowledged: Bool { didSet { defaults.set(consentAcknowledged, forKey: "consentAcknowledged") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    @Published var githubToken: String { didSet { defaults.set(githubToken, forKey: "githubToken") } }

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
        launchAtLogin = bool("launchAtLogin", false)
        playStartTone = bool("playStartTone", false)
        detectCalls = bool("detectCalls", true)
        consentAcknowledged = bool("consentAcknowledged", false)
        autoCheckUpdates = bool("autoCheckUpdates", true)
        githubToken = str("githubToken", "")

        inputDeviceUID = str("inputDeviceUID", "")
        echoCancellation = bool("echoCancellation", false)
        echoGate = bool("echoGate", true)
        captureMicrophone = bool("captureMicrophone", true)
        captureSystemAudio = bool("captureSystemAudio", true)

        languageCode = str("languageCode", "")
        encoderPrecision = str("encoderPrecision", "int8")
        diarizeRemote = bool("diarizeRemote", true)
        maxRemoteSpeakers = int("maxRemoteSpeakers", 4)
        vadThreshold = dbl("vadThreshold", 0.6)

        outputDirectory = str("outputDirectory", AppSettings.defaultOutputDirectory.path)
        exportMarkdown = bool("exportMarkdown", true)
        exportJSON = bool("exportJSON", false)
        exportSRT = bool("exportSRT", false)
        keepAudio = bool("keepAudio", true)
        askForTitle = bool("askForTitle", true)
        minFreeDiskGB = dbl("minFreeDiskGB", 2)
    }

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
    }
}
