import Foundation
@testable import Lab
import Testing

/// V5 B5 — opt-in V1 scoring of the optional final models against v3 on one public set.
///
/// `VOICEPLUS_EVAL_B5=<set>` after `EvalPublicSetTests` wrote `hyp-<model>.json` for
/// `parakeet-tdt-v3` and `parakeet-ultra` / `parakeet-redux` (`VOICEPLUS_EVAL_MODELS=…`). Each model
/// present is scored by `lab eval` (per-condition table, `Lab/results/<date>-<set>-<model>.json`).
/// The decision it feeds is `BundledModel.v1Ranking`.
@Suite("B5 final-model comparison (opt-in)", .serialized)
struct FinalModelComparisonB5Tests {
    @Test func scoreOptionalFinalModelsIfRequested() async throws {
        guard let set = ProcessInfo.processInfo.environment["VOICEPLUS_EVAL_B5"], !set.isEmpty else { return }
        let dir = EvalPaths().cacheDirectory.appendingPathComponent(set)
        for model in ["parakeet-tdt-v3", "parakeet-ultra", "parakeet-redux"] {
            let hyp = dir.appendingPathComponent("hyp-\(model).json").path
            guard FileManager.default.fileExists(atPath: hyp) else { print("B5: no hypotheses for \(model)"); continue }
            let out = await LabCLI.main(["eval", "--set", set, "--model", model, "--hyp", hyp])
            print("B5 \(model):\n\(out.text)")
            #expect(out.exitCode == 0)
        }
    }
}
