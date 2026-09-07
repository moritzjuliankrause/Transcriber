import AVFoundation
import AppKit

enum Permissions {
    /// Requests microphone access (shows the system prompt on first use).
    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - System audio (kTCCServiceAudioCapture)
    //
    // There is no public API to request the "System Audio Recording" permission;
    // creating a process tap does not reliably trigger the prompt. Like other
    // open-source capture tools we call the private TCC framework. Fine for a
    // personal, non-App-Store build.

    enum SystemAudioStatus { case granted, denied, unknown }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void
    private static let tccHandle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let service = "kTCCServiceAudioCapture" as CFString

    static func systemAudioStatus() -> SystemAudioStatus {
        guard let handle = tccHandle, let sym = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(sym, to: PreflightFn.self)
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user has not decided yet.
    static func requestSystemAudio() async -> Bool {
        if systemAudioStatus() == .granted { return true }
        guard let handle = tccHandle, let sym = dlsym(handle, "TCCAccessRequest") else { return true }
        let request = unsafeBitCast(sym, to: RequestFn.self)
        return await withCheckedContinuation { cont in
            request(service, nil) { granted in cont.resume(returning: granted) }
        }
    }

    static func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    static func openSystemAudioSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }
}
