import Engine
import Foundation
import Injection
import Shared

/// Pure data behind the status-item dropdown (T4).
public struct MenuModel: Equatable, Sendable {
    public var zeroEditCount: Int
    public var totalCount: Int
    public var wordsToday: Int
    public var activeModel: String
    public var micName: String
    public var micStatus: MicQuality.Verdict?
    public var paused: Bool
    /// R3.1 / V3 §4.7 vocabulary: **latched** is the double-tap mode; **muted** is the hard mute.
    public var latched: Bool
    public var hotkeyName: String
    public var launchAtLogin: Bool

    public init(zeroEditCount: Int = 0, totalCount: Int = 0, wordsToday: Int = 0, activeModel: String = "Mock engine",
                micName: String = "Default microphone", micStatus: MicQuality.Verdict? = nil, paused: Bool = false,
                latched: Bool = false, hotkeyName: String = HotkeyBinding.default.kind.displayName,
                launchAtLogin: Bool = false) {
        self.zeroEditCount = zeroEditCount
        self.totalCount = totalCount
        self.wordsToday = wordsToday
        self.activeModel = activeModel
        self.micName = micName
        self.micStatus = micStatus
        self.paused = paused
        self.latched = latched
        self.hotkeyName = hotkeyName
        self.launchAtLogin = launchAtLogin
    }

    public var zeroEditLine: String {
        guard totalCount > 0 else { return "Zero-edit: no dictations yet" }
        let pct = Int((Double(zeroEditCount) / Double(totalCount) * 100).rounded())
        return "Zero-edit: \(zeroEditCount)/\(totalCount) (\(pct)%)"
    }

    public var wordsLine: String { "Words today: \(wordsToday)" }
    public var modelLine: String { "Model: \(activeModel)" }

    public var micLine: String { Self.micLine(name: micName, status: micStatus) }

    /// The one place the microphone line is worded (device name + verdict). Static so the menu spec
    /// and this model cannot drift into two spellings of the same sentence.
    public static func micLine(name: String, status: MicQuality.Verdict?, available: Bool = true) -> String {
        guard available else { return "Mic: \(name) — off" }
        let suffix: String
        switch status {
        case .good?: suffix = " ✓"
        case .poor?: suffix = " — weak signal"
        case .bad?: suffix = " — check mic"
        case nil: suffix = ""
        }
        return "Mic: \(name)\(suffix)"
    }

    public var pauseTitle: String { paused ? "Resume VoicePlus" : "Pause VoicePlus" }

    /// Counts derived from dictation history. `now` is injectable for tests.
    public static func stats(from dictations: [DictationRecord], now: Date = Date(), calendar: Calendar = .current)
        -> (zeroEdit: Int, total: Int, wordsToday: Int) {
        let total = dictations.count
        let zeroEdit = dictations.filter { !$0.edited }.count
        let words = dictations
            .filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
            .reduce(0) { $0 + $1.finalText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
        return (zeroEdit, total, words)
    }

    public static func load(from db: AppDatabase, now: Date = Date()) -> (zeroEdit: Int, total: Int, wordsToday: Int) {
        let records = (try? db.recentDictations(limit: 5000)) ?? []
        return stats(from: records, now: now)
    }
}

// MARK: - S6 — the status menu (design §8.8, `DESIGN.md` §10)

/// What a menu item does when it is chosen. Deliberately data: the spec below decides *what the
/// menu says*, the controller decides *who is called*, and a test can read the first without an
/// `NSStatusItem` (there is no XCTest and no UI test on this toolchain — CLAUDE.md).
///
/// Exactly the design's rows. Latch, meeting start and Copy last text are not menu items in the
/// verified design (they live in Settings › Shortcuts, Meetings and Today — `DESIGN.md` §10).
public enum MenuAction: Equatable, Sendable {
    /// Explicit click-to-stop capture, through `SessionCoordinator` as the `.menu` requester. It
    /// cannot imply a held key: only Stop (or Escape, mute, lock) ends it.
    case startDictation
    case stopDictation
    /// `MuteController` — persistent hard mute. Closes every active capture; never auto-unmutes.
    case toggleMute
    /// "Review" on the held-dictations row: the recovery surface in the one window (Today).
    case reviewHeld
    /// The one window, at Today.
    case openWindow
    /// The one window, at Settings.
    case openSettings
    /// Guarded: open capture asks Stop and quit / Cancel; held drafts are saved first.
    case quit
}

/// One row of the menu. Rendered to `NSMenuItem` by `StatusItemController`; compared directly by
/// the tests. `isSeparator` rows carry nothing else.
public struct MenuEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The prototype's helper line under the title (rendered as the item's subtitle).
    public var detail: String?
    public var action: MenuAction?
    public var keyEquivalent: String
    public var isEnabled: Bool
    public var isOn: Bool
    public var isSeparator: Bool
    /// The cassette glyph before the title — the status line only (prototype `.menu-heading`).
    public var showsGlyph: Bool
    /// The green ready dot — the status line only, and only when ready (`DESIGN.md` §10).
    public var showsReadyDot: Bool

    public init(id: String, title: String, detail: String? = nil, action: MenuAction? = nil,
                keyEquivalent: String = "", isEnabled: Bool = true, isOn: Bool = false,
                isSeparator: Bool = false, showsGlyph: Bool = false, showsReadyDot: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.action = action
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.isSeparator = isSeparator
        self.showsGlyph = showsGlyph
        self.showsReadyDot = showsReadyDot
    }

    public static func separator(_ id: String) -> MenuEntry {
        MenuEntry(id: id, title: "", isEnabled: false, isSeparator: true)
    }

    /// A disabled information line (status, microphone).
    public static func info(_ id: String, _ title: String, detail: String? = nil) -> MenuEntry {
        MenuEntry(id: id, title: title, detail: detail, isEnabled: false)
    }
}

// MARK: The status line

/// What the menu's first line says: **Ready / Muted / Blocked**, plus the honest in-between states
/// a turn passes through, so the line never says "Microphone is closed." while it is open.
public enum MenuStatus: Equatable, Sendable {
    case ready
    /// C0 — capture requested, microphone not open yet. Not "listening".
    case starting
    case listening
    case latched
    /// F0 — microphone closed, the final pass is running. Not "listening".
    case finishing
    /// Meeting capture is recording (the microphone is open, for a meeting).
    case meeting
    case muted
    case paused
    case blocked(PresenceBlockReason)

    public var title: String {
        switch self {
        case .ready: return "VoicePlus · Ready"
        case .starting: return "VoicePlus · \(MenuCopy.Pill.starting)"
        case .listening: return "VoicePlus · \(MenuCopy.Pill.listening)"
        case .latched: return "VoicePlus · \(MenuCopy.Pill.latched)"
        case .finishing: return "VoicePlus · \(MenuCopy.Pill.finishing)"
        case .meeting: return "VoicePlus · \(MenuCopy.Pill.meeting)"
        case .muted: return "VoicePlus · Muted"
        case .paused: return "VoicePlus · Paused"
        case .blocked: return "VoicePlus · Blocked"
        }
    }

    /// The helper line. For a blocked state it is the recovery catalogue's `Problem — Action`.
    public var detail: String {
        switch self {
        case .ready, .paused: return MenuCopy.microphoneClosed
        case .starting: return MenuCopy.Pill.startingDetail
        case .listening, .latched: return MenuCopy.microphoneOpen
        case .finishing: return MenuCopy.Pill.finishingDetail
        case .meeting: return MenuCopy.Pill.meetingDetail
        case .muted: return MenuCopy.Catalogue.muted.consequence
        case .blocked(let reason): return MenuCopy.blockedLine(reason)
        }
    }

    public var isReady: Bool { self == .ready }

    /// Blockers that make "Start dictation" impossible. A missing *hotkey* permission is not one:
    /// the menu is exactly the fallback for that case.
    public var disablesDictation: Bool {
        switch self {
        case .muted, .finishing, .blocked(.microphoneDenied), .blocked(.modelMissing): return true
        default: return false
        }
    }

    /// Why "Start dictation" is disabled, in the title's parentheses (`DESIGN.md` §10: an unavailable
    /// action stays visible and disabled with the reason in its title).
    public var dictationBlockedReason: String? {
        switch self {
        case .muted: return MenuCopy.reason(MenuCopy.Catalogue.muted)
        case .finishing: return MenuCopy.reason(MenuCopy.Catalogue.finishingPrevious)
        case .blocked(.microphoneDenied): return MenuCopy.reason(MenuCopy.Catalogue.microphoneDenied)
        case .blocked(.modelMissing): return MenuCopy.reason(MenuCopy.Catalogue.modelMissing)
        default: return nil
        }
    }
}

/// Everything the status line is a function of. Every field is something another owner already
/// knows; nothing here is read by opening the menu that is not already a plain property.
public struct MenuStatusInputs: Equatable, Sendable {
    public var muted: Bool
    public var paused: Bool
    public var canCapture: Bool
    /// `PermissionPlanner.Capabilities.canUseGlobalHotkey`: false only when the configured key
    /// needs a grant it does not have. The menu is then the way to dictate.
    public var canUseHotkey: Bool
    public var engine: EngineState
    /// `SessionCoordinator.activeRequester`.
    public var holder: SessionCoordinator.Requester?
    public var latched: Bool
    public var meetingRunning: Bool
    /// The presence reducer's answer, when wired — the source of blockers the menu cannot derive
    /// itself (the hotkey, a relaunch, a model download).
    public var presence: PresenceState?

    public init(muted: Bool = false, paused: Bool = false, canCapture: Bool = true, canUseHotkey: Bool = true,
                engine: EngineState = .idle, holder: SessionCoordinator.Requester? = nil, latched: Bool = false,
                meetingRunning: Bool = false, presence: PresenceState? = nil) {
        self.muted = muted
        self.paused = paused
        self.canCapture = canCapture
        self.canUseHotkey = canUseHotkey
        self.engine = engine
        self.holder = holder
        self.latched = latched
        self.meetingRunning = meetingRunning
        self.presence = presence
    }

    /// A dictation capture is open (hold, menu or latch) — the row offers Stop. `.starting` counts:
    /// a session the user can see must be stoppable. `.finishing` does not: the microphone is
    /// closed and there is nothing left to stop. `.prewarming` is the model, not the microphone.
    public var dictationCaptureOpen: Bool {
        switch engine {
        case .starting, .listening, .previewing, .warning: return true
        case .finishing, .finalizing: return latched
        case .error, .unavailable: return false
        case .idle, .prewarming, .landed, .cancelled: return latched || holder?.dictates == true
        }
    }
}

public extension MenuStatus {
    /// Precedence: mute first, because the menu must never be less alarming than reality; then an
    /// open (or opening) microphone; then what is merely unavailable.
    static func derive(_ inputs: MenuStatusInputs) -> MenuStatus {
        if inputs.muted || inputs.presence == .muted { return .muted }
        switch inputs.engine {
        case .starting: return .starting
        case .listening, .previewing, .warning: return inputs.latched ? .latched : .listening
        case .finishing, .finalizing: return inputs.latched ? .latched : .finishing
        case .unavailable: return .blocked(.modelMissing)
        case .idle, .prewarming, .landed, .error, .cancelled: break
        }
        if inputs.latched { return .latched }
        // Capture was asked for and the engine has not reported yet: opening, not listening. (An
        // engine that failed to start is not "opening"; `dictationCaptureOpen` says no for it.)
        if inputs.holder?.dictates == true, inputs.dictationCaptureOpen { return .starting }
        if inputs.meetingRunning { return .meeting }
        if inputs.paused || inputs.presence == .paused { return .paused }
        if !inputs.canCapture { return .blocked(.microphoneDenied) }
        // The presence reducer is more specific when wired (a dead tap is "relaunch", not "key off").
        if case .blocked(let reason)? = inputs.presence { return .blocked(reason) }
        if !inputs.canUseHotkey { return .blocked(.hotkeyUnavailable) }
        return .ready
    }
}

// MARK: The copy

/// Every string the menu shows. Row titles and helper lines are the prototype's menu review surface
/// (`case'menu'` in `design_v1.html`) verbatim; state words are the pill's own (`design_copy.json` ›
/// `pill`); blocked and disabled reasons are recovery-catalogue lines (`design_copy.json` › `errors`).
/// `MenuStatusTests` compares all three against the fixtures.
public enum MenuCopy {
    public static let microphoneClosed = "Microphone is closed."
    /// The open-microphone counterpart of the design's "Microphone is closed." — the status line
    /// must never say "closed" while capture is open.
    public static let microphoneOpen = "Microphone is open."

    public static let startDictation = "Start dictation"
    public static let startDetail = "Menu capture has an explicit Stop control."
    public static let stop = "Stop"
    public static let mute = "Mute microphone"
    public static let muteDetail = "Close every active capture."
    public static let heldDetail = "Saved until you resolve it."
    public static let openWindow = "Open VoicePlus"
    public static let openWindowDetail = "Today and all settings."
    public static let settings = "Settings…"
    public static let quit = "Quit VoicePlus"
    public static let quitDetail = "Protect active capture and unsaved text."

    /// "1 held dictation", "3 held dictations".
    public static func held(count: Int) -> String {
        count == 1 ? "1 held dictation" : "\(count) held dictations"
    }

    /// The pill's words for the in-between states (`design_copy.json` › `pill`).
    public enum Pill {
        public static let starting = "Starting microphone…"
        public static let startingDetail = "Recording starts when the microphone is open"
        public static let listening = "Listening"
        public static let latched = "Hands-free · listening"
        public static let finishing = "Finishing…"
        public static let finishingDetail = "Microphone closed · nothing inserted yet"
        public static let meeting = "Meeting · recording"
        public static let meetingDetail = "Capture is separate from dictation"
    }

    /// One recovery-catalogue entry, as far as the menu needs it.
    public struct Line: Equatable, Sendable {
        public var id: String
        public var headline: String
        public var consequence: String
        public var action: String

        /// S11 — a line is always a catalogue entry's own words.
        public init(_ entry: RecoveryEntry) {
            id = entry.id.rawValue
            headline = entry.headline
            consequence = entry.consequence
            action = entry.action
        }
    }

    /// The catalogue entries the menu can show (design §10), looked up in `RecoveryCatalog` (S11).
    public enum Catalogue {
        public static let microphoneDenied = Line(RecoveryCatalog.entry(.P01))
        public static let shortcutPermission = Line(RecoveryCatalog.entry(.P03))
        public static let reopen = Line(RecoveryCatalog.entry(.P04))
        public static let finishingPrevious = Line(RecoveryCatalog.entry(.K04))
        public static let muted = Line(RecoveryCatalog.entry(.K05))
        public static let modelMissing = Line(RecoveryCatalog.entry(.M01))

        public static let all = [microphoneDenied, shortcutPermission, reopen, finishingPrevious, muted, modelMissing]

        /// The entry a blocked status names; nil for a download in progress (not a failure).
        public static func id(for reason: PresenceBlockReason) -> RecoveryID? {
            switch reason {
            case .microphoneDenied: return .P01
            case .hotkeyUnavailable: return .P03
            case .relaunchNeeded: return .P04
            case .modelMissing: return .M01
            case .modelDownloading: return nil
            }
        }
    }

    /// `Problem — Action` on one line (`DESIGN.md` §7.1), without saying the action twice when the
    /// headline already starts with it.
    public static func problemAction(_ line: Line) -> String {
        line.headline.hasPrefix(line.action) ? line.headline : "\(line.headline) — \(line.action)"
    }

    public static func blockedLine(_ reason: PresenceBlockReason) -> String {
        // Progress, not a failure: no catalogue entry, the presence line's own words.
        guard let id = Catalogue.id(for: reason) else { return reason.detail }
        return problemAction(Line(RecoveryCatalog.entry(id)))
    }

    /// A headline as a parenthetical reason: sentence case lowered, the product name kept.
    public static func reason(_ line: Line) -> String {
        let headline = line.headline
        guard let first = headline.first, !headline.hasPrefix("VoicePlus") else { return headline }
        return first.lowercased() + headline.dropFirst()
    }
}

// MARK: The state and the rows

/// Everything the one menu is a function of.
public struct StatusMenuState: Equatable, Sendable {
    /// One held dictation, as the menu needs it. Built from either held queue — `Injection`'s
    /// `FocusGuard.held` (the record of truth) or the app-side mirror — so the menu never grows a
    /// third copy of committed text.
    public struct Held: Equatable, Sendable, Identifiable {
        public let id: UUID
        /// `HeldMenu.header`: excerpt and destination, the same sentence the pill row uses.
        public var title: String
        public var text: String
        public var heldAt: Date?
        /// In history (Today), so quitting cannot lose it. Set by `HeldDrafts.save`.
        public var isSaved: Bool

        public init(id: UUID, title: String, text: String = "", heldAt: Date? = nil, isSaved: Bool = false) {
            self.id = id
            self.title = title
            self.text = text
            self.heldAt = heldAt
            self.isSaved = isSaved
        }
    }

    public var status: MenuStatus
    public var micName: String
    public var micStatus: MicQuality.Verdict?
    public var micAvailable: Bool
    /// A dictation capture is open (hold, menu or latch). Drives Stop.
    public var isCapturing: Bool
    public var isMuted: Bool
    /// Oldest first, exactly as `FocusGuard.held` orders it (max 20).
    public var held: [Held]
    /// Meeting capture is recording. Not a menu row; the quit guard needs it.
    public var meetingRunning: Bool

    public init(status: MenuStatus = .ready, micName: String = "Default microphone",
                micStatus: MicQuality.Verdict? = nil, micAvailable: Bool = true, isCapturing: Bool = false,
                isMuted: Bool = false, held: [Held] = [], meetingRunning: Bool = false) {
        self.status = status
        self.micName = micName
        self.micStatus = micStatus
        self.micAvailable = micAvailable
        self.isCapturing = isCapturing
        self.isMuted = isMuted
        self.held = held
        self.meetingRunning = meetingRunning
    }
}

public extension StatusMenuState.Held {
    /// From the app-side mirror (`HeldTextStore`, R2.4).
    init(_ item: HeldItem) {
        self.init(id: item.id, title: HeldMenu.header(for: item), text: item.text, heldAt: item.heldAt)
    }

    /// From `Injection`'s own queue — `FocusGuard.held`, oldest first, `maxHeld = 20` (R2.4).
    init(_ text: HeldText) {
        let item = HeldItem(id: text.id, text: text.text, destination: text.destinationName,
                            reason: text.reason, heldAt: text.heldAt)
        self.init(item)
    }
}

/// The one menu (design §8.8, `DESIGN.md` §10): Ready / Muted / Blocked line, current microphone,
/// Start dictation (click-to-stop), Mute, held dictations, Open VoicePlus, Settings…, Quit.
///
/// Pure, and pure on purpose: computing the menu must not open the microphone, read or take the
/// destination focus, or touch held text. Opening the menu never records; closing it never changes
/// recording.
public enum StatusMenuSpec {
    /// Identifiers, so tests and the renderer name the same rows.
    public enum ID {
        public static let status = "menu.status"
        public static let microphone = "menu.microphone"
        public static let dictate = "menu.dictate"
        public static let mute = "menu.mute"
        public static let held = "menu.held"
        public static let openWindow = "menu.openWindow"
        public static let settings = "menu.settings"
        public static let quit = "menu.quit"
    }

    /// `entryPoint` is accepted and ignored: one menu, whichever click opened it (V3 §9.3).
    public static func entries(_ state: StatusMenuState,
                               from entryPoint: MenuEntryPoint = .glyph) -> [MenuEntry] {
        _ = entryPoint
        var entries: [MenuEntry] = [
            status(state),
            .info(ID.microphone, MenuModel.micLine(name: state.micName, status: state.micStatus,
                                                   available: state.micAvailable)),
            .separator("menu.sep.capture"),
            dictate(state),
            mute(state),
        ]
        if let held = held(state) { entries.append(held) }
        entries += [
            .separator("menu.sep.app"),
            MenuEntry(id: ID.openWindow, title: MenuCopy.openWindow, detail: MenuCopy.openWindowDetail,
                      action: .openWindow),
            MenuEntry(id: ID.settings, title: MenuCopy.settings, action: .openSettings, keyEquivalent: ","),
            .separator("menu.sep.quit"),
            MenuEntry(id: ID.quit, title: MenuCopy.quit, detail: MenuCopy.quitDetail, action: .quit,
                      keyEquivalent: "q"),
        ]
        return entries
    }

    /// Depth-first lookup by id, for the renderer's tests.
    public static func entry(_ id: String, in entries: [MenuEntry]) -> MenuEntry? {
        entries.first { $0.id == id }
    }

    // MARK: The rows

    static func status(_ state: StatusMenuState) -> MenuEntry {
        // Mute outranks everything the status could say (`MenuStatus.derive` agrees; this covers a
        // hand-built state too).
        let status: MenuStatus = state.isMuted ? .muted : state.status
        return MenuEntry(id: ID.status, title: status.title, detail: status.detail, isEnabled: false,
                         showsGlyph: true, showsReadyDot: status.isReady)
    }

    static func dictate(_ state: StatusMenuState) -> MenuEntry {
        // Explicit Stop while capture is open. Always enabled: a session the user can see must
        // always be stoppable from here, muted or blocked or not.
        if state.isCapturing {
            return MenuEntry(id: ID.dictate, title: MenuCopy.stop, action: .stopDictation, keyEquivalent: "d")
        }
        let status: MenuStatus = state.isMuted ? .muted : state.status
        if let reason = status.dictationBlockedReason {
            return MenuEntry(id: ID.dictate, title: "\(MenuCopy.startDictation) (\(reason))",
                             detail: MenuCopy.startDetail, keyEquivalent: "d", isEnabled: false)
        }
        return MenuEntry(id: ID.dictate, title: MenuCopy.startDictation, detail: MenuCopy.startDetail,
                         action: .startDictation, keyEquivalent: "d")
    }

    /// A toggle ("Muted" in the prototype): checked while muted, always enabled.
    static func mute(_ state: StatusMenuState) -> MenuEntry {
        MenuEntry(id: ID.mute, title: MenuCopy.mute, detail: MenuCopy.muteDetail, action: .toggleMute,
                  keyEquivalent: "m", isOn: state.isMuted)
    }

    /// Hidden entirely when nothing is held; counted in the title when something is.
    static func held(_ state: StatusMenuState) -> MenuEntry? {
        guard HeldMenu.isVisible(count: state.held.count) else { return nil }
        return MenuEntry(id: ID.held, title: MenuCopy.held(count: state.held.count), detail: MenuCopy.heldDetail,
                         action: .reviewHeld)
    }
}

/// The menu never invents an order: it lists what the guard holds, oldest first.
public enum HeldMenuRouter {
    public static func held(in guard: FocusGuard) -> [StatusMenuState.Held] {
        `guard`.held.map(StatusMenuState.Held.init)
    }
}

// MARK: - Held drafts are saved before quitting

/// Held text lives in memory (`FocusGuard.held`, `HeldTextStore`); quitting ends both queues. Before
/// the app quits, every held dictation is made sure to be in history — the store Today reads — so
/// quitting loses nothing. The lander already writes one record per landing, held ones included;
/// only a draft that is not there is written, so nothing is duplicated.
public enum HeldDrafts {
    /// How far back to look for a draft the lander already wrote.
    static let lookback = 500

    /// Returns `held` with `isSaved` set. A draft is saved when history has a record with the same
    /// text, or when writing one succeeds. With no database, or an empty text, it is not saved.
    public static func save(_ held: [StatusMenuState.Held], into database: AppDatabase?,
                            now: Date = Date()) -> [StatusMenuState.Held] {
        guard !held.isEmpty else { return [] }
        guard let database else { return held.map { unsaved($0) } }
        var known = Set(((try? database.recentDictations(limit: lookback)) ?? []).map { key($0.finalText) })
        return held.map { item in
            var item = item
            let text = key(item.text)
            guard !text.isEmpty else { return unsaved(item) }
            if known.contains(text) {
                item.isSaved = true
                return item
            }
            let at = item.heldAt ?? now
            do {
                try database.insert(DictationRecord(startedAt: at, endedAt: at, register: "unknown", route: "dictate",
                                                    appBundleID: nil, rawText: item.text, finalText: item.text,
                                                    spansJSON: "[]"))
                known.insert(text)
                item.isSaved = true
                Log.app.notice("quit: saved a held dictation (\(item.text.count) chars) to history")
            } catch {
                item.isSaved = false
                Log.db.error("quit: could not save a held dictation: \(error)")
            }
            return item
        }
    }

    private static func unsaved(_ item: StatusMenuState.Held) -> StatusMenuState.Held {
        var item = item
        item.isSaved = false
        return item
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Quit

/// Design §8.8: "Quit during capture asks Stop and quit / Cancel; held drafts are saved or an
/// unsaved-data warning is shown." Pure decision; the controller runs the alert.
public enum MenuQuit {
    public struct Prompt: Equatable, Sendable {
        public var title: String
        public var message: String
        public var confirm: String
        public var cancel: String
        /// Confirming stops the open capture before quitting.
        public var stopsCapture: Bool
    }

    public enum Plan: Equatable, Sendable {
        case quit
        case ask(Prompt)
    }

    public static let title = "Quit VoicePlus?"
    public static let stopAndQuit = "Stop and quit"
    public static let quitAnyway = "Quit anyway"
    public static let cancel = "Cancel"
    public static let dictationLine = "Dictation is still recording. Words that haven’t been typed will be lost."
    public static let meetingLine = "A meeting is still recording. Stopping ends the recording."

    /// `held` must already have been through `HeldDrafts.save`.
    public static func plan(dictating: Bool, meeting: Bool, held: [StatusMenuState.Held]) -> Plan {
        let unsaved = held.filter { !$0.isSaved }
        var lines: [String] = []
        if dictating { lines.append(dictationLine) }
        if meeting { lines.append(meetingLine) }
        let capturing = !lines.isEmpty
        if let heldLine = heldLine(held: held, unsaved: unsaved) {
            // Saved drafts are worth a line only when the user is being asked anyway.
            if capturing || !unsaved.isEmpty { lines.append(heldLine) }
        }
        guard capturing || !unsaved.isEmpty else { return .quit }
        return .ask(Prompt(title: title, message: lines.joined(separator: " "),
                           confirm: capturing ? stopAndQuit : quitAnyway, cancel: cancel,
                           stopsCapture: capturing))
    }

    /// The unsaved-data warning names what would be lost; saved drafts say where they are.
    static func heldLine(held: [StatusMenuState.Held], unsaved: [StatusMenuState.Held]) -> String? {
        guard !held.isEmpty else { return nil }
        guard !unsaved.isEmpty else {
            return held.count == 1 ? "1 held dictation is saved in Today."
                : "\(held.count) held dictations are saved in Today."
        }
        let shown = unsaved.prefix(3).map(\.title).joined(separator: "; ")
        let more = unsaved.count > 3 ? "; and \(unsaved.count - 3) more" : ""
        let lead = unsaved.count == 1 ? "1 held dictation hasn’t been saved and will be lost"
            : "\(unsaved.count) held dictations haven’t been saved and will be lost"
        return "\(lead): \(shown)\(more)."
    }
}
