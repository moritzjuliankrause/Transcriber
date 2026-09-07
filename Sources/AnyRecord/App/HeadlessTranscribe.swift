import Foundation
import FluidAudio

/// `AnyRecord --transcribe <audio-file> [--language de] [--out <folder>]`
/// Runs the same VAD → ASR → SessionStore pipeline as a live recording, without
/// UI. Useful for re-transcribing kept audio and for testing the pipeline.
enum HeadlessTranscribe {
    static func run(arguments: [String]) async -> Int32 {
        guard let idx = arguments.firstIndex(of: "--transcribe"), idx + 1 < arguments.count else {
            print("usage: AnyRecord --transcribe <audio-file> [--language de] [--out <folder>] [--diarize]")
            return 2
        }
        let input = URL(fileURLWithPath: arguments[idx + 1])
        var language: String?
        if let li = arguments.firstIndex(of: "--language"), li + 1 < arguments.count { language = arguments[li + 1] }
        var outRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AnyRecordHeadless", isDirectory: true)
        if let oi = arguments.firstIndex(of: "--out"), oi + 1 < arguments.count { outRoot = URL(fileURLWithPath: arguments[oi + 1], isDirectory: true) }
        let diarize = arguments.contains("--diarize")

        do {
            try FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
            let t0 = Date()
            print("Loading models…")
            let engine = FluidAudioEngine(precision: .int8)
            try await engine.prepare()
            let vad = try await VadManagerFactory.make(threshold: 0.6)
            print("Models ready in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

            var samples = try AudioConverter().resampleAudioFile(input)
            print("Audio: \(String(format: "%.1f", Double(samples.count) / 16_000)) s")

            // `--reference system.wav`: treat the input as microphone and gate echo against the reference.
            if let ri = arguments.firstIndex(of: "--reference"), ri + 1 < arguments.count {
                let reference = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: arguments[ri + 1]))
                let gate = EchoGate()
                var gated: [Float] = []
                gated.reserveCapacity(samples.count)
                var offset = 0
                while offset < samples.count {
                    let end = min(samples.count, offset + 1_600)
                    let t = Double(offset) / 16_000
                    if offset < reference.count {
                        gate.pushSystem(Array(reference[offset..<min(reference.count, end)]), at: t)
                    }
                    gated.append(contentsOf: gate.processMic(Array(samples[offset..<end]), at: t))
                    offset = end
                }
                print("EchoGate: \(gate.stats)")
                samples = gated
                let gatedURL = input.deletingLastPathComponent().appendingPathComponent("mic_gated.wav")
                let w = try WavWriter(url: gatedURL); w.append(samples); w.close()
                print("Gated audio written to \(gatedURL.path)")
            }

            let store = try SessionStore(root: outRoot, myName: "Me", otherName: "Speaker", language: language ?? "")
            let queue = TranscriptionQueue(engine: engine, language: language) { segment, result in
                let entry = TranscriptEntry(channel: .them, speaker: "Speaker", start: segment.start, end: segment.end,
                                            text: result.text, confidence: result.confidence, createdAt: Date(),
                                            words: result.words.map { WordStamp(word: $0.word, start: segment.start + $0.startTime, end: segment.start + $0.endTime) })
                store.append(entry)
                print(String(format: "[%6.2f – %6.2f] %@", segment.start, segment.end, result.text))
            } onPartial: { segment, result in
                print(String(format: "  … partial [%6.2f – %6.2f] %@", segment.start, segment.end, result.text))
            }
            let processor = await ChannelProcessor(channel: .them, vad: vad, threshold: 0.6,
                                                   onSegment: { await queue.submit($0) },
                                                   onPartial: { await queue.submit($0) })

            // Feed in 100 ms slices like the live capture would (`--realtime` paces them).
            let realtime = arguments.contains("--realtime")
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + 1_600)
                await processor.append(Array(samples[offset..<end]))
                offset = end
                if realtime { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            await processor.finish()
            await queue.drain()

            if diarize {
                // Copy the source next to the transcript so the finalizer can diarize it.
                let wav = try WavWriter(url: store.systemWavURL)
                wav.append(samples)
                wav.close()
                store.registerAudioFiles(mic: false, system: true)
                let spans = try await RemoteDiarizer.diarize(wavURL: store.systemWavURL, maxSpeakers: 4) { _ in }
                let speakers = Set(spans.map(\.speaker))
                print("Diarization: \(speakers.count) speaker(s)")
                let names = Dictionary(uniqueKeysWithValues: speakers.sorted().enumerated().map { ($1, "Speaker \($0 + 1)") })
                store.replaceEntries(RemoteDiarizer.relabel(store.entries, spans: spans, names: names))
                for e in store.entries { print(String(format: "  %@ [%6.2f – %6.2f] %@", e.speaker, e.start, e.end, e.text)) }
            }

            store.exportExtras(json: true, srt: true)
            store.markComplete()
            store.close()
            print("Done in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s → \(store.directory.path)")
            return 0
        } catch {
            print("Error: \(error)")
            return 1
        }
    }
}
