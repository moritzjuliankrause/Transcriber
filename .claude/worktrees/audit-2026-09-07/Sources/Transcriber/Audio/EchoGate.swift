import Foundation

/// Suppresses loudspeaker echo in the microphone channel using the system audio
/// channel as reference. Works on 20 ms frames at 16 kHz, aligned by wall-clock
/// time (both captures report host time):
///
/// 1. Estimates the acoustic delay (system playback → mic) by correlating the
///    log-energy envelopes of both channels over the last few seconds.
/// 2. Estimates the echo gain as a low percentile of mic/system energy ratios
///    while the system channel is active (echo-only frames sit at that ratio,
///    double-talk frames are louder).
/// 3. Mutes a mic frame when the system channel is active, the envelopes
///    actually correlate, and the mic energy is not clearly above the expected
///    echo level – i.e. nobody at the mic is talking over it.
///
/// Fails open: without a confident estimate nothing is muted.
final class EchoGate {
    static let sampleRate = 16_000
    static let frameSize = 320                    // 20 ms
    static let frameDuration = 0.02

    private let lock = NSLock()
    private var systemEnergy: [Int: Float] = [:]  // frame index (by time) → RMS
    private var micEnergy: [Int: Float] = [:]
    private var micCarry: [Float] = []
    private var micCarryStart: Double = 0
    private var systemCarry: [Float] = []
    private var systemCarryStart: Double = 0
    private var latestMicFrame = 0
    private var lastEstimateFrame = 0

    private(set) var delayFrames = 0
    private(set) var echoGain: Float = 0          // 0 = no estimate yet
    private(set) var correlation: Float = 0
    private let noiseFloor: Float = 0.002
    private var systemFloor: Float = 0.002        // adaptive noise floor of the reference
    /// Mic must exceed the expected echo by this factor (~+8 dB) to count as near-end speech.
    private let margin: Float = 2.5
    private var hangover = 0

    private(set) var mutedFrames = 0
    private(set) var totalFrames = 0

    // MARK: - Reference

    /// `time` = session-relative seconds of the first sample.
    func pushSystem(_ samples: [Float], at time: Double) {
        lock.lock(); defer { lock.unlock() }
        if systemCarry.isEmpty { systemCarryStart = time }
        systemCarry.append(contentsOf: samples)
        var index = Int((systemCarryStart / EchoGate.frameDuration).rounded())
        while systemCarry.count >= EchoGate.frameSize {
            let frame = systemCarry.prefix(EchoGate.frameSize)
            systemCarry.removeFirst(EchoGate.frameSize)
            systemEnergy[index] = EchoGate.rms(frame)
            index += 1
            systemCarryStart += EchoGate.frameDuration
        }
        if systemCarry.isEmpty { systemCarryStart = 0 }
        trim()
    }

    // MARK: - Microphone

    /// Returns the mic samples with echo-only frames zeroed.
    func processMic(_ samples: [Float], at time: Double) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        if micCarry.isEmpty { micCarryStart = time }
        micCarry.append(contentsOf: samples)
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        var index = Int((micCarryStart / EchoGate.frameDuration).rounded())
        while micCarry.count >= EchoGate.frameSize {
            var frame = Array(micCarry.prefix(EchoGate.frameSize))
            micCarry.removeFirst(EchoGate.frameSize)
            let energy = EchoGate.rms(frame[...])
            micEnergy[index] = energy
            latestMicFrame = index
            totalFrames += 1
            if index - lastEstimateFrame >= 50 {  // re-estimate every second
                lastEstimateFrame = index
                estimate()
            }
            if shouldMute(micFrame: index, energy: energy) {
                frame = [Float](repeating: 0, count: frame.count)
                mutedFrames += 1
            }
            out.append(contentsOf: frame)
            index += 1
            micCarryStart += EchoGate.frameDuration
        }
        if micCarry.isEmpty { micCarryStart = 0 }
        trim()
        return out
    }

    private func shouldMute(micFrame index: Int, energy: Float) -> Bool {
        guard echoGain > 0, correlation > 0.5 else { return false }
        let refIndex = index - delayFrames
        var ref: Float = 0
        for i in (refIndex - 2)...(refIndex + 1) {
            ref = max(ref, systemEnergy[i] ?? 0)
        }
        let activeFloor = max(noiseFloor * 2, systemFloor * 4)
        guard ref > activeFloor else {
            hangover = max(0, hangover - 1)
            return hangover > 0 && energy < noiseFloor * 3
        }
        let expectedEcho = echoGain * ref
        if energy > expectedEcho * margin && energy > noiseFloor * 2 {
            hangover = 0
            return false                          // near-end speech on top of the echo
        }
        hangover = 5
        return true
    }

    // MARK: - Estimation

    private func estimate() {
        let window = 250                          // last 5 s
        let end = latestMicFrame
        let start = end - window
        var m: [Float] = [], s: [Float] = []
        var sysRaw: [Float] = [], micRaw: [Float] = []
        for i in start...end {
            guard let a = micEnergy[i], let b = systemEnergy[i] else { continue }
            micRaw.append(a); sysRaw.append(b)
        }
        guard micRaw.count > 100 else { return }
        // Adaptive reference noise floor: 10th percentile of recent reference energy.
        let sortedSys = sysRaw.sorted()
        systemFloor = max(0.0005, sortedSys[sortedSys.count / 10])
        let activeFloor = max(noiseFloor * 2, systemFloor * 4)
        guard sysRaw.filter({ $0 > activeFloor }).count > 25 else { return }

        // Delay: best normalized cross-correlation of log envelopes, lags −0.5…+0.8 s.
        // (Negative lags absorb timestamp offsets between the two capture paths.)
        func logs(_ dict: [Int: Float]) -> [Int: Float] { dict }
        var bestLag = delayFrames
        var bestCorr: Float = -1
        for lag in -25...40 {
            var sm: Float = 0, ss: Float = 0, smm: Float = 0, sss: Float = 0, sms: Float = 0, k: Float = 0
            for i in start...end {
                guard let a0 = micEnergy[i], let b0 = systemEnergy[i - lag] else { continue }
                let a = log(a0 + 1e-4), b = log(b0 + 1e-4)
                sm += a; ss += b; smm += a * a; sss += b * b; sms += a * b; k += 1
            }
            guard k > 50 else { continue }
            let cov = sms / k - (sm / k) * (ss / k)
            let va = smm / k - (sm / k) * (sm / k)
            let vb = sss / k - (ss / k) * (ss / k)
            let corr = cov / (sqrt(max(va, 1e-6)) * sqrt(max(vb, 1e-6)))
            if corr > bestCorr { bestCorr = corr; bestLag = lag }
        }
        correlation = correlation == 0 ? bestCorr : (0.5 * correlation + 0.5 * bestCorr)
        if bestCorr > 0.4 { delayFrames = bestLag }
        _ = m; _ = s

        // Gain: 20th percentile of mic/system energy ratio while the reference is active.
        var ratios: [Float] = []
        for i in start...end {
            guard let mic = micEnergy[i], let sys = systemEnergy[i - delayFrames], sys > activeFloor else { continue }
            ratios.append(mic / sys)
        }
        guard ratios.count > 15 else { return }
        ratios.sort()
        let p20 = min(ratios[ratios.count / 5], 3.0)   // clamp: echo is never wildly louder than the reference
        echoGain = echoGain == 0 ? p20 : (0.7 * echoGain + 0.3 * p20)
    }

    private func trim() {
        let keep = latestMicFrame - 2_500          // 50 s
        if micEnergy.count > 3_500 {
            micEnergy = micEnergy.filter { $0.key > keep }
            systemEnergy = systemEnergy.filter { $0.key > keep }
        }
    }

    private static func rms(_ frame: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(max(1, frame.count))).squareRoot()
    }

    var stats: String {
        lock.lock(); defer { lock.unlock() }
        return "delay=\(delayFrames * 20) ms gain=\(String(format: "%.3f", echoGain)) corr=\(String(format: "%.2f", correlation)) sysFloor=\(String(format: "%.4f", systemFloor)) muted=\(mutedFrames)/\(totalFrames) frames"
    }
}
