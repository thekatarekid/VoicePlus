import Foundation

// R4.1b — how the ranked list is *measured* before a model can consume it.
//
// The acceptance for this item is a number: entity recall and false insertions on the real-room
// corpus, with and without the list. Nothing in the shipping path can produce that number yet —
// the rescorer cannot substitute a word (`README.md`) and the refinement pass lands in R5.2. So
// the list is measured against a deliberately dumb, **reference-blind** stand-in for what a
// context-primed second pass does: a hypothesis word that sounds like a term in the list, and is
// not that term, becomes that term.
//
// What that measures honestly: how much of the corpus's entity error the list is *positioned* to
// fix, and how much damage the same list does when a term hijacks a word that was already right —
// the false-insertion side, which is the reason the cap and the tier order exist. What it does not
// measure: Qwen3's actual behaviour with the prompt. That is R5.4's benchmark, on the same corpus.
//
// This type is not installed in the pipeline by anything, and must not be: it is a measurement
// instrument. `ContextGate` is the shipping consumer today.

/// Reference-blind stand-in consumer, used only by the Lab/Engine measurements.
public struct ContextRecallProbe: Sendable {
    public var thresholds: ContextGate.Thresholds

    public init(thresholds: ContextGate.Thresholds = .default) {
        self.thresholds = thresholds
    }

    /// One rewritten hypothesis word.
    public struct Substitution: Sendable, Equatable {
        public var heard: String
        public var written: String
        public var similarity: Float
    }

    public struct Resolution: Sendable, Equatable {
        public var text: String
        public var substitutions: [Substitution]
        public var count: Int { substitutions.count }
    }

    /// Rewrite `hypothesis` using the list only — never the reference.
    public func resolve(hypothesis: String, context: RankedContext) -> Resolution {
        guard !context.isEmpty else { return Resolution(text: hypothesis, substitutions: []) }
        let index = PhoneticContextIndex(context: context)
        var substitutions: [Substitution] = []
        var pieces: [String] = []
        for raw in hypothesis.split(separator: " ", omittingEmptySubsequences: false) {
            let token = String(raw)
            let (leading, core, trailing) = Self.split(token)
            guard core.count >= thresholds.minWordCharacters,
                  let hit = index.neighbour(of: core, minSimilarity: thresholds.minSimilarity) else {
                pieces.append(token)
                continue
            }
            var replacement = Self.matchingCase(of: core, in: hit.candidate)
            // A possessive heard as a near miss stays a possessive: "Katari's" → "Kothari's".
            if core.lowercased().hasSuffix("'s"), !replacement.lowercased().hasSuffix("'s") {
                replacement += "'s"
            }
            substitutions.append(Substitution(heard: core, written: replacement, similarity: hit.similarity))
            pieces.append(leading + replacement + trailing)
        }
        return Resolution(text: pieces.joined(separator: " "), substitutions: substitutions)
    }

    /// `("(", "Kothari", "'s,")` → leading punctuation, word core, trailing remainder.
    static func split(_ token: String) -> (String, String, String) {
        var leading = ""
        var rest = Substring(token)
        while let first = rest.first, !first.isLetter, !first.isNumber {
            leading.append(first)
            rest = rest.dropFirst()
        }
        var trailing = ""
        while let last = rest.last, !last.isLetter, !last.isNumber {
            trailing = String(last) + trailing
            rest = rest.dropLast()
        }
        return (leading, String(rest), trailing)
    }

    /// Keep the sentence's capitalisation: a list term inserted mid-sentence should not shout.
    static func matchingCase(of heard: String, in candidate: String) -> String {
        guard let heardFirst = heard.first, let candidateFirst = candidate.first else { return candidate }
        if heardFirst.isUppercase, candidateFirst.isLowercase {
            return candidateFirst.uppercased() + candidate.dropFirst()
        }
        return candidate
    }
}
