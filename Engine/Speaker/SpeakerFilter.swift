import Foundation

/// R3.3 — the speaker guard, and the honest answer when there is nothing to guard with.
///
/// `SpeakerGate` answers "does this embedding look like the enrolled user?". That is not enough to
/// decide whether committed text may be inserted, for two reasons V3 §8 is explicit about:
///
/// 1. **Uncertain is not yes.** With filtering on, a mismatch *and* an uncertain result both
///    suppress insertion. `SpeakerGate.shouldAccept(_:latched:)` lets `.unknown` through, because
///    that is the right default for a machine with no enrolled profile and no filtering asked for.
///    Once the user has asked for filtering, "I could not tell" must not type another person's
///    speech into their editor.
/// 2. **No weights, no identification.** Without the WeSpeaker weights (V3 §2.3; since H3 they are
///    a required download with the speech stack, `ModelID.speakerEmbedding`)
///    `SpeakerEmbedderFactory.make()` falls back to `MFCCEmbedder`. That fallback was validated on
///    synthetic audio only. Reporting "speaker verified" from it would be a claim the app cannot
///    support, so filtering-on + no weights is `.suppress(.modelUnavailable)` and the user is told
///    **"Voice filtering unavailable"** (X03) — not "that wasn't you", and not a silent pass.
///
/// Nothing here stores audio or embeddings.
public struct SpeakerFilter: Sendable {
    /// What the filter can actually do right now. `message` is the exact user-facing sentence.
    public enum Status: Equatable, Sendable {
        /// The user has not asked for speaker filtering. Every voice is allowed through.
        case off
        /// Filtering is on, an identifying backend is loaded, and a profile is enrolled.
        case active
        /// Filtering is on and identification works, but nobody is enrolled yet.
        case notEnrolled
        /// Filtering is on and the embedding weights are absent: identification is impossible.
        case modelUnavailable

        /// What to show the user. `nil` when there is nothing to say.
        public var message: String? {
            switch self {
            case .off, .active: return nil
            case .notEnrolled: return SpeakerFilter.notEnrolledMessage
            case .modelUnavailable: return SpeakerFilter.modelUnavailableMessage
            }
        }

        /// True only when a verdict from this filter is evidence about who spoke.
        public var identifies: Bool { self == .active }

        /// The recovery-catalogue entry for this state, if it is one: no identifying model is
        /// `X03` ("Couldn’t finish voice setup" — hold-to-talk still works, filtering stays off).
        public var recoveryID: RecoveryID? { self == .modelUnavailable ? SpeakerFilter.unavailableRecovery : nil }
    }

    /// H3 — the label for the MFCC fallback: it keeps the pipeline working without weights, and it
    /// cannot tell voices apart, so filtering by voice is unavailable. Says what is missing; never
    /// implies a voice was checked. The recovery that goes with it is `unavailableRecovery`.
    public static let unavailableLabel = "Voice filtering unavailable"
    /// X03 in the design's recovery catalogue (`Fixtures/design/design_copy.json` › errors):
    /// "Couldn’t finish voice setup" / "Hold-to-talk still works; speaker filtering stays off." /
    /// "Try voice setup again". `EngineMessage.headline(for:)` has the headline.
    public static let unavailableRecovery: RecoveryID = .X03
    /// The sentence to show when the embedding weights are missing (kept under its R3.3 name; it is
    /// `unavailableLabel` since H3).
    public static let modelUnavailableMessage = unavailableLabel
    public static let notEnrolledMessage = "No enrolled voice — record one to filter by speaker"

    /// Why insertion was suppressed. The raw values are what the pill and the log show.
    public enum SuppressionReason: String, Equatable, Sendable, CaseIterable {
        /// The embedding matched somebody else (or a "not you" negative beat the centroid).
        case mismatch = "another voice"
        /// An embedding was produced but says nothing conclusive.
        case uncertain = "not sure it was you"
        /// The embedding weights are absent, so no voice can be identified at all.
        case modelUnavailable = "speaker model unavailable"
        /// Filtering is on but there is no profile to compare against.
        case notEnrolled = "no enrolled voice"

        /// The sentence for the user. Only the unavailable/not-enrolled cases explain themselves;
        /// the other two are about this utterance.
        public var message: String {
            switch self {
            case .modelUnavailable: return SpeakerFilter.modelUnavailableMessage
            case .notEnrolled: return SpeakerFilter.notEnrolledMessage
            case .mismatch: return "Not your voice — nothing was inserted"
            case .uncertain: return "Couldn't confirm it was you — nothing was inserted"
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        case allow(similarity: Float?)
        case suppress(SuppressionReason)

        public var allowsInsertion: Bool { if case .allow = self { return true } ; return false }
        public var suppression: SuppressionReason? {
            if case .suppress(let reason) = self { return reason }
            return nil
        }
    }

    /// Has the user asked for speaker filtering? Off → this type never suppresses anything.
    public var isOn: Bool
    /// The similarity gate. Its `profile` is the enrolled user, or nil.
    public var gate: SpeakerGate
    /// Does the loaded embedder actually identify speakers? False for the MFCC fallback, which
    /// exists so the rest of the pipeline keeps working without weights — not so the app can
    /// claim an identification it cannot make.
    public var canIdentify: Bool

    public init(isOn: Bool, gate: SpeakerGate, canIdentify: Bool) {
        self.isOn = isOn
        self.gate = gate
        self.canIdentify = canIdentify
    }

    public init(isOn: Bool, gate: SpeakerGate, embedder: any SpeakerEmbedder) {
        self.init(isOn: isOn, gate: gate, canIdentify: embedder.identifiesSpeakers)
    }

    public var status: Status {
        guard isOn else { return .off }
        guard canIdentify else { return .modelUnavailable }
        return gate.profile == nil ? .notEnrolled : .active
    }

    /// H3 — can voice filtering work at all with this embedder, whether or not it is switched on?
    /// Settings › Models and Voice read this; the MFCC fallback is `.unavailable`.
    public enum Availability: Equatable, Sendable {
        case available
        case unavailable(label: String, recovery: RecoveryID)

        public var label: String? {
            if case .unavailable(let label, _) = self { return label }
            return nil
        }
    }

    public static func availability(of embedder: any SpeakerEmbedder) -> Availability {
        embedder.identifiesSpeakers ? .available : .unavailable(label: unavailableLabel, recovery: unavailableRecovery)
    }

    /// The decision for one already-embedded utterance.
    public func decide(_ verdict: SpeakerGate.Verdict) -> Decision {
        switch status {
        case .off: return .allow(similarity: nil)
        case .modelUnavailable: return .suppress(.modelUnavailable)
        case .notEnrolled: return .suppress(.notEnrolled)
        case .active:
            switch verdict {
            case .user(let similarity): return .allow(similarity: similarity)
            case .other: return .suppress(.mismatch)
            // Filtering is on and identification is possible, yet this utterance produced no
            // usable embedding (too short, embedder threw, dimension mismatch). Uncertain is not
            // yes: V3 §8 — "never silently save another person's speech".
            case .unknown: return .suppress(.uncertain)
            }
        }
    }

    /// The decision for raw samples. Never runs the embedder when the answer is already known,
    /// so a machine with no weights does no work and makes no claim.
    public func decide(samples: [Float], embedder: any SpeakerEmbedder) -> Decision {
        switch status {
        case .off: return .allow(similarity: nil)
        case .modelUnavailable: return .suppress(.modelUnavailable)
        case .notEnrolled: return .suppress(.notEnrolled)
        case .active: return decide(gate.verdict(for: samples, embedder: embedder))
        }
    }
}
