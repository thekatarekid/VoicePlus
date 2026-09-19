import Engine
import Foundation
import Shared

// S7b — Today's words (design §8.1, §9; `DESIGN.md` §9.1): held and recoverable text first, then
// recent dictations in time order, each row with time · destination · excerpt · an explicit
// Inserted / Held / Unconfirmed / "1 to review" tag, read from the turn store (S11, `TurnStore`).
//
// Everything here is a value, so every rendering Today, the turn detail and the recovery sheet can
// produce is assertable on a toolchain with no UI testing. Copy that the design fixture carries is
// read from `DesignScreen` / `RecoveryCatalog`; the few sentences the fixture has no entry for
// (history off, search) live in `TodayCopy` below and follow the Problem — Action voice.

// MARK: - The history switch

public extension SettingsKeys {
    /// "Save dictation history" (design §8.5 Privacy row; S7f draws the toggle). When off, Today lists
    /// no recent dictations and search has nothing to search; held text is kept regardless, under
    /// recovery persistence (`SettingsKeys.recoveryPersistence`), which is a separate switch.
    static let dictationHistory = "history.dictation.enabled"
}

public enum TodayHistorySettings {
    /// ON unless the user turned it off — the app has always kept its dictation history.
    public static func isEnabled(_ store: SettingsStore?) -> Bool {
        store?.bool(SettingsKeys.dictationHistory) ?? true
    }

    public static func setEnabled(_ on: Bool, store: SettingsStore?) {
        store?.set(on, for: SettingsKeys.dictationHistory)
    }
}

// MARK: - Reading the turn store

/// What Today, the turn detail and the recovery sheet need from the turn store (S11). A protocol so
/// every rendering is driven by a stub in tests; the app's is `TodayTurnStoreReader` over
/// `TurnStore.current`.
public protocol TodayTurnReading: AnyObject, Sendable {
    /// Newest first. Throws only when the history store exists and cannot be read (S01) — a store
    /// that is merely empty returns `[]`.
    func recentTurns(limit: Int) throws -> [TurnEntry]
    /// Held and partial turns, newest first. Never throws: this session's copies live in memory, and
    /// held text must stay on screen when history cannot be read (design §9 "retain held drafts").
    func recoverableTurns(limit: Int) -> [TurnEntry]
    /// One turn, or nil when it is gone. Throws when it is not in memory and the store can't be read.
    func turnEntry(_ id: TurnID) throws -> TurnEntry?
    /// What a new row gets: kept until resolved, or kept for this session only.
    var persistence: TurnStore.Persistence { get }
    /// True when this turn's save to disk failed (S03: "This text hasn't been saved").
    func saveFailed(_ id: TurnID) -> Bool
    /// Held or partial text the user copied or discarded outside the live held queue.
    func markResolved(_ id: TurnID)
    /// An explicit Insert here that ran outside the live held queue.
    func recordInsertion(_ id: TurnID, outcome: DeliveryOutcome)
    /// Deletes the turn everywhere (Turn detail › Delete, a discarded only copy).
    func delete(_ id: TurnID)
}

// MARK: - Rows and tags

/// The outcome a Today row states in words (`DESIGN.md` §4 "Today tag", §9.1). Colour is never the
/// only signal: every tag is a word, and good / warn also carry a glyph (`StatusTag`).
public enum TodayTag: Equatable, Hashable, Sendable {
    /// Readback confirmed the insertion and no word needs review.
    case inserted
    /// Written, but readback could not confirm it — or only part may have landed (`partial`).
    case unconfirmed
    /// Final text with no safe destination, waiting for Insert here / Copy / Discard.
    case held
    /// Inserted and confirmed, with this many uncertain words ("1 to review"). Opens the turn.
    case toReview(Int)
    /// Held text the user copied or discarded, or a turn that failed before writing.
    case notInserted
    /// An insertion the user undid.
    case undone

    public enum Tone: String, Equatable, Sendable { case good, warn, neutral }

    public var label: String {
        switch self {
        case .inserted: return "Inserted"
        case .unconfirmed: return "Unconfirmed"
        case .held: return "Held"
        case .toReview(let n): return "\(n) to review"
        case .notInserted: return "Not inserted"
        case .undone: return "Undone"
        }
    }

    public var tone: Tone {
        switch self {
        case .inserted: return .good
        case .unconfirmed, .held: return .warn
        case .toReview, .notInserted, .undone: return .neutral
        }
    }

    /// "1 to review" is a button that opens the turn (prototype Today row), not a passive tag.
    public var opensTurn: Bool {
        if case .toReview = self { return true }
        return false
    }

    /// The tag for a turn, or nil for a turn Today does not list (still live, cancelled, nothing
    /// heard, taken by a command). Delivery evidence outranks review: an unconfirmed write says
    /// "Unconfirmed" even when a word is uncertain.
    public static func of(_ entry: TurnEntry) -> TodayTag? {
        let record = entry.record
        switch entry.stage {
        case .held:
            return .held
        case .landed:
            guard let outcome = record.outcome, outcome.isVerified else { return .unconfirmed }
            return record.hasUncertainty ? .toReview(record.uncertainSpans.count) : .inserted
        case .resolved:
            // Copied or discarded held text was never inserted; a resolved partial is still only
            // partly confirmed; a delivery that was resolved afterwards is an Undo (R2).
            guard let outcome = record.outcome else { return .notInserted }
            if outcome.isPartial { return .unconfirmed }
            return outcome.isDelivered ? .undone : .notInserted
        case .failed:
            return .notInserted
        case .starting, .listening, .listeningQuiet, .finishing, .finalPreview, .inserting,
             .cancelled, .empty, .consumed:
            return nil
        }
    }
}

/// One row of "Recent dictations": time · destination · excerpt · tag.
public struct TodayTurnRow: Identifiable, Equatable, Sendable {
    public var id: TurnID
    public var time: Date
    public var destination: String
    public var excerpt: String
    public var tag: TodayTag

    public init(id: TurnID, time: Date, destination: String, excerpt: String, tag: TodayTag) {
        self.id = id
        self.time = time
        self.destination = destination
        self.excerpt = excerpt
        self.tag = tag
    }

    /// A row for an entry Today lists; nil for the rest (and for a turn with no text).
    public init?(_ entry: TurnEntry) {
        guard let tag = TodayTag.of(entry) else { return nil }
        let text = entry.record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.init(id: entry.id, time: entry.record.startedAt, destination: TodayFormat.destination(entry.record),
                  excerpt: TodayFormat.excerpt(text), tag: tag)
    }

    /// "12:42 · Mail" — the row's second line (prototype `row(…, '12:42 · Mail', …)`).
    public func subtitle(timeStyle: (Date) -> String = TodayFormat.time) -> String {
        "\(timeStyle(time)) · \(destination)"
    }
}

/// Where a turn's text is kept, in the words every recovery surface uses (design §8.1).
public enum TodayRetention: Equatable, Sendable {
    /// On disk until the user resolves it.
    case keptUntilResolved
    /// In memory only: persistence is off, there is no database, or the text never reached a turn.
    case sessionOnly
    /// A save was attempted and failed: in memory only, and the surface says so (S03).
    case saveFailed

    public var label: String {
        self == .keptUntilResolved ? TurnStore.keptUntilResolvedLabel : TurnStore.sessionOnlyLabel
    }

    /// True when closing VoicePlus would lose the text.
    public var isSessionOnly: Bool { self != .keptUntilResolved }

    static func of(_ entry: TurnEntry, saveFailed: Bool) -> TodayRetention {
        if saveFailed { return .saveFailed }
        return entry.persisted ? .keptUntilResolved : .sessionOnly
    }
}

// MARK: - Drafts: held and recoverable text

/// One piece of text that still needs the user: held (nothing was inserted) or partial (only part
/// may have been). Today lists these first; Review opens the recovery sheet on one.
///
/// A draft is the union of two records of the same words: the turn (S11, persisted, survives a
/// relaunch) and the live held queue (`FocusGuard.held` via `HeldTextStore`, this session, what
/// Insert here / Copy / Discard act on). Either may be missing — a held latch segment has no turn,
/// a held turn from before a relaunch is not in the live queue.
public struct TodayDraft: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Nothing was inserted.
        case held
        /// Only part may have been inserted (D07).
        case partial
    }

    public var turnID: TurnID?
    /// The live held item carrying these words, when there is one.
    public var heldID: UUID?
    public var kind: Kind
    public var text: String
    /// What the engine heard before formatting, when the turn kept it.
    public var rawText: String
    /// App name ("Mail"); empty when unknown.
    public var destination: String
    /// `DeliveryOutcome` reason ("destination changed", …); empty for a partial.
    public var reason: String
    public var date: Date
    public var uncertainSpans: [Range<Int>]
    public var retention: TodayRetention

    public init(turnID: TurnID? = nil, heldID: UUID? = nil, kind: Kind = .held, text: String, rawText: String = "",
                destination: String, reason: String = "", date: Date = Date(), uncertainSpans: [Range<Int>] = [],
                retention: TodayRetention = .sessionOnly) {
        self.turnID = turnID
        self.heldID = heldID
        self.kind = kind
        self.text = text
        self.rawText = rawText
        self.destination = destination
        self.reason = reason
        self.date = date
        self.uncertainSpans = uncertainSpans
        self.retention = retention
    }

    /// Stable across reloads: the turn when there is one, else the held item.
    public var id: String {
        if let turnID { return "turn:\(turnID.rawValue.uuidString)" }
        return "held:\(heldID?.uuidString ?? "")"
    }

    /// The catalogue entry that explains what happened (D01 destination changed, D04 app rule, …).
    public var recovery: RecoveryEntry {
        kind == .partial ? RecoveryCatalog.entry(.D07) : RecoveryCatalog.entry(forDeliveryReason: reason.isEmpty ? "destination changed" : reason)
    }

    /// "Text waiting for Mail" (prototype Today banner) · "Only part may have been inserted in Mail".
    public var headline: String {
        switch kind {
        case .held: return destination.isEmpty ? TodayCopy.textWaiting : TodayCopy.textWaiting(for: destination)
        case .partial: return destination.isEmpty ? TodayCopy.partialHeadline : TodayCopy.partialHeadline(in: destination)
        }
    }

    /// The line under the text: "Destination changed. Nothing was inserted." for D01, the entry's
    /// own words otherwise.
    public var consequence: String {
        switch kind {
        case .partial:
            return recovery.consequence
        case .held:
            if recovery.id == .D01 { return TodayCopy.destinationChangedNothingInserted }
            return "\(TodayFormat.sentence(recovery.headline)) \(TodayCopy.nothingInserted)"
        }
    }

    /// "Destination changed · held for Mail" — the recovery sheet's subtitle.
    public var sheetSubtitle: String {
        let cause: String
        switch kind {
        case .partial: cause = TodayCopy.partialCause
        case .held: cause = recovery.id == .D01 ? TodayCopy.destinationChangedCause : TodayFormat.sentenceFragment(recovery.headline)
        }
        return destination.isEmpty ? cause : "\(cause) · held for \(destination)"
    }

    /// Builds the draft list: every recoverable turn, joined to its live held item, plus live held
    /// items no turn accounts for. Newest first.
    public static func merge(recoverable: [TurnEntry], live: [HeldItem], turnOf: (UUID) -> TurnID?,
                             saveFailed: (TurnID) -> Bool) -> [TodayDraft] {
        var liveByTurn: [TurnID: HeldItem] = [:]
        var unclaimed: [HeldItem] = []
        for item in live {
            if let turn = turnOf(item.id) { liveByTurn[turn] = item } else { unclaimed.append(item) }
        }
        var drafts: [TodayDraft] = []
        var seen: Set<TurnID> = []
        for entry in recoverable where isRecoverable(entry) && !seen.contains(entry.id) {
            seen.insert(entry.id)
            let record = entry.record
            let item = liveByTurn[entry.id]
            let text = record.finalText.isEmpty ? (item?.text ?? "") : record.finalText
            guard !text.isEmpty else { continue }
            let partial = entry.stage != .held
            drafts.append(TodayDraft(turnID: entry.id, heldID: item?.id, kind: partial ? .partial : .held,
                                     text: text, rawText: record.rawText,
                                     destination: TodayFormat.appName(record) ?? item?.destination ?? "",
                                     reason: record.outcome?.reason ?? item?.reason ?? "",
                                     date: record.startedAt, uncertainSpans: record.uncertainSpans,
                                     retention: .of(entry, saveFailed: saveFailed(entry.id))))
        }
        // A live item whose turn is not listed as recoverable (the turn record is gone, or the text
        // never came through a turn): it is still held, so it is still shown.
        for (turn, item) in liveByTurn where !seen.contains(turn) { unclaimed.append(item) }
        for item in unclaimed where !item.text.isEmpty {
            drafts.append(TodayDraft(turnID: turnOf(item.id), heldID: item.id, kind: .held, text: item.text,
                                     destination: item.destination, reason: item.reason, date: item.heldAt,
                                     retention: .sessionOnly))
        }
        return drafts.sorted { $0.date > $1.date }
    }

    /// Held, or landed with only part of the text written. A partial the user resolved is settled
    /// (`TurnEntry.isRecoverable` alone would keep it on top forever).
    public static func isRecoverable(_ entry: TurnEntry) -> Bool {
        switch entry.stage {
        case .held: return true
        case .landed: return entry.record.outcome?.isPartial == true
        default: return false
        }
    }
}

// MARK: - Formatting

public enum TodayFormat {
    /// The row excerpt: the first line, at most `limit` characters, never cut mid-word when a space
    /// is near.
    public static func excerpt(_ text: String, limit: Int = 72) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        var cut = String(trimmed.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    /// The app a turn was aimed at, by name — never a bundle ID in copy.
    public static func appName(_ record: TurnRecord) -> String? {
        guard let name = record.destination.appName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
    }

    /// The row's destination word: the app name, or "Unknown app".
    public static func destination(_ record: TurnRecord) -> String { appName(record) ?? TodayCopy.unknownApp }

    /// "12:42" in the user's clock style.
    public static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// Words in a text, the way a person counts them.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// "9 words" / "1 word".
    public static func words(_ count: Int) -> String { count == 1 ? "1 word" : "\(count) words" }

    /// A turn's page title: the first few words of its first sentence ("Can we meet with Mira…").
    /// The prototype's "Friday check-in" is sample data; a real turn is named by what was said.
    public static func title(_ text: String, words limit: Int = 6) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = trimmed.firstIndex(where: { ".?!\n".contains($0) }) ?? trimmed.endIndex
        let words = trimmed[..<end].split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return TodayCopy.untitledTurn }
        if words.count <= limit { return words.joined(separator: " ") }
        return words.prefix(limit).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters) + "…"
    }

    /// "Today" / "Yesterday" / the date — the same words the Timeline uses.
    public static func day(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        TimelineDay.title(for: calendar.startOfDay(for: date), calendar: calendar, now: now)
    }

    /// "Mail · Today, 12:42 · 9 words" (`DESIGN.md` §9 Turn detail subtitle).
    public static func turnSubtitle(_ record: TurnRecord, calendar: Calendar = .current, now: Date = Date(),
                                    timeStyle: (Date) -> String = TodayFormat.time) -> String {
        "\(destination(record)) · \(day(record.startedAt, calendar: calendar, now: now)), \(timeStyle(record.startedAt)) · \(words(wordCount(record.finalText)))"
    }

    /// The words at `spans` (UTF-16 ranges) of `text`, in order; out-of-range spans are skipped.
    public static func words(in text: String, spans: [Range<Int>]) -> [String] {
        let ns = text as NSString
        return spans.sorted { $0.lowerBound < $1.lowerBound }.compactMap { span in
            guard span.lowerBound >= 0, span.upperBound <= ns.length, !span.isEmpty else { return nil }
            return ns.substring(with: NSRange(location: span.lowerBound, length: span.count))
        }
    }

    /// A headline as the start of a sentence: "Dictation is off in this app." (trailing period added).
    static func sentence(_ headline: String) -> String {
        let t = headline.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }

    /// A headline as a subtitle fragment: no trailing period.
    static func sentenceFragment(_ headline: String) -> String {
        headline.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
    }
}

// MARK: - Copy

/// Today's own sentences — only those the design fixture has no entry for. Everything with a fixture
/// entry (titles, empties, catalogue errors) is read from `DesignScreen` and `RecoveryCatalog`.
public enum TodayCopy {
    // The page
    public static let recentHeading = "Recent dictations"
    public static let tryDictation = "Try dictation"
    /// Design §9 Today loading.
    public static let loadingRecent = "Loading recent dictations…"
    /// Design §9 Turn detail / recovery loading.
    public static let openingSavedText = "Opening saved text…"
    /// Prototype Today foot: "Hold [key] to speak. Release to preview, then insert."
    public static let holdHintBefore = "Hold"
    public static let holdHintAfter = "to speak. Release to preview, then insert."

    // History off (design §8.1: its own explanatory empty state, not "No results")
    public static let historyOff = "Dictation history is off"
    public static let historyOffDetail = "Recent dictations aren’t kept on this Mac, so there is nothing to list or search. Held text still waits here until you resolve it."
    /// The Privacy empty state's action (fixture `emptyCopy.privacy`).
    public static let reviewRetention = "Review retention"

    // Search (design §9 Search: "No matches for …" + Clear search)
    public static func noMatches(_ query: String) -> String { "No matches for “\(query)”" }
    public static let noMatchesDetail = "Search looks through the dictations kept on this Mac."
    public static let clearSearch = "Clear search"

    // Held / recoverable
    public static let textWaiting = "Text waiting"
    public static func textWaiting(for app: String) -> String { "Text waiting for \(app)" }
    public static let partialHeadline = "Only part may have been inserted"
    public static func partialHeadline(in app: String) -> String { "Only part may have been inserted in \(app)" }
    public static let destinationChangedNothingInserted = "Destination changed. Nothing was inserted."
    public static let nothingInserted = "Nothing was inserted."
    public static let destinationChangedCause = "Destination changed"
    public static let partialCause = "Only part may have been inserted"
    public static let reviewText = "Review text"
    public static let copy = "Copy"
    public static let copyText = "Copy text"
    /// Shown only after the pasteboard was read back and holds exactly the text.
    public static let copied = "Copied. Paste it wherever you want it."
    public static let unknownApp = "Unknown app"
    public static let untitledTurn = "Untitled dictation"

    // Navigation
    /// The turn detail's way back to the list.
    public static let backToToday = "Today"
}
