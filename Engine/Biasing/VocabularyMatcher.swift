import Foundation
import Shared

// Context Writer §2.4 — personal vocabulary matching, no model, milliseconds.
//
// The packet builder hands the raw 1-best with per-word confidence; this finds the user's own
// terms that *sound like* the uncertain parts. Every uncertain word and every 1–4-word window
// holding one is encoded (Double Metaphone, heard digits read as words: "4o" → "four o"), its
// phonetic neighbours are looked up in `PhoneticVocabularyIndex`, and each candidate is scored
//
//     match = phonetic closeness × (½ + ½ spelling similarity)          (gated by `minMatch`)
//     score = match × (½ + ½ term weight) × source weight × recency     (ranked; `minScore` floor)
//
// then deduplicated by written term and cut to the top N `ContextPacket.VocabularyMatch` evidence
// lines. The writer decides whether a candidate fits the sentence; nothing here rewrites text.
//
// Precision rules: an ordinary word alone matches only a trusted spoken form it sounds exactly like
// ("queen" → Qwen, typed or learned) — "ordinary" by how the token is said: a dictionary word, a
// contraction or possessive of one ("can't", "it's", "we're"), or a plain number ("1", "10",
// "3.5", "1st", "90s"), so "can't" never offers Kant nor "10" Tenn; a window of ordinary words must
// also spell an untrusted form ("super base" → Supabase, never "on a" → ANE); a window must be
// tight — dropping any one of its words, first, last or interior, must make the match worse ("a
// cab" never stands in for "cab", "akash to kotari" never for "Akash Kothari"); a heard → written
// pair the user undid (C1 negative alias) is never offered. Privacy: nothing is logged; Contacts
// enter only as full names of people the user interacts with (`ContactEvidence`).

/// The `VocabularyMatching` implementation the packet builder calls per dictation.
public struct VocabularyMatcher: VocabularyMatching, Sendable {
    public struct Config: Sendable, Equatable {
        /// Longest heard window compared, in heard words (plan §2.4: 1–4).
        public var maxWindowWords = 4
        /// Match quality (phonetic closeness × (½ + ½ spelling)) below which a form is not a match.
        public var minMatch = 0.55
        /// Final score below which a match is dropped.
        public var minScore = 0.25
        /// A window made only of ordinary words ("super base", "on a") matches an untrusted form
        /// only when it also spells it this closely: short common words share codes with everything,
        /// so their sound alone is no evidence ("on a" ≠ ANE), while a split spells the term
        /// ("super base" → Supabase, "paper clip" → Paperclip).
        public var minCommonWordsSpelling = 0.6
        /// Recency decays to a floor of 0.6 with this half-life.
        public var recencyHalfLife: TimeInterval = 30 * 24 * 3600
        public init() {}
    }

    public let index: PhoneticVocabularyIndex
    public var config: Config
    /// Heard → written pairs the user undid; never offered.
    public var blocked: BlockedVocabularyPairs

    public init(index: PhoneticVocabularyIndex, config: Config = Config(), blocked: BlockedVocabularyPairs = .init()) {
        self.index = index
        self.config = config
        self.blocked = blocked
    }

    public init(terms: [VocabularyTerm], config: Config = Config(), blocked: BlockedVocabularyPairs = .init()) {
        self.init(index: PhoneticVocabularyIndex(terms: terms), config: config, blocked: blocked)
    }

    /// The integrator's factory: the matcher over everything the user taught us.
    /// - Parameters:
    ///   - entries: Dictionary rows with origin and typed spoken forms (`DictionaryOrigins.entries`).
    ///     Contacts rows count only as full names of people the user interacts with
    ///     (`ContactEvidence`: the name appears in `corrections`, `learned` or `people`).
    ///   - corrections: confirmed corrections (`DatabaseCorrectionStore.correctedTerms()`).
    ///   - learned: the learned lexicon (`AdaptationLoop.lexicon`): its terms, the C1 re-dictation
    ///     aliases as trusted spoken forms, and its negative aliases as blocked pairs.
    ///   - people: names the user deals with (recent thread participants, Contacts rows with
    ///     recorded use). Only admits Contacts rows; never indexed on its own. Default none.
    /// Build cost grows with the vocabulary (`index.buildMilliseconds`); rebuild off the dictation
    /// path when any of the three changes. Recency is measured at query time, so the matcher does
    /// not go stale between rebuilds.
    public static func build(entries: [DictionaryEntry], corrections: [(term: String, at: Date)] = [],
                             learned: PersonalLexicon? = nil, people: [String] = [],
                             config: Config = Config()) -> VocabularyMatcher {
        let evidence: ContactEvidence = entries.contains { $0.origin == .contacts }
            ? ContactEvidence(corrections: corrections.map(\.term), learned: learned, people: people) : .none
        var terms = VocabularyTerm.dictionary(entries, contacts: evidence) + VocabularyTerm.corrections(corrections)
        if let learned { terms += VocabularyTerm.learned(learned) }
        return VocabularyMatcher(terms: terms, config: config, blocked: learned.map(BlockedVocabularyPairs.init) ?? .init())
    }

    public func matches(heard: ContextPacket.Heard, limit: Int) -> [ContextPacket.VocabularyMatch] {
        matches(heard: heard, limit: limit, now: Date())
    }

    public func matches(heard: ContextPacket.Heard, limit: Int, now: Date) -> [ContextPacket.VocabularyMatch] {
        guard limit > 0, !index.isEmpty, heard.words.contains(where: \.isUncertain) else { return [] }
        return VocabularyQuery(index: index, config: config, blocked: blocked, now: now).run(heard.words, limit: limit)
    }

    // MARK: helpers shared with the query

    /// A heard word without its surrounding punctuation, lower-cased.
    static func clean(_ word: String) -> String {
        var w = Substring(word.lowercased())
        while let f = w.first, !(f.isLetter || f.isNumber) { w = w.dropFirst() }
        while let l = w.last, !(l.isLetter || l.isNumber) { w = w.dropLast() }
        return String(w)
    }
}

/// One `matches` call: heard words → windows → table lookups → verified candidates → top N.
/// The loops over the index use raw pointers and `while` (see `PhoneticVocabularyIndex`).
struct VocabularyQuery {
    struct Token {
        var text: String          // cleaned, lower-cased (what `heard` and negative aliases use)
        var uncertain: Bool
        var primary: [UInt8]
        var secondary: [UInt8]    // per word: secondary, or primary when none
        var hasSecondary: Bool
        var letters: [UInt8]
        var isCommon: Bool
    }

    struct Window {
        var count: Int
        var text: String
        /// Joined codes; `codes[1]` is the secondary variant when any word has one.
        var codes: [[UInt8]]
        /// Per variant, where each word's code ends in `codes[variant]` (tightness rule).
        var wordEnds: [[Int]]
        var letters: [UInt8]
        var isSingleCommonWord: Bool
        /// Every token is an ordinary English word.
        var isAllCommonWords: Bool
    }

    struct Candidate {
        var window: Int32
        var form: Int32
        var distance: Int32
        var closeness: Double
        var upperBound: Double
    }

    let index: PhoneticVocabularyIndex
    let config: VocabularyMatcher.Config
    let blocked: BlockedVocabularyPairs
    let now: Date

    init(index: PhoneticVocabularyIndex, config: VocabularyMatcher.Config, blocked: BlockedVocabularyPairs, now: Date) {
        self.index = index
        self.config = config
        self.blocked = blocked
        self.now = now
    }

    func run(_ words: [ContextPacket.HeardWord], limit: Int) -> [ContextPacket.VocabularyMatch] {
        let windows = Self.windows(tokenize(words), index: index, maxWords: config.maxWindowWords)
        guard !windows.isEmpty else { return [] }
        let scratch = QueryScratch(index.storage)
        let candidates = collect(windows, scratch)
        return rank(candidates, windows: windows, scratch, limit: limit)
    }

    // MARK: 1. heard words, encoded once per distinct word

    func tokenize(_ words: [ContextPacket.HeardWord]) -> [Token] {
        let encoder = PhoneticEncoder(metaphoneLength: index.parameters.metaphoneLength)
        var cache: [String: Token] = [:]
        var wordCodes: [String: DoubleMetaphone.Codes] = [:]
        return words.map { w in
            let text = VocabularyMatcher.clean(w.text)
            if var t = cache[text] { t.uncertain = w.isUncertain; return t }
            // Digits are read as words, the way the forms were verbalized ("4o" → "four o").
            let spoken = PhoneticEncoder.spokenWords(text)
            let c = encoder.codes(of: spoken, cache: &wordCodes)
            let t = Token(text: text, uncertain: w.isUncertain, primary: c.primary, secondary: c.secondary ?? c.primary,
                          hasSecondary: c.secondary != nil, letters: PhoneticEncoder.letters(spoken.joined(separator: " ")),
                          isCommon: Self.isOrdinary(text))
            cache[text] = t
            return t
        }
    }

    /// Whether a heard token (cleaned, lower-cased) is an ordinary word by how it is said: a word of
    /// the collision lexicon; a contraction ("can't", "don't", "we're", "I'll", "you'd", "I'm") or
    /// possessive ("it's", "dog's", "dogs'") of an ordinary word; or a plain number, ordinal or
    /// decade ("1", "10", "3.5", "1,000", "1st", "90s"), whose reading is number words. A name's
    /// possessive ("kothari's") and a token mixing letters into digits ("4o", "a16z") are not.
    static func isOrdinary(_ text: String) -> Bool {
        if CollisionLexicon.isCommonWord(text) { return true }
        let t = text.replacingOccurrences(of: "\u{2019}", with: "'")
        if t.contains("'") {
            if ordinaryWithApostrophe.contains(t) { return true }
            guard let a = t.lastIndex(of: "'") else { return false }
            let stem = String(t[..<a]), suffix = String(t[t.index(after: a)...])
            guard !stem.isEmpty, !stem.contains("'") else { return false }
            switch suffix {
            case "t": return stem.count >= 2 && stem.hasSuffix("n")             // n't
            case "", "s", "re", "ve", "ll", "d", "m": return CollisionLexicon.isCommonWord(stem)
            default: return false
            }
        }
        guard t.contains(where: \.isNumber) else { return false }
        var number = Substring(t)
        for suffix in ["st", "nd", "rd", "th", "s"] where number.hasSuffix(suffix) {
            let head = number.dropLast(suffix.count)
            if head.last?.isNumber == true { number = head; break }
        }
        guard number.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }),
              let reading = SpokenFormVerbalizer.reading(of: String(number)) else { return false }
        return reading.split(separator: " ").allSatisfy { CollisionLexicon.isCommonWord(String($0)) }
    }

    /// Ordinary words spelled with an apostrophe that no contraction rule covers.
    static let ordinaryWithApostrophe: Set<String> = ["o'clock", "y'all", "ma'am", "ain't", "'em", "'cause"]

    // MARK: 2. windows of 1…maxWords tokens holding an uncertain one (identical windows once)

    static func windows(_ tokens: [Token], index: PhoneticVocabularyIndex, maxWords: Int) -> [Window] {
        // A window longer than this cannot be within reach of any indexed code.
        let longest = min(DeletionKeys.maxKeyedLength, index.maxCodeLength + index.parameters.maxDistance(index.maxCodeLength + 2))
        var out: [Window] = []
        var seen = Set<String>()
        for start in tokens.indices {
            var primary: [UInt8] = [], secondary: [UInt8] = [], letters: [UInt8] = []
            var primaryEnds: [Int] = [], secondaryEnds: [Int] = []
            var hasSecondary = false, hasUncertain = false, allCommon = true
            var text = ""
            for n in 1...max(1, maxWords) {
                let i = start + n - 1
                guard i < tokens.count else { break }
                let t = tokens[i]
                // A punctuation-only token is a boundary; a token without sound carries no match.
                guard !t.text.isEmpty, !t.primary.isEmpty else { break }
                primary += t.primary
                secondary += t.secondary
                primaryEnds.append(primary.count)
                secondaryEnds.append(secondary.count)
                if !letters.isEmpty && !t.letters.isEmpty { letters.append(32) }
                letters += t.letters
                hasSecondary = hasSecondary || t.hasSecondary
                hasUncertain = hasUncertain || t.uncertain
                allCommon = allCommon && t.isCommon
                text = n == 1 ? t.text : text + " " + t.text
                guard primary.count <= longest, secondary.count <= longest else { break }
                guard hasUncertain, seen.insert(text).inserted else { continue }
                out.append(Window(count: n, text: text, codes: hasSecondary ? [primary, secondary] : [primary],
                                  wordEnds: hasSecondary ? [primaryEnds, secondaryEnds] : [primaryEnds],
                                  letters: letters, isSingleCommonWord: n == 1 && t.isCommon,
                                  isAllCommonWords: allCommon))
            }
        }
        return out
    }

    // MARK: 3. table lookups, verified on codes

    func collect(_ windows: [Window], _ scratch: QueryScratch) -> [Candidate] {
        let s = index.storage
        let codeBytes = s.codeBytes, codeStarts = s.codeStarts, codeForms = s.codeForms, codeFormStarts = s.codeFormStarts
        let slotKeys = s.slotKeys, slotHeads = s.slotHeads, slotMask = s.slotMask, slotShift = s.slotShift
        let postingCode = s.postingCode, postingNext = s.postingNext, maxDistance = s.maxDistance
        let formTerm = s.formTerm, formTrusted = s.formTrusted, termBase = s.termBase
        let codeSeen = scratch.codeSeen, formSeen = scratch.formSeen, formCloseness = scratch.formCloseness
        let formDistance = scratch.formDistance, touched = scratch.touched, keys = scratch.keys
        let prefix = scratch.prefix, row = scratch.row
        let gate = max(index.parameters.minPhonetic, config.minMatch)
        let minScore = config.minScore
        var found: [Candidate] = []

        var w = 0
        while w < windows.count {
            let window = windows[w]
            let windowStamp = Int32(w)
            var touchedCount = 0
            var variant = 0
            while variant < window.codes.count {
                let stamp = Int32(w * 2 + variant)
                window.codes[variant].withUnsafeBufferPointer { qb in
                    guard let q = qb.baseAddress else { return }
                    let m = qb.count
                    let keyCount = DeletionKeys.write(q, count: m, depth: Int(maxDistance[m]), into: keys, prefix: prefix)
                    var k = 0
                    while k < keyCount {
                        let key = keys[k]
                        k += 1
                        var slot = Int(truncatingIfNeeded: key >> slotShift)
                        var p: Int32 = -1
                        while true {
                            let found = slotKeys[slot]
                            if found == key { p = slotHeads[slot]; break }
                            if found == 0 { break }
                            slot = (slot + 1) & slotMask
                        }
                        while p >= 0 {
                            let c = Int(postingCode[Int(p)])
                            p = postingNext[Int(p)]
                            if codeSeen[c] == stamp { continue }
                            codeSeen[c] = stamp
                            let start = Int(codeStarts[c]), length = Int(codeStarts[c + 1]) - start
                            let longer = m > length ? m : length
                            let bound = Int(maxDistance[longer])
                            let d = PhoneticEncoder.distance(q, m, codeBytes + start, length, bound: bound, row: row)
                            if d > bound { continue }
                            let closeness = 1 - Double(d) / Double(longer)
                            if closeness < gate { continue }
                            var i = Int(codeFormStarts[c])
                            let end = Int(codeFormStarts[c + 1])
                            while i < end {
                                let f = Int(codeForms[i])
                                i += 1
                                if formSeen[f] != windowStamp {
                                    formSeen[f] = windowStamp
                                    formCloseness[f] = closeness
                                    formDistance[f] = Int32(d)
                                    touched[touchedCount] = Int32(f)
                                    touchedCount += 1
                                } else if closeness > formCloseness[f] {
                                    formCloseness[f] = closeness
                                    formDistance[f] = Int32(d)
                                }
                            }
                        }
                    }
                }
                variant += 1
            }
            var t = 0
            while t < touchedCount {
                let f = Int(touched[t])
                t += 1
                // Collision rule: an ordinary word alone matches only a trusted spoken form it
                // sounds exactly like ("queen" typed for Qwen); never a derived form or a near one.
                if window.isSingleCommonWord && (formTrusted[f] == 0 || formDistance[f] != 0) { continue }
                let term = Int(formTerm[f])
                let upper = formCloseness[f] * termBase[term] * scratch.recency(term, index: index, now: now,
                                                                                  halfLife: config.recencyHalfLife)
                if upper < minScore { continue }
                found.append(Candidate(window: windowStamp, form: Int32(f), distance: formDistance[f],
                                       closeness: formCloseness[f], upperBound: upper))
            }
            w += 1
        }
        return found
    }

    // MARK: 4. exact scores, best bound first, stopping when nothing left can enter the top N

    func rank(_ candidates: [Candidate], windows: [Window], _ scratch: QueryScratch, limit: Int) -> [ContextPacket.VocabularyMatch] {
        let s = index.storage
        let buckets = QueryScratch.bucketCount
        // Bucket by upper bound (descending), keeping discovery order inside a bucket: O(n), and the
        // stop test uses the bucket's top edge, so nothing that could still place is skipped.
        let order = scratch.order(candidates.map { min(buckets - 1, Int($0.upperBound * Double(buckets))) })
        var best = [Double](repeating: 0, count: index.groupCount)
        var bestCandidate = [Int](repeating: -1, count: index.groupCount)
        var inTop = [Bool](repeating: false, count: index.groupCount)
        var top: [Int] = []   // groups, best first (score desc, then written form asc)
        top.reserveCapacity(limit + 1)
        /// True when group `a` ranks before group `b`.
        func before(_ a: Int, _ b: Int) -> Bool {
            best[a] != best[b] ? best[a] > best[b] : index.groupName[a] < index.groupName[b]
        }
        for ci in order {
            let c = candidates[ci]
            let edge = Double(min(buckets - 1, Int(c.upperBound * Double(buckets))) + 1) / Double(buckets)
            if top.count >= limit, let last = top.last, edge < best[last] { break }
            let form = Int(c.form)
            let term = Int(s.formTerm[form])
            let group = Int(s.termGroup[term])
            guard c.upperBound > best[group] else { continue }
            let window = windows[Int(c.window)]
            guard isTight(window, form: form, distance: Int(c.distance), scratch) else { continue }
            if !blocked.isEmpty, blocked.contains(heard: window.text, written: index.terms[term].term) { continue }
            let spelling = spellingSimilarity(window.letters, form: form, scratch.row)
            if window.isAllCommonWords && s.formTrusted[form] == 0 && spelling < config.minCommonWordsSpelling { continue }
            let match = c.closeness * (0.5 + 0.5 * spelling)
            guard match >= config.minMatch else { continue }
            let score = match * s.termBase[term] * scratch.recency(term, index: index, now: now, halfLife: config.recencyHalfLife)
            guard score >= config.minScore, score > best[group] else { continue }
            best[group] = score
            bestCandidate[group] = ci
            // Keep the top N ordered: a group already in it moves up; another enters only if it
            // beats the last one.
            if inTop[group] {
                var i = top.count - 1
                while top[i] != group { i -= 1 }
                while i > 0 && before(group, top[i - 1]) { top[i] = top[i - 1]; i -= 1 }
                top[i] = group
            } else if top.count < limit || before(group, top[top.count - 1]) {
                if top.count == limit { inTop[top.removeLast()] = false }
                var i = top.count
                top.append(group)
                while i > 0 && before(group, top[i - 1]) { top[i] = top[i - 1]; i -= 1 }
                top[i] = group
                inTop[group] = true
            }
        }
        return top.map { g in
            let c = candidates[bestCandidate[g]]
            let form = Int(c.form)
            let term = index.terms[Int(s.formTerm[form])]
            return ContextPacket.VocabularyMatch(term: term.term, spokenForm: index.formText[form],
                                                 heard: windows[Int(c.window)].text, score: best[g],
                                                 source: term.source.rawValue)
        }
    }

    // MARK: scoring helpers

    /// A multi-word window is tight when dropping any one of its words — first, last or interior —
    /// makes the match worse: every heard word in it is explained by the form, so "a cab" never
    /// stands in for "cab" and "akash to kotari" never for "Akash Kothari" (the "to" would be
    /// deleted). A word that contributes no sound is unexplained by definition.
    func isTight(_ window: Window, form: Int, distance: Int, _ scratch: QueryScratch) -> Bool {
        guard window.count > 1 else { return true }
        let s = index.storage
        let codeBytes = s.codeBytes, codeStarts = s.codeStarts
        let primary = Int(s.formPrimary[form]), secondary = Int(s.formSecondary[form])
        let row = scratch.row, gap = scratch.gap
        var v = 0
        while v < window.codes.count {
            let ends = window.wordEnds[v]
            let explained = window.codes[v].withUnsafeBufferPointer { qb -> Bool in
                guard let q = qb.baseAddress else { return true }
                let n = qb.count
                var w = 0
                while w < window.count {
                    let lo = w == 0 ? 0 : ends[w - 1], hi = ends[w]
                    w += 1
                    if hi == lo { return true }
                    let m = n - (hi - lo)
                    if m == 0 { continue }
                    // The window's code without this word's symbols.
                    let rest: UnsafePointer<UInt8>
                    if lo == 0 {
                        rest = q + hi
                    } else if hi == n {
                        rest = q
                    } else {
                        gap.update(from: q, count: lo)
                        (gap + lo).update(from: q + hi, count: n - hi)
                        rest = UnsafePointer(gap)
                    }
                    var c = primary
                    while c >= 0 {
                        let start = Int(codeStarts[c]), length = Int(codeStarts[c + 1]) - start
                        if PhoneticEncoder.distance(rest, m, codeBytes + start, length, bound: distance, row: row) <= distance {
                            return true
                        }
                        c = c == primary ? secondary : -1
                    }
                }
                return false
            }
            if explained { return false }
            v += 1
        }
        return true
    }

    func spellingSimilarity(_ heard: [UInt8], form: Int, _ row: UnsafeMutablePointer<Int>) -> Double {
        let s = index.storage
        let start = Int(s.letterStarts[form]), length = Int(s.letterStarts[form + 1]) - start
        let longer = max(heard.count, length)
        guard longer > 0 else { return 1 }
        let d = heard.withUnsafeBufferPointer { hb -> Int in
            guard let h = hb.baseAddress else { return length }
            return PhoneticEncoder.distance(h, hb.count, s.letterBytes + start, length, bound: longer, row: row)
        }
        return 1 - Double(d) / Double(longer)
    }
}

/// Per-query working memory, sized to the index and freed with the query.
final class QueryScratch {
    static let bucketCount = 1024
    let codeSeen: UnsafeMutablePointer<Int32>
    let formSeen: UnsafeMutablePointer<Int32>
    let formCloseness: UnsafeMutablePointer<Double>
    let formDistance: UnsafeMutablePointer<Int32>
    let touched: UnsafeMutablePointer<Int32>
    let keys: UnsafeMutablePointer<UInt64>
    let prefix: UnsafeMutablePointer<UInt64>
    let row: UnsafeMutablePointer<Int>
    /// A window's code with one word cut out (tightness rule).
    let gap: UnsafeMutablePointer<UInt8>
    /// Recency factor per term; 0 = not computed yet (a factor is never below 0.6).
    let recencies: UnsafeMutablePointer<Double>

    init(_ s: PhoneticIndexStorage) {
        codeSeen = .allocate(capacity: max(1, s.codeCount))
        memset(codeSeen, 0xFF, max(1, s.codeCount) * MemoryLayout<Int32>.stride)   // -1
        formSeen = .allocate(capacity: max(1, s.formCount))
        memset(formSeen, 0xFF, max(1, s.formCount) * MemoryLayout<Int32>.stride)
        formCloseness = .allocate(capacity: max(1, s.formCount))
        formDistance = .allocate(capacity: max(1, s.formCount))
        touched = .allocate(capacity: max(1, s.formCount))
        keys = .allocate(capacity: DeletionKeys.maxKeys)
        prefix = .allocate(capacity: DeletionKeys.maxLength + 1)
        row = .allocate(capacity: max(s.maxCodeLength, s.maxLetterLength, DeletionKeys.maxKeyedLength) + 2)
        gap = .allocate(capacity: DeletionKeys.maxKeyedLength + 2)
        recencies = .allocate(capacity: max(1, s.termCount))
        memset(recencies, 0, max(1, s.termCount) * MemoryLayout<Double>.stride)
    }

    deinit {
        codeSeen.deallocate(); formSeen.deallocate(); formCloseness.deallocate(); formDistance.deallocate()
        touched.deallocate(); keys.deallocate(); prefix.deallocate(); row.deallocate(); gap.deallocate()
        recencies.deallocate()
    }

    /// 0.6 + 0.4 · ½^(age / half-life), once per term per query; 1 for a term with no date.
    func recency(_ term: Int, index: PhoneticVocabularyIndex, now: Date, halfLife: TimeInterval) -> Double {
        let cached = recencies[term]
        if cached > 0 { return cached }
        var r = 1.0
        if let lastUsed = index.terms[term].lastUsed {
            r = 0.6 + 0.4 * pow(0.5, max(0, now.timeIntervalSince(lastUsed)) / halfLife)
        }
        recencies[term] = r
        return r
    }

    /// Indices of `buckets` ordered by bucket, highest first, stable inside a bucket.
    func order(_ buckets: [Int]) -> [Int] {
        var start = [Int](repeating: 0, count: Self.bucketCount + 1)
        for b in buckets { start[Self.bucketCount - 1 - b + 1] += 1 }
        for i in 0..<Self.bucketCount { start[i + 1] += start[i] }
        var out = [Int](repeating: 0, count: buckets.count)
        for (i, b) in buckets.enumerated() {
            let slot = Self.bucketCount - 1 - b
            out[start[slot]] = i
            start[slot] += 1
        }
        return out
    }
}
