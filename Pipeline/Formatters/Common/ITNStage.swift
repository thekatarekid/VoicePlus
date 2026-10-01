import Foundation
import Shared

/// V5 D1 + K7 — inverse text normalisation, **one implementation** for the preview and the final pass.
///
/// Spoken forms become written forms ("five thousand one hundred and fifty" → `5150`, "three thirty
/// p.m." → `3:30 PM`, en-IN "twelve lakh" → `12,00,000`). Layers, always in this order:
///
/// 1. **Locale rules** (Swift): en-IN lakh/crore with Indian digit grouping, `₹`, and day-first dates.
/// 2. **Span rules** (Swift, `Numbers`): cardinals, `hundred and`, times, `%`/currency, years, and
///    the E2 digit-sequence rule read off span timing (≥ 3 single digits with gaps < 250 ms join).
///    These are span-aware, so confidence/audioRange/provenance survive (Bet 9).
/// 0. **NeMo** (`ITNBackend`, optional, runs first): NeMo's grammars (`FluidAudio.TextNormalizer`,
///    wired by `App` via `NemoITN` in `Engine`; `Pipeline` has no FluidAudio dependency) for what the
///    Swift rules cannot write — "five dollars and fifty cents" → `$5.50`, "two point five" → `2.5`.
///    Measured on LibriSpeech test-clean (D1), NeMo's English sentence mode also rewrites prose
///    ("and one more" → "1 more", "four to five" → "04:56", "six miles" → "6 mi"), so only a rewrite
///    to a single currency / decimal / percent token is accepted (Hindi: a single numeric token).
///
/// Punctuation-tolerant: every lookup strips trailing `[,.;:!?]` and re-attaches it (E1, V4.11).
///
/// Field-role aware (`ITNPolicy`): never in `.codeEditor` / `.terminal`; always — small numbers too —
/// in a spreadsheet cell; prose rules everywhere else.
///
/// `ProseListFormatter` runs `apply` in place of its old number pass; `PreviewFormatter` (Engine)
/// runs `normalize(text:)` through the hook `App` installs. Same code, so preview == final.
public struct ITNStage: PipelineStage {
    public static let stageID: StageID = "itn"
    public let id: StageID = ITNStage.stageID

    /// `StageContext.extra` keys. `App` writes them; tests set them directly.
    public enum Keys {
        /// A LANG tag: `en`, `en-IN`, `hi`, `hi_en` (anything else → `en`).
        public static let locale = "itn.locale"
        /// A `FieldRole` raw value, or `spreadsheetCell`. Overrides the role read off the AX keys.
        public static let fieldRole = "itn.fieldRole"
    }

    public init() {}

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard !spans.isEmpty else { return [] }
        let config = Self.config(for: context)
        guard config.policy != .never else { return spans.map { $0.touched(by: id) } }
        var toks = Tokenizer.tokens(from: spans)
        Self.apply(&toks, spans: spans, config: config)
        return Assembler.assemble(toks, into: spans, stage: id)
    }

    // MARK: Configuration

    public struct Config: Sendable, Equatable {
        public var locale: ITNLocale
        public var policy: ITNPolicy
        public init(locale: ITNLocale = .en, policy: ITNPolicy = .prose) {
            self.locale = locale
            self.policy = policy
        }
    }

    /// Locale from `Keys.locale`, else the process default (`App` sets it from LANG / the system).
    /// Policy from `Keys.fieldRole`, else the role `FieldRole.classify` reads off the AX keys.
    public static func config(for context: StageContext) -> Config {
        let locale = context.extra[Keys.locale].map(ITNLocale.init(tag:)) ?? defaultLocale
        let role: String?
        if let explicit = context.extra[Keys.fieldRole] {
            role = explicit
        } else if context.extra[FieldContext.Keys.axRole] != nil || context.extra[FieldContext.Keys.hints] != nil {
            role = FieldRole.classify(FieldContext(stageContext: context)).rawValue
        } else {
            role = nil
        }
        return Config(locale: locale, policy: ITNPolicy(fieldRole: role))
    }

    // MARK: Process-wide wiring (App)

    private final class Wiring: @unchecked Sendable {
        let lock = NSLock()
        var backend: (any ITNBackend)?
        var locale: ITNLocale = .en
    }
    private static let wiring = Wiring()

    /// The NeMo backend. `nil` (the default, and every Pipeline test) = Swift rules only.
    public static var backend: (any ITNBackend)? {
        get { wiring.lock.lock(); defer { wiring.lock.unlock() }; return wiring.backend }
        set { wiring.lock.lock(); wiring.backend = newValue; wiring.lock.unlock() }
    }

    /// Locale used when a context does not name one.
    public static var defaultLocale: ITNLocale {
        get { wiring.lock.lock(); defer { wiring.lock.unlock() }; return wiring.locale }
        set { wiring.lock.lock(); wiring.locale = newValue; wiring.lock.unlock() }
    }

    // MARK: Text path (preview)

    /// The same rules over plain text. Preview text has no span timing, so the digit-sequence rule
    /// is off — exactly what the final pass does with untimed spans. No capitalisation, no period.
    public static func normalize(text: String, config: Config = Config(locale: defaultLocale),
                                 backend: (any ITNBackend)? = ITNStage.backend) -> String {
        guard config.policy != .never, !text.isEmpty else { return text }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard !words.isEmpty else { return text }
        let spans = words.map { TranscriptSpan(text: String($0), confidence: 1, audioRange: 0...0) }
        var toks = Tokenizer.tokens(from: spans)
        apply(&toks, spans: [], config: config, backend: backend)
        return Assembler.assemble(toks, into: spans, stage: stageID).renderedText
    }

    /// The span path rendered — what the final pass's ITN layer writes for these spans.
    public static func normalizeSpans(_ spans: [TranscriptSpan], config: Config = Config(locale: defaultLocale),
                                      backend: (any ITNBackend)? = ITNStage.backend) -> String {
        guard config.policy != .never else { return spans.renderedText }
        var toks = Tokenizer.tokens(from: spans)
        apply(&toks, spans: spans, config: config, backend: backend)
        return Assembler.assemble(toks, into: spans, stage: stageID).renderedText
    }

    // MARK: Token path (final)

    /// Rewrites number tokens in place. `spans` drives the timing rules; empty turns them off.
    static func apply(_ toks: inout [Tok], spans: [TranscriptSpan], config: Config,
                      backend: (any ITNBackend)? = ITNStage.backend) {
        guard config.policy != .never else { return }
        if let backend, backend.supports(config.locale.backendLanguage) {
            NemoResidual.apply(&toks, backend: backend, language: config.locale.backendLanguage, policy: config.policy)
        }
        if config.locale.indian { IndianNumbers.apply(&toks) }
        Numbers.normalize(&toks, spellOutSmall: config.policy != .always, spans: spans)
        Meridiem.apply(&toks)
    }
}

// MARK: - Locale

/// The ITN locale, from a LANG tag.
public enum ITNLocale: String, Sendable, CaseIterable, Equatable {
    case en
    case enIN = "en-IN"
    case hi
    /// Hinglish (Latin-script Hindi mixed with English).
    case hiEn = "hi_en"

    /// `en_IN`, `en-in`, `EN-IN` → `.enIN`; `hi`, `hi-IN` → `.hi`; `hi_en`, `hi-Latn`, `hinglish` →
    /// `.hiEn`; everything else → `.en`.
    public init(tag: String) {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if t == "hi-en" || t == "hi-latn" || t == "hinglish" || t.hasPrefix("hi-en-") { self = .hiEn }
        else if t == "hi" || t.hasPrefix("hi-") { self = .hi }
        else if t == "en-in" || t.hasPrefix("en-in-") { self = .enIN }
        else { self = .en }
    }

    /// Lakh/crore, `₹`, day-first dates.
    public var indian: Bool { self != .en }

    /// The NeMo grammar to ask for. Hinglish is Latin script, so it uses the English grammar; `hi`
    /// asks for NeMo's Hindi grammar (`NemoITN` falls back to `en` when it is not linked).
    public var backendLanguage: String { self == .hi ? "hi" : "en" }
}

// MARK: - Field-role policy

public enum ITNPolicy: String, Sendable, Equatable {
    /// Code editor, terminal: spoken numbers stay exactly as the formatter for that field leaves them.
    case never
    /// Prose rules: 0–9 alone stay words.
    case prose
    /// Spreadsheet cell: every number is digits, even "five".
    case always

    /// `codeEditor` / `terminal` → `.never`; `spreadsheetCell` → `.always`; anything else → `.prose`.
    /// Takes the raw string so a `FieldRole.spreadsheetCell` added later (E2) maps with no change here.
    public init(fieldRole: String?) {
        switch fieldRole {
        case FieldRole.codeEditor.rawValue?, FieldRole.terminal.rawValue?: self = .never
        case "spreadsheetCell"?: self = .always
        default: self = .prose
        }
    }
}

// MARK: - Backend

/// A sentence-level spoken→written normaliser (NeMo). `nil` from `normalizeSentence` = no answer.
public protocol ITNBackend: Sendable {
    func supports(_ language: String) -> Bool
    func normalizeSentence(_ text: String, language: String) -> String?
}

/// Adapts closures — how `App` hands `Engine.NemoITN` to `Pipeline` without a module dependency.
public struct ClosureITNBackend: ITNBackend {
    let supportsLanguage: @Sendable (String) -> Bool
    let normalize: @Sendable (String, String) -> String?
    public init(supports: @escaping @Sendable (String) -> Bool,
                normalize: @escaping @Sendable (String, String) -> String?) {
        self.supportsLanguage = supports
        self.normalize = normalize
    }
    public func supports(_ language: String) -> Bool { supportsLanguage(language) }
    public func normalizeSentence(_ text: String, language: String) -> String? { normalize(text, language) }
}
