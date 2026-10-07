import Foundation
import Shared

// Context Writer §2.4 — what the vocabulary matcher indexes: the user's own terms, each with the
// spoken forms that say it. Sources: the Dictionary (non-Contacts rows), confirmed corrections, the
// learned lexicon (C1 re-dictation aliases included), and Contacts only as the full names of people
// the user interacts with (`ContactEvidence`): an address book is not vocabulary, and a name in a
// VOCAB line may travel to a cloud writer.

/// Where a vocabulary term came from (the packet's `VocabularyMatch.source`).
public enum VocabularySource: String, CaseIterable, Sendable, Codable {
    case dictionary, correction, learned, contact, screen, repo, document

    /// How much a match from this source counts, 0…1.
    public var weight: Double {
        switch self {
        case .dictionary, .correction: return 1.0
        case .learned: return 0.9
        case .repo, .document: return 0.8
        case .screen, .contact: return 0.7
        }
    }
}

/// One indexable term: its written form, the spoken forms the user (or the learner) gave it, and
/// what the scorer needs. `SpokenFormVerbalizer` forms are derived when the index is built.
public struct VocabularyTerm: Hashable, Sendable {
    public var term: String
    /// Trusted spoken forms: typed in the Dictionary ("queen" for Qwen) or learned from a
    /// re-dictation ("sub variance" for subagents). A trusted form may match an ordinary English
    /// word; a derived form never does.
    public var spokenForms: [String]
    public var source: VocabularySource
    /// 0…1 (Dictionary weight, learned-lexicon weight); clamped.
    public var weight: Double
    public var lastUsed: Date?

    public init(term: String, spokenForms: [String] = [], source: VocabularySource,
                weight: Double = 1.0, lastUsed: Date? = nil) {
        self.term = term
        self.spokenForms = spokenForms
        self.source = source
        self.weight = min(1, max(0, weight))
        self.lastUsed = lastUsed
    }

    /// Dictionary rows: non-Contacts rows as `.dictionary` with their typed spoken forms; Contacts
    /// rows only when they are a full name (two or more capitalised words) **and** `contacts` holds
    /// evidence the user interacts with that person, as `.contact`, without typed forms. "Code",
    /// "Cab", "Bucket" never enter; with no evidence (the default) no Contact enters at all.
    public static func dictionary(_ entries: [DictionaryEntry], contacts: ContactEvidence = .none) -> [VocabularyTerm] {
        entries.compactMap { e in
            if e.origin == .contacts {
                guard isFullName(e.term), contacts.admits(fullName: e.term) else { return nil }
                return VocabularyTerm(term: e.term, source: .contact, weight: e.weight)
            }
            return VocabularyTerm(term: e.term, spokenForms: e.spokenForms, source: .dictionary, weight: e.weight)
        }
    }

    /// Confirmed corrections: their entity-like words and short phrases (`ContextCandidates`' split).
    public static func corrections(_ corrected: [(term: String, at: Date)]) -> [VocabularyTerm] {
        ContextCandidates.corrections(corrected).map {
            VocabularyTerm(term: $0.text, source: .correction, lastUsed: $0.observedAt)
        }
    }

    /// The learned lexicon (C1 included): every learned term, with each heard form the learner
    /// mapped to it (`PersonalLexicon.variants`, "sub variance" → subagents) as a trusted spoken
    /// form. A pair the user undid (`PersonalLexicon.negatives`) is not a spoken form; the matcher
    /// also refuses it as a match (`VocabularyMatcher.blocked`).
    public static func learned(_ lexicon: PersonalLexicon) -> [VocabularyTerm] {
        var heardByTerm: [String: [String]] = [:]
        var orphanVariants: [String: PersonalLexicon.Variant] = [:]
        for v in lexicon.variants.values.sorted(by: { $0.heard < $1.heard }) {
            let key = v.corrected.lowercased()
            guard !lexicon.isBlocked(heard: v.heard, written: v.corrected) else { continue }
            heardByTerm[key, default: []].append(v.heard)
            if lexicon.terms[key] == nil { orphanVariants[key] = v }
        }
        var out = lexicon.terms.sorted { $0.key < $1.key }.map { key, t in
            VocabularyTerm(term: t.text, spokenForms: heardByTerm[key] ?? [], source: .learned,
                           weight: max(0.3, t.weight), lastUsed: t.lastSeen)
        }
        // A variant whose written form has no term of its own (trimmed by "forget", or written by
        // an older learner) still says how that form sounds.
        for (key, v) in orphanVariants.sorted(by: { $0.key < $1.key }) {
            out.append(VocabularyTerm(term: v.corrected, spokenForms: heardByTerm[key] ?? [], source: .learned, weight: 0.3))
        }
        return out
    }

    static func isFullName(_ s: String) -> Bool {
        let words = s.split(whereSeparator: \.isWhitespace)
        return words.count >= 2 && words.allSatisfy { $0.first?.isUppercase == true && $0.dropFirst().allSatisfy(\.isLetter) }
    }
}

/// Evidence that the user interacts with a person, which a Contacts full name needs before it is
/// indexed (plan §2.4: "full names only, and only people you actually interact with"). A name
/// counts when it appears whole, as consecutive words (case and punctuation ignored, a possessive
/// "'s" dropped), in
/// * a confirmed correction's text ("send it to Akash Kothari" — the user wrote the name),
/// * the learned lexicon (a term or the written side of a learned alias), or
/// * `people`: names the App knows the user deals with. Nothing feeds it yet; the intended inputs
///   are recent thread participants (To/Cc, chat titles — `FieldContext.participants`) and
///   Contacts-origin Dictionary rows with recorded use (the complement of the rubric's
///   `neverUsed`). Pass them through `VocabularyMatcher.build(...people:)`.
/// A first or last name alone is not evidence: "Kothari" says nothing about which Kothari.
public struct ContactEvidence: Sendable, Equatable {
    public static let none = ContactEvidence()

    struct Position: Hashable, Sendable {
        var text: Int32
        var word: Int32
    }

    /// Every evidence text as normalised words, and where each word occurs: a name is looked up from
    /// its first word, so building costs one entry per evidence word and a query a few comparisons.
    private var texts: [[String]] = []
    private var occurrences: [String: [Position]] = [:]

    public init(corrections: [String] = [], learned: PersonalLexicon? = nil, people: [String] = []) {
        var all = corrections + people
        if let learned {
            all += learned.terms.values.map(\.text).sorted()
            all += learned.variants.values.map(\.corrected).sorted()
        }
        for text in all {
            let words = Self.words(text)
            guard words.count >= 2 else { continue }
            let t = Int32(texts.count)
            texts.append(words)
            for (i, w) in words.enumerated() { occurrences[w, default: []].append(Position(text: t, word: Int32(i))) }
        }
    }

    public var isEmpty: Bool { texts.isEmpty }

    /// True when `fullName` appears whole, as consecutive words, in the evidence.
    public func admits(fullName: String) -> Bool {
        let name = Self.words(fullName)
        guard name.count >= 2, let first = occurrences[name[0]] else { return false }
        for p in first {
            let words = texts[Int(p.text)], at = Int(p.word)
            guard at + name.count <= words.count else { continue }
            if words[at..<(at + name.count)].elementsEqual(name) { return true }
        }
        return false
    }

    /// Lower-cased words without surrounding punctuation or a possessive "'s".
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var w = VocabularyMatcher.clean(String(raw)).replacingOccurrences(of: "\u{2019}", with: "'")
            if w.hasSuffix("'s") { w.removeLast(2) }
            return w.isEmpty ? nil : w
        }
    }
}

/// Heard → written pairs the user undid (C1 `undoCorrection`, `PersonalLexicon.negatives`): the
/// matcher never offers `written` for exactly that heard text, whatever the term's source.
public struct BlockedVocabularyPairs: Sendable, Equatable {
    private var pairs: [String: Set<String>]

    public init(_ pairs: [String: [String]] = [:]) {
        var out: [String: Set<String>] = [:]
        for (heard, written) in pairs {
            let h = Self.normalise(heard)
            guard !h.isEmpty else { continue }
            out[h, default: []].formUnion(written.map(Self.normalise).filter { !$0.isEmpty })
        }
        self.pairs = out
    }

    public init(_ lexicon: PersonalLexicon) { self.init(lexicon.negatives) }

    public var isEmpty: Bool { pairs.isEmpty }

    /// `heard` is compared word by word with leading/trailing punctuation dropped, case-insensitively.
    public func contains(heard: String, written: String) -> Bool {
        guard !pairs.isEmpty else { return false }
        return pairs[Self.normalise(heard)]?.contains(Self.normalise(written)) ?? false
    }

    static func normalise(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).map { VocabularyMatcher.clean(String($0)) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
