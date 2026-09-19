import Engine
import Foundation
import Shared

// S7e — Voice › Recognition › Your voice (design §8.4; V4.48–V4.50, H2/H3): whether a voice is
// enrolled, how far passive enrollment has got ("learning N of 10"), whether speaker filtering can
// run with it, and the "Not you" corrections folded into it. Enrollment is optional and never gates
// hold dictation; every line here says so where it matters.

/// What the Voice pane reads about the speaker profile. Taken fresh on every refresh: the latch
/// controller writes the profile and the passive progress through its own store, and a cached read
/// would keep saying "No voice enrolled" after the tenth hold built one.
public struct VoiceSpeakerReading: Equatable, Sendable {
    public var profile: SpeakerProfile?
    /// H2 — a passive enrollment in progress (embeddings from qualifying holds).
    public var passive: SpeakerEnrollment?
    /// H3 — the WeSpeaker weights are on this Mac, so a voice can actually be identified.
    public var identifyingEmbedderAvailable: Bool

    public init(profile: SpeakerProfile?, passive: SpeakerEnrollment?, identifyingEmbedderAvailable: Bool) {
        self.profile = profile
        self.passive = passive
        self.identifyingEmbedderAvailable = identifyingEmbedderAvailable
    }

    /// `FluidSpeakerEmbedder.name`: profiles it built are the only ones speaker filtering can use
    /// (`LatchController.canFilter`: an MFCC profile means nothing in WeSpeaker's cosine space).
    public static let identifyingEmbedderName = "fluid-wespeaker"

    public static func read(_ store: SpeakerProfileStore,
                            identifyingEmbedderAvailable: Bool = FluidSpeakerEmbedder.isAvailable) -> VoiceSpeakerReading {
        VoiceSpeakerReading(profile: store.profile, passive: store.passiveEnrollment,
                            identifyingEmbedderAvailable: identifyingEmbedderAvailable)
    }
}

/// H2 — the "Not you" corrections kept in the profile: each rejected voice is a negative, and the
/// similarity a hands-free segment must reach is lifted just past the closest one.
public struct NotYouHistory: Equatable, Sendable {
    public var corrections: Int
    /// The lifted similarity, when a correction was comparable with the voice.
    public var thresholdFloor: Float?

    public init(corrections: Int, thresholdFloor: Float?) {
        self.corrections = corrections
        self.thresholdFloor = thresholdFloor
    }

    public init(_ profile: SpeakerProfile) {
        self.init(corrections: profile.negatives.count, thresholdFloor: profile.thresholdFloor)
    }

    public var title: String { VoiceEnrollmentCopy.notYouTitle }

    public var summary: String {
        guard corrections > 0 else { return VoiceEnrollmentCopy.notYouNone }
        let voices = corrections == 1 ? "1 voice" : "\(corrections) voices"
        guard let thresholdFloor else { return "\(voices) marked “Not you”. Each one is kept so it is not let through again." }
        return "\(voices) marked “Not you”. Hands-free Latch now needs a match of at least "
            + String(format: "%.2f", thresholdFloor) + " before a segment lands."
    }
}

/// Enrolled / learning N of 10 / off (build doc S7e).
public enum VoiceEnrollmentStatus: Equatable, Sendable {
    case off
    case learning(learned: Int, of: Int)
    case enrolled(since: Date, filtering: Bool, notYou: NotYouHistory)

    public init(_ reading: VoiceSpeakerReading) {
        if let profile = reading.profile {
            let filtering = reading.identifyingEmbedderAvailable
                && profile.centroid.embedder == VoiceSpeakerReading.identifyingEmbedderName
            self = .enrolled(since: profile.enrolledAt, filtering: filtering, notYou: NotYouHistory(profile))
        } else if let passive = reading.passive, passive.mode == .passive, passive.learnedCount > 0 {
            self = .learning(learned: passive.learnedCount, of: passive.requiredCount)
        } else {
            self = .off
        }
    }

    public var isEnrolled: Bool {
        if case .enrolled = self { return true }
        return false
    }

    /// The short tag beside "Your voice".
    public var tag: String {
        switch self {
        case .off: return VoiceEnrollmentCopy.offTag
        case .learning(let learned, let total): return "Learning \(learned) of \(total)"
        case .enrolled: return VoiceEnrollmentCopy.enrolledTag
        }
    }

    public var tagIsGood: Bool {
        if case .enrolled(_, true, _) = self { return true }
        return false
    }

    /// The sentence under the row.
    public func line(hotkey: String, dateStyle: (Date) -> String = VoiceEnrollmentCopy.date) -> String {
        switch self {
        case .off:
            return DesignScreen.voice.empty.rendered(hotkey: hotkey).body
        case .learning(let learned, let total):
            let left = total - learned
            return "VoicePlus is learning your voice from your holds: \(left) more with at least "
                + String(format: "%.1f", SpeakerEnrollment.minimumHoldSpeechSeconds)
                + " s of speech, or set it up now. Hold-to-talk works the same meanwhile."
        case .enrolled(let since, let filtering, _):
            return filtering
                ? "Enrolled \(dateStyle(since)). Hands-free Latch only answers to you; hold-to-talk is never filtered."
                : "Enrolled \(dateStyle(since)). \(RecoveryCatalog.entry(.X03).consequence)"
        }
    }

    /// The primary button: set up while off or learning, re-enroll once enrolled.
    public var primaryAction: String {
        isEnrolled ? VoiceEnrollmentCopy.reenroll : DesignScreen.voice.empty.action
    }
}

public enum VoiceEnrollmentCopy {
    public static let rowTitle = "Your voice"
    public static let rowDetail = "Enrollment helps optional speaker filtering."
    public static let offTag = DesignScreen.voice.empty.headline
    public static let enrolledTag = "Enrolled"
    public static let filteringUnavailableTag = SpeakerFilter.unavailableLabel
    public static let reenroll = "Re-enroll"
    public static let delete = "Delete voice"
    public static let stop = "Stop"
    public static let notYouTitle = "“Not you” corrections"
    public static let notYouNone = "None yet. Say “not you” during hands-free Latch when it picks up someone else."
    /// Shown while a prompted enrollment runs in the pane.
    public static let running = "Teach VoicePlus your voice"

    public static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
