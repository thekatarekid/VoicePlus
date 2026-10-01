import Foundation
import Shared

// V5 LANG1/LANG2/G3 — the output script, applied once, at the very end of the pipeline.
//
// The script a Hindi(-English) turn is written in is a user choice (LANG1 per language, LANG2 per
// turn from the notch, remembered per app), never a model guess. Default is Roman (owner decision).
// Transliteration itself is P6's (`ScriptTransliterator`: IndicXlit when a converted model is
// installed, else `RuleBasedDevanagari`); this stage only decides *which* words change and does the
// sentence punctuation: the danda (।) belongs to Devanagari output only.

/// The script a turn is written in.
public enum OutputScript: String, Codable, CaseIterable, Sendable {
    /// Latin script for everything (romanised Hindi). The default.
    case roman
    /// Devanagari for Hindi; English words too when a real transliteration model is installed.
    case devanagari
    /// Hindi words in Devanagari, English words kept in Latin (G3).
    case mixed

    public static let `default`: OutputScript = .roman

    /// Plain menu title (flags-free).
    public var title: String {
        switch self {
        case .roman: return "Roman"
        case .devanagari: return "Devanagari"
        case .mixed: return "Mixed"
        }
    }
}

public struct ScriptOutputStage: PipelineStage {
    public static let stageID: StageID = "lang.scriptOutput"
    public let id: StageID = ScriptOutputStage.stageID

    public enum Keys {
        /// `StageContext.extra` — an `OutputScript.rawValue`. Absent = the stage is inert (no Hindi
        /// chosen in LANG1 and no notch override): nothing is rewritten.
        public static let script = "lang.output.script"
    }

    public typealias WordClassifier = @Sendable (String) -> Bool

    public let backends: [any ScriptTransliterator]
    private let classifier: WordClassifier?
    private let englishClassifier: WordClassifier?

    /// - Parameters:
    ///   - backends: P6's transliterators, first available wins (IndicXlit, then rule-based).
    ///   - isHindiWord: whether a Latin word is romanised Hindi. Nil = the process-wide classifier
    ///     the App installs (`Engine.LanguageDetector`); with neither, every Latin word counts as
    ///     English, so Mixed / Devanagari never invent Devanagari for an English word.
    ///   - isEnglishWord: G3 — whether a romanised word is English (Mixed turns a Devanagari-written
    ///     English word back to Latin). Nil = the installed public word list (SCOWL / system words).
    public init(backends: [any ScriptTransliterator] = [IndicXlitTransliterator(), RuleBasedDevanagari()],
                isHindiWord: WordClassifier? = nil, isEnglishWord: WordClassifier? = nil) {
        self.backends = backends
        self.classifier = isHindiWord
        self.englishClassifier = isEnglishWord
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard let raw = context.extra[Keys.script], let script = OutputScript(rawValue: raw) else {
            return spans.map { $0.touched(by: id) }
        }
        let backend = backends.first(where: \.isAvailable)
        let isHindi = classifier ?? Self.hindiWordClassifier ?? { _ in false }
        let isEnglish = englishClassifier ?? { PublicDictionaries.shared.vocabulary.contains($0) }
        return spans.map { span in
            let converted = Self.apply(script, to: span.text, backend: backend, isHindiWord: isHindi, isEnglishWord: isEnglish)
            guard converted != span.text else { return span.touched(by: id) }
            return span.isLowConfidence ? span.flaggedForRepair(by: id) : span.rewritten(converted, by: id)
        }
    }

    /// The rewrite over one span's text. Pure; tests call it directly.
    ///
    /// G3 policy: Roman writes every word in Latin (the default); Mixed writes Hindi in Devanagari and
    /// keeps English Latin — including an English word the ASR wrote in Devanagari (Srota does:
    /// "ऑफिस"), recognised when its romanisation is an English word and not a Hindi one;
    /// Devanagari writes Hindi in Devanagari (English too only with a real transliteration model).
    public static func apply(_ script: OutputScript, to text: String, backend: (any ScriptTransliterator)?,
                             isHindiWord: (String) -> Bool, isEnglishWord: (String) -> Bool = { _ in false }) -> String {
        // A real model (IndicXlit) can write English words in Devanagari; the rule-based fallback
        // cannot do that legibly ("meeting" → "मेएतिन्ग"), so then English words stay Latin.
        let modelBacked = backend.map { !($0 is RuleBasedDevanagari) } ?? false
        return text.split(separator: " ", omittingEmptySubsequences: false).map { raw -> String in
            var (lead, core, trail) = TokenEdges.split(String(raw))
            // `TokenEdges` keeps a danda inside the word ("है।"); it is sentence punctuation here (G3).
            while let last = core.last, last == "।" || last == "॥" { trail = String(last) + trail; core.removeLast() }
            guard !core.isEmpty else { return String(raw).replacingOccurrences(of: "।", with: script == .devanagari ? "।" : ".") }
            var word = core
            let devanagari = isDevanagari(core)
            switch script {
            case .roman:
                if devanagari, let out = backend?.transliterate(core, to: .latin) { word = out }
            case .mixed:
                if !devanagari, isHindiWord(core), let out = backend?.transliterate(core, to: .devanagari) { word = out }
                if devanagari, let latin = backend?.transliterate(core, to: .latin),
                   isEnglishWord(latin), !isHindiWord(latin) { word = latin }
            case .devanagari:
                if !devanagari, isHindiWord(core) || modelBacked, let out = backend?.transliterate(core, to: .devanagari) { word = out }
            }
            return lead + word + danda(trail, after: word, script: script)
        }.joined(separator: " ")
    }

    /// Sentence-final full stop ↔ danda. Devanagari output ends a Devanagari sentence with "।";
    /// Roman and Mixed never carry a danda. Decimals never reach here (no trailing "." on "3.5").
    static func danda(_ trail: String, after word: String, script: OutputScript) -> String {
        switch script {
        case .devanagari:
            guard isDevanagari(word) else { return trail }
            return trail.replacingOccurrences(of: ".", with: "।")
        case .roman, .mixed:
            return trail.replacingOccurrences(of: "।", with: ".").replacingOccurrences(of: "॥", with: ".")
        }
    }

    static func isDevanagari(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) && $0.value != 0x0964 && $0.value != 0x0965 }
    }

    // MARK: Process-wide wiring (App)

    private final class Wiring: @unchecked Sendable {
        let lock = NSLock()
        var classifier: WordClassifier?
    }
    private static let wiring = Wiring()

    /// The romanised-Hindi word test the App installs (`LanguageDetector.isRomanHindi`, constrained
    /// to the LANG1 languages). Pipeline cannot import Engine, so it arrives as a closure.
    public static var hindiWordClassifier: WordClassifier? {
        get { wiring.lock.lock(); defer { wiring.lock.unlock() }; return wiring.classifier }
        set { wiring.lock.lock(); wiring.classifier = newValue; wiring.lock.unlock() }
    }
}

// MARK: - ITN locale from LANG1

public extension ITNLocale {
    /// D1's locale from the LANG1 answers: Hindi chosen and written in Roman → Hinglish rules; in
    /// Devanagari → `hi`; Indian English spelling → `en-IN`; otherwise `en`. Lakh/crore follow.
    static func from(languages: [String], hindiScript: OutputScript?, spelling: String?) -> ITNLocale {
        let codes = languages.map { $0.lowercased().split(separator: "-").first.map(String.init) ?? $0 }
        if codes.contains("hi") {
            return (hindiScript ?? .default) == .devanagari ? .hi : .hiEn
        }
        if spelling?.lowercased() == "en-in" { return .enIN }
        return .en
    }
}
