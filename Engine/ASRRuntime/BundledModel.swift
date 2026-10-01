import Foundation
import Shared

/// First-launch model strategy. The **full installer** (`make_app.sh` with `FULL_INSTALLER=1` +
/// `BUNDLE_MODELS_FROM`, staged by `Packaging/bundle_models.py`) ships the default stack inside
/// `Contents/Resources/Models`: Parakeet TDT v3 (final pass), the realtime EOU 160 ms preview model and
/// the speaker-diarization models. `BundledModelResources` exposes those as read-only candidates, so a
/// full-installer user downloads nothing to dictate. Only when **no** final model is on disk (a
/// model-free build, or the bundle was removed) is the tiny TDT-CTC 110M (~110 MB) fetched *first*,
/// with `AppleSpeechRecognizer` (on-device) covering dictation until it lands; TDT v3 and EOU then
/// follow in the background and are picked up on the next `start()` (see `firstLaunchOrder`).
public enum BundledModel {
    public static let id: ModelID = .parakeetTDTCTC110m

    /// Final-pass models, **best first**. This is the one ranking of transcription quality in the
    /// engine: `RecognizerFactory.chooseFinal` and `ModelManager.bestFinalModelOnDisk` both pick the
    /// first entry that is on disk, and `ModelManagerTiers.readiness` mirrors it in the UI.
    ///
    /// V5 B5: Parakeet Ultra and Redux are drop-in v3 replacements fetched only on request
    /// (`ModelRole.onDemand`), so they rank only for a user who has one on disk. The order between
    /// them and v3 is the V1 result (`v1Ranking`); a model this OS cannot load (Redux before macOS 15)
    /// is left out rather than failing at load time.
    public static let finalModelsByQuality: [ModelID] = v1Ranking.filter(ModelCatalog.isSupportedOnThisOS)

    /// The V1 ranking of every final model, best first, before the OS filter.
    ///
    /// **Provisional (V5 B5, T1):** the deciding V1 run (LibriSpeech-other + MUSAN 10 dB +
    /// FLEURS-en-IN) has not been made — Ultra is 0.63 GB and those sets are not on this machine.
    /// Until it is: Ultra first on the vendor's published WER (beats v3 on English 6.26→5.80, noise
    /// 6.72→5.82, FLEURS 11.62→9.55; not measured here). Redux was measured against v3 on
    /// `librispeech-test-clean-noisy` (450 items, `Lab/results/2026-10-01-…-parakeet-redux.json`):
    /// WER 8.06 vs 12.67 overall — better under babble (13.3 vs 25.0) and at 0–10 dB, but worse
    /// clean (2.12 vs 1.65) and under pink noise (4.33 vs 3.07), and its 2-bit encoder failed the
    /// ANE compile on this Mac (CPU/GPU fallback, p50 199 vs 117 ms). Mixed on one set and slower, so
    /// it stays below v3 until the full V1 run decides. Re-order here, and only here, when V1 says
    /// otherwise; `ModelLayoutTests` pins the order.
    public static let v1Ranking: [ModelID] = [.parakeetUltra, .parakeetTDTv3, .parakeetRedux, .parakeetTDTCTC110m]

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
        case .parakeetTDTv3, .parakeetUltra, .parakeetRedux:
            // A full-size final model is here (v3, or an optional one the user chose — B5); only the
            // preview is missing. Redux is never "upgraded" behind the user's back: it was picked to
            // save memory.
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
    public enum Choice: Equatable, Sendable { case ultra, tdtV3, redux, tiny, appleSpeech }

    /// Best final model on disk, else Apple Speech. Walks `BundledModel.finalModelsByQuality` so this
    /// and the download order can never disagree about which model is better.
    public static func chooseFinal(manager: ModelManager, appleSpeechAvailable: Bool = AppleSpeechRecognizer.isAvailable()) async -> Choice? {
        for id in BundledModel.finalModelsByQuality where await manager.isPresent(id) {
            switch id {
            case .parakeetUltra: return .ultra
            case .parakeetTDTv3: return .tdtV3
            case .parakeetRedux: return .redux
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
        case .ultra?:
            guard let models = try await manager.load(.parakeetUltra).asrModels else { throw EngineError.modelUnavailable("tdt-ultra") }
            return DecoderFinalRecognizer(decoder: try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.ultra"))
        case .redux?:
            guard let models = try await manager.load(.parakeetRedux).asrModels else { throw EngineError.modelUnavailable("tdt-redux") }
            return DecoderFinalRecognizer(decoder: try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.redux"))
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

    /// The preview recognizer for `backend`, wrapped in R1.5's light preview formatting.
    ///
    /// `.eouStreaming120m` (the measured default) needs the EOU model on disk and falls back to
    /// polling the final model when it is missing — a first launch where only the tiny final model
    /// has landed still gets a preview. Apple Speech has no usable polling preview, so that returns
    /// `nil` and the pill simply shows no words until the final text arrives.
    public static func makePreview(manager: ModelManager, final: FinalRecognizer,
                                   backend: PreviewBackend = .measuredDefault,
                                   formatted: Bool = true) async -> PreviewRecognizer? {
        func wrap(_ preview: PreviewRecognizer?) -> PreviewRecognizer? {
            guard let preview else { return nil }
            return formatted ? FormattedPreviewRecognizer(preview) : preview
        }
        // V5 C5: 320 ms when on disk, else the 160 ms an existing install already has.
        if backend == .eouStreaming120m, let eouID = await PreviewEOUTier.resolve(in: manager),
           let eou = try? await manager.load(eouID).eouManager {
            return wrap(EOUPreviewRecognizer(manager: eou))
        }
        return wrap(final is AppleSpeechRecognizer ? nil : PollingPreviewRecognizer(recognizer: final))
    }
}
