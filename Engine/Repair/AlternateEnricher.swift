import Foundation
import Shared

/// T2 — where the beam is weak (fewer than `minBeamAlternates` alternates, or none above
/// `minBeamScore`), generate candidates from the bias vocabulary and the user dictionary
/// using Double Metaphone phonetic matching plus a Levenshtein tie-breaker.
///
/// Candidate scoring (0…1): phonetic match on primary code 0.6, on secondary 0.5, plus
/// up to 0.4 for orthographic similarity (`1 - lev/maxLen`). Candidates with no phonetic
/// match still qualify when orthographic similarity ≥ `minSimilarity`.
///
/// V5 B3 — generated variants are added *after* the span's real alternates (`merge`).
public struct AlternateEnricher: Sendable {
    public var biasVocabulary: [String]
    public var userDictionary: [String]
    public var minBeamAlternates: Int
    public var minBeamScore: Float
    public var minSimilarity: Float
    public var limit: Int
    public var metaphoneLength: Int

    private let biasCodes: [(word: String, codes: DoubleMetaphone.Codes)]
    private let dictCodes: [(word: String, codes: DoubleMetaphone.Codes)]

    public init(biasVocabulary: [String] = [], userDictionary: [String] = [], minBeamAlternates: Int = 2,
                minBeamScore: Float = 0.15, minSimilarity: Float = 0.6, limit: Int = 5, metaphoneLength: Int = 6) {
        self.biasVocabulary = biasVocabulary
        self.userDictionary = userDictionary
        self.minBeamAlternates = minBeamAlternates
        self.minBeamScore = minBeamScore
        self.minSimilarity = minSimilarity
        self.limit = limit
        self.metaphoneLength = metaphoneLength
        let dm = DoubleMetaphone(maxLength: metaphoneLength)
        biasCodes = biasVocabulary.map { ($0, dm.encode($0)) }
        dictCodes = userDictionary.map { ($0, dm.encode($0)) }
    }

    /// True when the existing alternates are not good enough to show on their own.
    public func beamIsWeak(_ alternates: [Alternate]) -> Bool {
        let strong = alternates.filter { $0.score >= minBeamScore }
        return strong.count < minBeamAlternates
    }

    /// Enrich a single low-confidence span. High-confidence spans pass through untouched.
    public func enrich(_ span: TranscriptSpan, force: Bool = false) -> TranscriptSpan {
        guard span.isLowConfidence || force else { return span }
        guard force || beamIsWeak(span.alternates) else { return span }
        var out = span
        out.alternates = merge(existing: span.alternates, generated: candidates(for: span.text))
        return out
    }

    public func enrich(_ spans: [TranscriptSpan]) -> [TranscriptSpan] { spans.map { enrich($0) } }

    /// Phonetic + orthographic neighbours of `word` from both vocabularies, best first.
    public func candidates(for word: String) -> [Alternate] {
        let dm = DoubleMetaphone(maxLength: metaphoneLength)
        let target = dm.encode(word)
        let key = WordConfusionNetwork.normalize(word)
        var scored: [(Alternate, Float)] = []
        func consider(_ entries: [(word: String, codes: DoubleMetaphone.Codes)], source: Alternate.Source) {
            for (candidate, codes) in entries {
                if WordConfusionNetwork.normalize(candidate) == key { continue }
                var score: Float = 0
                if codes.primary == target.primary { score = 0.6 }
                else if codes.matches(target) { score = 0.5 }
                let sim = Self.similarity(key, WordConfusionNetwork.normalize(candidate))
                if score == 0 && sim < minSimilarity { continue }
                score += 0.4 * sim
                scored.append((Alternate(text: candidate, score: score, source: source), score))
            }
        }
        consider(dictCodes, source: .userDictionary)
        consider(biasCodes, source: .biasing)
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }
            .map(\.0)
            .filter { seen.insert(WordConfusionNetwork.normalize($0.text)).inserted }
            .prefix(limit).map { $0 }
    }

    /// V5 B3 — the recogniser's own candidates (joint top-K / beam, in their order) come first;
    /// dictionary and bias-vocabulary variants are appended second, never ahead of them, best
    /// first, deduplicated. When real candidates fill `limit`, the last slot still goes to the best
    /// generated variant so a Dictionary term stays reachable.
    func merge(existing: [Alternate], generated: [Alternate]) -> [Alternate] {
        var seen = Set<String>()
        var real: [Alternate] = []
        for alt in existing where seen.insert(WordConfusionNetwork.normalize(alt.text)).inserted { real.append(alt) }
        var extra: [Alternate] = []
        for alt in generated.sorted(by: { $0.score > $1.score })
        where seen.insert(WordConfusionNetwork.normalize(alt.text)).inserted { extra.append(alt) }
        guard limit > 0 else { return [] }
        if !extra.isEmpty, real.count >= limit { return Array(real.prefix(limit - 1)) + [extra[0]] }
        return Array((real + extra).prefix(limit))
    }

    /// 1 - normalised Levenshtein distance.
    public static func similarity(_ a: String, _ b: String) -> Float {
        let n = max(a.count, b.count)
        guard n > 0 else { return 1 }
        return 1 - Float(levenshtein(a, b)) / Float(n)
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
