import Foundation
import Shared

// Context Writer §2.4 — what the vocabulary matcher indexes: the user's own terms, each with the
// spoken forms that say it. Sources: the Dictionary (non-Contacts rows), confirmed corrections, the
// learned lexicon (C1 re-dictation aliases included), and Contacts only as full names.

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
    /// rows only when they are a full name (two or more capitalised words), as `.contact`, and
    /// without typed forms. "Code", "Cab", "Bucket" never enter.
    public static func dictionary(_ entries: [DictionaryEntry]) -> [VocabularyTerm] {
        entries.compactMap { e in
            if e.origin == .contacts {
                guard isFullName(e.term) else { return nil }
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
