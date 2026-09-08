import Foundation
import Shared

/// "Bundled tiny model" strategy (T3). 100 MB+ blobs cannot live in git, so the bundled model is
/// the smallest TDT-capable Parakeet (TDT-CTC 110M, ~110 MB) fetched *first* at first launch;
/// until it lands, `AppleSpeechRecognizer` (on-device) handles dictation. The full TDT v3 and the
/// EOU preview model download in the background and are picked up on the next `start()`.
public enum BundledModel {
    public static let id: ModelID = .parakeetTDTCTC110m

    /// Final-pass models, **best first**. This is the one ranking of transcription quality in the
    /// engine: `RecognizerFactory.chooseFinal` and `ModelManager.bestFinalModelOnDisk` both pick the
    /// first entry that is on disk, and `ModelManagerTiers.readiness` mirrors it in the UI.
    public static let finalModelsByQuality: [ModelID] = [.parakeetTDTv3, .parakeetTDTCTC110m]

    /// What to fetch at first launch, given the best final model already on disk — best first, and
    /// never the tiny model when something better is already there.
    ///
    /// The old value was a *constant* headed by the 110M tiny model, so the background loop fetched
    /// 110 MB the user had no use for and left the 0.6B v3 for last, behind the 400 MB EOU download:
    /// a user with v3 already on disk stayed on the weakest model for the whole of that queue, and one
    /// with nothing on disk waited for EOU before the good final model even started. Ordering is a
    /// function of what is installed, so it can say "already better than that, skip it".
    ///
    /// The fallback path is untouched: with nothing on disk, `.parakeetTDTCTC110m` is still first and
    /// still what `bootstrap` awaits, because 110 MB is what makes dictation work in seconds rather
    /// than minutes.
    public static func firstLaunchOrder(bestFinalOnDisk: ModelID?) -> [ModelID] {
        switch bestFinalOnDisk {
        case .parakeetTDTv3:                    // the best final model is here; only the preview is missing
            return [.parakeetEOU160]
        case .some:                             // something usable is here: upgrade it, don't re-fetch tiny
            return [.parakeetTDTv3, .parakeetEOU160]
        case nil:                               // cold start: smallest-usable first, then best, then preview
            return [.parakeetTDTCTC110m, .parakeetTDTv3, .parakeetEOU160]
        }
    }

    /// Await the tiny model, then fetch the rest in a detached background task.
    /// Returns as soon as the tiny model is present (or immediately if anything final is on disk).
    public static func bootstrap(manager: ModelManager, progress: ModelProgressHandler? = nil) async throws {
        if await manager.bestFinalModelOnDisk() == nil {
            try await manager.ensureAvailable(id, progress: progress)
        }
        let best = await manager.bestFinalModelOnDisk()
        Task.detached(priority: .utility) {
            for m in firstLaunchOrder(bestFinalOnDisk: best) where await !manager.isPresent(m) {
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

    /// Best final model on disk, else Apple Speech. Walks `BundledModel.finalModelsByQuality` so this
    /// and the download order can never disagree about which model is better.
    public static func chooseFinal(manager: ModelManager, appleSpeechAvailable: Bool = AppleSpeechRecognizer.isAvailable()) async -> Choice? {
        for id in BundledModel.finalModelsByQuality where await manager.isPresent(id) {
            switch id {
            case .parakeetTDTv3: return .tdtV3
            case .parakeetTDTCTC110m: return .tiny
            default: continue
            }
        }
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
