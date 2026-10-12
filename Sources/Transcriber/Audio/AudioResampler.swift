import AVFoundation

/// Converts arbitrary PCM buffers into 16 kHz mono Float32 samples (what the
/// ASR / VAD / diarization models expect). Keeps one AVAudioConverter alive so
/// streaming conversion stays continuous.
final class AudioResampler {
    static let targetRate: Double = 16_000
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioResampler.targetRate, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ input: AVAudioPCMBuffer) -> [Float] {
        // AVAudioConverter's implicit N→1 channel mapping is unreliable (a 3-channel
        // MacBook mic came out as pure silence), so downmix to mono ourselves first.
        let buffer = input.format.channelCount > 1 ? AudioResampler.downmixToMono(input) ?? input : input
        if sourceFormat != buffer.format || converter == nil {
            sourceFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return [] }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    /// Averages all channels of a Float32 buffer (interleaved or not) into a mono buffer.
    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 1, frames > 0, buffer.format.commonFormat == .pcmFormatFloat32,
              let src = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = mono.floatChannelData else { return nil }
        // Per-channel energy. Some inputs (a voice-processing aggregate, a multi-channel USB
        // interface) carry the voice on ONE channel and leave the rest near silent; averaging
        // then attenuates real speech by 1/channels and can push it below the noise floor. When
        // one channel clearly dominates, use it alone; otherwise average as before.
        func sampleAt(_ c: Int, _ i: Int) -> Float {
            buffer.format.isInterleaved ? src[0][i * channels + c] : src[c][i]
        }
        var energy = [Float](repeating: 0, count: channels)
        for c in 0..<channels {
            var e: Float = 0
            for i in 0..<frames { let v = sampleAt(c, i); e += v * v }
            energy[c] = e
        }
        let loudest = energy.indices.max(by: { energy[$0] < energy[$1] }) ?? 0
        let others = energy.enumerated().reduce(Float(0)) { $1.offset == loudest ? $0 : $0 + $1.element }
        let dominant = energy[loudest] > 0 && energy[loudest] >= 8 * others

        if dominant {
            for i in 0..<frames { dst[0][i] = sampleAt(loudest, i) }
        } else {
            let scale = 1 / Float(channels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += sampleAt(c, i) }
                dst[0][i] = sum * scale
            }
        }
        mono.frameLength = AVAudioFrameCount(frames)
        return mono
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Loudest 20 ms RMS in the buffer. Comparable across channels whatever their buffer size
    /// (the mic delivers ~100 ms at once, the system tap ~10 ms; a plain RMS over a long buffer
    /// averages speech down into its pauses).
    static func peakRMS(_ samples: [Float], frame: Int = 320) -> Float {
        guard samples.count > frame else { return rms(samples) }
        var peak: Float = 0
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + frame)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            peak = max(peak, (sum / Float(end - i)).squareRoot())
            i = end
        }
        return peak
    }

    /// Maps RMS to a 0...1 display level with a soft log curve.
    static func displayLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)          // roughly -60...0
        return min(1, max(0, (db + 55) / 55))
    }
}
