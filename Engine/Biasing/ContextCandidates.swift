import Foundation
import Shared

// N11 — context providers → typed candidates (Investigation R3 §E2). Generic: a provider hands
// over plain data (Dictionary rows, corrections, a `ShellContext`, a surface lexicon, field / window
// text) and gets `ContextCandidate`s back. No app names, no reads here.

public enum ContextCandidates {
    /// Kivi-style cap on terms taken from screen text.
    public static let maxScreenTerms = 300
    /// Characters from the caret within which a visible term counts as "near".
    public static let nearRadius = 400

    /// Dictionary rows. Contacts-origin rows become `.contact` (admitted only on conversational
    /// surfaces by the rubric); everything else `.dictionary`. `neverUsed` marks rows with no usage.
    public static func dictionary(_ entries: [DictionaryEntry], neverUsed: Set<String> = []) -> [ContextCandidate] {
        entries.map { e in
            let contact = e.origin == .contacts
            return ContextCandidate(text: e.term, type: contact ? .person : nil,
                                    source: contact ? .contact : .dictionary,
                                    evidence: min(1, max(0.3, e.weight)),
                                    neverUsed: neverUsed.contains(e.term.lowercased()))
        }
    }

    /// Corrected phrases: only their entity-like words, plus short phrases kept whole.
    public static func corrections(_ corrected: [(term: String, at: Date)]) -> [ContextCandidate] {
        var out: [ContextCandidate] = []
        for (term, at) in corrected {
            let words = term.split(whereSeparator: \.isWhitespace)
            if words.count <= 3, EntityExtractor.isEntityLike(term) || words.count == 1 {
                out.append(ContextCandidate(text: term, source: .correction, observedAt: at))
            } else {
                for e in EntityExtractor.extract(from: term) {
                    out.append(ContextCandidate(text: e, source: .correction, observedAt: at))
                }
            }
        }
        return out
    }

    /// F26 / N13: the shell's commands and the current folder's entries (not recursive).
    public static func shell(_ shell: ShellContext, observedAt: Date = Date(), maxCommands: Int = 400) -> [ContextCandidate] {
        var out: [ContextCandidate] = []
        for cmd in shell.allCommands.sorted().prefix(maxCommands) {
            out.append(ContextCandidate(text: cmd, type: .command, source: .surfaceLexicon,
                                        observedAt: observedAt, lexiconSurface: .terminal))
        }
        for e in shell.entries where !e.name.hasPrefix(".") {
            out.append(ContextCandidate(text: e.name, type: .path, source: .surfaceLexicon,
                                        observedAt: observedAt, lexiconSurface: .terminal))
        }
        return out
    }

    /// Any surface lexicon (formula functions, code symbols, visible column headers, domains).
    public static func lexicon(_ terms: [String], type: CandidateType, surface: SurfaceKind,
                               observedAt: Date = Date(), evidence: Double = 1) -> [ContextCandidate] {
        terms.map { ContextCandidate(text: $0, type: type, source: .surfaceLexicon, observedAt: observedAt,
                                     evidence: evidence, lexiconSurface: surface) }
    }

    /// Thread participants (chat / email only, enforced by the rubric).
    public static func participants(_ names: [String], observedAt: Date = Date()) -> [ContextCandidate] {
        names.map { ContextCandidate(text: $0, type: .person, source: .participant, observedAt: observedAt) }
    }

    /// Recent dictations in one app: their entity-like words.
    public static func recentDictations(_ texts: [(text: String, at: Date)], app: String?) -> [ContextCandidate] {
        texts.flatMap { item in
            EntityExtractor.extract(from: item.text).map {
                ContextCandidate(text: $0, source: .recentDictation, observedAt: item.at, app: app)
            }
        }
    }

    /// Screen / field text → typed terms, capped, each with its distance from the caret.
    /// `caretOffset` is the caret's character offset in `text` (nil = window text, no caret).
    /// Data, never instructions: only terms are kept, never sentences.
    public static func screen(text: String, caretOffset: Int? = nil, observedAt: Date = Date(),
                              salience: Double = 1, maxTerms: Int = ContextCandidates.maxScreenTerms) -> [ContextCandidate] {
        let weighted = EntityExtractor.extractWeighted(from: text, maxTerms: maxTerms)
        var out: [ContextCandidate] = []
        for (term, strength) in weighted {
            var distance: Int?
            if let caret = caretOffset, let r = nearestRange(of: term, in: text, to: caret) {
                distance = r
            }
            let near = distance.map { $0 <= nearRadius } ?? false
            out.append(ContextCandidate(text: term, source: near ? .screenNear : .screenWindow,
                                        caretDistance: distance, observedAt: observedAt,
                                        evidence: strength * salience, onScreenNow: true))
        }
        return out
    }

    /// Distance in characters from `caret` to the nearest occurrence of `term`.
    static func nearestRange(of term: String, in text: String, to caret: Int) -> Int? {
        var best: Int?
        var searchStart = text.startIndex
        while let r = text.range(of: term, range: searchStart..<text.endIndex) {
            let lo = text.distance(from: text.startIndex, to: r.lowerBound)
            let hi = text.distance(from: text.startIndex, to: r.upperBound)
            let d = caret < lo ? lo - caret : (caret > hi ? caret - hi : 0)
            best = min(best ?? d, d)
            searchStart = r.upperBound
        }
        return best
    }

    /// Legacy harvest entries (`ContextHarvester`) → candidates.
    public static func entries(_ entries: [ContextEntry]) -> [ContextCandidate] {
        entries.map { e in
            let source: CandidateSource
            switch e.source {
            case .corrections: source = .correction
            case .dictionary: source = .dictionary
            case .axTree, .codeSymbols: source = .screenWindow
            case .recentWords: source = .recentDictation
            case .participants: source = .participant
            case .contacts: source = .contact
            }
            return ContextCandidate(text: e.text, type: e.source == .contacts ? .person : nil, source: source,
                                    observedAt: e.observedAt, evidence: e.salience)
        }
    }
}
