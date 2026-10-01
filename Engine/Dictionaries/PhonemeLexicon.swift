import Foundation
import Shared

/// V5 P4 — the CMU Pronouncing Dictionary (BSD-2-Clause): word → ARPAbet phonemes, stress stripped.
///
/// Not bundled (3.6 MB): the user downloads it from Settings › Dictionary › Public word lists into
/// `~/Library/Application Support/VoicePlus/Dictionaries/cmudict.dict`; until then the phoneme path
/// is simply absent and matching is Double Metaphone alone, exactly as before.
public struct PhonemeLexicon: Sendable {
    private var entries: [String: [[String]]] = [:]

    /// Parses `cmudict.dict` lines: `word PH1 PH2 …`, `word(2) …` for variants, `# …` comments.
    public init(cmudictText text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, first != "#", first != ";" else { continue }
            let body = line.split(separator: "#", maxSplits: 1).first ?? line
            let parts = body.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            var word = String(parts[0]).lowercased()
            if let paren = word.firstIndex(of: "("), word.hasSuffix(")") { word = String(word[..<paren]) }
            let phones = parts.dropFirst().map { String($0.filter { !$0.isNumber }) }
            if !entries[word, default: []].contains(phones) { entries[word, default: []].append(phones) }
        }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Every pronunciation of `word` (case-insensitive; edge punctuation and a possessive `'s`
    /// tolerated). Empty when the word is not in the dictionary.
    public func pronunciations(of word: String) -> [[String]] {
        let key = Self.key(word)
        if let hit = entries[key] { return hit }
        if key.hasSuffix("'s"), let stem = entries[String(key.dropLast(2))] { return stem.map { $0 + ["Z"] } }
        return []
    }

    static func key(_ word: String) -> String {
        var w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        while let c = w.first, !c.isLetter { w.removeFirst() }
        while let c = w.last, !c.isLetter { w.removeLast() }
        return w
    }

    /// 1 − (phoneme edit distance / longer length), best over both words' variants.
    public func similarity(_ a: String, _ b: String) -> Float? {
        let pa = pronunciations(of: a), pb = pronunciations(of: b)
        guard !pa.isEmpty, !pb.isEmpty else { return nil }
        var best: Float = 0
        for x in pa { for y in pb { best = max(best, Self.similarity(x, y)) } }
        return best
    }

    static func similarity(_ a: [String], _ b: [String]) -> Float {
        let n = max(a.count, b.count)
        guard n > 0 else { return 1 }
        return 1 - Float(levenshtein(a, b)) / Float(n)
    }

    static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: Installed copy

    /// `~/Library/Application Support/VoicePlus/Dictionaries/cmudict.dict` (see `PublicDictionaryCatalog.cmudict`).
    public static func installedURL() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("Dictionaries/cmudict.dict")
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (path: String, modified: Date?, lexicon: PhonemeLexicon?)?

    /// The downloaded dictionary, parsed once per file version; nil when not downloaded.
    public static func installed(at url: URL = installedURL()) -> PhonemeLexicon? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return cacheLock.withLock {
            if let cached, cached.path == url.path, cached.modified == modified { return cached.lexicon }
            let lexicon = modified == nil ? nil : (try? String(contentsOf: url, encoding: .utf8)).map(PhonemeLexicon.init(cmudictText:))
            cached = (url.path, modified, lexicon?.isEmpty == false ? lexicon : nil)
            return cached?.lexicon
        }
    }
}

/// V5 P4 — the phoneme path beside Double Metaphone: indexes the ranked context's words that have a
/// CMUdict pronunciation, and finds the one a heard word *sounds* like even when the spellings
/// share no metaphone code ("Shawn" → "Sean", "neve" → "Niamh").
public struct PhonemeContextIndex: Sendable {
    private let lexicon: PhonemeLexicon
    private var terms: [(text: String, phones: [[String]])] = []
    private var exact: Set<String> = []

    public init(context: RankedContext, lexicon: PhonemeLexicon) {
        self.lexicon = lexicon
        for term in context.terms {
            for word in term.text.split(whereSeparator: { $0.isWhitespace }) {
                let text = String(word)
                guard text.count >= 3 else { continue }
                exact.insert(PhonemeLexicon.key(text))
                let phones = lexicon.pronunciations(of: text)
                if !phones.isEmpty, !terms.contains(where: { $0.text == text }) { terms.append((text, phones)) }
            }
        }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// The context word whose pronunciation is closest to `word`'s (≥ `minSimilarity`), or nil.
    public func neighbour(of word: String, minSimilarity: Float) -> ContextGate.NearMiss? {
        let key = PhonemeLexicon.key(word)
        guard !key.isEmpty, !exact.contains(key) else { return nil }
        let heard = lexicon.pronunciations(of: word)
        guard !heard.isEmpty else { return nil }
        var best: ContextGate.NearMiss?
        for term in terms {
            var score: Float = 0
            for h in heard { for t in term.phones { score = max(score, PhonemeLexicon.similarity(h, t)) } }
            guard score >= minSimilarity else { continue }
            if let current = best, current.similarity >= score { continue }
            best = ContextGate.NearMiss(heard: word, candidate: term.text, similarity: score)
        }
        return best
    }
}

/// V5 P4 — Double Metaphone and, when CMUdict is installed, phonemes; the better hit wins.
public struct CombinedPhoneticIndex: Sendable {
    public let metaphone: PhoneticContextIndex
    public let phonemes: PhonemeContextIndex?
    /// Phoneme matches are stricter than spelling ones: a shared sound skeleton is strong evidence,
    /// but short words share most of theirs.
    public var minPhonemeSimilarity: Float

    public init(context: RankedContext, lexicon: PhonemeLexicon? = PhonemeLexicon.installed(), minPhonemeSimilarity: Float = 0.75) {
        metaphone = PhoneticContextIndex(context: context)
        phonemes = lexicon.map { PhonemeContextIndex(context: context, lexicon: $0) }
        self.minPhonemeSimilarity = minPhonemeSimilarity
    }

    public func neighbour(of word: String, minSimilarity: Float) -> ContextGate.NearMiss? {
        let spelled = metaphone.neighbour(of: word, minSimilarity: minSimilarity)
        guard let phonemes, let sounded = phonemes.neighbour(of: word, minSimilarity: minPhonemeSimilarity) else { return spelled }
        guard let spelled else { return sounded }
        return sounded.similarity > spelled.similarity ? sounded : spelled
    }
}

public extension ContextGate {
    /// `nearMisses(hypothesis:context:thresholds:)` with the V5 P4 phoneme path beside Double
    /// Metaphone. With `lexicon == nil` it is exactly the metaphone-only answer.
    static func nearMisses(hypothesis: String, context: RankedContext, thresholds: Thresholds = .default,
                           lexicon: PhonemeLexicon?) -> [NearMiss] {
        guard let lexicon else { return nearMisses(hypothesis: hypothesis, context: context, thresholds: thresholds) }
        guard !context.isEmpty else { return [] }
        let index = CombinedPhoneticIndex(context: context, lexicon: lexicon)
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
