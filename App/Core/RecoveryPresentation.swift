import Actions
import Engine
import Foundation
import Shared

// S11 — catalogue wiring (design_v1 §10). How one `RecoveryEntry` becomes a pill row, a window notice
// and a menu line, and what its one recovery action is allowed to do. The copy is always the
// catalogue's (`RecoveryCatalog`, S9); nothing here writes a sentence of its own.

// MARK: - Retry semantics

/// What an entry's one primary recovery action does. Design §10: "Retry is never a universal button:
/// no-speech retries a turn, model retry restarts a download, permission action opens the correct
/// setting, held text uses explicit retargeting, and unconfirmed insertion asks for inspection.
/// Clipboard operations acknowledge only verified copy success. A 'recover' action is present only
/// when recovery material exists."
///
/// There is deliberately no automatic kind: nothing in the catalogue re-runs work on its own, and an
/// unconfirmed or partial write (D06, D07) is `.inspect`, never a retry.
public enum RecoveryActionKind: String, CaseIterable, Sendable {
    /// P01–P03: open the one System Settings pane for that permission.
    case openSetting
    /// P04: relaunch after saving held text.
    case relaunch
    /// K01: pick another key; the previous binding stays active.
    case chooseShortcut
    /// K03, A06, A07: the retry of a turn is the key itself, pressed again. Never a pill button.
    case retryTurn
    /// K04: the running turn keeps its pose; nothing to press.
    case waitOrCancel
    /// K05.
    case unmute
    /// A01–A04.
    case chooseMicrophone
    /// A05.
    case testMicrophone
    /// A08: capture continues; the check is optional.
    case checkMicrophone
    /// A09: the other internal recorder keeps the microphone.
    case openActiveSession
    /// M01, M08.
    case openModels
    /// M02–M04: model retry restarts (or resumes) the download.
    case restartDownload
    /// M05.
    case manageStorage
    /// M06.
    case chooseModel
    /// M07.
    case retryLoad
    /// T02: keep the valid partial text instead of waiting (needs that text).
    case useAvailableText
    /// T03: the unrefined transcript stands.
    case useOriginal
    /// K02, T01, T04, T05, D08, D09, D11: look at the words that were kept (needs them).
    case review
    /// D01: explicit retargeting, revalidated at the new destination (held rows only).
    case retarget
    /// D02, D05, D10, S03: copy the kept words (needs them; acknowledged only when verified).
    case copy
    /// D03: nothing is typed into a secure field; the notice is closed.
    case dismiss
    /// D04.
    case reviewAppRule
    /// D06, D07: inspect the destination before anything else — never re-insert.
    case inspect
    /// S01, S02, S04, N01, X03, X05, X07: retry the failed scope only (a section, a row, a save).
    case retryScope
    /// S05, X08: recover what is actually retained (needs it).
    case recover
    /// X02: recover the affected meeting from what was saved (needs it).
    case recoverMeeting
    /// N02.
    case reconnect
    /// N03.
    case useLocal
    /// N04.
    case serviceSettings
    /// X01.
    case reviewPermissions
    /// X04.
    case reviewImport
    /// X06.
    case reviewSync

    /// The action re-runs the work that failed ("Try again", "Retry …", "Download again", "Pair
    /// again"). Always scoped to that work, always started by the user.
    public var rerunsWork: Bool {
        switch self {
        case .retryTurn, .restartDownload, .retryLoad, .retryScope: return true
        default: return false
        }
    }

    /// The action acts on kept words or retained audio; offered only when that material exists.
    public var needsRecoveryMaterial: Bool {
        switch self {
        case .review, .copy, .recover, .recoverMeeting, .useAvailableText, .retarget: return true
        default: return false
        }
    }

    /// The pill button this action becomes (`PillActionRoute` decides what the button opens), or nil
    /// when the pill cannot carry it out: the row then states the problem and offers Dismiss.
    /// `.retryTurn` is nil on purpose — the retry of a turn is pressing the key again.
    public var pillAction: PillActionKind? {
        switch self {
        case .openSetting, .reviewPermissions: return .permissions
        case .unmute: return .unmute
        case .chooseMicrophone, .testMicrophone, .checkMicrophone: return .voice
        case .openModels, .restartDownload, .manageStorage, .chooseModel, .retryLoad: return .models
        case .useAvailableText: return .useAvailable
        case .review, .recover: return .review
        case .recoverMeeting: return .meeting
        case .copy: return .copy
        case .inspect: return .check
        case .dismiss: return .dismiss
        // Explicit retargeting is the held row's own "Insert here" (`PillDeck.heldButtons`); an
        // error row has no held item to retarget.
        case .retarget: return nil
        case .relaunch, .chooseShortcut, .retryTurn, .waitOrCancel, .openActiveSession, .useOriginal,
             .reviewAppRule, .retryScope, .reconnect, .useLocal, .serviceSettings, .reviewImport, .reviewSync:
            return nil
        }
    }
}

public extension RecoveryID {
    /// The kind of this entry's one recovery action (its `RecoveryEntry.action` label).
    var actionKind: RecoveryActionKind {
        switch self {
        case .P01, .P02, .P03: return .openSetting
        case .P04: return .relaunch
        case .K01: return .chooseShortcut
        case .K02: return .review
        case .K03: return .retryTurn
        case .K04: return .waitOrCancel
        case .K05: return .unmute
        case .A01, .A02, .A03, .A04: return .chooseMicrophone
        case .A05: return .testMicrophone
        case .A06, .A07: return .retryTurn
        case .A08: return .checkMicrophone
        case .A09: return .openActiveSession
        case .M01, .M08: return .openModels
        case .M02, .M03, .M04: return .restartDownload
        case .M05: return .manageStorage
        case .M06: return .chooseModel
        case .M07: return .retryLoad
        case .T01: return .review
        case .T02: return .useAvailableText
        case .T03: return .useOriginal
        case .T04, .T05: return .review
        case .D01: return .retarget
        case .D02: return .copy
        case .D03: return .dismiss
        case .D04: return .reviewAppRule
        case .D05: return .copy
        case .D06, .D07: return .inspect
        case .D08, .D09: return .review
        case .D10: return .copy
        case .D11: return .review
        case .S01, .S02: return .retryScope
        case .S03: return .copy
        case .S04: return .retryScope
        case .S05: return .recover
        case .N01: return .retryScope
        case .N02: return .reconnect
        case .N03: return .useLocal
        case .N04: return .serviceSettings
        case .X01: return .reviewPermissions
        case .X02: return .recoverMeeting
        case .X03: return .retryScope
        case .X04: return .reviewImport
        case .X05: return .retryScope
        case .X06: return .reviewSync
        case .X07: return .retryScope
        case .X08: return .recover
        }
    }

    /// The permission an `.openSetting` action opens.
    var permission: Permission? {
        switch self {
        case .P01: return .microphone
        case .P02: return .accessibility
        case .P03: return .inputMonitoring
        default: return nil
        }
    }
}

public extension RecoveryEntry {
    var actionKind: RecoveryActionKind { id.actionKind }

    /// The pill button for this entry's action, when the pill can carry it out and — for an action
    /// on kept words — only when there are kept words (`hasMaterial`).
    func pillButton(hasMaterial: Bool, primary: Bool = true) -> PillButton? {
        let kind = actionKind
        guard let pill = kind.pillAction else { return nil }
        if kind.needsRecoveryMaterial, !hasMaterial { return nil }
        return PillButton(action, pill, primary: primary)
    }
}

// MARK: - The pill row

public extension PillContent {
    /// Any catalogue entry as the pill's notice row: the prototype's error pill (`showError`):
    /// "⚠ <headline>", the consequence, the entry's one action — with the Spool pose of its treatment.
    ///
    /// - A quiet return (A06, A07, K03) is the headline and consequence only, no ⚠, no buttons; it
    ///   fades (`RecoveryDismissal.fades`).
    /// - T01 with recovered words is the design's E0 row verbatim (`PillDeck.error*`).
    /// - Words kept from the turn stay on the row; an action on kept words (Review, Copy, Recover,
    ///   Use available text) appears only when there are some, and Copy text is always offered with them.
    /// - A notice that stays until the user acts always has Dismiss; a live warning or K04 leaves with
    ///   its condition and has none. No row ever gets a retry the entry does not name.
    static func recovery(_ entry: RecoveryEntry, context c: PillTurnContext) -> PillContent {
        let e = entry.rendered(hotkey: c.keyLabel)
        let trailing: Trailing = c.destinationName.map(Trailing.destination) ?? .none
        let words = c.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWords = !words.isEmpty
        if entry.treatment == .quietReturn {
            return PillContent(designKey: "error", status: e.headline, trailing: trailing, helper: e.consequence,
                               spoolKey: entry.poseKey)
        }
        if entry.id == .T01, hasWords {
            return PillContent(designKey: "error", status: PillDeck.errorStatus, tone: .warn, trailing: trailing,
                               words: .final(c.liveText), helper: PillDeck.errorHelper,
                               buttons: PillDeck.errorButtons, notice: true)
        }
        var buttons: [PillButton] = []
        if let primary = e.pillButton(hasMaterial: hasWords) { buttons.append(primary) }
        if hasWords, !buttons.contains(where: { $0.action == .copy }) {
            buttons.append(PillButton(PillDeck.copyTextLabel, .copy, primary: buttons.isEmpty))
        }
        let sticky = entry.dismissal == .untilAction
        if sticky, !buttons.contains(where: { $0.action == .dismiss }) {
            buttons.append(PillButton(PillDeck.dismissLabel, .dismiss, primary: buttons.isEmpty))
        }
        return PillContent(designKey: "error", status: PillDeck.warnPrefix + e.headline, tone: .warn,
                           trailing: trailing, words: hasWords ? .final(c.liveText) : .none, helper: e.consequence,
                           buttons: buttons, notice: sticky, spoolKey: entry.poseKey)
    }
}

public extension PillDeck {
    /// The E0 / H0 rows' copy button (`design_copy.json` › `pill` › `error` / `held`).
    static let copyTextLabel = "Copy text"
}

public extension PillState {
    /// A catalogue entry as the pill's notice state. The message is the catalogue's own headline
    /// (not rendered with the key), so `PillNotice.entry(forMessage:)` finds the entry again.
    static func recovery(_ entry: RecoveryEntry) -> PillState { .error(message: entry.headline) }
    static func recovery(_ id: RecoveryID) -> PillState { .recovery(RecoveryCatalog.entry(id)) }
}

// MARK: - Window notices

public extension SectionBanner {
    /// A named condition (`RecoveryCatalog.Signal`) as a scoped banner; raw detail stays behind
    /// Copy diagnostics.
    static func recovery(_ signal: RecoveryCatalog.Signal, diagnostics: String? = nil) -> SectionBanner {
        var banner = SectionBanner.recovery(RecoveryCatalog.entry(for: signal))
        banner.diagnostics = diagnostics
        return banner
    }
}

public extension SectionState {
    /// A named condition as a whole-group error rendering.
    static func error(_ signal: RecoveryCatalog.Signal) -> SectionState { .error(RecoveryCatalog.entry(for: signal)) }
    static func error(_ id: RecoveryID) -> SectionState { .error(RecoveryCatalog.entry(id)) }
}

// MARK: - Menu and presence lines

public extension RecoveryEntry {
    /// `Problem — Action` on one line (`DESIGN.md` §7.1), without saying the action twice when the
    /// headline already starts with it ("Reopen VoicePlus to finish setup").
    var problemAction: String {
        headline.hasPrefix(action) ? headline : "\(headline) — \(action)"
    }
}

// MARK: - App-level pill notices with no thrown error

/// S11 — pill notices the composition root raises from a condition rather than a thrown error.
/// Each is a catalogue entry; the condition's own wording (a request kind, a planner reason) goes to
/// the log only.
public enum AppRecovery {
    /// The hotkey tap is armed and macOS still delivers no keys to this process: only a relaunch
    /// fixes it (P04 "Reopen VoicePlus to finish setup").
    public static let tapProvenDead: RecoveryID = .P04

    /// A session the user did not end (lock, sleep, a lost device, another recorder): its entry, or
    /// nil when the user ended it themselves.
    public static func entry(forStop reason: SessionCoordinator.StopReason) -> RecoveryEntry? {
        RecoveryCatalog.entry(for: reason)
    }

    /// A deterministic action that failed: the catch-all X08 (the catalogue has no act family).
    /// Nil for any outcome that is not a failure.
    public static func entry(forAct outcome: ActionOutcome) -> RecoveryEntry? {
        outcome.isSuccess ? nil : RecoveryCatalog.entry(.X08)
    }

    /// An agent run that failed, gave up or timed out: X08. Completed, stopped, declined and
    /// unavailable (a configuration state, not an error) keep their own plain words.
    public static func entry(forAgent status: AgentRunStatus) -> RecoveryEntry? {
        switch status {
        case .failed, .gaveUp, .timedOut: return RecoveryCatalog.entry(.X08)
        case .completed, .stopped, .declined, .unavailable: return nil
        }
    }
}
