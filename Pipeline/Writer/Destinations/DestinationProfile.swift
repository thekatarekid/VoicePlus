import Foundation

// Context Writer (VoicePlus_ContextWriter_Plan.md §3) — one output spec per destination.
//
// A profile is data: what the surface is, how it is detected, how transcribed text must look there,
// what instruct mode adds, and what must never happen. `WriterPrompt` renders the text fields into
// the system prompt; the `formatting` switches are for the guard and the formatters, which must not
// parse prose. The rows live in `DestinationProfiles.all` (a Swift literal: the package declares no
// resources). Keep every string tight — it is rendered into every prompt.

public struct DestinationProfile: Sendable, Equatable, Identifiable {

    /// How words are cased when nothing was dictated about it.
    public enum Casing: String, Sendable, Codable, CaseIterable {
        /// First word of each sentence capitalised.
        case sentence
        /// Title Case (slide titles, subjects, event titles).
        case title
        /// Everything lowercase (shell, URL bar, search).
        case lower
        /// The file's own convention (camelCase / snake_case from nearby symbols).
        case fileConvention
        /// Exactly as spoken; the field's own format decides (form values, cells).
        case asSpoken
    }

    /// Whether a sentence ends with a full stop.
    public enum TerminalPunctuation: String, Sendable, Codable, CaseIterable {
        /// Proper sentences, always punctuated.
        case always
        /// No full stop on a one-liner; punctuation inside longer messages.
        case light
        /// Never a trailing period (commands, titles, cells, fragments).
        case never
    }

    /// Where line breaks may appear.
    public enum LineBreaks: String, Sendable, Codable, CaseIterable {
        /// Only where the user said "new line" / "new paragraph".
        case onlyWhenDictated
        /// Paragraphs on long pauses and topic shifts.
        case paragraphs
        /// Short lines for beats (social posts).
        case beats
        /// One line, never a break.
        case none
    }

    /// Numerals versus words (units, currency, times, phone numbers, versions are always numerals).
    public enum Numerals: String, Sendable, Codable, CaseIterable {
        /// Words under ten, numerals from ten.
        case tenAndAbove
        /// Always digits.
        case always
        /// As spoken; the field's own pattern decides.
        case asSpoken
    }

    /// How an enumeration ("first… second…", "bullet …") lands.
    public enum Lists: String, Sendable, Codable, CaseIterable {
        /// No list structure; keep it inline.
        case none
        /// `1.` lines.
        case numbered
        /// `-` bullets.
        case bullets
        /// The app's own list style (Docs, Word, Pages).
        case appStyle
        /// Checklist items (Notes, Reminders).
        case checklist
        /// One fragment per bullet, no bullet glyph (slide body boxes).
        case fragments
    }

    /// A length ceiling the profile enforces.
    public enum LengthLimit: Sendable, Equatable, Codable {
        case words(Int)
        case characters(Int)
        /// The platform's own post limit.
        case platform
    }

    /// Whether a greeting ("Hi Sam,") may open the text.
    public enum Greeting: String, Sendable, Codable, CaseIterable {
        /// Never add one.
        case never
        /// Only when dictated.
        case whenDictated
        /// By default, unless the persona says otherwise.
        case byDefault
    }

    /// The machine-readable switches the guard and formatters read.
    public struct Formatting: Sendable, Equatable {
        public var casing: Casing
        public var terminalPunctuation: TerminalPunctuation
        public var lineBreaks: LineBreaks
        public var numerals: Numerals
        public var lists: Lists
        public var lengthLimit: LengthLimit?
        public var greeting: Greeting
        public var markdownAllowed: Bool

        public init(casing: Casing = .sentence, terminalPunctuation: TerminalPunctuation = .always,
                    lineBreaks: LineBreaks = .paragraphs, numerals: Numerals = .tenAndAbove, lists: Lists = .none,
                    lengthLimit: LengthLimit? = nil, greeting: Greeting = .whenDictated, markdownAllowed: Bool = false) {
            self.casing = casing
            self.terminalPunctuation = terminalPunctuation
            self.lineBreaks = lineBreaks
            self.numerals = numerals
            self.lists = lists
            self.lengthLimit = lengthLimit
            self.greeting = greeting
            self.markdownAllowed = markdownAllowed
        }
    }

    /// Stable id, the value of `ContextPacket.Destination.profileID` (`chat.message`, `shell`, …).
    public let id: String
    /// Human title, also the prompt's heading ("Chat message").
    public let title: String
    /// How the packet builder recognises the destination (for the builder and the Lab; not rendered).
    public let detection: String
    /// Output rules in transcribe mode (rendered as the profile block).
    public let transcribe: String
    /// What instruct mode adds; `nil` when instruct is not offered on this destination.
    public let instruct: String?
    /// What must never happen here; `nil` when the row has none.
    public let never: String?
    public let formatting: Formatting
    /// True when no model may be called and nothing is read (secure fields).
    public let isSecure: Bool

    public init(id: String, title: String, detection: String, transcribe: String, instruct: String? = nil,
                never: String? = nil, formatting: Formatting = Formatting(), isSecure: Bool = false) {
        self.id = id
        self.title = title
        self.detection = detection
        self.transcribe = transcribe
        self.instruct = instruct
        self.never = never
        self.formatting = formatting
        self.isSecure = isSecure
    }

    /// Whether the destination offers instruct mode at all (plan §3: "—" rows do not).
    public var supportsInstruct: Bool { instruct != nil }
}
