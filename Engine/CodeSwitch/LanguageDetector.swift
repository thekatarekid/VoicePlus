import Foundation

/// Script- and n-gram-based language detector over streaming text. No toggle: it is fed every
/// partial/final word and reports what it has heard so far. Devanagari → Hindi by script;
/// Latin words → romanized-Hindi vs English by a small function-word + character-trigram model.
public struct LanguageDetector: Sendable {
    public struct WordTag: Equatable, Sendable {
        public var word: String
        public var script: Script
        public var language: SpokenLanguage
    }
    public struct Detection: Equatable, Sendable {
        public var language: SpokenLanguage
        public var dominantScript: Script
        public var scripts: Set<Script>
        /// 0…1 share of words supporting `language` (1 for pure, ~0.5 for even mixes).
        public var confidence: Float
        public var words: [WordTag]
    }

    /// High-frequency romanized Hindi tokens (function words + common verbs/particles).
    static let romanHindiWords: Set<String> = [
        "hai", "hain", "ho", "hoon", "hun", "tha", "thi", "nahi", "nahin", "na", "mat",
        "kya", "kyun", "kyon", "kaise", "kab", "kahan", "kaun", "kaunsa", "kitna",
        "ka", "ki", "ke", "ko", "se", "mein", "main", "me", "par", "pe", "tak", "aur", "ya", "toh", "to",
        "bhi", "hi", "yaar", "bhai", "acha", "accha", "theek", "thik", "bahut", "bohot", "thoda",
        "kar", "karo", "karna", "karte", "karta", "karti", "kiya", "kijiye", "chahiye", "chalo", "chal",
        "abhi", "kal", "aaj", "phir", "fir", "matlab", "lekin", "magar", "agar", "jab", "tab",
        "yeh", "ye", "woh", "wo", "yahan", "wahan", "mujhe", "tumhe", "humko", "hum", "tum", "aap", "unka", "uska", "mera", "meri", "tera", "apna",
        "bol", "bolo", "dekho", "dekh", "suno", "batao", "bata", "jao", "aao", "raha", "rahi", "rahe", "gaya", "gayi", "gaye", "de", "do", "le", "lo", "bhej", "bhejo", "milte",
    ]
    /// Character trigrams that are much more common in romanized Hindi than in English.
    static let romanHindiTrigrams: Set<String> = [
        "aha", "kya", "hai", "ahi", "chh", "kar", "aar", "yaa", "jao", "bha", "dha", "tha", "kke", "aap", "hun", "ega", "egi", "enge", "aun", "ein",
    ]
    /// English trigrams that veto Hindi for ambiguous words ("the", "main").
    static let englishWords: Set<String> = ["the", "to", "do", "me", "main", "par", "the", "de", "ya"]

    private var tags: [WordTag] = []
    /// V5 LANG1 — the languages the user chose, as the detector knows them. Nil = unconstrained
    /// (every guess allowed). Without Hindi a Latin word is never guessed as romanised Hindi; with
    /// Hindi alone a Latin word is never guessed as English. Devanagari stays Hindi either way:
    /// that is the script, not a guess.
    public let allowed: Set<SpokenLanguage>?

    public init(allowed: Set<SpokenLanguage>? = nil) { self.allowed = allowed }

    /// LANG1 codes (`"en"`, `"hi"`, `"fr"`, BCP-47 tags allowed) → the detector's constraint.
    /// Hindi iff `hi` was chosen; "English" (= Latin, not Hindi) iff anything else was. Empty → nil.
    public static func allowedLanguages(fromCodes codes: [String]) -> Set<SpokenLanguage>? {
        let bases = Set(codes.map { $0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "" }
            .filter { !$0.isEmpty })
        guard !bases.isEmpty else { return nil }
        var out: Set<SpokenLanguage> = []
        if bases.contains("hi") { out.insert(.hindi) }
        if !bases.subtracting(["hi"]).isEmpty { out.insert(.english) }
        return out
    }

    // MARK: Streaming

    /// Feed a word or phrase (final or partial). Returns the detection over everything fed so far.
    @discardableResult
    public mutating func feed(_ text: String) -> Detection {
        tags.append(contentsOf: Self.tag(text, allowed: allowed))
        return Self.summarize(tags)
    }

    public mutating func reset() { tags.removeAll() }
    public var current: Detection { Self.summarize(tags) }

    /// One-shot detection over a complete string.
    public static func detect(_ text: String) -> Detection { summarize(tag(text)) }

    /// One-shot detection constrained to the chosen languages (LANG1).
    public static func detect(_ text: String, allowed: Set<SpokenLanguage>?) -> Detection { summarize(tag(text, allowed: allowed)) }

    // MARK: Word tagging

    public static func tag(_ text: String, allowed: Set<SpokenLanguage>? = nil) -> [WordTag] {
        text.split(whereSeparator: { $0.isWhitespace }).map { raw in
            let word = String(raw)
            let script = Script.dominant(in: word)
            return WordTag(word: word, script: script, language: language(of: word, script: script, allowed: allowed))
        }
    }

    static func language(of word: String, script: Script, allowed: Set<SpokenLanguage>? = nil) -> SpokenLanguage {
        switch script {
        case .devanagari: return .hindi
        case .latin:
            if let allowed {
                if !allowed.contains(.hindi) { return .english }
                if !allowed.contains(.english) { return .hindi }
            }
            return isRomanHindi(word) ? .hindi : .english
        case .other, .neutral: return .unknown
        }
    }

    /// Whether a Latin word is romanised Hindi under the chosen languages (LANG1). The App hands
    /// this to `ScriptOutputStage` (Pipeline cannot import Engine) for Mixed / Devanagari output.
    public static func isHindiWord(_ word: String, allowed: Set<SpokenLanguage>?) -> Bool {
        let script = Script.dominant(in: word)
        return script == .latin && language(of: word, script: script, allowed: allowed) == .hindi
    }

    public static func isRomanHindi(_ word: String) -> Bool {
        let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !w.isEmpty else { return false }
        if englishWords.contains(w) { return false }
        if romanHindiWords.contains(w) { return true }
        if w.count < 4 { return false }
        let scalars = Array(w)
        var hits = 0
        for i in 0..<(scalars.count - 2) where romanHindiTrigrams.contains(String(scalars[i...i + 2])) { hits += 1 }
        return hits >= 2
    }

    static func summarize(_ tags: [WordTag]) -> Detection {
        let scripts = Set(tags.map(\.script)).subtracting([.neutral])
        var counts: [Script: Int] = [:]
        for t in tags where t.script != .neutral { counts[t.script, default: 0] += 1 }
        let dominant = counts.max { $0.value < $1.value }?.key ?? .neutral

        let en = tags.filter { $0.language == .english }.count
        let hi = tags.filter { $0.language == .hindi }.count
        let total = en + hi
        guard total > 0 else {
            return Detection(language: .unknown, dominantScript: dominant, scripts: scripts, confidence: 0, words: tags)
        }
        let share = Float(max(en, hi)) / Float(total)
        let language: SpokenLanguage
        if en > 0 && hi > 0 && share < 0.9 { language = .mixed }
        else { language = hi >= en ? .hindi : .english }
        let confidence = language == .mixed ? 1 - share + 0.5 : share
        return Detection(language: language, dominantScript: dominant, scripts: scripts,
                         confidence: min(confidence, 1), words: tags)
    }
}
