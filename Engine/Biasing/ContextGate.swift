import Foundation

// R4.1b — the consumer the ranked list has *today* (V3 §7.1).
//
// Until R5.2 wires the refinement pass, nothing in the shipping path can change a word from the
// list: the Parakeet rescorer adjusts the log-prob of tokens that were already chosen
// (`Engine/Biasing/README.md`). So the list's first real job is a **gate check**: is a second pass
// worth its deadline for this segment? The two signals are pass-1 confidence and whether the
// hypothesis contains a word that sounds like a term in the list but is not that term — the exact
// case a context-primed second pass is supposed to fix.
//
// R5.3 owns the shipped policy and its tunable thresholds; this is the check, kept next to the
// list it reads. Every field of `Decision` is a count or an enum: a decision can be logged, the
// list it came from cannot (V3 §7.3).

/// Should this segment get a second, context-primed pass?
public struct ContextGate: Sendable {

    public struct Thresholds: Sendable, Equatable {
        /// Pass-1 confidence at or below which a second pass is always worth it.
        public var lowConfidence: Float
        /// Phonetic-neighbour similarity (1 − normalised edit distance) that counts as a near miss.
        /// Only words whose double-metaphone code already matches are scored, so this is the second
        /// of two filters, not the only one: "Katari's"/"Kothari" is 0.57, "Prea"/"Priya" 0.60.
        public var minSimilarity: Float
        /// A near miss must be at least this long, so "a"/"the" cannot trip the gate.
        public var minWordCharacters: Int

        public init(lowConfidence: Float = 0.5, minSimilarity: Float = 0.55, minWordCharacters: Int = 4) {
            self.lowConfidence = lowConfidence
            self.minSimilarity = minSimilarity
            self.minWordCharacters = minWordCharacters
        }

        public static let `default` = Thresholds()
    }

    public enum Reason: String, Sendable, Equatable {
        /// No usable prompt: nothing to prime a second pass with beyond the audio.
        case noContext
        /// Pass-1 was not confident about this segment.
        case lowConfidence
        /// A hypothesis word sounds like a term in the list but is not it.
        case contextNearMiss
        /// Confident, and nothing in the hypothesis looks like a missed context term.
        case confidentAndNoNearMiss
    }

    public struct Decision: Sendable, Equatable {
        public var shouldRefine: Bool
        public var reason: Reason
        /// Terms in the prompt (not the terms).
        public var promptTerms: Int
        /// Hypothesis words that are phonetic neighbours of a list term without matching it.
        public var nearMisses: Int
        public var confidence: Float

        /// Term-free, safe to log.
        public var summary: String {
            String(format: "refine=%@ reason=%@ terms=%d nearMisses=%d conf=%.2f",
                   shouldRefine ? "yes" : "no", reason.rawValue, promptTerms, nearMisses, confidence)
        }
    }

    public var thresholds: Thresholds

    public init(thresholds: Thresholds = .default) { self.thresholds = thresholds }

    /// Decide for one segment. `hypothesis` is pass-1 text; `context` the ranked list for this
    /// utterance; `prompt` the string `PromptBuilder` produced from it (passing it in keeps the
    /// gate honest: the terms the model will *not* see cannot make the gate fire).
    public func decide(hypothesis: String, confidence: Float, context: RankedContext,
                       prompt: PromptBuilder.Result) -> Decision {
        let terms = prompt.included
        guard terms > 0 else {
            return Decision(shouldRefine: false, reason: .noContext, promptTerms: 0,
                            nearMisses: 0, confidence: confidence)
        }
        // V5 P4 — phoneme path (CMUdict) beside Double Metaphone once the user downloaded it; nil → metaphone only.
        let misses = Self.nearMisses(hypothesis: hypothesis, context: context, thresholds: thresholds,
                                     lexicon: PhonemeLexicon.installed())
        if confidence <= thresholds.lowConfidence {
            return Decision(shouldRefine: true, reason: .lowConfidence, promptTerms: terms,
                            nearMisses: misses.count, confidence: confidence)
        }
        if !misses.isEmpty {
            return Decision(shouldRefine: true, reason: .contextNearMiss, promptTerms: terms,
                            nearMisses: misses.count, confidence: confidence)
        }
        return Decision(shouldRefine: false, reason: .confidentAndNoNearMiss, promptTerms: terms,
                        nearMisses: 0, confidence: confidence)
    }

    /// Convenience: build the prompt and decide in one call.
    public func decide(hypothesis: String, confidence: Float, context: RankedContext,
                       builder: PromptBuilder = PromptBuilder()) -> Decision {
        decide(hypothesis: hypothesis, confidence: confidence, context: context,
               prompt: builder.build(context))
    }

    // MARK: - Near misses

    /// One hypothesis word that sounds like a list term but is not it.
    public struct NearMiss: Sendable, Equatable {
        public var heard: String
        public var candidate: String
        public var similarity: Float
    }

    /// Reference-blind: uses only the hypothesis and the list. A word that *is* a list term is not
    /// a near miss; a word that is a phonetic neighbour of one is.
    public static func nearMisses(hypothesis: String, context: RankedContext,
                                  thresholds: Thresholds = .default) -> [NearMiss] {
        guard !context.isEmpty else { return [] }
        let index = PhoneticContextIndex(context: context)
        var out: [NearMiss] = []
        for word in hypothesis.split(whereSeparator: { $0.isWhitespace }) {
            var token = String(word)
            while let last = token.last, ".,;:!?\"')".contains(last) { token.removeLast() }
            while let first = token.first, "\"'(".contains(first) { token.removeFirst() }
            guard token.count >= thresholds.minWordCharacters else { continue }
            guard let hit = index.neighbour(of: token, minSimilarity: thresholds.minSimilarity) else { continue }
            out.append(hit)
        }
        return out
    }
}

/// Double-metaphone index over a ranked list, so looking a word up is a dictionary hit rather than
/// four hundred edit distances.
public struct PhoneticContextIndex: Sendable {
    private let metaphone: DoubleMetaphone
    private var byCode: [String: [String]] = [:]
    private var exact: Set<String> = []

    public init(context: RankedContext, metaphoneLength: Int = 6) {
        self.metaphone = DoubleMetaphone(maxLength: metaphoneLength)
        for term in context.terms {
            // Index single words: a hypothesis token can only ever match one.
            for word in term.text.split(whereSeparator: { $0.isWhitespace }) {
                let text = String(word)
                guard text.count >= 3 else { continue }
                exact.insert(Self.normalize(text))
                let codes = metaphone.encode(text)
                byCode[codes.primary, default: []].append(text)
                if let secondary = codes.secondary, secondary != codes.primary {
                    byCode[secondary, default: []].append(text)
                }
            }
        }
    }

    public var isEmpty: Bool { byCode.isEmpty }

    /// True when the list already contains this word verbatim (modulo case and punctuation).
    public func containsExactly(_ word: String) -> Bool { exact.contains(Self.normalize(word)) }

    /// The best list word that sounds like `word` without being it, or nil.
    ///
    /// Tries the word as heard first, then — because "Kothari's" and "Kothari" have different
    /// metaphone codes and English attaches possessives to exactly the nouns a context list is made
    /// of — the word with a trailing `s` removed.
    public func neighbour(of word: String, minSimilarity: Float) -> ContextGate.NearMiss? {
        if let hit = lookup(word, minSimilarity: minSimilarity) { return hit }
        let key = Self.normalize(word)
        guard key.count > 3, key.hasSuffix("s") else { return nil }
        guard let hit = lookup(String(key.dropLast()), minSimilarity: minSimilarity) else { return nil }
        return ContextGate.NearMiss(heard: word, candidate: hit.candidate, similarity: hit.similarity)
    }

    private func lookup(_ word: String, minSimilarity: Float) -> ContextGate.NearMiss? {
        let key = Self.normalize(word)
        guard !key.isEmpty, !exact.contains(key) else { return nil }
        let codes = metaphone.encode(word)
        var candidates = byCode[codes.primary] ?? []
        if let secondary = codes.secondary, secondary != codes.primary {
            candidates += byCode[secondary] ?? []
        }
        var best: ContextGate.NearMiss?
        for candidate in candidates {
            let similarity = AlternateEnricher.similarity(key, Self.normalize(candidate))
            guard similarity >= minSimilarity else { continue }
            if let current = best, current.similarity >= similarity { continue }
            best = ContextGate.NearMiss(heard: word, candidate: candidate, similarity: similarity)
        }
        return best
    }

    static func normalize(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }.map(Character.init))
    }
}
