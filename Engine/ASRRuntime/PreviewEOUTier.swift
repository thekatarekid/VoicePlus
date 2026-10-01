import FluidAudio
import Foundation

/// V5 C5 — which Parakeet realtime EOU variant drives the live preview.
///
/// FluidAudio ships the 120M EOU model at 160 ms and 320 ms chunk sizes (and 1280 ms). Upstream
/// measures 320 ms at ~5.7 % WER on LibriSpeech test-clean against ~8.3 % for 160 ms, at 14× the
/// throughput, for 160 ms more latency between preview updates — the preview is a hint, so the
/// accuracy is worth more than the cadence. The tier moves to 320 ms:
///
/// * The loader runs a model at its own chunk size (`chunkSize(for:)`).
/// * The preview uses 320 ms when it is on disk, and **keeps 160 ms when only that is present**
///   (the migration rule: an install that already has 160 ms is never forced to download again).
/// * Only one of the two is ever warmed or loaded.
///
/// What is *not* switched yet: the first-run stack (`ModelStack.models`) and the app bundle still
/// install 160 ms. Moving them is the V1 preview-WER gate's decision (§W2 public sets, measured with
/// both variants on disk) — flip `stackVariant` and `Packaging/bundle_models.py` together then.
public enum PreviewEOUTier {
    /// The preferred variant, best first.
    public static let preference: [ModelID] = [.parakeetEOU320, .parakeetEOU160]
    /// The variant the first-run stack installs (unchanged until the V1 gate).
    public static let stackVariant: ModelID = .parakeetEOU160

    public static var all: Set<ModelID> { Set(preference) }

    /// The EOU model the preview should load: 320 ms if present, else 160 ms if present, else nil.
    public static func resolve(isPresent: (ModelID) -> Bool) -> ModelID? {
        preference.first(where: isPresent)
    }

    public static func resolve(in manager: ModelManager) async -> ModelID? {
        for id in preference where await manager.isPresent(id) { return id }
        return nil
    }

    /// FluidAudio's streaming chunk size for an EOU model id.
    public static func chunkSize(for id: ModelID) -> StreamingChunkSize {
        id == .parakeetEOU320 ? .ms320 : .ms160
    }

    /// `preferred` with every EOU variant except the one `resolve` picks removed (warm one, not two).
    public static func dedupe(_ preferred: [ModelID], isPresent: (ModelID) -> Bool) -> [ModelID] {
        guard preferred.contains(where: all.contains) else { return preferred }
        let chosen = resolve(isPresent: isPresent)
        var out: [ModelID] = []
        var placed = false
        for id in preferred {
            if all.contains(id) {
                if !placed, let chosen { out.append(chosen); placed = true }
            } else {
                out.append(id)
            }
        }
        return out
    }
}
