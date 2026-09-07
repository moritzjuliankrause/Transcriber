import Foundation
import FluidAudio
import CoreML

/// Tracks download / availability of the local models (Parakeet ASR, Silero VAD,
/// pyannote diarization) and exposes progress for the settings UI.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Status: Equatable {
        case unknown
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    @Published var asrStatus: Status = .unknown
    @Published var diarizerStatus: Status = .unknown
    @Published var vadStatus: Status = .unknown

    private init() {}

    var precision: ParakeetEncoderPrecision {
        AppSettings.shared.encoderPrecision == "int4" ? .int4 : .int8
    }

    var asrDirectory: URL { AsrModels.defaultCacheDirectory(for: .v3) }
    var modelsRootDirectory: URL { OfflineDiarizerModels.defaultModelsDirectory() }

    func refreshStatus() async {
        let dir = asrDirectory
        let precision = precision
        let exists = AsrModels.modelsExist(at: dir, version: .v3, encoderPrecision: precision)
        if case .downloading = asrStatus {} else {
            asrStatus = exists ? .ready : .notDownloaded
        }
        // VAD / diarizer download lazily on first use; report what the cache holds.
        let root = modelsRootDirectory
        let vadExists = FileManager.default.fileExists(atPath: root.appendingPathComponent(Repo.vad.folderName).path)
        let diarizerExists = FileManager.default.fileExists(atPath: root.appendingPathComponent(Repo.diarizer.folderName).path)
        if case .downloading = vadStatus {} else { vadStatus = vadExists ? .ready : .notDownloaded }
        if case .downloading = diarizerStatus {} else { diarizerStatus = diarizerExists ? .ready : .notDownloaded }
    }

    /// Downloads (if needed) every model the app uses. Safe to call repeatedly.
    func downloadAll() async {
        await downloadASR()
        await downloadVAD()
        await downloadDiarizer()
    }

    func downloadASR() async {
        asrStatus = .downloading(0)
        let precision = precision
        do {
            _ = try await AsrModels.download(version: .v3, encoderPrecision: precision) { [weak self] progress in
                Task { @MainActor in self?.asrStatus = .downloading(progress.fractionCompleted) }
            }
            asrStatus = .ready
        } catch {
            asrStatus = .failed(error.localizedDescription)
        }
    }

    func downloadVAD() async {
        vadStatus = .downloading(0)
        do {
            _ = try await VadManager(config: VadConfig()) { [weak self] progress in
                Task { @MainActor in self?.vadStatus = .downloading(progress.fractionCompleted) }
            }
            vadStatus = .ready
        } catch {
            vadStatus = .failed(error.localizedDescription)
        }
    }

    func downloadDiarizer() async {
        diarizerStatus = .downloading(0)
        do {
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels()
            diarizerStatus = .ready
        } catch {
            diarizerStatus = .failed(error.localizedDescription)
        }
    }

    func deleteAllModels() {
        ModelHub.clearAllCaches()
        try? FileManager.default.removeItem(at: modelsRootDirectory)
        asrStatus = .notDownloaded
        vadStatus = .notDownloaded
        diarizerStatus = .notDownloaded
    }

    func modelsDiskUsage() -> Int64 {
        guard let e = FileManager.default.enumerator(at: modelsRootDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
