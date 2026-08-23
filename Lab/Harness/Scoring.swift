import Foundation

/// Word normalisation shared by WER and entity scoring.
public enum TextNormalizer {
    /// Lowercase; keep letters, digits and inner apostrophes; everything else becomes a separator.
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                current = ""
            }
        }
        if !current.isEmpty { out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))) }
        return out.filter { !$0.isEmpty }
    }

    /// Raw tokens with surrounding punctuation stripped but case and inner symbols kept (for entities).
    public static func rawTokens(_ text: String) -> [String] {
        let strip = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_/@#+"))
        return text.split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: strip) }
            .filter { !$0.isEmpty }
    }
}

public struct WERResult: Equatable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWords: Int

    public var errors: Int { substitutions + deletions + insertions }
    /// Errors / reference words; 0 when both sides are empty.
    public var wer: Double {
        if referenceWords == 0 { return errors == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceWords)
    }
}

public enum WERScorer {
    /// Levenshtein over normalised words with substitution/deletion/insertion backtrace.
    public static func score(reference: String, hypothesis: String) -> WERResult {
        let r = TextNormalizer.words(reference), h = TextNormalizer.words(hypothesis)
        return score(reference: r, hypothesis: h)
    }

    public static func score(reference r: [String], hypothesis h: [String]) -> WERResult {
        let n = r.count, m = h.count
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let cost = r[i - 1] == h[j - 1] ? 0 : 1
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                }
            }
        }
        // Backtrace, preferring matches/substitutions so counts are stable.
        var i = n, j = m, sub = 0, del = 0, ins = 0
        while i > 0 || j > 0 {
            if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { sub += 1 }
                i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                del += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return WERResult(substitutions: sub, deletions: del, insertions: ins, referenceWords: n)
    }
}

public struct EntityResult: Equatable, Sendable {
    public var expected: [String]
    public var found: [String]
    public var falseEntities: [String]
    public var hypothesisWords: Int

    public var recall: Double? { expected.isEmpty ? nil : Double(found.count) / Double(expected.count) }
    /// Entity-looking tokens in the hypothesis that are not in the reference, per hypothesis word.
    public var falseEntityRate: Double { hypothesisWords == 0 ? 0 : Double(falseEntities.count) / Double(hypothesisWords) }
}

public enum EntityScorer {
    /// Tokens always treated as entities when they appear in a reference (the entity suite's hard list).
    public static let knownEntities: Set<String> = [
        "TeamViewer", "AG", "Kothari", "kubectl", "gpt-4o", "Anthropic", "GRDB", "FluidAudio", "Devanagari",
        "Sundar", "Pichai", "Zsh", "SQLite", "Mumbai", "swift", "git", "npm", "grep", "sudo", "nano",
    ]
    static let commonCapitalised: Set<String> = ["I", "I'm", "I'll", "I've", "I'd", "Mister", "Mr", "Mrs", "Ms", "Dr"]

    /// Heuristic entity detection on a reference transcript: known tokens, non-sentence-initial
    /// capitalised tokens, mixed-case / digit-bearing / hyphenated tokens.
    public static func detectEntities(in text: String) -> [String] {
        let raw = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var result: [String] = []
        var sentenceStart = true
        for original in raw {
            defer { sentenceStart = original.last.map { ".!?".contains($0) } ?? false }
            guard let tok = TextNormalizer.rawTokens(original).first else { continue }
            if commonCapitalised.contains(tok) { continue }
            if knownEntities.contains(tok) { result.append(tok); continue }
            let hasUpper = tok.contains { $0.isUppercase }
            let hasLowerAfterFirst = tok.dropFirst().contains { $0.isLowercase }
            let hasDigit = tok.contains { $0.isNumber }
            let innerUpper = tok.dropFirst().contains { $0.isUppercase }
            let firstUpper = tok.first?.isUppercase ?? false
            if innerUpper && hasLowerAfterFirst { result.append(tok); continue }       // camelCase, TeamViewer
            if hasUpper && tok.count > 1 && !hasLowerAfterFirst && !hasDigit { result.append(tok); continue } // AG, GRDB
            if hasDigit && hasUpper { result.append(tok); continue }
            if tok.contains("-") && (hasDigit || hasUpper) { result.append(tok); continue } // gpt-4o
            if firstUpper && !sentenceStart { result.append(tok); continue }
        }
        return Array(NSOrderedSet(array: result)) as? [String] ?? result
    }

    public static func score(reference: String, hypothesis: String, entities: [String]? = nil) -> EntityResult {
        let expected = entities ?? detectEntities(in: reference)
        let hypTokens = TextNormalizer.rawTokens(hypothesis)
        let hypSet = Set(hypTokens)
        let found = expected.filter { hypSet.contains($0) }
        let refSet = Set(TextNormalizer.rawTokens(reference))
        let hypEntities = detectEntities(in: hypothesis)
        let falseOnes = hypEntities.filter { !refSet.contains($0) }
        return EntityResult(expected: expected, found: found, falseEntities: falseOnes, hypothesisWords: hypTokens.count)
    }
}

public enum Percentile {
    /// Nearest-rank percentile (p in 0...100) on a sorted copy; 0 for empty input.
    public static func value(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }
}
