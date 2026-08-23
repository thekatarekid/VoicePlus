import Foundation
import Shared

/// "Bundled tiny model" strategy (T3). 100 MB+ blobs cannot live in git, so the bundled model is
/// the smallest TDT-capable Parakeet (TDT-CTC 110M, ~110 MB) fetched *first* at first launch;
/// until it lands, `AppleSpeechRecognizer` (on-device) handles dictation. The full TDT v3 and the
/// EOU preview model download in the background and are picked up on the next `start()`.
public enum BundledModel {
    public static let id: ModelID = .parakeetTDTCTC110m
    /// Order in which onboarding fetches models: smallest-usable first.
    public static let firstLaunchOrder: [ModelID] = [.parakeetTDTCTC110m, .parakeetEOU160, .parakeetTDTv3]

    /// Await the tiny model, then fetch the rest in a detached background task.
    /// Returns as soon as the tiny model is present (or immediately if anything final is on disk).
    public static func bootstrap(manager: ModelManager, progress: ModelProgressHandler? = nil) async throws {
        if await manager.bestFinalModelOnDisk() == nil {
            try await manager.ensureAvailable(id, progress: progress)
        }
        Task.detached(priority: .utility) {
            for m in firstLaunchOrder where await !manager.isPresent(m) {
                do { try await manager.ensureAvailable(m, progress: progress) } catch {
                    Log.engine.warning("background model download failed for \(m.rawValue): \(error)")
                }
            }
        }
    }
}

/// Picks the best recognizers for what is on disk right now.
public enum RecognizerFactory {
    public enum Choice: Equatable, Sendable { case tdtV3, tiny, appleSpeech }

    public static func chooseFinal(manager: ModelManager, appleSpeechAvailable: Bool = AppleSpeechRecognizer.isAvailable()) async -> Choice? {
        if await manager.isPresent(.parakeetTDTv3) { return .tdtV3 }
        if await manager.isPresent(.parakeetTDTCTC110m) { return .tiny }
        return appleSpeechAvailable ? .appleSpeech : nil
    }

    /// Loads (if needed) and wraps the chosen final model. Throws `EngineError.modelUnavailable` if none.
    public static func makeFinal(manager: ModelManager) async throws -> FinalRecognizer {
        switch await chooseFinal(manager: manager) {
        case .tdtV3?:
            guard let models = try await manager.load(.parakeetTDTv3).asrModels else { throw EngineError.modelUnavailable("tdt-v3") }
            return DecoderFinalRecognizer(decoder: try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.v3"))
        case .tiny?:
            guard let models = try await manager.load(.parakeetTDTCTC110m).asrModels else { throw EngineError.modelUnavailable("tdt-ctc-110m") }
            return DecoderFinalRecognizer(decoder: try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.ctc110m"))
        case .appleSpeech?:
            guard let r = AppleSpeechRecognizer() else { throw EngineError.modelUnavailable("apple-speech") }
            return r
        case nil:
            throw EngineError.modelUnavailable("no ASR model on disk and Apple Speech unavailable")
        }
    }

    /// EOU streaming preview if present; otherwise poll the final recognizer; nil if no preview possible.
    public static func makePreview(manager: ModelManager, final: FinalRecognizer) async -> PreviewRecognizer? {
        if await manager.isPresent(.parakeetEOU160), let eou = try? await manager.load(.parakeetEOU160).eouManager {
            return EOUPreviewRecognizer(manager: eou)
        }
        return final is AppleSpeechRecognizer ? nil : PollingPreviewRecognizer(recognizer: final)
    }
}
