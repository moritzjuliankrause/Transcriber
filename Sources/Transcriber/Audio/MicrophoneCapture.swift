import AVFoundation
import CoreAudio

/// Captures the microphone with AVAudioEngine. Optionally enables Apple's voice
/// processing (echo cancellation) so loudspeaker playback of the remote party is
/// removed from the microphone signal – important for speaker attribution when
/// the user is not wearing headphones.
final class MicrophoneCapture {
    typealias Handler = (_ samples16k: [Float], _ hostTime: UInt64) -> Void

    private var engine: AVAudioEngine?
    private let resampler = AudioResampler()
    private let queue = DispatchQueue(label: "transcriber.mic", qos: .userInitiated)
    private let handler: Handler
    private(set) var isRunning = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(deviceUID: String?, echoCancellation: Bool) throws {
        do {
            try startEngine(deviceUID: deviceUID, echoCancellation: echoCancellation)
        } catch where echoCancellation {
            AppLog.write("Voice processing engine failed (\(error)), falling back to plain capture")
            try startPlainWithRetry(deviceUID: deviceUID)
        }
    }

    /// After a failed voice-processing engine the HAL briefly hands the next engine's input
    /// node no device (id 0) with a stale 44.1 kHz stereo format; engine.start then fails with
    /// -10868 (kAudioUnitErr_FormatNotSupported). Retry a few times with a short pause.
    private func startPlainWithRetry(deviceUID: String?, attempts: Int = 3) throws {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                try startEngine(deviceUID: deviceUID, echoCancellation: false)
                return
            } catch {
                lastError = error
                AppLog.write("Plain capture attempt \(attempt) failed: \(error)")
                stop()
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt))
            }
        }
        throw lastError!
    }

    private func startEngine(deviceUID: String?, echoCancellation: Bool) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let unit = input.audioUnit {
            // Bind the device explicitly: the user's pinned device, or – when the HAL has not
            // assigned one yet (id 0, seen right after a voice-processing engine went away) –
            // the current default input. Without this the node keeps a stale format and the
            // engine fails to start with -10868.
            let pinned = (deviceUID?.isEmpty == false) ? AudioDevices.device(forUID: deviceUID!) : nil
            var current = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
            if let target = pinned ?? (current == 0 ? AudioDevices.defaultInputDevice() : nil) {
                var id = target.id
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
        }

        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                AppLog.write("Voice processing unavailable, continuing without echo cancellation: \(error)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Transcriber", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input format."])
        }

        let deviceName: String = {
            guard let unit = input.audioUnit else { return "?" }
            var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
            return AudioDevices.allDevices().first { $0.id == id }?.name ?? "id \(id)"
        }()
        AppLog.write("MicrophoneCapture: device=\(deviceName) format \(format.sampleRate) Hz, \(format.channelCount) ch, interleaved=\(format.isInterleaved), voiceProcessing=\(input.isVoiceProcessingEnabled)")
        // format: nil → the node's own output format; passing an explicit format throws an
        // uncatchable ObjC exception when voice processing changes the format internally.
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, time in
            guard let self else { return }
            self.queue.async {
                let samples = self.resampler.convert(buffer)
                self.handler(samples, time.hostTime)
            }
        }

        if input.isVoiceProcessingEnabled {
            // The voice-processing IO unit only produces audio when its output side is
            // wired up, so route input → mixer (muted) → output.
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        isRunning = true
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        isRunning = false
    }
}
