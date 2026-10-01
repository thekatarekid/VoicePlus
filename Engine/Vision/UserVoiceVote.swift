import Foundation

/// V5 LR1 — the camera's vote in O-b rubric rule 3 ("who spoke: only the user's voice may start a
/// capability"). The audio side (speaker id `SpeakerGate` + near-field `NearFieldGate` /
/// `TurnAnchoredVoice`) casts the first vote; lip activity casts the second.
///
/// The rule, deliberately conservative in the direction that matters (never let a TV start a
/// capability, never silence the user because the camera is off):
/// * camera off / no face / lips unjudged → the audio vote stands unchanged;
/// * audio says user, lips say not-user → **other** (the voice matched, but the person at the screen
///   is not talking — a recording of the user, or a similar voice nearby);
/// * audio unknown, lips say user → **user** (lips rescue an unenrolled / unmeasurable voice);
/// * audio says other, lips say user → **unknown** (the two disagree; the caller's default applies);
/// * otherwise agreement.
public enum UserVoiceVote {
    public enum Vote: String, Sendable, Equatable, Codable { case user, other, unknown }

    public struct Decision: Equatable, Sendable {
        public var vote: Vote
        /// Short machine-readable reason for Q13 diagnostics (no text, no audio).
        public var reason: String
        public init(vote: Vote, reason: String) { self.vote = vote; self.reason = reason }
    }

    public static func combine(audio: Vote, lips: LipActivity?) -> Decision {
        guard let lips else { return Decision(vote: audio, reason: "audio-only:camera-off") }
        switch (audio, lips.verdict) {
        case (_, .noFace), (_, .unknown):
            return Decision(vote: audio, reason: "audio-only:lips-\(lips.verdict.rawValue)")
        case (.user, .userSpeaking):
            return Decision(vote: .user, reason: "agree:user")
        case (.user, .notUser):
            return Decision(vote: .other, reason: "lips-veto")
        case (.unknown, .userSpeaking):
            return Decision(vote: .user, reason: "lips-rescue")
        case (.unknown, .notUser):
            return Decision(vote: .other, reason: "lips:not-user")
        case (.other, .userSpeaking):
            return Decision(vote: .unknown, reason: "disagree")
        case (.other, .notUser):
            return Decision(vote: .other, reason: "agree:other")
        }
    }

    /// Convenience over `SpeakerGate.Verdict`.
    public static func audioVote(_ verdict: SpeakerGate.Verdict) -> Vote {
        switch verdict {
        case .user: return .user
        case .other: return .other
        case .unknown: return .unknown
        }
    }
}
