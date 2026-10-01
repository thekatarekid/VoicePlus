import Foundation
import Shared

/// V5 P6 — script transliteration for LANG (Hindi in Devanagari ↔ romanised Hinglish).
public enum TransliterationScript: String, Sendable, CaseIterable {
    case latin
    case devanagari
}

/// One word in, one word out. `nil` = "can't" (the word is left as it is).
public protocol ScriptTransliterator: Sendable {
    var name: String { get }
    var isAvailable: Bool { get }
    func transliterate(_ word: String, to script: TransliterationScript) -> String?
}

/// V5 P6 — the IndicXlit (AI4Bharat, MIT) slot. The published checkpoints are fairseq transformers;
/// no Core ML conversion exists yet (rule 0.1: convert, don't train — the conversion is the open
/// work, see `PublicDictionaryCatalog.indicXlit`). Until a converted model is installed this backend
/// reports unavailable and `TransliterationStage` falls back to `RuleBasedDevanagari`.
public struct IndicXlitTransliterator: ScriptTransliterator {
    public typealias Model = @Sendable (_ word: String, _ script: TransliterationScript) -> String?
    public let name = "IndicXlit"
    private let model: Model?
    public init(model: Model? = nil) { self.model = model }
    public var isAvailable: Bool { model != nil }
    public func transliterate(_ word: String, to script: TransliterationScript) -> String? { model?(word, script) }
}

/// Deterministic Devanagari ↔ Latin, Hindi conventions: inherent "a", virama conjuncts, matras,
/// word-final schwa deletion ("काम" → "kaam", "kaam" → "काम", "namaste" ↔ "नमस्ते").
/// A fallback, not a model: romanised Hindi is ambiguous ("main" is "मैं"; this gives "मैन").
public struct RuleBasedDevanagari: ScriptTransliterator {
    public let name = "Rule-based Devanagari"
    public var isAvailable: Bool { true }
    public init() {}

    public func transliterate(_ word: String, to script: TransliterationScript) -> String? {
        switch script {
        case .latin: return Self.isDevanagari(word) ? Self.romanize(word) : nil
        case .devanagari: return Self.isLatinWord(word) ? Self.devanagari(word) : nil
        }
    }

    static func isDevanagari(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
    }

    static func isLatinWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x41 && $0.value <= 0x5A) }
    }

    // MARK: Devanagari → Latin
    //
    // Works on Unicode scalars: Swift folds a consonant with its virama or matra into one
    // `Character`, which is exactly the boundary this needs to see through.

    static let consonants: [UInt32: String] = [
        0x0915: "k", 0x0916: "kh", 0x0917: "g", 0x0918: "gh", 0x0919: "n", 0x091A: "ch", 0x091B: "chh", 0x091C: "j",
        0x091D: "jh", 0x091E: "n", 0x091F: "t", 0x0920: "th", 0x0921: "d", 0x0922: "dh", 0x0923: "n", 0x0924: "t",
        0x0925: "th", 0x0926: "d", 0x0927: "dh", 0x0928: "n", 0x092A: "p", 0x092B: "ph", 0x092C: "b", 0x092D: "bh",
        0x092E: "m", 0x092F: "y", 0x0930: "r", 0x0932: "l", 0x0935: "v", 0x0936: "sh", 0x0937: "sh", 0x0938: "s",
        0x0939: "h",
        // precomposed nukta forms
        0x0958: "q", 0x0959: "kh", 0x095A: "g", 0x095B: "z", 0x095C: "d", 0x095D: "rh", 0x095E: "f",
    ]
    /// Consonant + nukta (U+093C) → the sound the nukta form makes.
    static let nuktaForms: [UInt32: String] = [0x0915: "q", 0x0916: "kh", 0x0917: "g", 0x091C: "z", 0x0921: "d", 0x0922: "rh", 0x092B: "f"]
    static let vowels: [UInt32: String] = [
        0x0905: "a", 0x0906: "aa", 0x0907: "i", 0x0908: "ee", 0x0909: "u", 0x090A: "oo", 0x090B: "ri", 0x090F: "e",
        0x0910: "ai", 0x0913: "o", 0x0914: "au",
    ]
    static let matras: [UInt32: String] = [
        0x093E: "aa", 0x093F: "i", 0x0940: "ee", 0x0941: "u", 0x0942: "oo", 0x0943: "ri", 0x0947: "e", 0x0948: "ai",
        0x094B: "o", 0x094C: "au",
    ]
    static let viramaScalar: UInt32 = 0x094D
    static let nuktaScalar: UInt32 = 0x093C

    static func romanize(_ word: String) -> String {
        let scalars = word.unicodeScalars.map(\.value)
        var out = ""
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if var base = consonants[c] {
                var j = i + 1
                if j < scalars.count, scalars[j] == nuktaScalar { base = nuktaForms[c] ?? base; j += 1 }
                out += base
                if j < scalars.count, let m = matras[scalars[j]] { out += m; i = j + 1; continue }
                if j < scalars.count, scalars[j] == viramaScalar { i = j + 1; continue }
                // Inherent "a" — deleted word-finally (Hindi schwa deletion).
                if j < scalars.count, consonants[scalars[j]] != nil || [0x0902, 0x0901, 0x0903].contains(scalars[j]) {
                    out += "a"
                }
                i = j
                continue
            }
            if let v = vowels[c] { out += v; i += 1; continue }
            switch c {
            case 0x0902, 0x0901: out += "n"      // anusvara, chandrabindu
            case 0x0903: out += "h"              // visarga
            case 0x0964: out += "."              // danda
            case 0x0966...0x096F: out += String(c - 0x0966)
            case nuktaScalar, viramaScalar: break
            default: out.unicodeScalars.append(Unicode.Scalar(c) ?? " ")
            }
            i += 1
        }
        return out
    }

    // MARK: Latin → Devanagari

    /// Longest-first Latin clusters.
    static let latinConsonants: [(String, String)] = [
        ("chh", "छ"), ("kh", "ख"), ("gh", "घ"), ("ch", "च"), ("jh", "झ"), ("th", "थ"), ("dh", "ध"), ("ph", "फ"),
        ("bh", "भ"), ("sh", "श"), ("k", "क"), ("g", "ग"), ("c", "क"), ("j", "ज"), ("t", "त"), ("d", "द"), ("n", "न"),
        ("p", "प"), ("b", "ब"), ("m", "म"), ("y", "य"), ("r", "र"), ("l", "ल"), ("v", "व"), ("w", "व"), ("s", "स"),
        ("h", "ह"), ("f", "फ़"), ("z", "ज़"), ("q", "क़"), ("x", "क्स"),
    ]
    /// (latin, independent vowel, matra) — "a" has no matra (inherent).
    static let latinVowels: [(String, String, String)] = [
        ("aa", "आ", "ा"), ("ai", "ऐ", "ै"), ("au", "औ", "ौ"), ("ee", "ई", "ी"), ("ii", "ई", "ी"), ("oo", "ऊ", "ू"),
        ("uu", "ऊ", "ू"), ("a", "अ", ""), ("i", "इ", "ि"), ("u", "उ", "ु"), ("e", "ए", "े"), ("o", "ओ", "ो"),
    ]

    static func devanagari(_ word: String) -> String {
        let lower = word.lowercased()
        var rest = Substring(lower)
        var out = ""
        var pendingConsonant = false   // last emitted a consonant with no vowel yet
        while !rest.isEmpty {
            if let (latin, independent, matra) = latinVowels.first(where: { rest.hasPrefix($0.0) }) {
                rest = rest.dropFirst(latin.count)
                // Hinglish writes a word-final long ā as "a": "kya" क्या, "gaya" गया, "tha" था.
                let finalA = latin == "a" && pendingConsonant && rest.isEmpty
                out += finalA ? "\u{093E}" : (pendingConsonant ? matra : independent)
                pendingConsonant = false
                continue
            }
            if let (latin, deva) = latinConsonants.first(where: { rest.hasPrefix($0.0) }) {
                if pendingConsonant { out += "\u{094D}" }
                out += deva
                pendingConsonant = true
                rest = rest.dropFirst(latin.count)
                continue
            }
            out.append(rest.removeFirst())
            pendingConsonant = false
        }
        // A final consonant keeps its implicit schwa-less reading: no virama (Hindi convention).
        return out
    }
}

/// V5 P6 — transliterates whole tokens into the run's target script. Off unless the run asks:
/// `StageContext.extra[TransliterationStage.targetKey]` = `latin` | `devanagari` (set by LANG for a
/// Hinglish or Hindi destination). Only tokens in the *other* script change; punctuation, digits,
/// and low-confidence spans (Bet 9: flagged, not rewritten) are left alone.
public struct TransliterationStage: PipelineStage {
    public let id: StageID = .transliteration
    public static let targetKey = "dictionary.transliteration.target"
    public let backends: [any ScriptTransliterator]

    /// IndicXlit first when a converted model is installed, else the rule-based fallback.
    public init(backends: [any ScriptTransliterator] = [IndicXlitTransliterator(), RuleBasedDevanagari()]) {
        self.backends = backends
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard let raw = context.extra[Self.targetKey], let target = TransliterationScript(rawValue: raw),
              let backend = backends.first(where: \.isAvailable) else {
            return spans.map { $0.touched(by: id) }
        }
        return spans.map { span in
            let converted = Self.apply(backend, to: span.text, target: target)
            guard converted != span.text else { return span.touched(by: id) }
            return span.isLowConfidence ? span.flaggedForRepair(by: id) : span.rewritten(converted, by: id)
        }
    }

    static func apply(_ backend: any ScriptTransliterator, to text: String, target: TransliterationScript) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { raw -> String in
            let (lead, core, trail) = TokenEdges.split(String(raw))
            guard !core.isEmpty, let out = backend.transliterate(core, to: target) else { return String(raw) }
            return lead + out + trail
        }.joined(separator: " ")
    }
}
