import Engine
import Foundation

/// C1 helper — the phonetic comparison behind `RedictationLearner`: the words of a landing, digits
/// spelled out so "a16z" and "a sixteen z" sound alike, Double Metaphone keys (long cap, so long
/// names are not truncated into false collisions), and the word-level alignment whose replaced
/// runs are the candidate `heard → written` regions.
enum RedictationAlignment {
    /// One differing region between two landings.
    struct Region: Equatable, Sendable {
        /// Words of the earlier landing, joined by spaces, as they landed (casing kept).
        var heard: String
        /// What the re-dictation landed in their place.
        var written: String
        /// Phonetic closeness of the two sides, 0…1.
        var similarity: Double
    }

    static let metaphoneLength = 16
    /// A region side longer than this is a rewording, not a respelling.
    static let maxRegionWords = 4

    /// Words of a landed text, outer punctuation stripped, inner characters kept ("a16z",
    /// "kubectl", "we're" stay one token). Casing is kept; comparisons lowercase.
    static func words(_ text: String) -> [String] {
        let trim = CharacterSet.punctuationCharacters.union(.symbols)
        return text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: trim) }
            .filter { !$0.isEmpty }
    }

    /// `token` with every digit run spelled out: "a16z" → ["a", "sixteen", "z"], "phase" → ["phase"].
    static func spellOutDigits(_ token: String) -> [String] {
        var out: [String] = []
        var run = ""
        var runIsDigit: Bool?
        func flush() {
            guard !run.isEmpty else { return }
            if runIsDigit == true, let n = Int(run) { out.append(numberWords(n)) } else { out.append(run) }
            run = ""
        }
        for ch in token {
            let digit = ch.isNumber
            if runIsDigit != nil, digit != runIsDigit { flush() }
            runIsDigit = digit
            run.append(ch)
        }
        flush()
        return out
    }

    /// English words for a number: 0…999 as spoken ("sixteen", "two hundred five"); longer
    /// numbers digit by digit ("two zero two four"), which is how a re-dictation of a code sounds.
    static func numberWords(_ n: Int) -> String {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        guard n >= 0 else { return numberWords(-n) }
        if n < 20 { return ones[n] }
        if n < 100 { return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10]) \(ones[n % 10])" }
        if n < 1000 {
            let head = "\(ones[n / 100]) hundred"
            return n % 100 == 0 ? head : "\(head) \(numberWords(n % 100))"
        }
        return String(n).compactMap { $0.wholeNumberValue }.map { ones[$0] }.joined(separator: " ")
    }

    /// Phonetic key of one word: digits spelled out, each piece Double-Metaphone encoded (primary
    /// code), joined. Pieces with no letters ("." in "v2.1") contribute nothing.
    static func phoneticKey(_ word: String) -> String {
        let dm = DoubleMetaphone(maxLength: metaphoneLength)
        return spellOutDigits(word).flatMap { $0.split(separator: " ") }.map { dm.encode(String($0)).primary }.joined()
    }

    static func phoneticKey(words: [String]) -> String { words.map(phoneticKey).joined() }

    /// 1 − edit distance / longer length over the two keys; 1 for two empty keys, 0 when one is empty.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty && y.isEmpty { return 1 }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Phonetic closeness of two whole landings.
    static func similarity(heard: [String], written: [String]) -> Double {
        similarity(phoneticKey(words: heard), phoneticKey(words: written))
    }

    /// Words equal textually (case-insensitive) are anchors; each replaced run between anchors is a
    /// region. Pure insertions and deletions are not regions: nothing was *heard* for them.
    static func regions(heard: [String], written: [String]) -> [Region] {
        WordDiff.replacedRuns(original: heard, edited: written).compactMap { run in
            let h = Array(heard[run.originalRange])
            let w = run.replacement.split(separator: " ").map(String.init)
            guard !h.isEmpty, !w.isEmpty, h.count <= maxRegionWords, w.count <= maxRegionWords else { return nil }
            return Region(heard: h.joined(separator: " "), written: w.joined(separator: " "),
                          similarity: similarity(phoneticKey(words: h), phoneticKey(words: w)))
        }
    }

    /// A region made only of function words ("him" → "them") is the user changing their mind,
    /// not a respelling: never an alias.
    static func isFunctionWordsOnly(_ text: String) -> Bool {
        let ws = words(text).map { $0.lowercased() }
        return !ws.isEmpty && ws.allSatisfy { functionWords.contains($0) }
    }

    static let functionWords: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "i", "me", "my", "mine", "we", "us", "our", "ours",
        "you", "your", "yours", "he", "him", "his", "she", "her", "hers", "it", "its", "they", "them", "their",
        "theirs", "who", "whom", "whose", "which", "what", "and", "or", "but", "nor", "so", "yet", "if", "then",
        "than", "as", "at", "by", "for", "from", "in", "into", "of", "off", "on", "onto", "to", "up", "with",
        "without", "about", "over", "under", "after", "before", "is", "am", "are", "was", "were", "be", "been",
        "being", "do", "does", "did", "have", "has", "had", "will", "would", "can", "could", "shall", "should",
        "may", "might", "must", "not", "no", "yes", "here", "there", "now", "also", "just", "very", "too",
        "please", "okay", "ok", "um", "uh", "well", "i'm", "it's", "we're", "they're", "don't", "can't",
    ]
}
