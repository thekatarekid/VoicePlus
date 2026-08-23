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
    public static let contextBiasing = FeatureFlag(
        id: "contextBiasing", defaultOn: true,
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

    public static let all: [FeatureFlag] = [.contextBiasing, .voiceRepair, .dualPath, .cloudASR]
}
