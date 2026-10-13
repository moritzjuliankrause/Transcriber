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
///
/// The tap only delivers buffers while one of its processes plays something; silence on the
/// system channel is therefore normal and filled in by the coordinator.
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
    /// The process objects the current tap covers.
    private(set) var tappedProcesses: Set<AudioObjectID> = []
    private var rateListener: AudioPropertyListener?
    /// Rate watchdog (IO queue only): frames delivered since `rateCheckStart` (host time).
    private var rateCheckFrames = 0
    private var rateCheckStart: UInt64 = 0
    private var rateCheckLast: UInt64 = 0
    /// A deviating rate seen in the previous window; applied only when the next one agrees.
    private var rateCandidate: Double?
    private static let hostTimeToSeconds: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    private static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
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
            tappedProcesses = Set(processes)
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
        guard let tapReported = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.badFormat }
        AppLog.write("SystemAudioCapture: tap format \(tapReported.sampleRate) Hz, \(tapReported.channelCount) ch, interleaved=\(tapReported.isInterleaved)")

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

        // The tap delivers its audio on the aggregate's clock. When the output device runs at a
        // different rate than the tap reports – AirPods drop to 24 kHz in call mode once their
        // microphone is opened – the buffers carry the *device* rate. Wrapping them with the tap's
        // 48 kHz made the system channel record at double speed and half the length (a whole
        // Zoom call with chipmunk voices that diarization could not tell apart).
        let aggregateRate = AudioDevices.nominalSampleRate(aggregateID)
        let format = SystemAudioCapture.format(tapReported, rate: aggregateRate > 0 ? aggregateRate : tapReported.sampleRate)
        tapFormat = format
        resetRateCheck()
        if format.sampleRate != tapReported.sampleRate {
            AppLog.write("SystemAudioCapture: aggregate runs at \(format.sampleRate) Hz, using that instead of the tap's \(tapReported.sampleRate) Hz")
        }
        let aggregateForListener = aggregateID
        rateListener = AudioPropertyListener(objectID: aggregateID, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self, self.aggregateID == aggregateForListener else { return }
            let rate = AudioDevices.nominalSampleRate(aggregateForListener)
            self.queue.async { self.applyRate(rate, reason: "aggregate rate changed") }
        }

        // 4. Install an IOProc that receives the tapped audio as input.
        // The tap's buffers are the last ones in the input list: 1 for interleaved audio,
        // one per channel otherwise.
        let tapBufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, options.useQueue ? queue : nil) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, var format = self.tapFormat else { return }
            // When the first frame of this buffer was captured (not when the callback runs, which
            // can lag on a busy queue); falls back to "now" if the device gives no host time.
            let hostTime = inInputTime.pointee.mFlags.contains(.hostTimeValid) ? inInputTime.pointee.mHostTime : mach_absolute_time()
            // The aggregate's input side lists the output device's own input streams first (a USB
            // interface such as a Scarlett has microphone inputs; built-in speakers have none), then
            // the tap. Using the whole list as-is would read the interface's silent inputs.
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let total = all.count
            let tapBuffers: UnsafeMutablePointer<AudioBufferList>
            var owned: UnsafeMutablePointer<AudioBufferList>?
            if total > tapBufferCount {
                let list = AudioBufferList.allocate(maximumBuffers: tapBufferCount)
                for (i, index) in ((total - tapBufferCount)..<total).enumerated() { list[i] = all[index] }
                tapBuffers = list.unsafeMutablePointer
                owned = tapBuffers
            } else {
                tapBuffers = UnsafeMutablePointer(mutating: inInputData)
            }
            defer { owned?.deallocate() }
            if let corrected = self.checkRate(frames: Int(tapBuffers.pointee.mBuffers.mDataByteSize) / Int(format.streamDescription.pointee.mBytesPerFrame), at: hostTime) {
                format = corrected
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tapBuffers, deallocator: nil) else {
                AppLog.write("SystemAudioCapture: could not wrap buffer list")
                return
            }
            let samples = self.resampler.convert(buffer)
            self.callbackCount += 1
            if self.callbackCount == 1 {
                let channels = (0..<total).map { "\(all[$0].mNumberChannels)ch" }.joined(separator: ",")
                AppLog.write("SystemAudioCapture: first callback, \(total) input buffer(s) [\(channels)], using the last \(tapBufferCount); \(buffer.frameLength) frames → \(samples.count) samples at 16 kHz")
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

    private static func format(_ base: AVAudioFormat, rate: Double) -> AVAudioFormat {
        guard rate != base.sampleRate else { return base }
        var asbd = base.streamDescription.pointee
        asbd.mSampleRate = rate
        return AVAudioFormat(streamDescription: &asbd) ?? base
    }

    /// Switches the wrapping format to a new sample rate. IO queue only.
    private func applyRate(_ rate: Double, reason: String) {
        guard rate > 0, let current = tapFormat, abs(rate - current.sampleRate) > 1 else { return }
        AppLog.write("SystemAudioCapture: \(reason): \(current.sampleRate) → \(rate) Hz")
        tapFormat = SystemAudioCapture.format(current, rate: rate)
        resetRateCheck()
    }

    private func resetRateCheck() {
        rateCheckFrames = 0
        rateCheckStart = 0
        rateCheckLast = 0
        rateCandidate = nil
    }

    /// Safety net for rate changes nobody announces: compares the frames actually delivered
    /// against wall-clock time over ~5 s windows and, when two windows in a row disagree with the
    /// format by more than 10 %, snaps to the nearest standard rate. A gap in delivery (device
    /// asleep, switching) restarts the window, so it never reads as a slow rate. Returns the
    /// corrected format, if any. IO queue only.
    private func checkRate(frames: Int, at hostTime: UInt64) -> AVAudioFormat? {
        guard frames > 0, let format = tapFormat else { return nil }
        let sinceLast = Double(hostTime &- rateCheckLast) * SystemAudioCapture.hostTimeToSeconds
        rateCheckLast = hostTime
        if rateCheckStart == 0 || sinceLast > 0.5 {
            rateCheckStart = hostTime   // count from the next buffer on
            rateCheckFrames = 0
            return nil
        }
        rateCheckFrames += frames
        let elapsed = Double(hostTime - rateCheckStart) * SystemAudioCapture.hostTimeToSeconds
        guard elapsed >= 5 else { return nil }
        let measured = Double(rateCheckFrames) / elapsed
        rateCheckFrames = 0
        rateCheckStart = hostTime
        guard abs(measured / format.sampleRate - 1) > 0.1,
              let nearest = SystemAudioCapture.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }),
              abs(nearest / measured - 1) < 0.05 else { rateCandidate = nil; return nil }
        guard rateCandidate == nearest else {
            rateCandidate = nearest
            return nil
        }
        applyRate(nearest, reason: String(format: "measured %.0f frames/s", measured))
        return tapFormat
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
                let current = Set(SystemAudioCapture.allProcessObjects().filter { $0 != me })
                // Compare the sets, not their size: a call app starting its call can swap one
                // audio process for another, and a count-only check then kept a tap without the
                // call's audio (a whole FaceTime call recorded nothing on the system channel).
                let added = current.subtracting(self.tappedProcesses)
                guard !added.isEmpty || current.count != self.tappedProcesses.count else { return }
                let names = added.map { SystemAudioCapture.processName($0) }.joined(separator: ", ")
                AppLog.write("SystemAudioCapture: process list changed (\(self.tappedProcesses.count) → \(current.count)\(names.isEmpty ? "" : ", new: " + names)), rebuilding tap")
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
        rateListener = nil
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

    /// Processes (other than this app) currently playing audio, and those of them the tap does
    /// not cover. Used by the coordinator's stall watchdog: no buffers while something plays
    /// means the tap is broken or blind to that process.
    func playbackState() -> (playing: [AudioObjectID], untapped: [AudioObjectID]) {
        let me = SystemAudioCapture.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
        let playing = SystemAudioCapture.allProcessObjects().filter { $0 != me && SystemAudioCapture.isRunningOutput($0) }
        return (playing, playing.filter { !tappedProcesses.contains($0) })
    }

    static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    /// Bundle id (or pid) of a process object, for the log.
    static func processName(_ process: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        if AudioObjectGetPropertyData(process, &address, 0, nil, &size, &name) == noErr, let id = name?.takeRetainedValue() as String?, !id.isEmpty {
            return id
        }
        address.mSelector = kAudioProcessPropertyPID
        var pid: pid_t = 0
        size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return "pid \(pid)"
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
