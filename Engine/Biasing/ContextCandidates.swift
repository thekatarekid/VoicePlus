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

    /// H17 / H18 — the focused field's text either side of the caret (the key-down read, already
    /// bounded to a UTF-16 window) → `.screenNear` candidates, each with its distance from the caret
    /// in UTF-16 units. Data, never instructions: only terms and short phrases are kept.
    ///
    /// - Entity-like words (Capitalised, camelCase, with digits / `-` / `_` / `.`) and capitalised
    ///   runs; a single word that is an ordinary English word ("Will", "Code") is left out — near
    ///   the caret it is usually a sentence start, and boosting it rewrites what the user said.
    /// - Uncommon plain words (≥ 4 letters, e.g. `kubectl`) at lower evidence.
    /// - H18: lowercase 2–3-word phrases close to the caret ("hold to talk") at lower evidence.
    /// - Each term carries its heard aliases ("hold-to-talk" ↔ "hold to talk").
    public static func nearCaret(before: String, after: String, observedAt: Date = Date(),
                                 maxTerms: Int = 40, phraseRadius: Int = 160,
                                 maxPhrases: Int = 6) -> [ContextCandidate] {
        var found: [String: ContextCandidate] = [:]
        var order: [String] = []
        func add(_ text: String, distance: Int, evidence: Double, aliases: [String]) {
            let k = text.lowercased()
            if let e = found[k] {
                if distance < (e.caretDistance ?? .max) { found[k]?.caretDistance = distance }
                return
            }
            found[k] = ContextCandidate(text: text, source: .screenNear, caretDistance: distance, observedAt: observedAt,
                                        evidence: evidence, onScreenNow: true, heardAliases: aliases)
            order.append(k)
        }
        var phrases: [(text: String, d: Int)] = []
        for side in [NearCaretWords.split(before, isBefore: true), NearCaretWords.split(after, isBefore: false)] {
            var run: [NearCaretWords.Word] = []
            func flushRun() {
                if run.count >= 2 {
                    add(run.map(\.text).joined(separator: " "), distance: run.map(\.distance).min() ?? 0,
                        evidence: 1, aliases: [])
                }
                run.removeAll()
            }
            for (idx, w) in side.enumerated() {
                let t = w.text
                guard t.count >= 2, t.count <= 40, t.first?.isLetter == true else { flushRun(); continue }
                if t.first!.isUppercase, !EntityExtractor.stop.contains(t.lowercased()) { run.append(w) } else { flushRun() }
                if w.breakAfter { flushRun() }
                let common = CollisionLexicon.isCommonWord(t)
                if EntityExtractor.isEntityLike(t), !common {
                    add(t, distance: w.distance, evidence: 1, aliases: HeardAliases.aliases(for: t))
                } else if t.count >= 4, !common, !EntityExtractor.stop.contains(t.lowercased()), t.allSatisfy(\.isLetter) {
                    add(t, distance: w.distance, evidence: 0.35, aliases: [])
                }
                // H18 — lowercase phrases close to the caret.
                for n in 2...3 where idx + n <= side.count {
                    let span = Array(side[idx..<(idx + n)])
                    guard span.dropLast().allSatisfy({ !$0.breakAfter }),
                          span.allSatisfy({ w in !w.text.isEmpty && w.text.allSatisfy { $0.isLetter && $0.isLowercase } }),
                          !EntityExtractor.stop.contains(span.first!.text), !EntityExtractor.stop.contains(span.last!.text),
                          span.reduce(0, { $0 + $1.text.count }) >= 8,
                          let d = span.map(\.distance).min(), d <= phraseRadius else { continue }
                    phrases.append((span.map(\.text).joined(separator: " "), d))
                }
            }
            flushRun()
        }
        var out = order.compactMap { found[$0] }.sorted { ($0.caretDistance ?? 0) < ($1.caretDistance ?? 0) }
        out = Array(out.prefix(maxTerms))
        var taken = Set(out.map { $0.text.lowercased() })
        var phraseCount = 0
        for p in phrases.sorted(by: { $0.d < $1.d }) where phraseCount < maxPhrases {
            guard taken.insert(p.text).inserted else { continue }
            out.append(ContextCandidate(text: p.text, type: .word, source: .screenNear, caretDistance: p.d,
                                        observedAt: observedAt, evidence: 0.35, onScreenNow: true))
            phraseCount += 1
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
