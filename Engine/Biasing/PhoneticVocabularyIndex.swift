import Foundation

// Context Writer §2.4 — the phonetic index behind `VocabularyMatcher`. Built once per vocabulary
// change, off the dictation path; queried at key-up.
//
// Every spoken form of every term (trusted forms the user typed or the learner recorded, the
// written form itself when it has no digits, and `SpokenFormVerbalizer`'s forms) is encoded once:
// Double Metaphone per word, joined, primary and secondary. Identical codes are stored once. Each
// distinct code is entered into a deletion-neighbourhood table: the code itself and every string
// made by deleting up to `maxDistance(length)` (≤ 2) of its symbols. Two codes within that many
// edits always share one such key (each side deletes what the other lacks), so a query looks up a
// handful of keys and verifies only real neighbours — no scan over the vocabulary.
//
// The frozen index lives in raw buffers (`PhoneticIndexStorage`) and the hot loops use raw
// pointers and `while`: the matcher runs at key-up, and in debug builds (the test suite) array and
// buffer-pointer subscripts are calls while raw pointer subscripts are inlined.

public struct PhoneticVocabularyIndex: Sendable {
    /// What "sounds alike" means; fixed when the index is built (the table depends on it).
    public struct Parameters: Sendable, Equatable {
        /// Double Metaphone code length per word.
        public var metaphoneLength = 6
        /// Phonetic closeness (1 − code edit distance / longer code length) a match needs.
        public var minPhonetic = 0.6
        /// Most code edits between a heard window and a spoken form (≤ 2: the table stores up to
        /// two deletions per code).
        public var maxEdits = 2
        public init() {}

        /// Edits allowed between codes whose longer one has `length` symbols.
        public func maxDistance(_ length: Int) -> Int {
            min(min(maxEdits, 2), max(0, Int((1 - minPhonetic) * Double(length) + 1e-9)))
        }
    }

    public let terms: [VocabularyTerm]
    public let parameters: Parameters
    /// Wall time the build took, for the Lab and the integrator's log (counts only).
    public let buildMilliseconds: Double

    let storage: PhoneticIndexStorage
    /// Distinct lower-cased written form per group (dedupe and tie-break key).
    let groupName: [String]
    let formText: [String]

    /// Forms longer than this many code symbols are not indexed (no 1–4-word window reaches them).
    static let maxIndexedCodeLength = 40

    public init(terms: [VocabularyTerm], parameters: Parameters = Parameters()) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        self.terms = terms
        self.parameters = parameters
        let encoder = PhoneticEncoder(metaphoneLength: parameters.metaphoneLength)
        var wordCodes: [String: DoubleMetaphone.Codes] = [:]   // number words and names repeat

        var b = PhoneticIndexStorage.Builder()
        var groupIDs: [String: Int32] = [:]
        var groupName: [String] = [], formText: [String] = []
        var codeIDs: [[UInt8]: Int32] = [:]
        var formsOfCode: [[Int32]] = []

        func codeID(_ code: [UInt8]) -> Int32 {
            if let id = codeIDs[code] { return id }
            let id = Int32(formsOfCode.count)
            codeIDs[code] = id
            b.codeBytes += code
            b.codeStarts.append(Int32(b.codeBytes.count))
            formsOfCode.append([])
            return id
        }

        for (i, t) in terms.enumerated() {
            let key = t.term.lowercased()
            let group: Int32
            if let g = groupIDs[key] { group = g } else {
                group = Int32(groupName.count)
                groupIDs[key] = group
                groupName.append(key)
            }
            b.termGroup.append(group)
            b.termBase.append((0.5 + 0.5 * t.weight) * t.source.weight)

            // Trusted forms first, so a typed form spelled like the term keeps its trust. The written
            // form is a spoken form only without digits ("a16z" is said through its verbalized forms)
            // and without a symbol nobody reads silently ("C++" is not "c"; only a typed form says it).
            var candidates = t.spokenForms.map { (PhoneticEncoder.collapse($0), true) }
            if !t.term.contains(where: \.isNumber), !SpokenFormVerbalizer.hasUnsayableSymbol(t.term) {
                candidates.append((PhoneticEncoder.collapse(t.term), false))
            }
            candidates += SpokenFormVerbalizer.forms(for: t.term).map { ($0, false) }
            var seen = Set<String>()
            for (text, trusted) in candidates where !text.isEmpty && seen.insert(text.lowercased()).inserted {
                // A trusted form may hold digits (a learned heard alias "gpt 4o"): read them as words,
                // exactly as heard tokens are read.
                let words = PhoneticEncoder.spokenWords(text)
                let c = encoder.codes(of: words, cache: &wordCodes)
                guard !c.primary.isEmpty, c.primary.count <= Self.maxIndexedCodeLength else { continue }
                let form = Int32(formText.count)
                formText.append(text)
                b.formTerm.append(Int32(i))
                b.formTrusted.append(trusted ? 1 : 0)
                b.letterBytes += PhoneticEncoder.letters(words.joined(separator: " "))
                b.letterStarts.append(Int32(b.letterBytes.count))
                let p = codeID(c.primary)
                formsOfCode[Int(p)].append(form)
                b.formPrimary.append(p)
                if let s = c.secondary, s != c.primary, s.count <= Self.maxIndexedCodeLength {
                    let sid = codeID(s)
                    formsOfCode[Int(sid)].append(form)
                    b.formSecondary.append(sid)
                } else {
                    b.formSecondary.append(-1)
                }
            }
        }
        for list in formsOfCode {
            b.codeForms += list
            b.codeFormStarts.append(Int32(b.codeForms.count))
        }
        b.maxDistance = (0...DeletionKeys.maxLength).map { Int32(parameters.maxDistance($0)) }

        self.storage = PhoneticIndexStorage(b)
        self.groupName = groupName
        self.formText = formText
        // The collision lexicon (the system word list) loads lazily; load it here, off the key-up path.
        _ = CollisionLexicon.isCommonWord("warm")
        self.buildMilliseconds = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
    }

    public var isEmpty: Bool { storage.formCount == 0 }
    public var formCount: Int { storage.formCount }
    public var distinctCodeCount: Int { storage.codeCount }
    /// (key, code) postings in the deletion-neighbourhood table.
    public var tableKeyCount: Int { storage.postingCount }
    /// Longest indexed code, in Double Metaphone symbols.
    public var maxCodeLength: Int { storage.maxCodeLength }
    var groupCount: Int { groupName.count }
}

/// The frozen index: immutable raw buffers, owned and freed by this object.
final class PhoneticIndexStorage: @unchecked Sendable {
    struct Builder {
        var codeBytes: [UInt8] = [], codeStarts: [Int32] = [0]
        var codeForms: [Int32] = [], codeFormStarts: [Int32] = [0]
        var formTerm: [Int32] = [], formTrusted: [UInt8] = [], formPrimary: [Int32] = [], formSecondary: [Int32] = []
        var letterBytes: [UInt8] = [], letterStarts: [Int32] = [0]
        var termGroup: [Int32] = [], termBase: [Double] = []
        var maxDistance: [Int32] = []
    }

    let codeCount: Int, formCount: Int, termCount: Int
    let maxCodeLength: Int, maxLetterLength: Int
    let codeBytes: UnsafeMutablePointer<UInt8>, codeStarts: UnsafeMutablePointer<Int32>
    let codeForms: UnsafeMutablePointer<Int32>, codeFormStarts: UnsafeMutablePointer<Int32>
    let formTerm: UnsafeMutablePointer<Int32>, formTrusted: UnsafeMutablePointer<UInt8>
    let formPrimary: UnsafeMutablePointer<Int32>, formSecondary: UnsafeMutablePointer<Int32>
    let letterBytes: UnsafeMutablePointer<UInt8>, letterStarts: UnsafeMutablePointer<Int32>
    let termGroup: UnsafeMutablePointer<Int32>, termBase: UnsafeMutablePointer<Double>
    /// `maxDistance[length]` for lengths 0…`DeletionKeys.maxLength`.
    let maxDistance: UnsafeMutablePointer<Int32>
    // Deletion-neighbourhood table: open addressing, key → newest posting; postings chain by `next`.
    let slotKeys: UnsafeMutablePointer<UInt64>, slotHeads: UnsafeMutablePointer<Int32>
    let slotMask: Int, slotShift: UInt64
    let postingCode: UnsafeMutablePointer<Int32>, postingNext: UnsafeMutablePointer<Int32>
    let postingCount: Int
    private let owned: [UnsafeMutableRawPointer]

    init(_ b: Builder) {
        let codeCount = b.codeStarts.count - 1
        var owned: [UnsafeMutableRawPointer] = []
        func freeze<T>(_ a: [T]) -> UnsafeMutablePointer<T> {
            let p = UnsafeMutablePointer<T>.allocate(capacity: max(1, a.count))
            a.withUnsafeBufferPointer { if let base = $0.baseAddress { p.initialize(from: base, count: a.count) } }
            owned.append(UnsafeMutableRawPointer(p))
            return p
        }
        let codeBytes = freeze(b.codeBytes), codeStarts = freeze(b.codeStarts)
        let maxDistance = freeze(b.maxDistance)

        // Size the table for every key every code can produce (an upper bound on distinct keys).
        var expected = 0, longest = 0
        for c in 0..<codeCount {
            let n = Int(b.codeStarts[c + 1] - b.codeStarts[c])
            longest = max(longest, n)
            expected += DeletionKeys.count(length: n, depth: Int(b.maxDistance[min(n, b.maxDistance.count - 1)]))
        }
        var bits = 4
        while (1 << bits) < max(16, expected * 2) { bits += 1 }
        let slots = 1 << bits
        let slotMask = slots - 1, slotShift = UInt64(64 - bits)
        let slotKeys = UnsafeMutablePointer<UInt64>.allocate(capacity: slots)
        slotKeys.initialize(repeating: 0, count: slots)
        let slotHeads = UnsafeMutablePointer<Int32>.allocate(capacity: slots)
        slotHeads.initialize(repeating: -1, count: slots)
        let postingCode = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, expected))
        let postingNext = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, expected))
        owned += [UnsafeMutableRawPointer(slotKeys), UnsafeMutableRawPointer(slotHeads),
                  UnsafeMutableRawPointer(postingCode), UnsafeMutableRawPointer(postingNext)]

        let keys = UnsafeMutablePointer<UInt64>.allocate(capacity: DeletionKeys.maxKeys)
        let prefix = UnsafeMutablePointer<UInt64>.allocate(capacity: DeletionKeys.maxLength + 1)
        defer { keys.deallocate(); prefix.deallocate() }
        var postings = 0
        var c = 0
        while c < codeCount {
            let start = Int(codeStarts[c]), n = Int(codeStarts[c + 1]) - start
            let k = DeletionKeys.write(codeBytes + start, count: n, depth: Int(maxDistance[n]), into: keys, prefix: prefix)
            var i = 0
            while i < k {
                let key = keys[i]
                var slot = Int(truncatingIfNeeded: key >> slotShift)
                while slotKeys[slot] != 0 && slotKeys[slot] != key { slot = (slot + 1) & slotMask }
                slotKeys[slot] = key
                let head = slotHeads[slot]
                // All keys of one code go in together: a repeated key of this code heads its list.
                if head < 0 || postingCode[Int(head)] != Int32(c) {
                    postingCode[postings] = Int32(c)
                    postingNext[postings] = head
                    slotHeads[slot] = Int32(postings)
                    postings += 1
                }
                i += 1
            }
            c += 1
        }

        self.codeCount = codeCount
        self.formCount = b.formTerm.count
        self.termCount = b.termGroup.count
        self.maxCodeLength = longest
        var longestLetters = 0
        for f in 0..<b.formTerm.count { longestLetters = max(longestLetters, Int(b.letterStarts[f + 1] - b.letterStarts[f])) }
        self.maxLetterLength = longestLetters
        self.codeBytes = codeBytes
        self.codeStarts = codeStarts
        self.codeForms = freeze(b.codeForms)
        self.codeFormStarts = freeze(b.codeFormStarts)
        self.formTerm = freeze(b.formTerm)
        self.formTrusted = freeze(b.formTrusted)
        self.formPrimary = freeze(b.formPrimary)
        self.formSecondary = freeze(b.formSecondary)
        self.letterBytes = freeze(b.letterBytes)
        self.letterStarts = freeze(b.letterStarts)
        self.termGroup = freeze(b.termGroup)
        self.termBase = freeze(b.termBase)
        self.maxDistance = maxDistance
        self.slotKeys = slotKeys
        self.slotHeads = slotHeads
        self.slotMask = slotMask
        self.slotShift = slotShift
        self.postingCode = postingCode
        self.postingNext = postingNext
        self.postingCount = postings
        self.owned = owned
    }

    deinit { for p in owned { p.deallocate() } }
}

/// Deletion-neighbourhood keys: a 64-bit hash of a byte string and of each string made by deleting
/// one or two of its bytes, computed from prefix hashes in O(1) per variant.
enum DeletionKeys {
    static let maxLength = 128
    /// Longest string `write` keys (longer windows cannot reach any indexed code).
    static let maxKeyedLength = 64
    /// Keys one string of `maxKeyedLength` symbols produces at depth 2.
    static let maxKeys = 1 + maxKeyedLength + maxKeyedLength * (maxKeyedLength - 1) / 2
    static let base: UInt64 = 0x0000_0100_0000_01B3
    /// `base^i` for i in 0…`maxLength`; allocated once for the process.
    nonisolated(unsafe) static let powers: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: maxLength + 1)
        p[0] = 1
        for i in 1...maxLength { p[i] = p[i - 1] &* base }
        return p
    }()

    static func count(length n: Int, depth: Int) -> Int {
        let d = min(depth, max(0, n - 1), 2)
        return 1 + (d >= 1 ? n : 0) + (d >= 2 ? n * (n - 1) / 2 : 0)
    }

    /// Writes the key of `s` and of every string made by deleting 1…`depth` (≤ 2) of its bytes into
    /// `keys` (room for `count(length:depth:)`), returning how many. Keys may repeat (deleting either
    /// of two equal neighbours yields the same string). `prefix` needs `n + 1` slots.
    static func write(_ s: UnsafePointer<UInt8>, count n: Int, depth: Int, into keys: UnsafeMutablePointer<UInt64>,
                      prefix: UnsafeMutablePointer<UInt64>) -> Int {
        guard n > 0, n <= maxKeyedLength else { return 0 }
        let pw = powers
        prefix[0] = 0
        var i = 0
        while i < n { prefix[i + 1] = prefix[i] &* base &+ UInt64(s[i]) &+ 1; i += 1 }
        var k = 0
        keys[k] = finish(prefix[n], length: n); k += 1
        var d = depth
        if d > n - 1 { d = n - 1 }
        if d > 2 { d = 2 }
        guard d >= 1 else { return k }
        i = 0
        while i < n {
            // s without i: P[i]·B^(n−1−i) + (P[n] − P[i+1]·B^(n−1−i))
            let shift = pw[n - 1 - i]
            keys[k] = finish(prefix[i] &* shift &+ (prefix[n] &- prefix[i + 1] &* shift), length: n - 1); k += 1
            i += 1
        }
        guard d >= 2 else { return k }
        i = 0
        while i < n - 1 {
            let head = prefix[i] &* pw[n - 2 - i]
            var j = i + 1
            while j < n {
                // s without i and j: P[i]·B^(n−2−i) + H(s[i+1..<j])·B^(n−1−j) + H(s[j+1..<n])
                let middle = prefix[j] &- prefix[i + 1] &* pw[j - i - 1]
                let tail = prefix[n] &- prefix[j + 1] &* pw[n - 1 - j]
                keys[k] = finish(head &+ middle &* pw[n - 1 - j] &+ tail, length: n - 2); k += 1
                j += 1
            }
            i += 1
        }
        return k
    }

    /// splitmix64 over the polynomial hash and the length; never 0 (0 marks an empty table slot).
    @inline(__always)
    static func finish(_ h: UInt64, length: Int) -> UInt64 {
        var z = h ^ (UInt64(truncatingIfNeeded: length) &* 0x9E37_79B9_7F4A_7C15)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return (z ^ (z >> 31)) | 1
    }
}

/// Double Metaphone codes and spelling letters for spoken words, shared by the index (forms) and
/// the matcher (heard words) so both sides are encoded the same way.
struct PhoneticEncoder: Sendable {
    let metaphone: DoubleMetaphone

    init(metaphoneLength: Int) { metaphone = DoubleMetaphone(maxLength: metaphoneLength) }

    /// Per-word codes joined without boundaries ("team viewer" and "teamviewer" compare equal).
    /// `secondary` is nil when no word has one; otherwise each word contributes its secondary
    /// (or its primary when it has none).
    func codes(of words: [String], cache: inout [String: DoubleMetaphone.Codes]) -> (primary: [UInt8], secondary: [UInt8]?) {
        var primary: [UInt8] = [], secondary: [UInt8] = []
        var hasSecondary = false
        for w in words {
            let c: DoubleMetaphone.Codes
            if let hit = cache[w] { c = hit } else { c = encode(word: w); cache[w] = c }
            primary += Array(c.primary.utf8)
            if let s = c.secondary { hasSecondary = true; secondary += Array(s.utf8) } else { secondary += Array(c.primary.utf8) }
        }
        return (primary, hasSecondary ? secondary : nil)
    }

    /// One word's codes. A word that is said letter by letter is coded by its letters' names
    /// (`SpokenFormVerbalizer.letterNames`: "h" → "aitch", "w" → "double you", "c" → "see"): a
    /// single letter, and a run of two to `maxSpelledLetters` letters with no vowel ("wwdc", "html",
    /// "gpt"), which nobody can read as a word. Both sides are coded this way — the verbalizer's
    /// spelled forms ("h t m l") and heard tokens — so a spelled initialism keeps every letter's
    /// sound, a window never breaks on a letter Double Metaphone leaves silent, and "wwdc" is not
    /// "TK" (the code of "dec").
    func encode(word w: String) -> DoubleMetaphone.Codes {
        let lower = w.lowercased()
        guard Self.isSaidLetterByLetter(lower) else { return metaphone.encode(w) }
        var primary = "", secondary = ""
        var hasSecondary = false
        for letter in lower {
            for part in SpokenFormVerbalizer.letterNames[letter] ?? [] {
                let c = metaphone.encode(part)
                primary += c.primary
                if let s = c.secondary { hasSecondary = true; secondary += s } else { secondary += c.primary }
            }
        }
        return DoubleMetaphone.Codes(primary: primary, secondary: hasSecondary ? secondary : nil)
    }

    /// A lower-cased word that is spelled when said: one ASCII letter, or 2…`maxSpelledLetters`
    /// ASCII letters without a vowel (a, e, i, o, u, y).
    static func isSaidLetterByLetter(_ w: String) -> Bool {
        guard (1...SpokenFormVerbalizer.maxSpelledLetters).contains(w.count),
              w.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return w.count == 1 || !w.contains { "aeiouy".contains($0) }
    }

    /// The words a form or a heard token is said as: a word with digits is read through the
    /// verbalizer ("4o" → "four", "o"); a dotted abbreviation is spelled ("U.S." → "u", "s"); any
    /// other word is itself.
    static func spokenWords(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).flatMap { w -> [String] in
            if let reading = SpokenFormVerbalizer.reading(of: String(w)) { return reading.split(separator: " ").map(String.init) }
            if let letters = SpokenFormVerbalizer.spelledAbbreviation(String(w)) { return letters }
            return [String(w)]
        }
    }

    /// Lower-cased letters and digits (and any non-ASCII byte, so accented letters still count),
    /// words separated by one space: spelling similarity sees how the words are cut, so "gpt four o"
    /// is closer to a heard "gpt 4o" than "g p t four o" is.
    static func letters(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for word in s.lowercased().split(whereSeparator: \.isWhitespace) {
            let kept = word.utf8.filter { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 >= 0x80 }
            guard !kept.isEmpty else { continue }
            if !out.isEmpty { out.append(32) }
            out += kept
        }
        return out
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Levenshtein distance, or `bound + 1` as soon as it must exceed `bound`. `row` needs `m + 1`
    /// slots.
    static func distance(_ a: UnsafePointer<UInt8>, _ n: Int, _ b: UnsafePointer<UInt8>, _ m: Int, bound: Int,
                         row: UnsafeMutablePointer<Int>) -> Int {
        let gap = n > m ? n - m : m - n
        if gap > bound { return bound + 1 }
        if n == 0 { return m }
        if m == 0 { return n }
        var j = 0
        while j <= m { row[j] = j; j += 1 }
        var i = 1
        while i <= n {
            var diagonal = row[0]
            row[0] = i
            var rowMin = i
            let ai = a[i - 1]
            j = 1
            while j <= m {
                let above = row[j]
                var v = diagonal
                if ai != b[j - 1] { v += 1 }
                if above + 1 < v { v = above + 1 }
                let left = row[j - 1] + 1
                if left < v { v = left }
                diagonal = above
                row[j] = v
                if v < rowMin { rowMin = v }
                j += 1
            }
            if rowMin > bound { return bound + 1 }
            i += 1
        }
        return row[m]
    }
}
