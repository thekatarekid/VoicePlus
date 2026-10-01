import Engine
import Foundation

// R8.1 — what ambient capture is allowed to keep.
//
// The whole of this file is about *storage*. There is no delivery, no injection, no action here: an
// `AmbientEntry` has no route to an injector and the only consumer of a captured entry is
// `AmbientTranscriptSink`. Since V5 L2 (amends V3 §8) a kept utterance may *also* be decided by the
// arbiter, and leaves the Timeline only as `AmbientGuarantees` allow (Listen & act, the user's voice,
// the act band, never self-confirming) — see `AmbientDecisionPipeline` and
// `Tests/AppTests/AmbientGuaranteesTests.swift`.

/// One thing that was said, on its way to the Timeline and nowhere else.
///
/// Deliberately *not* an `Utterance`, a `TranscriptSpan` array, or anything the delivery pipeline
/// accepts: nothing downstream of ambient capture can mistake this for text to type.
public struct AmbientEntry: Equatable, Sendable {
    /// Who said it, in the meeting store's own vocabulary (`.you` is the enrolled user).
    public var speaker: MeetingSpeaker
    public var text: String
    public var capturedAt: Date
    /// Seconds of speech, used only for the stored range.
    public var duration: TimeInterval
    public var confidence: Float

    public init(speaker: MeetingSpeaker, text: String, capturedAt: Date,
                duration: TimeInterval = 0, confidence: Float = 1) {
        self.speaker = speaker
        self.text = text
        self.capturedAt = capturedAt
        self.duration = duration
        self.confidence = confidence
    }

    /// What the Timeline shows in its source column. Another voice is labelled as one — an entry
    /// that is not the enrolled user never reads as if it were.
    public var sourceLabel: String {
        switch speaker {
        case .you: return AmbientEntry.enrolledSource
        case .others: return AmbientEntry.otherVoiceSource
        }
    }

    public static let enrolledSource = "Ambient"
    public static let otherVoiceSource = "Ambient · other voice"
}

/// The only destination a captured ambient entry has.
///
/// One conformance ships (`AmbientTranscriptStore`). No injector can be one: `AmbientEntry` is not
/// an injection request and this protocol returns an id, not a delivery outcome. The test asserts
/// that no `Injector` conforms.
public protocol AmbientTranscriptSink: AnyObject, Sendable {
    /// Stores the entry and returns its stable Timeline id.
    @discardableResult
    func store(_ entry: AmbientEntry) throws -> String
}

/// Why an utterance was not kept. Every one of these is a *discard*, never a downgrade to "kept
/// anyway": the reasons exist so the user can be told, not so the text can be stored with a caveat.
public enum AmbientDiscardReason: String, Equatable, Sendable, CaseIterable {
    case captureOff = "ambient capture is off"
    case emptyText = "nothing was said"
    case anotherVoice = "another voice"
    case uncertainVoice = "not sure it was you"
    case speakerModelUnavailable = "speaker model unavailable"
    case notEnrolled = "no enrolled voice"

    /// Built from R3's suppression reasons, one-to-one, so ambient never invents a second vocabulary
    /// for the same verdict. `.modelUnavailable` maps to `.speakerModelUnavailable` — it can never
    /// arrive here as "enrolled".
    public init(_ suppression: SpeakerFilter.SuppressionReason) {
        switch suppression {
        case .mismatch: self = .anotherVoice
        case .uncertain: self = .uncertainVoice
        case .modelUnavailable: self = .speakerModelUnavailable
        case .notEnrolled: self = .notEnrolled
        }
    }

    /// The sentence for the Timeline's "why is this empty?" line.
    public var message: String {
        switch self {
        case .captureOff: return "Ambient capture is off."
        case .emptyText: return "Nothing was said."
        case .anotherVoice: return "Another voice — not kept."
        case .uncertainVoice: return "Couldn't confirm it was you — not kept."
        case .speakerModelUnavailable: return SpeakerFilter.modelUnavailableMessage
        case .notEnrolled: return SpeakerFilter.notEnrolledMessage
        }
    }
}

public enum AmbientCaptureDecision: Equatable, Sendable {
    case keep(AmbientEntry)
    case discard(AmbientDiscardReason)

    public var kept: AmbientEntry? { if case .keep(let e) = self { return e } ; return nil }
    public var discardReason: AmbientDiscardReason? { if case .discard(let r) = self { return r } ; return nil }
}

/// Decides whether one heard utterance may be written to the Timeline.
///
/// ## Why this does not simply ask `SpeakerFilter`
/// R3's `SpeakerFilter` is off by default, and when it is off it allows every voice — the right
/// answer for hold-to-talk on a Mac with no enrolled profile. Ambient capture cannot inherit that
/// default: "allow everything" is precisely what V3 §8 forbids it to do. So unless the user has
/// explicitly widened capture, the filter is evaluated as if it were *on*, and an ambient entry is
/// kept only when the filter's status is `.active` — an identifying backend, loaded, with a profile
/// enrolled — and the verdict is `.user`. Uncertain is not yes, and "no weights" is not yes either.
public struct AmbientCaptureGate: Sendable {
    /// The separate opt-in (`ambient.capture.enabled`).
    public var isEnabled: Bool
    /// Explicitly widened capture (`ambient.capture.everySpeaker`).
    public var capturesEverySpeaker: Bool
    /// R3's filter. Its `isOn` is ignored for the enrolled-only path; see above.
    public var filter: SpeakerFilter

    public init(isEnabled: Bool, capturesEverySpeaker: Bool, filter: SpeakerFilter) {
        self.isEnabled = isEnabled
        self.capturesEverySpeaker = capturesEverySpeaker
        self.filter = filter
    }

    /// The filter as ambient evaluates it: identification is mandatory unless the user asked for
    /// every speaker.
    public var effectiveFilter: SpeakerFilter {
        capturesEverySpeaker ? filter : SpeakerFilter(isOn: true, gate: filter.gate, canIdentify: filter.canIdentify)
    }

    /// What to tell the user about the state of speaker identification right now, or nil when there
    /// is nothing to say.
    public var statusMessage: String? { isEnabled ? effectiveFilter.status.message : nil }

    public func decide(text: String, verdict: SpeakerGate.Verdict, at now: Date,
                       duration: TimeInterval = 0, confidence: Float = 1) -> AmbientCaptureDecision {
        guard isEnabled else { return .discard(.captureOff) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .discard(.emptyText) }

        if capturesEverySpeaker {
            // Broader capture was asked for, so another voice is kept — and labelled as another
            // voice. `.user` is claimed only when the filter can actually identify one.
            let isEnrolled = effectiveFilter.status.identifies && verdict.isUser
            return .keep(AmbientEntry(speaker: isEnrolled ? .you : .others(1), text: trimmed,
                                      capturedAt: now, duration: duration, confidence: confidence))
        }

        switch effectiveFilter.decide(verdict) {
        case .allow:
            return .keep(AmbientEntry(speaker: .you, text: trimmed, capturedAt: now,
                                      duration: duration, confidence: confidence))
        case .suppress(let reason):
            return .discard(AmbientDiscardReason(reason))
        }
    }
}
