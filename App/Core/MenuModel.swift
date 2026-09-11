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
    /// R3.1 / V3 §4.7 vocabulary: the mode formerly called `handsFree`.
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

    /// The one place the microphone line is worded (DESIGN §10: device name + verdict). Static so
    /// the menu spec and this model cannot drift into two spellings of the same sentence.
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
    public var statusSymbol: String { paused ? "mic.slash" : (latched ? "mic.badge.plus" : "mic") }

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

// MARK: - R7.3 — the one menu

/// What a menu item does when it is chosen. Deliberately data: the spec below decides *what the
/// menu says*, the controller decides *who is called*, and a test can read the first without an
/// `NSStatusItem` (there is no XCTest and no UI test on this toolchain — CLAUDE.md).
public enum MenuAction: Equatable, Sendable {
    /// Through `SessionCoordinator` (R3), never the engine directly.
    case startDictation
    case stopDictation
    case toggleLatch
    /// `MuteController` — persistent hard mute. Never auto-unmutes.
    case toggleMute
    case copyLastText
    /// R2.4's held queue: `insertHere(_:)` / `copy(_:)` / `discard(_:)`.
    case held(UUID, HeldAction)
    /// Meeting capture is still off, so "Start meeting" is the gesture that asks for Calendar.
    case enableMeetingCapture
    case startMeeting
    case stopMeeting
    /// The one window, at Today.
    case openWindow
    /// The one window, at Settings.
    case openSettings
    case quit
}

/// One row of the menu. Rendered to `NSMenuItem` by `StatusItemController`; compared directly by
/// the tests. `isSeparator` rows carry nothing else.
public struct MenuEntry: Equatable, Sendable {
    public var id: String
    public var title: String
    public var action: MenuAction?
    public var keyEquivalent: String
    public var isEnabled: Bool
    public var isOn: Bool
    /// The one red-tinted item (DESIGN §10: Mute).
    public var isDestructive: Bool
    public var isSeparator: Bool
    public var children: [MenuEntry]

    public init(id: String, title: String, action: MenuAction? = nil, keyEquivalent: String = "",
                isEnabled: Bool = true, isOn: Bool = false, isDestructive: Bool = false,
                isSeparator: Bool = false, children: [MenuEntry] = []) {
        self.id = id
        self.title = title
        self.action = action
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
        self.isOn = isOn
        self.isDestructive = isDestructive
        self.isSeparator = isSeparator
        self.children = children
    }

    public static func separator(_ id: String) -> MenuEntry {
        MenuEntry(id: id, title: "", isEnabled: false, isSeparator: true)
    }

    /// A disabled information line (status, microphone, a held item's own header).
    public static func info(_ id: String, _ title: String) -> MenuEntry {
        MenuEntry(id: id, title: title, isEnabled: false)
    }
}

/// Everything the one menu is a function of. Every field is something another owner already knows:
/// `PresenceState` (the chin's own words), `MuteController`, `SessionCoordinator`, the held queue.
public struct StatusMenuState: Equatable, Sendable {
    /// One held item, as the menu needs it. Built from either held queue — `Injection`'s
    /// `FocusGuard.held` (the record of truth) or the app-side mirror — so the menu never grows a
    /// third copy of committed text.
    public struct Held: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var title: String
        public init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    public enum Meeting: Equatable, Sendable {
        /// Capture has not been opted into; choosing the item is what asks for Calendar access.
        case needsCalendarAccess
        /// Opted in, nothing recording. `canStart` is false when no manual start is wired — the item
        /// stays visible and says why (DESIGN §10).
        case idle(canStart: Bool)
        case running
    }

    /// The chin's state, so the menu's first line says exactly what the chin says.
    public var presence: PresenceState
    public var micName: String
    public var micStatus: MicQuality.Verdict?
    public var micAvailable: Bool
    /// A capture session is open (hold or latch). Drives Stop.
    public var isCapturing: Bool
    public var isLatched: Bool
    public var isMuted: Bool
    /// There is a last committed segment to copy.
    public var hasLastText: Bool
    /// Oldest first, exactly as `FocusGuard.held` orders it (max 20).
    public var held: [Held]
    public var meeting: Meeting

    public init(presence: PresenceState = .ready, micName: String = "Default microphone",
                micStatus: MicQuality.Verdict? = nil, micAvailable: Bool = true,
                isCapturing: Bool = false, isLatched: Bool = false, isMuted: Bool = false,
                hasLastText: Bool = false, held: [Held] = [], meeting: Meeting = .needsCalendarAccess) {
        self.presence = presence
        self.micName = micName
        self.micStatus = micStatus
        self.micAvailable = micAvailable
        self.isCapturing = isCapturing
        self.isLatched = isLatched
        self.isMuted = isMuted
        self.hasLastText = hasLastText
        self.held = held
        self.meeting = meeting
    }
}

public extension StatusMenuState.Held {
    /// From the app-side mirror (`HeldTextStore`, R2.4).
    init(_ item: HeldItem) {
        self.init(id: item.id, title: HeldMenu.header(for: item))
    }
}

/// The one menu (V3 §9.2–9.3, `DESIGN.md` §10).
///
/// Pure, and pure on purpose: computing the menu must not read, take or invalidate the destination
/// focus. Dictation focus is sacred (DESIGN §5.3) — the menu is popped from a non-activating status
/// item, and nothing on this path touches `FocusGuard`.
public enum StatusMenuSpec {
    /// Identifiers, so tests and the renderer name the same rows.
    public enum ID {
        public static let status = "menu.status"
        public static let microphone = "menu.microphone"
        public static let dictate = "menu.dictate"
        public static let latch = "menu.latch"
        public static let mute = "menu.mute"
        public static let copyLast = "menu.copyLast"
        public static let recover = "menu.recover"
        public static let meeting = "menu.meeting"
        public static let openWindow = "menu.openWindow"
        public static let settings = "menu.settings"
        public static let quit = "menu.quit"

        public static func held(_ id: UUID) -> String { "menu.recover.\(id.uuidString)" }
        public static func held(_ id: UUID, _ action: HeldAction) -> String {
            "menu.recover.\(id.uuidString).\(action.rawValue)"
        }
    }

    /// `entryPoint` is accepted and ignored: one menu, whichever click opened it (V3 §9.3).
    public static func entries(_ state: StatusMenuState,
                               from entryPoint: MenuEntryPoint = .glyph) -> [MenuEntry] {
        _ = entryPoint
        var entries: [MenuEntry] = [
            .info(ID.status, statusLine(state)),
            .info(ID.microphone, MenuModel.micLine(name: state.micName, status: state.micStatus,
                                                   available: state.micAvailable)),
            .separator("menu.sep.capture"),
            dictate(state),
            latch(state),
            mute(state),
            .separator("menu.sep.text"),
            copyLast(state),
        ]
        if let recover = recover(state) { entries.append(recover) }
        entries.append(meeting(state))
        entries.append(.separator("menu.sep.app"))
        entries.append(MenuEntry(id: ID.openWindow, title: "Open VoicePlus", action: .openWindow))
        entries.append(MenuEntry(id: ID.settings, title: "Settings…", action: .openSettings, keyEquivalent: ","))
        entries.append(MenuEntry(id: ID.quit, title: "Quit VoicePlus", action: .quit, keyEquivalent: "q"))
        return entries
    }

    /// Depth-first lookup by id, for the renderer's tests.
    public static func entry(_ id: String, in entries: [MenuEntry]) -> MenuEntry? {
        for entry in entries {
            if entry.id == id { return entry }
            if let hit = self.entry(id, in: entry.children) { return hit }
        }
        return nil
    }

    // MARK: The rows

    /// The chin's own sentence. Mute outranks everything else the chin could say, because the menu
    /// must never be less alarming than reality (DESIGN §8.3 precedence).
    static func statusLine(_ state: StatusMenuState) -> String {
        state.isMuted ? PresenceState.muted.detail : state.presence.detail
    }

    static func dictate(_ state: StatusMenuState) -> MenuEntry {
        // Explicit Stop while capture is open (V3 §9.3). Always enabled: a session the user can see
        // must always be stoppable from here, muted or blocked or not.
        if state.isCapturing {
            return MenuEntry(id: ID.dictate, title: "Stop", action: .stopDictation, keyEquivalent: "d")
        }
        if state.isMuted {
            return MenuEntry(id: ID.dictate, title: "Start dictation (muted — unmute first)",
                             action: nil, keyEquivalent: "d", isEnabled: false)
        }
        if case .blocked(let reason) = state.presence {
            return MenuEntry(id: ID.dictate, title: "Start dictation (\(reason.badge))",
                             action: nil, keyEquivalent: "d", isEnabled: false)
        }
        return MenuEntry(id: ID.dictate, title: "Start dictation", action: .startDictation, keyEquivalent: "d")
    }

    static func latch(_ state: StatusMenuState) -> MenuEntry {
        MenuEntry(id: ID.latch, title: state.isMuted ? "Latch (muted)" : "Latch",
                  action: state.isMuted ? nil : .toggleLatch,
                  isEnabled: !state.isMuted, isOn: state.isLatched)
    }

    static func mute(_ state: StatusMenuState) -> MenuEntry {
        MenuEntry(id: ID.mute,
                  title: state.isMuted ? "Unmute microphone" : "Mute microphone (hard)",
                  action: .toggleMute, keyEquivalent: "m", isOn: state.isMuted, isDestructive: true)
    }

    static func copyLast(_ state: StatusMenuState) -> MenuEntry {
        state.hasLastText
            ? MenuEntry(id: ID.copyLast, title: "Copy last text", action: .copyLastText)
            : MenuEntry(id: ID.copyLast, title: "Copy last text (nothing dictated yet)", isEnabled: false)
    }

    /// Hidden entirely when nothing is held; counted in the title when something is (DESIGN §10).
    /// One submenu per held item, each carrying R2.4's three actions in their shipped order.
    static func recover(_ state: StatusMenuState) -> MenuEntry? {
        guard HeldMenu.isVisible(count: state.held.count) else { return nil }
        let items = state.held.map { item in
            MenuEntry(id: ID.held(item.id), title: item.title,
                      children: HeldMenu.actions.map { action in
                          MenuEntry(id: ID.held(item.id, action), title: action.menuTitle,
                                    action: .held(item.id, action))
                      })
        }
        return MenuEntry(id: ID.recover, title: HeldMenu.title(count: state.held.count), children: items)
    }

    static func meeting(_ state: StatusMenuState) -> MenuEntry {
        switch state.meeting {
        case .running:
            return MenuEntry(id: ID.meeting, title: "Stop meeting", action: .stopMeeting)
        case .needsCalendarAccess:
            return MenuEntry(id: ID.meeting, title: "Start meeting (asks for Calendar access)",
                             action: .enableMeetingCapture)
        case .idle(let canStart):
            return canStart
                ? MenuEntry(id: ID.meeting, title: "Start meeting", action: .startMeeting)
                : MenuEntry(id: ID.meeting, title: "Start meeting (starts when a meeting is detected)",
                            isEnabled: false)
        }
    }
}

public extension StatusMenuState.Held {
    /// From `Injection`'s own queue — `FocusGuard.held`, oldest first, `maxHeld = 20` (R2.4).
    /// Worded by `HeldMenu.header`, the same sentence the pill row uses.
    init(_ text: HeldText) {
        self.init(id: text.id,
                  title: HeldMenu.header(for: HeldItem(id: text.id, text: text.text,
                                                       destination: text.destinationName,
                                                       reason: text.reason, heldAt: text.heldAt)))
    }
}

/// The menu's three held-text actions, routed into `Injection`'s queue — R2.4's surface, not a
/// second implementation of it. `discardAll()` is there for the quit path.
public enum HeldMenuRouter {
    @discardableResult
    public static func perform(_ action: HeldAction, on id: UUID, in guard: FocusGuard) -> Bool {
        switch action {
        case .insertHere: return `guard`.insertHere(id) != nil
        case .copy: return `guard`.copy(id)
        case .discard: return `guard`.discard(id)
        }
    }

    /// The menu never invents an order: it lists what the guard holds, oldest first.
    public static func held(in guard: FocusGuard) -> [StatusMenuState.Held] {
        `guard`.held.map(StatusMenuState.Held.init)
    }
}
