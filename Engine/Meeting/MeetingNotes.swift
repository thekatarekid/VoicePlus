import Foundation
import Shared

/// One diarized utterance of the meeting transcript.
public struct MeetingUtterance: Codable, Equatable, Sendable {
    public var speaker: MeetingSpeaker
    public var text: String
    public var range: ClosedRange<TimeInterval>
    public var confidence: Float
    /// V5 O2 — the capability that claimed this span while the recorder ran ("dictated", "command",
    /// "note"); nil for plain conversation. Optional so records written before O2 still decode.
    public var tag: UtteranceOwner?
    public init(speaker: MeetingSpeaker, text: String, range: ClosedRange<TimeInterval>, confidence: Float,
                tag: UtteranceOwner? = nil) {
        self.speaker = speaker; self.text = text; self.range = range; self.confidence = confidence
        self.tag = tag
    }

    /// The tag as the transcript renders it (`UtteranceOwner.recorderLabel`).
    public var tagLabel: String? { tag?.recorderLabel }
}

public struct MeetingTranscript: Codable, Equatable, Sendable {
    public var utterances: [MeetingUtterance]
    public init(utterances: [MeetingUtterance] = []) { self.utterances = utterances }
    public var plainText: String { utterances.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n") }

    /// V5 O2 — how far a tag's wall-clock edges may sit from the recorder's own timestamps (VAD
    /// chunking and the capture start are not sample-aligned with the dictation claim).
    public static let tagSlack: TimeInterval = 0.5

    /// Does `tag` claim an utterance spanning `range` (seconds from `origin`)? Only the user's own
    /// voice can be claimed by a capability, and the claim must cover at least half of the span —
    /// so a dictation never labels the conversation it sat next to.
    public static func claims(_ tag: UtteranceTag, speaker: MeetingSpeaker, range: ClosedRange<TimeInterval>,
                              origin: Date) -> Bool {
        guard speaker == .you else { return false }
        let lo = origin.addingTimeInterval(range.lowerBound), hi = origin.addingTimeInterval(range.upperBound)
        let widened = UtteranceTag(utteranceID: tag.utteranceID, owner: tag.owner,
                                   range: tag.range.lowerBound.addingTimeInterval(-tagSlack)...tag.range.upperBound.addingTimeInterval(tagSlack))
        let overlap = widened.overlap(lo, hi)
        let duration = range.upperBound - range.lowerBound
        return duration <= 0.05 ? (widened.range.contains(lo)) : overlap >= duration * 0.5
    }

    /// Labels every untagged utterance `tag` claims. A span keeps the first owner it was given (one
    /// owner per utterance); `.ignore` labels nothing. Returns how many utterances were tagged.
    @discardableResult
    public mutating func apply(_ tag: UtteranceTag, origin: Date) -> Int {
        guard tag.owner != .ignore else { return 0 }
        var n = 0
        for i in utterances.indices where utterances[i].tag == nil
            && Self.claims(tag, speaker: utterances[i].speaker, range: utterances[i].range, origin: origin) {
            utterances[i].tag = tag.owner
            n += 1
        }
        return n
    }
}

public struct MeetingNotes: Codable, Equatable, Sendable {
    public var summary: [String]
    public var actionItems: [String]
    public var decisions: [String]
    public var provider: String
    public init(summary: [String], actionItems: [String], decisions: [String], provider: String) {
        self.summary = summary; self.actionItems = actionItems; self.decisions = decisions; self.provider = provider
    }

    public var markdown: String {
        var s = "## Summary\n"
        s += summary.isEmpty ? "_(nothing captured)_\n" : summary.map { "- \($0)" }.joined(separator: "\n") + "\n"
        if !decisions.isEmpty { s += "\n## Decisions\n" + decisions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !actionItems.isEmpty { s += "\n## Action items\n" + actionItems.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n" }
        return s
    }
}

/// Provider-shaped seam: the Providers module (local LLM / cloud, user-enabled) plugs in here at
/// integration. The engine default is fully local and deterministic.
public protocol MeetingNotesProvider: Sendable {
    var name: String { get }
    func notes(for transcript: MeetingTranscript) async throws -> MeetingNotes
}

/// Deterministic extractive notes: sentences scored by summed term frequency of non-stopword
/// tokens (normalised by length), top-N kept in transcript order; action items / decisions by
/// cue phrases. Same transcript → byte-identical notes.
public struct ExtractiveNotesProvider: MeetingNotesProvider {
    public let name = "extractive-local"
    public var maxSummary: Int
    public init(maxSummary: Int = 5) { self.maxSummary = maxSummary }

    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "is", "are", "was", "were", "be", "it", "that", "this", "we", "i", "you", "they", "he", "she", "so", "just", "like", "um", "uh", "yeah", "okay", "ok", "with", "as", "at", "by", "if", "then", "do", "did", "have", "has", "had", "not", "no", "yes", "my", "our", "your", "me", "us", "them", "about", "from", "what", "can", "will", "all", "there", "here", "its", "it's", "i'm", "let's", "let"]
    static let actionCues = ["i will", "i'll", "we will", "we'll", "you will", "need to", "needs to", "should", "must", "todo", "to do", "action item", "follow up", "by friday", "by monday", "by tomorrow", "by next", "take care of", "send", "ship", "owner"]
    static let decisionCues = ["decided", "we agreed", "agreed", "let's go with", "go with", "decision", "we're going to", "we are going to", "final answer", "settled on"]

    public func notes(for transcript: MeetingTranscript) async throws -> MeetingNotes {
        Self.generate(transcript, maxSummary: maxSummary)
    }

    public static func generate(_ transcript: MeetingTranscript, maxSummary: Int = 5) -> MeetingNotes {
        let sentences = transcript.utterances.flatMap { u in split(u.text).map { (speaker: u.speaker, text: $0) } }
        var freq: [String: Int] = [:]
        let tokenized = sentences.map { tokens($0.text) }
        for t in tokenized { for w in t { freq[w, default: 0] += 1 } }
        var scored: [(index: Int, score: Double)] = []
        for (i, t) in tokenized.enumerated() where t.count >= 3 {
            let s = Double(t.reduce(0) { $0 + freq[$1, default: 0] }) / Double(t.count + 2)
            scored.append((i, s))
        }
        // Stable: highest score, ties by earliest position.
        let top = scored.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }.prefix(maxSummary).map(\.index).sorted()
        let summary = top.map { sentences[$0].text }
        var actions: [String] = [], decisions: [String] = []
        for s in sentences {
            let low = s.text.lowercased()
            if decisionCues.contains(where: { low.contains($0) }) { decisions.append(s.text) }
            else if actionCues.contains(where: { low.contains($0) }) { actions.append("\(s.speaker.label): \(s.text)") }
        }
        return MeetingNotes(summary: summary, actionItems: actions, decisions: decisions, provider: "extractive-local")
    }

    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init).filter { !stopwords.contains($0) && $0.count > 1 }
    }
}
