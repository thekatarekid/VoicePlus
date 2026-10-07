import Foundation

// Context Writer (VoicePlus_ContextWriter_Plan.md §1–§2) — the shared packet contract.
//
// The App builds one `ContextPacket` per turn at key-down (AX snapshot, thread/document text,
// screen terms, vocabulary matches, the raw recogniser output) and writes it into
// `StageContext.extra[ContextPacket.contextKey]` as JSON. `Pipeline`'s `ContextWriterStage`
// renders it into the prompt; `Providers` backends and the Lab suite consume the same type.
// Shared owns only the type: no reading, no ranking, no prompt text lives here.

/// What the writer is asked to do with the heard text (plan §1).
public enum WriterMode: String, Codable, Sendable, CaseIterable {
    /// What the user said, corrected and formatted for the destination.
    case transcribe
    /// What the user meant: compose the text the destination needs (or report `act`).
    case instruct
}

public struct ContextPacket: Codable, Sendable, Equatable {
    /// `StageContext.extra` key holding the JSON-encoded packet.
    public static let contextKey = "writer.packet"
    /// `StageContext.extra` key holding `WriterMode.rawValue` (defaults to `.transcribe`).
    public static let modeKey = "writer.mode"

    /// Where the text is going (plan §2.1). `fields` is the surface-specific record, keys such as
    /// `to`, `cc`, `subject`, `quotedFrom`, `channel`, `participants`, `foregroundProcess`,
    /// `shell`, `cwd`, `entries`, `knownCommands`, `activeCell`, `headers`, `filePath`,
    /// `language`, `caretRegion` (code|comment|string), `heading`, `windowTitle`, `documentTitle`,
    /// `urlHost`, `box` (title|body|notes). Only what the reader actually found.
    public struct Destination: Codable, Sendable, Equatable {
        /// Destination profile id (plan §3, `Pipeline/Writer/Destinations`), e.g. `chat.message`,
        /// `ai.chat`, `ai.agentCLI`, `shell`, `code.body`, `code.comment`, `commit`, `document`,
        /// `markdown`, `slides.title`, `slides.body`, `slides.notes`, `spreadsheet.cell`,
        /// `email.subject`, `email.body.reply`, `email.body.new`, `browser.urlBar`, `search`,
        /// `form`, `notes`, `social`, `calendar.title`, `calendar.notes`, `secure`, `unknown`.
        public var profileID: String
        public var appName: String?
        public var appBundleID: String?
        /// `SurfaceKind.key` of the resolved surface.
        public var surfaceKind: String
        public var fields: [String: String]

        public init(profileID: String, appName: String? = nil, appBundleID: String? = nil,
                    surfaceKind: String = "unknown", fields: [String: String] = [:]) {
            self.profileID = profileID
            self.appName = appName
            self.appBundleID = appBundleID
            self.surfaceKind = surfaceKind
            self.fields = fields
        }
    }

    /// One message or block of the visible thread / document around the caret (plan §2.2).
    public struct ThreadBlock: Codable, Sendable, Equatable {
        public var author: String?
        public var text: String
        /// True when the block is the user's own earlier message (when the reader can tell).
        public var isSelf: Bool?
        public init(author: String? = nil, text: String, isSelf: Bool? = nil) {
            self.author = author
            self.text = text
            self.isSelf = isSelf
        }
    }

    /// A vocabulary term matched phonetically to an uncertain span (plan §2.4).
    public struct VocabularyMatch: Codable, Sendable, Equatable {
        /// Written form, as it should land.
        public var term: String
        /// The spoken form that matched.
        public var spokenForm: String
        /// The heard words it matched (one or more adjacent words, joined by spaces).
        public var heard: String
        /// 0…1, higher is a closer match (phonetic closeness × frequency × recency × source).
        public var score: Double
        /// `dictionary`, `correction`, `learned`, `screen`, `repo`, `document`, `contact`, …
        public var source: String
        public init(term: String, spokenForm: String, heard: String, score: Double, source: String) {
            self.term = term
            self.spokenForm = spokenForm
            self.heard = heard
            self.score = score
            self.source = source
        }
    }

    /// The recogniser's output, raw (plan §2.5): the pre-boost 1-best with per-word confidence
    /// and top-K alternates. Anything a booster or repair pass produced is evidence in
    /// `alternates` / `boosted`, never the base text.
    public struct HeardWord: Codable, Sendable, Equatable {
        public var text: String
        public var confidence: Float
        /// Top-K alternates from the decoder and any evidence pass, best first, deduplicated.
        public var alternates: [String]
        public var isUncertain: Bool { confidence < TranscriptSpan.lowConfidenceThreshold }
        public init(text: String, confidence: Float, alternates: [String] = []) {
            self.text = text
            self.confidence = confidence
            self.alternates = alternates
        }
    }

    public struct Heard: Codable, Sendable, Equatable {
        /// The raw 1-best, pre-boost, as the recogniser wrote it.
        public var raw: String
        public var words: [HeardWord]
        /// What the booster / repair pre-pass would have written, when it differs (evidence only).
        public var boosted: String?
        public init(raw: String, words: [HeardWord] = [], boosted: String? = nil) {
            self.raw = raw
            self.words = words
            self.boosted = boosted
        }

        /// `raw` with every uncertain word wrapped in ⟦ ⟧ (the prompt's marking).
        public var marked: String {
            guard !words.isEmpty else { return raw }
            return words.map { $0.isUncertain ? "⟦\($0.text)⟧" : $0.text }.joined(separator: " ")
        }
    }

    public var mode: WriterMode
    public var destination: Destination
    /// Text immediately before / after the caret in the focused field (bounded by the builder).
    public var textBefore: String
    public var textAfter: String
    /// The visible thread (chat, email, AI chat) or the document around the caret, oldest first.
    public var thread: [ThreadBlock]
    /// Ranked screen terms, nearest the caret first (spelling aid only, ≤ 40).
    public var screenTerms: [String]
    public var vocabulary: [VocabularyMatch]
    /// The user's last few landed dictations in this app, newest first.
    public var recentDictations: [String]
    /// The per-app persona text (Settings › Personas), when any.
    public var persona: String?
    /// BCP-47 of the dictation when known (`en`, `hi`, …).
    public var language: String?
    public var heard: Heard
    /// A secure destination: the builder read nothing from the field or the screen.
    public var isSecure: Bool

    public init(mode: WriterMode = .transcribe, destination: Destination, textBefore: String = "",
                textAfter: String = "", thread: [ThreadBlock] = [], screenTerms: [String] = [],
                vocabulary: [VocabularyMatch] = [], recentDictations: [String] = [], persona: String? = nil,
                language: String? = nil, heard: Heard, isSecure: Bool = false) {
        self.mode = mode
        self.destination = destination
        self.textBefore = textBefore
        self.textAfter = textAfter
        self.thread = thread
        self.screenTerms = screenTerms
        self.vocabulary = vocabulary
        self.recentDictations = recentDictations
        self.persona = persona
        self.language = language
        self.heard = heard
        self.isSecure = isSecure
    }

    // MARK: StageContext transport

    public func encoded() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func decode(_ json: String?) -> ContextPacket? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ContextPacket.self, from: data)
    }

    public func write(into context: inout StageContext) {
        context.extra[Self.contextKey] = encoded()
        context.extra[Self.modeKey] = mode.rawValue
    }

    public static func read(from context: StageContext) -> ContextPacket? {
        decode(context.extra[contextKey])
    }

    public static func mode(of context: StageContext) -> WriterMode {
        context.extra[modeKey].flatMap(WriterMode.init(rawValue:)) ?? .transcribe
    }
}

/// Phonetic vocabulary lookup over the heard words (plan §2.4). Implemented in `Engine`
/// (`Engine/Biasing`), consumed by the App's packet builder; no model call, milliseconds.
public protocol VocabularyMatching: Sendable {
    func matches(heard: ContextPacket.Heard, limit: Int) -> [ContextPacket.VocabularyMatch]
}
