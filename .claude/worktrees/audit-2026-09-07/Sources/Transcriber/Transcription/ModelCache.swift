import Foundation
import FluidAudio

/// Keeps the loaded ASR engine and VAD in memory across recordings and preloads them
/// at app launch, so pressing "record" does not wait for CoreML to instantiate the
/// Parakeet models again (several seconds). Loads are deduplicated: concurrent callers
/// share one in-flight task. The cache is dropped when the precision changes or the
/// models are deleted.
@MainActor
final class ModelCache {
    static let shared = ModelCache()

    private var engineTask: Task<FluidAudioEngine, Error>?
    private var enginePrecision: ParakeetEncoderPrecision?
    private var vadTask: Task<VadManager, Error>?
    private var vadThreshold: Float?

    private init() {}

    /// The loaded engine for `precision`, loading it if needed.
    func engine(precision: ParakeetEncoderPrecision) async throws -> FluidAudioEngine {
        if enginePrecision != precision { engineTask?.cancel(); engineTask = nil }
        if let engineTask { return try await engineTask.value }
        enginePrecision = precision
        let task = Task<FluidAudioEngine, Error> {
            let t0 = Date()
            let engine = FluidAudioEngine(precision: precision)
            try await engine.prepare()
            // One dummy pass so the Neural Engine is warm for the first real segment.
            _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), language: nil)
            AppLog.write(String(format: "ASR engine loaded (%@) in %.2fs", precision == .int4 ? "int4" : "int8", Date().timeIntervalSince(t0)))
            return engine
        }
        engineTask = task
        do {
            return try await task.value
        } catch {
            if engineTask == task { engineTask = nil }
            throw error
        }
    }

    /// The loaded VAD for `threshold`, loading it if needed.
    func vad(threshold: Float) async throws -> VadManager {
        if vadThreshold != threshold { vadTask?.cancel(); vadTask = nil }
        if let vadTask { return try await vadTask.value }
        vadThreshold = threshold
        let task = Task<VadManager, Error> {
            let t0 = Date()
            let vad = try await VadManagerFactory.make(threshold: threshold)
            AppLog.write(String(format: "VAD loaded in %.2fs", Date().timeIntervalSince(t0)))
            return vad
        }
        vadTask = task
        do {
            return try await task.value
        } catch {
            if vadTask == task { vadTask = nil }
            throw error
        }
    }

    /// Loads everything in the background if the models are already on disk.
    /// Never triggers a download – that stays an explicit action (first recording / settings).
    func preload(settings: AppSettings) async {
        let manager = ModelManager.shared
        await manager.refreshStatus()
        guard manager.asrStatus.isReady else { return }
        async let engine: Void = { _ = try? await self.engine(precision: manager.precision) }()
        async let vad: Void = { _ = try? await self.vad(threshold: Float(settings.vadThreshold)) }()
        _ = await (engine, vad)
    }

    /// Forgets the loaded models (precision change, models deleted).
    func invalidate() {
        engineTask?.cancel(); engineTask = nil; enginePrecision = nil
        vadTask?.cancel(); vadTask = nil; vadThreshold = nil
    }
}
