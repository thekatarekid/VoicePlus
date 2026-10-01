import Foundation

/// A measurable, Lab-linked switch for a risky bet (Build doc §0 rule 5).
/// Flagged code paths are never deleted; kill criteria only flip `defaultOn`.
public struct FeatureFlag: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var defaultOn: Bool
    public var description: String

    public init(id: String, defaultOn: Bool, description: String) {
        self.id = id
        self.defaultOn = defaultOn
        self.description = description
    }

    // MARK: Known flags

    // `contextBiasing` (Bet 2, decode-time shallow fusion) was deleted by V5 A1/B1: inert on the real
    // decoder (0 entity-recall gain), replaced by final-pass CTC vocabulary boosting, which needs no
    // flag — it acts only on words the user put in their Dictionary or corrected. A stored override
    // for the old id is simply never read.
    /// Bet 3 — spoken repair of the last utterance.
    public static let voiceRepair = FeatureFlag(
        id: "voiceRepair", defaultOn: true,
        description: "Allow 'no, X' style voice corrections against alternates (Bet 3)."
    )
    /// Bet 4 — dual-path silent correction (Phase 1.5; default off until it ships).
    public static let dualPath = FeatureFlag(
        id: "dualPath", defaultOn: false,
        description: "Run a slower second ASR pass and silently reconcile (Bet 4). Verdict (A3): off. Kill: delete unless the V1 "
            + "replay (LibriSpeech test-other, Earnings-22) shows ≥0.5 abs WER gain with no test-clean regression and ≤1.5 s added p95."
    )
    /// Cloud ASR provider (privacy-sensitive; default off).
    public static let cloudASR = FeatureFlag(
        id: "cloudASR", defaultOn: false,
        description: "Send audio to a cloud ASR provider when explicitly enabled. Verdict (A3): ship as opt-in, off — a privacy "
            + "choice, not an accuracy bet. Kill: delete if it is still unused when RoutingTable sends ASR elsewhere (W8)."
    )

    /// P5.1 — hands-free directed-speech detection. Experimental: stays opt-in until the
    /// recorded home+office corpus (not just the synthetic harness) holds < 1 false trigger/day.
    public static let directedSpeech = FeatureFlag(
        id: "directedSpeech", defaultOn: false,
        description: "Experimental: hands-free mode answers speech directed at the machine (no hotkey). Verdict (A3): off. "
            + "Kill: delete when the O2/O3 decision layer ships unless V1 decide-stage replay (AMI/NOTSOFAR ambient) holds <1 false trigger/day."
    )

    /// R1.5 — which recognizer draws the streaming preview. `false` (the default) is the measured
    /// winner, the EOU 120M stream; `true` selects polling the final TDT model, which is much more
    /// accurate but misses the 300 ms first-word budget (V3 §10.2). Both paths stay in the build;
    /// see `PreviewBackend` and the R1.5 table in `DECISIONS.md`.
    public static let previewBackend = FeatureFlag(
        id: "previewBackend", defaultOn: false,
        description: "Draw the preview by polling the final model instead of the EOU 120M stream (R1.5 candidate B). Verdict (A3): "
            + "off pending V1. Kill: flip on and delete the EOU path if V1 shows B ≥0.05 abs WER better with first-word p95 ≤1.5 s; else delete B."
    )

    /// R5 — the Qwen3-ASR 0.6B second pass. **Default off, set by measurement, not caution.**
    /// On the twenty real-room dictations (11 Sep 2026, real int8 weights) the second pass was
    /// *worse overall*: pass-1 mean WER 0.0991 against pass-2's 0.1784. It improved 1 segment of 20
    /// and made 7 worse, and it ran 1.9–4.2 s against the 1500 ms deadline in V3 §10.2. R5's gate
    /// asks for useful gain, no clean-speech regression, and the deadline met; it failed all three.
    /// The path stays in the build per §0 rule 5 — the port itself is correct since the forced
    /// decoder ids landed (WER 1.000 → 0.000 on the probe line). Flip this on only if R5.4's
    /// segment-class breakdown finds a class where it wins. See the R5 rows in `DECISIONS.md`.
    public static let qwenRefinement = FeatureFlag(
        id: "qwenRefinement", defaultOn: false,
        description: "Refine finalized segments with a second Qwen3-ASR pass (R5; measured worse overall). Verdict (A3): off. "
            + "Kill: delete the path in W8 unless V1 finds a segment class with ≥1.0 abs WER gain at ≤2.5 s p95."
    )

    /// A3 — the flags V5 §X20 found switched off (six; `contextBiasing` since deleted by A1/B1).
    /// Each carries its verdict and written kill criterion in `description` (DECISIONS.md, "2026-10-01 — A3").
    public static let x20: [FeatureFlag] = [.dualPath, .cloudASR, .directedSpeech, .previewBackend, .qwenRefinement]

    public static let all: [FeatureFlag] = [.voiceRepair, .dualPath, .cloudASR, .directedSpeech, .previewBackend, .qwenRefinement]
}
