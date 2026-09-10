import Foundation
import Shared

/// Which recognizer draws the streaming preview (R1.5).
///
/// Two candidates, both kept: the Parakeet Realtime **EOU 120M** stream that ships today, and
/// **polling the final TDT v3 model** over the accumulated buffer. R1.5 measured both on
/// `Fixtures/real-room/builtin` (see `DECISIONS.md`, 11 September 2026): polling TDT v3 is far more
/// accurate but shows its first word roughly a second after speech onset, well past the 300 ms
/// preview budget in V3 §10.2, so the default stays the EOU stream.
///
/// The choice is a `FeatureFlag`, so it is one boolean on the wire (`previewBackend`): `false` — the
/// default — means "the measured winner", the EOU stream; `true` selects the polling candidate. The
/// losing path is not deleted, per the flag rule, and Lab can run either
/// (`LabConfigChoice.previewBackendChoices`).
public enum PreviewBackend: String, CaseIterable, Sendable {
    /// Parakeet Realtime EOU 120M, streaming at 160 ms internally. Falls back to `pollingFinal`
    /// when the EOU model is not on disk.
    case eouStreaming120m
    /// `PollingPreviewRecognizer` over whatever final model is loaded (TDT v3 in practice).
    case pollingFinal

    /// The measured winner (R1.5). Changing this changes what users see, so it moves only with a
    /// new measurement recorded in `DECISIONS.md`.
    public static let measuredDefault: PreviewBackend = .eouStreaming120m

    /// Resolves the backend from a flag snapshot (`FeatureFlagService.snapshot()` or
    /// `StageContext.flags`). Absent or `false` → the measured default.
    public static func resolve(flags: [String: Bool]) -> PreviewBackend {
        (flags[FeatureFlag.previewBackend.id] ?? FeatureFlag.previewBackend.defaultOn)
            ? .pollingFinal : measuredDefault
    }

    public static func resolve(_ service: FeatureFlagService) -> PreviewBackend {
        service.isEnabled(.previewBackend) ? .pollingFinal : measuredDefault
    }

    public var displayName: String {
        switch self {
        case .eouStreaming120m: return "EOU 120M stream"
        case .pollingFinal: return "polling final model"
        }
    }
}

/// Applies `PreviewFormatter` to whatever a preview recognizer produces (V3 §5.2). Preview path
/// only — the final pass keeps its own formatting in `Pipeline`.
public final class FormattedPreviewRecognizer: PreviewRecognizer, @unchecked Sendable {
    public let base: PreviewRecognizer

    public init(_ base: PreviewRecognizer) { self.base = base }

    public func feed(_ samples: [Float]) async throws -> String {
        PreviewFormatter.format(try await base.feed(samples))
    }

    public func reset() async { await base.reset() }
}
