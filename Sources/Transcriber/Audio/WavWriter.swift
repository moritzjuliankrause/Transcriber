import Foundation

/// Crash-safe incremental WAV writer (16 kHz, mono, 16-bit PCM).
/// The RIFF header is re-written and the file is fsync'ed on every flush so an
/// unclean shutdown still leaves a readable file up to the last flush.
final class WavWriter {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: UInt32
    private var dataBytes: UInt32 = 0
    private var pendingSinceFlush = 0
    private let flushEverySamples: Int
    private let lock = NSLock()

    init(url: URL, sampleRate: Int = 16_000, flushIntervalSeconds: Double = 2) throws {
        self.url = url
        self.sampleRate = UInt32(sampleRate)
        self.flushEverySamples = Int(Double(sampleRate) * flushIntervalSeconds)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: WavWriter.header(dataBytes: 0, sampleRate: self.sampleRate))
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); defer { lock.unlock() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            dataBytes += UInt32(data.count)
            pendingSinceFlush += samples.count
            if pendingSinceFlush >= flushEverySamples {
                try flushLocked()
            }
        } catch {
            NSLog("WavWriter append failed: \(error)")
        }
    }

    var durationSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(dataBytes / 2) / Double(sampleRate)
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        try? flushLocked()
    }

    private func flushLocked() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavWriter.header(dataBytes: dataBytes, sampleRate: sampleRate))
        try handle.synchronize()
        pendingSinceFlush = 0
    }

    func close() {
        flush()
        try? handle.close()
    }

    static func header(dataBytes: UInt32, sampleRate: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16)
        u16(1)                 // PCM
        u16(1)                 // mono
        u32(sampleRate)
        u32(sampleRate * 2)    // byte rate
        u16(2)                 // block align
        u16(16)                // bits per sample
        d.append("data".data(using: .ascii)!)
        u32(dataBytes)
        return d
    }

    /// Reads a 16 kHz mono 16-bit WAV written by this class back into floats.
    static func readSamples(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return [] }
        let body = data.subdata(in: 44..<data.count)
        let count = body.count / 2
        var out = [Float](repeating: 0, count: count)
        body.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: p[i])) / 32768 }
        }
        return out
    }
}
