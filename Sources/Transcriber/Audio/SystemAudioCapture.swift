import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays back (Zoom, Teams, browsers, WhatsApp…)
/// using a Core Audio process tap (macOS 14.2+). Unlike ScreenCaptureKit this
/// only needs the "System Audio Recording" permission, not screen recording.
///
/// A private aggregate device wraps the current default output device plus the
/// tap; an IOProc on that aggregate hands us the tapped audio.
///
/// Note: on macOS 26 a *global* tap (`stereoGlobalTapButExcludeProcesses`) is
/// created without error but its aggregate device never starts IO. A mixdown
/// tap over the explicit list of all audio process objects works, so that is
/// what we use – and we rebuild the tap whenever the process list changes so
/// apps launched mid-recording are included too.
final class SystemAudioCapture {
    typealias Handler = (_ samples16k: [Float], _ hostTime: UInt64) -> Void

    private let handler: Handler
    private let resampler = AudioResampler()
    private let queue = DispatchQueue(label: "transcriber.systemaudio", qos: .userInitiated)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private(set) var isRunning = false
    private var callbackCount = 0
    private var currentOptions = Options.default
    private var processListListener: AudioPropertyListener?
    private var rebuildWorkItem: DispatchWorkItem?
    private var tappedProcessCount = 0
    var formatDescription: String { tapFormat.map { "\($0.sampleRate) Hz, \($0.channelCount) ch, interleaved=\($0.isInterleaved)" } ?? "-" }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Knobs for experimenting with the tap configuration (see `--capture-test`).
    struct Options {
        var useSystemOutputDevice = false
        var privateTap = true
        var mixdownOfProcesses = false
        var useQueue = true
        var startAllProcs = false
        var includeOutputInSubDeviceList = true
        var noTap = false
        var excludeSelf = false
        var mixdownAllProcesses = true
        static let `default` = Options()
    }

    func start(options: Options = .default) throws {
        teardownTap()

        let outputID = options.useSystemOutputDevice
            ? AudioDevices.defaultDeviceID(kAudioHardwarePropertyDefaultSystemOutputDevice)
            : AudioDevices.defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        guard let outputID, let output = AudioDevices.allDevices().first(where: { $0.id == outputID }) else {
            throw CaptureError.noOutputDevice
        }

        // 1. Create the process tap (global mix of all processes, excluding none).
        let description: CATapDescription
        currentOptions = options
        if options.mixdownAllProcesses {
            let me = SystemAudioCapture.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
            let processes = SystemAudioCapture.allProcessObjects().filter { $0 != me }
            tappedProcessCount = processes.count
            description = CATapDescription(stereoMixdownOfProcesses: processes)
            AppLog.write("SystemAudioCapture: tapping \(processes.count) process objects")
        } else if options.mixdownOfProcesses {
            description = CATapDescription(stereoMixdownOfProcesses: [])
        } else if options.excludeSelf, let me = SystemAudioCapture.processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [me])
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.uuid = UUID()
        description.name = "Transcriber System Audio Tap"
        description.muteBehavior = .unmuted
        description.isPrivate = options.privateTap
        description.isExclusive = false

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw CaptureError.osStatus("AudioHardwareCreateProcessTap", tapStatus) }
        tapID = newTapID

        // 2. Read the tap's stream format.
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &asbdSize, &asbd)
        guard formatStatus == noErr else { throw CaptureError.osStatus("kAudioTapPropertyFormat", formatStatus) }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.badFormat }
        tapFormat = format
        AppLog.write("SystemAudioCapture: tap format \(formatDescription)")

        // 3. Build a private aggregate device: default output + our tap.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcriber Capture",
            kAudioAggregateDeviceUIDKey: "com.moritzkrause.anyrecord.aggregate." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: options.includeOutputInSubDeviceList ? [
                [kAudioSubDeviceUIDKey: output.uid]
            ] : [],
            kAudioAggregateDeviceTapListKey: options.noTap ? [] : [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggStatus == noErr else { throw CaptureError.osStatus("AudioHardwareCreateAggregateDevice", aggStatus) }
        aggregateID = newAggregateID

        // 4. Install an IOProc that receives the tapped audio as input.
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, options.useQueue ? queue : nil) { [weak self] _, inInputData, _, _, _ in
            guard let self, let format = self.tapFormat else { return }
            let hostTime = mach_absolute_time()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else {
                AppLog.write("SystemAudioCapture: could not wrap buffer list")
                return
            }
            let samples = self.resampler.convert(buffer)
            self.callbackCount += 1
            if self.callbackCount == 1 {
                AppLog.write("SystemAudioCapture: first callback, \(buffer.frameLength) frames → \(samples.count) samples at 16 kHz")
            }
            self.handler(samples, hostTime)
        }
        guard procStatus == noErr else { throw CaptureError.osStatus("AudioDeviceCreateIOProcIDWithBlock", procStatus) }

        let startStatus = AudioDeviceStart(aggregateID, options.startAllProcs ? nil : ioProcID)
        guard startStatus == noErr else { throw CaptureError.osStatus("AudioDeviceStart", startStatus) }
        AppLog.write("SystemAudioCapture: started tap \(tapID) on aggregate \(aggregateID) (output \(output.name))")
        isRunning = true

        if options.mixdownAllProcesses {
            installProcessListListener()
        }
    }

    /// Rebuilds the tap when audio processes appear or disappear (debounced).
    private func installProcessListListener() {
        guard processListListener == nil else { return }
        processListListener = AudioPropertyListener(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
            guard let self, self.isRunning else { return }
            self.rebuildWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning else { return }
                let me = SystemAudioCapture.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
                let count = SystemAudioCapture.allProcessObjects().filter { $0 != me }.count
                guard count != self.tappedProcessCount else { return }
                AppLog.write("SystemAudioCapture: process list changed (\(self.tappedProcessCount) → \(count)), rebuilding tap")
                let options = self.currentOptions
                self.teardownTap()
                do { try self.start(options: options) } catch { AppLog.write("SystemAudioCapture: rebuild failed: \(error)") }
            }
            self.rebuildWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    func stop() {
        processListListener = nil
        rebuildWorkItem?.cancel()
        rebuildWorkItem = nil
        teardownTap()
    }

    private func teardownTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pidValue) { ptr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), ptr, &size, &object)
        }
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func allProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Debug description of the aggregate device (stream/channel counts, sub-devices, taps).
    var aggregateDebugDescription: String {
        guard aggregateID != kAudioObjectUnknown else { return "no aggregate" }
        let inCh = AudioDevices.channelCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let outCh = AudioDevices.channelCount(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &ids) == noErr else { return [] }
            return ids
        }
        var aliveAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0; var sz = UInt32(4)
        AudioObjectGetPropertyData(aggregateID, &aliveAddr, 0, nil, &sz, &alive)
        let subs = objectList(kAudioAggregateDevicePropertyActiveSubDeviceList)
        let taps = objectList(kAudioAggregateDevicePropertyTapList)
        let rate = AudioDevices.nominalSampleRate(aggregateID)
        return "alive=\(alive) rate=\(rate) inCh=\(inCh) outCh=\(outCh) subDevices=\(subs) taps=\(taps) tapID=\(tapID)"
    }

    var isAggregateRunning: Bool {
        guard aggregateID != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunning, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &value)
        return value != 0
    }

    deinit { stop() }

    enum CaptureError: LocalizedError {
        case noOutputDevice
        case badFormat
        case osStatus(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice: return "No default output device found."
            case .badFormat: return "The system audio tap reported an unusable format."
            case .osStatus(let call, let status): return "\(call) failed (OSStatus \(status)). Check System Settings › Privacy & Security › Screen & System Audio Recording."
            }
        }
    }
}
