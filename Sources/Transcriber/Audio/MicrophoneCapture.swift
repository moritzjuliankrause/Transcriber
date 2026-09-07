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
            try startEngine(deviceUID: deviceUID, echoCancellation: false)
        }
    }

    private func startEngine(deviceUID: String?, echoCancellation: Bool) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, !uid.isEmpty, let device = AudioDevices.device(forUID: uid), let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
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
