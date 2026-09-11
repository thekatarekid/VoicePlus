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

    /// Bet 2 — decode-time context biasing from screen/app vocabulary.
    /// Default OFF since P1.12 T2 (see DECISIONS.md): on the real Parakeet decoder the biaser is a
    /// post-hoc rescorer that cannot change the greedy path, so the Lab measured zero entity-recall
    /// gain. Flip back once the decoder fork exposes logits (synthetic suite: 33% → 100% recall).
    public static let contextBiasing = FeatureFlag(
        id: "contextBiasing", defaultOn: false,
        description: "Bias the decoder toward on-screen and app-specific vocabulary (Bet 2)."
    )
    /// Bet 3 — spoken repair of the last utterance.
    public static let voiceRepair = FeatureFlag(
        id: "voiceRepair", defaultOn: true,
        description: "Allow 'no, X' style voice corrections against alternates (Bet 3)."
    )
    /// Bet 4 — dual-path silent correction (Phase 1.5; default off until it ships).
    public static let dualPath = FeatureFlag(
        id: "dualPath", defaultOn: false,
        description: "Run a slower second ASR pass and silently reconcile (Bet 4)."
    )
    /// Cloud ASR provider (privacy-sensitive; default off).
    public static let cloudASR = FeatureFlag(
        id: "cloudASR", defaultOn: false,
        description: "Send audio to a cloud ASR provider when explicitly enabled."
    )

    /// P5.1 — hands-free directed-speech detection. Experimental: stays opt-in until the
    /// recorded home+office corpus (not just the synthetic harness) holds < 1 false trigger/day.
    public static let directedSpeech = FeatureFlag(
        id: "directedSpeech", defaultOn: false,
        description: "Experimental: hands-free mode answers speech directed at the machine (no hotkey)."
    )

    /// R1.5 — which recognizer draws the streaming preview. `false` (the default) is the measured
    /// winner, the EOU 120M stream; `true` selects polling the final TDT model, which is much more
    /// accurate but misses the 300 ms first-word budget (V3 §10.2). Both paths stay in the build;
    /// see `PreviewBackend` and the R1.5 table in `DECISIONS.md`.
    public static let previewBackend = FeatureFlag(
        id: "previewBackend", defaultOn: false,
        description: "Draw the preview by polling the final model instead of the EOU 120M stream (R1.5 candidate B)."
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
        description: "Refine finalized segments with a second Qwen3-ASR pass (R5; measured worse overall)."
    )

    public static let all: [FeatureFlag] = [.contextBiasing, .voiceRepair, .dualPath, .cloudASR, .directedSpeech, .previewBackend, .qwenRefinement]
}
