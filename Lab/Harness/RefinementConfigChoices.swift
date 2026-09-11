// VoicePlus original (task R5.4). The three refinement arms as Lab configurations.
import Foundation
import Shared

/// Names the R5.4 arms share with the Lab registry and the benchmark tables.
///
/// The strings live here rather than at call sites so the panel, the CLI (`lab run --transcriber …`)
/// and `Tests/AppTests/RefinementBenchmarkCorpusTests.swift` all spell the arms the same way, and a
/// rename is one edit.
public enum RefinementLabConfigs {
    /// Arm 1 — the shipping recognizer alone (Parakeet TDT 0.6B v3). `LabWiring`'s `engine`
    /// transcriber: the same decoder as dictation, fed from a WAV.
    public static let parakeetOnly = "parakeet only"
    /// Arm 2 — the refinement model used as the *only* recognizer (Qwen3-ASR 0.6B int8, R5.1), with
    /// the R4.1b context prompt. Not a shipping configuration; it is the arm that says whether the
    /// second model is better at recognition at all, independently of any gate.
    public static let qwenOnly = "qwen only"
    /// Arm 3 — the shipping arrangement under test: Parakeet, then `RefineStage` on the segments
    /// `RefinementGate` selects, under the V3 §10.2 deadline.
    public static let twoPass = "two-pass (gated)"
    /// Arm 3′ — the same gated two-pass with the deadline lifted. **Not a configuration anything can
    /// ship**: it exists so the benchmark can separate "the second pass has nothing to offer" from
    /// "the second pass never finished in time", which the shipping deadline alone cannot tell apart
    /// on hardware where Qwen takes 1.9–4.2 s (R5.3). Reported beside `twoPass`, never instead of it.
    public static let twoPassDeadlineWaived = "two-pass (gated, deadline waived)"

    /// The registry name of the real Parakeet transcriber (`LabWiring.registry`).
    public static let parakeetTranscriber = "engine"
    /// The registry name a real single-pass Qwen transcriber must be registered under for the
    /// `qwen only` arm to run from the panel or the CLI. `LabWiring` does not register it today —
    /// the measurement behind the R5.4 decision runs in `AppTests`, which can build the session
    /// directly (the same split `PreviewBackendChoices` uses for the R1.5 numbers).
    public static let qwenTranscriber = "qwen"

    /// `StageID.refine.rawValue` from `Pipeline`, repeated as a literal because the `Lab` target may
    /// not depend on `Pipeline` (Package.swift). `refineStageIDMatchesPipeline` in
    /// `Tests/AppTests/RefinementBenchmarkCorpusTests.swift` asserts the two never drift apart.
    public static let refineStageID = "refine.qwen3"
}

/// R5.4 — the three benchmark arms as Lab configurations.
public extension LabConfigChoice {

    /// One row per arm: Parakeet only, Qwen only, and the gated two-pass.
    ///
    /// All three are offered **unselected**, like the R1.5 preview rows: the default panel run stays
    /// the biasing comparison, and these are picked deliberately because two of them need the Qwen
    /// weights (1.2 GB) and minutes of ANE time per run.
    ///
    /// `transcriber` is the pass-1 transcriber (`"perfect"` for a wiring-only run, `"engine"` for the
    /// real recognizer) and `qwenTranscriber` is the single-pass Qwen one; it defaults to
    /// `transcriber` so that a mock run has no unresolvable name in it.
    static func refinementChoices(transcriber: String = "perfect",
                                  qwenTranscriber: String? = nil,
                                  stages: [String] = [],
                                  suites: [String] = FixtureSuite.defaultNames,
                                  selected: Bool = false) -> [LabConfigChoice] {
        let flag = FeatureFlag.qwenRefinement.id
        let qwen = qwenTranscriber ?? transcriber
        return [
            LabConfigChoice(config: LabConfig(name: RefinementLabConfigs.parakeetOnly, transcriber: transcriber,
                                              stages: stages, flags: [flag: false], suites: suites),
                            selected: selected),
            LabConfigChoice(config: LabConfig(name: RefinementLabConfigs.qwenOnly, transcriber: qwen,
                                              stages: stages, flags: [flag: true], suites: suites),
                            selected: selected),
            LabConfigChoice(config: LabConfig(name: RefinementLabConfigs.twoPass, transcriber: transcriber,
                                              stages: stages + [RefinementLabConfigs.refineStageID],
                                              flags: [flag: true], suites: suites),
                            selected: selected),
        ]
    }
}
