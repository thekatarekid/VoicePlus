import Foundation
import Injection
import Shared

// H25 — one outcome type for every turn (investigation 2026-10-03 §2 "Outcome messages", final fix
// list H25). Every turn ends with exactly one `TurnOutcome`; the pill, Today, the menu ("Last: …"),
// the turn detail and the menu's Recent rows all read their one plain line from here, so the five
// surfaces can never disagree about where the words went.
//
// Producers record the outcome beside the turn through the generic `TurnRecordExtras` keys
// (`TurnOutcome.write(into:)` → `outcomeKind` / `outcomeReason` / `outcomeAction` / `intendedApp`);
// a turn recorded before H25, or by a path that does not set them, is derived from its stage and
// delivery outcome (`TurnOutcome.of(_:)`).

/// Why words went to Notes instead of a field. Raw values are stable on disk (turn extras, note
/// metadata). `why` is the short phrase a Notes row shows after "Not typed in <App> · ".
public enum NoteReason: String, Codable, Sendable, CaseIterable, Equatable {
    case noTextField = "no-text-field"
    case windowClosed = "window-closed"
    case couldNotReturn = "could-not-return"
    case editFailed = "edit-failed"
    case cancelled
    case appSwitched = "app-switched"
    case otherVoice = "other-voice"
    case meetingAside = "meeting-aside"
    case actionRunning = "action-running"
    case neverInject = "never-inject"
    case spokenNote = "spoken-note"
    case declinedAsk = "declined-ask"
    case overheard

    /// "window closed", "no text field" — lower case, no app name.
    public var why: String {
        switch self {
        case .noTextField: return "no text field"
        case .windowClosed: return "window closed"
        case .couldNotReturn: return "couldn’t return to it"
        case .editFailed: return "couldn’t edit the selection"
        case .cancelled: return "cancelled"
        case .appSwitched: return "you switched apps"
        case .otherVoice: return "another voice"
        case .meetingAside: return "meeting aside"
        case .actionRunning: return "an action was running"
        case .neverInject: return "app is set to never type"
        case .spokenNote: return "you said “note”"
        case .declinedAsk: return "you declined"
        case .overheard: return "overheard"
        }
    }

    /// The words were meant for Notes (not a failed delivery): the row does not say "Not typed".
    public var isIntentional: Bool { self == .spokenNote }

    /// "Not typed in Claude · window closed" / "Not typed · no text field" (H24 note row).
    public func noteLine(intendedApp: String?) -> String {
        if isIntentional { return "Saved to Notes · \(why)" }
        let app = TurnOutcome.clean(intendedApp)
        return (app.map { "Not typed in \($0)" } ?? "Not typed") + " · " + why
    }
}

/// The surfaces that show a turn's outcome.
public enum OutcomeSurface: String, CaseIterable, Sendable {
    case pill, today, menu, turnDetail, recent
}

/// How one turn ended. One case per situation in §2; `line(on:)` is the only place its words live.
public enum TurnOutcome: Equatable, Sendable {
    case inserted(app: String?)
    case replacedSelection(app: String?)
    /// A voice edit applied: `action` is "Shortened selection", "Made a bulleted list", …
    case edited(action: String, app: String?)
    /// A spoken command / action ran: `action` is "Undo", "Send", …
    case actionDone(action: String, app: String?)
    case savedToNotes(intendedApp: String?, reason: NoteReason)
    /// Cancel / Escape after the words were recognised (Q6).
    case cancelledToNotes(intendedApp: String?)
    /// Cancelled before anything was recognised.
    case cancelled
    /// A password field: nothing typed, nothing saved anywhere.
    case refusedSecure
    case nothingHeard
    /// Notes could not store the words: they stay in history with Copy.
    case notesSaveFailed(intendedApp: String?)
    case handsFreeSegment(app: String?)
    case handsFreeEnded(app: String?, inserted: Int, savedToNotes: Int)
    /// Written, but readback could not confirm it.
    case unconfirmed(app: String?)
    /// Only part may have landed.
    case partial(app: String?)
    /// Inserted, then undone.
    case undone(app: String?)
    /// Nothing typed for another reason (a failed write, a pre-H23 held row).
    case notTyped(app: String?)
    /// Still moving.
    case inProgress(app: String?)

    // MARK: Words

    /// The one plain line (§2 "Exact text").
    public var text: String {
        switch self {
        case .inserted(let app), .handsFreeSegment(let app): return Self.phrase("Inserted", app)
        case .replacedSelection(let app): return Self.phrase("Replaced selection", app)
        case .edited(let action, let app): return Self.phrase(action, app)
        case .actionDone(let action, let app): return Self.phrase("\(action) done", app)
        case .savedToNotes(let intended, let reason): return Self.notesLine(reason, intended)
        case .cancelledToNotes: return "Cancelled · Saved to Notes"
        case .cancelled: return "Cancelled · nothing typed"
        case .refusedSecure: return "Not typed · password field"
        case .nothingHeard: return "Didn’t hear anything · Nothing was typed."
        case .notesSaveFailed: return "Couldn’t save to Notes"
        case .handsFreeEnded(let app, let inserted, let saved):
            var s = "Hands-free ended · " + Self.phrase("\(inserted) inserted", app)
            if saved > 0 { s += " · \(saved) saved to Notes" }
            return s
        case .unconfirmed(let app): return Self.phrase("Couldn’t confirm insertion", app)
        case .partial(let app): return Self.phrase("Partly inserted", app)
        case .undone(let app): return Self.phrase("Inserted", app) + ", then undone"
        case .notTyped(let app): return Self.phrase("Not typed", app)
        case .inProgress(let app): return Self.phrase("Inserting", app) + "…"
        }
    }

    /// The line a surface shows. Every surface says the same thing; the menu prefixes "Last: ", and
    /// the pill's nothing-heard line is the short form (Q3).
    public func line(on surface: OutcomeSurface) -> String {
        switch surface {
        case .menu: return "Last: " + text
        // Q3 (round 2, overrides §2): the pill says only "Didn't hear anything", gone 1.5 s after
        // release; the history surfaces keep the full sentence.
        case .pill where self == .nothingHeard: return "Didn’t hear anything"
        case .pill, .today, .turnDetail, .recent: return text
        }
    }

    public var pillLine: String { line(on: .pill) }
    public var todayLine: String { line(on: .today) }
    public var menuLine: String { line(on: .menu) }
    public var turnDetailLine: String { line(on: .turnDetail) }
    public var recentLine: String { line(on: .recent) }

    /// A Copy button goes with the line (the Notes save failed; the words are in history).
    public var offersCopy: Bool { if case .notesSaveFailed = self { return true }; return false }

    /// The words are in Notes.
    public var savedToNotes: Bool {
        switch self {
        case .savedToNotes, .cancelledToNotes: return true
        case .handsFreeEnded(_, _, let saved): return saved > 0
        default: return false
        }
    }

    /// A password-field turn: never listed in Recent, no text kept.
    public var isSecureRefusal: Bool { self == .refusedSecure }

    // MARK: Persisted form (generic TurnRecordExtras keys)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case inserted, replacedSelection = "replaced-selection", edited, actionDone = "action-done"
        case savedToNotes = "saved-to-notes", cancelledToNotes = "cancelled-to-notes", cancelled
        case refusedSecure = "refused-secure", nothingHeard = "nothing-heard"
        case notesSaveFailed = "notes-save-failed", handsFreeSegment = "hands-free-segment"
        case handsFreeEnded = "hands-free-ended", unconfirmed, partial, undone
        case notTyped = "not-typed", inProgress = "in-progress"
    }

    public var kind: Kind {
        switch self {
        case .inserted: return .inserted
        case .replacedSelection: return .replacedSelection
        case .edited: return .edited
        case .actionDone: return .actionDone
        case .savedToNotes: return .savedToNotes
        case .cancelledToNotes: return .cancelledToNotes
        case .cancelled: return .cancelled
        case .refusedSecure: return .refusedSecure
        case .nothingHeard: return .nothingHeard
        case .notesSaveFailed: return .notesSaveFailed
        case .handsFreeSegment: return .handsFreeSegment
        case .handsFreeEnded: return .handsFreeEnded
        case .unconfirmed: return .unconfirmed
        case .partial: return .partial
        case .undone: return .undone
        case .notTyped: return .notTyped
        case .inProgress: return .inProgress
        }
    }

    /// The app the words were (or were meant to be) for.
    public var app: String? {
        switch self {
        case .inserted(let a), .replacedSelection(let a), .edited(_, let a), .actionDone(_, let a),
             .savedToNotes(let a, _), .cancelledToNotes(let a), .notesSaveFailed(let a),
             .handsFreeSegment(let a), .handsFreeEnded(let a, _, _), .unconfirmed(let a), .partial(let a),
             .undone(let a), .notTyped(let a), .inProgress(let a):
            return a
        case .cancelled, .refusedSecure, .nothingHeard: return nil
        }
    }

    /// The stored reason: a `NoteReason` raw value, or "secure field" for a password refusal.
    public var reasonCode: String? {
        switch self {
        case .savedToNotes(_, let r): return r.rawValue
        case .cancelledToNotes: return NoteReason.cancelled.rawValue
        case .refusedSecure: return Self.secureReason
        default: return nil
        }
    }

    /// The stored reason for a password-field refusal (matches `DeliveryReason.secureField`).
    public static let secureReason = "secure field"

    /// Records this outcome in a turn's extras (`TurnStore.setExtras`).
    public func write(into extras: inout TurnRecordExtras) {
        extras.outcomeKind = kind.rawValue
        extras.outcomeReason = reasonCode
        extras.intendedApp = app
        switch self {
        case .edited(let action, _), .actionDone(let action, _): extras.outcomeAction = action
        case .handsFreeEnded(_, let inserted, let saved): extras.outcomeAction = "\(inserted)/\(saved)"
        default: break
        }
    }

    /// The outcome a producer recorded in `extras`, if any.
    public static func recorded(in extras: TurnRecordExtras, fallbackApp: String? = nil) -> TurnOutcome? {
        guard let raw = extras.outcomeKind, let kind = Kind(rawValue: raw) else { return nil }
        let app = clean(extras.intendedApp) ?? clean(fallbackApp)
        let action = extras.outcomeAction ?? ""
        switch kind {
        case .inserted: return .inserted(app: app)
        case .replacedSelection: return .replacedSelection(app: app)
        case .edited: return .edited(action: action.isEmpty ? "Edited selection" : action, app: app)
        case .actionDone: return .actionDone(action: action.isEmpty ? "Command" : action, app: app)
        case .savedToNotes:
            return .savedToNotes(intendedApp: app, reason: extras.outcomeReason.flatMap(NoteReason.init) ?? .noTextField)
        case .cancelledToNotes: return .cancelledToNotes(intendedApp: app)
        case .cancelled: return .cancelled
        case .refusedSecure: return .refusedSecure
        case .nothingHeard: return .nothingHeard
        case .notesSaveFailed: return .notesSaveFailed(intendedApp: app)
        case .handsFreeSegment: return .handsFreeSegment(app: app)
        case .handsFreeEnded:
            let parts = action.split(separator: "/").compactMap { Int($0) }
            return .handsFreeEnded(app: app, inserted: parts.first ?? 0, savedToNotes: parts.count > 1 ? parts[1] : 0)
        case .unconfirmed: return .unconfirmed(app: app)
        case .partial: return .partial(app: app)
        case .undone: return .undone(app: app)
        case .notTyped: return .notTyped(app: app)
        case .inProgress: return .inProgress(app: app)
        }
    }

    // MARK: Deriving from a turn

    /// The outcome of one turn: what a producer recorded, else derived from stage + delivery.
    public static func of(_ entry: TurnEntry) -> TurnOutcome {
        let app = clean(entry.record.destination.appName)
        if let recorded = recorded(in: entry.extras, fallbackApp: app) { return recorded }
        let outcome = entry.record.outcome
        switch entry.stage {
        case .starting, .listening, .listeningQuiet, .finishing, .finalPreview, .inserting:
            return .inProgress(app: app)
        case .landed:
            guard let outcome else { return .inserted(app: app) }
            if outcome.isPartial { return .partial(app: app) }
            return outcome.isVerified ? .inserted(app: app) : .unconfirmed(app: app)
        case .held, .failed:
            if outcome?.reason == secureReason { return .refusedSecure }
            return .notTyped(app: app)
        case .resolved:
            guard let outcome else { return .notTyped(app: app) }
            if outcome.isPartial { return .partial(app: app) }
            return outcome.isDelivered ? .undone(app: app) : .notTyped(app: app)
        case .cancelled: return .cancelled
        case .empty: return .nothingHeard
        case .consumed: return .actionDone(action: "Command", app: app)
        }
    }

    // MARK: Helpers

    static func clean(_ name: String?) -> String? {
        guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return n
    }

    private static func phrase(_ head: String, _ app: String?) -> String {
        clean(app).map { "\(head) in \($0)" } ?? head
    }

    private static func notesLine(_ reason: NoteReason, _ intended: String?) -> String {
        let app = clean(intended)
        switch reason {
        case .noTextField: return "Saved to Notes · no text field"
        case .windowClosed: return "Saved to Notes · " + (app.map { "\($0) window closed" } ?? "window closed")
        case .couldNotReturn: return "Saved to Notes · couldn’t return to " + (app ?? "the app")
        case .editFailed: return "Couldn’t edit the selection · Saved to Notes"
        case .cancelled: return "Cancelled · Saved to Notes"
        default: return "Saved to Notes · " + reason.why
        }
    }
}

public extension TurnEntry {
    /// H25 — this turn's one outcome.
    var turnOutcome: TurnOutcome { TurnOutcome.of(self) }
}

// MARK: - H23 — a former hold's reason, as the Notes reason

public extension NoteReason {
    /// H23 — the Notes reason for words that used to be *held* (`FocusGuard.hold`, a `.held` turn),
    /// from the held / delivery reason string. `nil` for a password field: a secure turn saves
    /// nothing anywhere.
    static func forHeld(reason: String?) -> NoteReason? {
        guard let raw = reason?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .couldNotReturn
        }
        if raw == TurnOutcome.secureReason || raw == "password field" { return nil }
        if let exact = NoteReason(rawValue: raw) { return exact }
        // N2 / Q6 — Cancel or Escape after words ("kept, not typed"): "Cancelled · Saved to Notes".
        if raw == DeliveryReason.keptByUser { return .cancelled }
        if raw.contains("never-inject") { return .neverInject }
        if raw.contains("window was closed") || raw.contains("window closed") || raw.contains("window gone") {
            return .windowClosed
        }
        if raw.contains("no destination") || raw.contains("no window") || raw.contains("text box")
            || raw.contains("no text field") || raw.contains("not editable") { return .noTextField }
        if raw.contains("selection") || raw.contains("edit") { return .editFailed }
        return .couldNotReturn
    }
}
