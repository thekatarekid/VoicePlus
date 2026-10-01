import Engine
import Foundation

/// What the directed-speech classifier (P5.1) learns from. Each false trigger the user dismisses
/// with "not you" becomes a labelled negative; each accepted dictation a positive.
public struct DirectedSpeechExample: Equatable, Sendable {
    public enum Label: Equatable, Sendable { case directed, notDirected }
    public enum Reason: Equatable, Sendable { case notMe, notTalkingToYou, accepted }
    public var utteranceID: UUID
    public var label: Label
    public var reason: Reason
    /// Speaker embedding of the utterance when available (feeds the speaker profile negatives).
    public var embedding: SpeakerEmbedding?
    public var at: Date
    public init(utteranceID: UUID, label: Label, reason: Reason, embedding: SpeakerEmbedding? = nil, at: Date = Date()) {
        self.utteranceID = utteranceID; self.label = label; self.reason = reason; self.embedding = embedding; self.at = at
    }
}

/// Implemented by the P5.1 classifier (or a recorder in tests). Nothing here stores audio.
public protocol DirectedSpeechTeacher: AnyObject, Sendable {
    func learn(_ example: DirectedSpeechExample)
}

/// Where "not me" corrections fold into the enrolled speaker profile.
public protocol SpeakerProfileUpdating: AnyObject, Sendable {
    func addNegative(_ e: SpeakerEmbedding)
    func reinforce(_ e: SpeakerEmbedding)
}

/// A false trigger the glyph surfaced and the user can dismiss. Holding the last few lets
/// "not you" apply to the trigger that just happened rather than requiring a modal.
public struct PendingTrigger: Equatable, Sendable {
    public var utteranceID: UUID
    public var text: String
    public var embedding: SpeakerEmbedding?
    public var at: Date
    public init(utteranceID: UUID = UUID(), text: String, embedding: SpeakerEmbedding? = nil, at: Date = Date()) {
        self.utteranceID = utteranceID; self.text = text; self.embedding = embedding; self.at = at
    }
}

/// The "not you" hook: keeps recent triggers, turns a dismissal into a teaching example, and
/// optionally pushes the speaker embedding into the profile as a negative.
public final class NotYouCorrection: @unchecked Sendable {
    public static let window: TimeInterval = 30
    public static let keep = 5
    private let lock = NSLock()
    private(set) var recent: [PendingTrigger] = []
    private let teacher: any DirectedSpeechTeacher
    private let profile: (any SpeakerProfileUpdating)?
    /// A second teacher told about every example after `teacher` (V5 O4: `BandNudgingTeacher`, which
    /// raises the frontmost app's decision bands on "not for you").
    public var observer: (any DirectedSpeechTeacher)?

    public init(teacher: any DirectedSpeechTeacher, profile: (any SpeakerProfileUpdating)? = nil) {
        self.teacher = teacher; self.profile = profile
    }

    public var pending: [PendingTrigger] { lock.withLock { recent } }

    /// Register a trigger the system acted on (dictated/acted). Oldest beyond `keep` drop out.
    public func didTrigger(_ t: PendingTrigger) {
        lock.withLock {
            recent.append(t)
            if recent.count > Self.keep { recent.removeFirst(recent.count - Self.keep) }
        }
    }

    /// "Not you" — the most recent trigger (within the window) was not meant for the machine.
    /// `notMe` additionally means the voice was not the user's. Returns the corrected trigger.
    @discardableResult
    public func notYou(reason: DirectedSpeechExample.Reason = .notTalkingToYou, now: Date = Date()) -> PendingTrigger? {
        let t: PendingTrigger? = lock.withLock {
            guard let last = recent.last, now.timeIntervalSince(last.at) <= Self.window else { return nil }
            recent.removeLast(); return last
        }
        guard let t else { return nil }
        let example = DirectedSpeechExample(utteranceID: t.utteranceID, label: .notDirected, reason: reason, embedding: t.embedding, at: now)
        teacher.learn(example)
        observer?.learn(example)
        if reason == .notMe, let e = t.embedding { profile?.addNegative(e) }
        return t
    }

    /// The user kept the result: a positive example, and the voice reinforces the profile.
    public func accepted(_ id: UUID, now: Date = Date()) {
        let t: PendingTrigger? = lock.withLock {
            guard let i = recent.firstIndex(where: { $0.utteranceID == id }) else { return nil }
            return recent.remove(at: i)
        }
        guard let t else { return }
        let example = DirectedSpeechExample(utteranceID: id, label: .directed, reason: .accepted, embedding: t.embedding, at: now)
        teacher.learn(example)
        observer?.learn(example)
        if let e = t.embedding { profile?.reinforce(e) }
    }
}
