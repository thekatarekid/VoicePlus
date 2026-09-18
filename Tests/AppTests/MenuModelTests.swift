import Foundation
import Shared
import Testing
@testable import VoicePlusApp

@Suite("Menu model (T4, S6)")
struct MenuModelTests {
    @Test func linesAndStats() throws {
        let db = try AppDatabase.inMemory()
        let now = Date()
        try db.insert(DictationRecord(startedAt: now, endedAt: now, register: "chat", route: "dictate", appBundleID: nil,
                                      rawText: "a b c", finalText: "one two three", spansJSON: "[]", edited: false))
        try db.insert(DictationRecord(startedAt: now.addingTimeInterval(-86_400 * 3), endedAt: nil, register: "chat", route: "dictate",
                                      appBundleID: nil, rawText: "x", finalText: "old words here", spansJSON: "[]", edited: true))
        let stats = MenuModel.load(from: db, now: now)
        #expect(stats.total == 2 && stats.zeroEdit == 1 && stats.wordsToday == 3)
        let m = MenuModel(zeroEditCount: stats.zeroEdit, totalCount: stats.total, wordsToday: stats.wordsToday,
                          micStatus: .bad, paused: true)
        #expect(m.zeroEditLine == "Zero-edit: 1/2 (50%)")
        #expect(m.wordsLine == "Words today: 3")
        #expect(m.micLine.hasSuffix("check mic"))
        #expect(m.pauseTitle == "Resume VoicePlus")
        #expect(MenuModel().zeroEditLine == "Zero-edit: no dictations yet")
    }

    @Test func updaterStubAndFlags() throws {
        let u = NoopUpdater()
        u.checkForUpdates()
        #expect(u.checkCount == 1 && !u.canCheckForUpdates && u.feedURL != nil)
        let flags = FeatureFlagService.inMemory()
        try flags.setOverride(false, for: .voiceRepair)
        #expect(!flags.isEnabled(.voiceRepair))
        #expect(!LaunchAtLogin.isAvailable) // swift test runs outside an .app bundle
    }

    // MARK: - S6 · the item table per state (design §8.8, `DESIGN.md` §10)

    /// One row as the table states it: id, title, helper line, enabled, action, toggle.
    struct Row: Equatable, Sendable, CustomStringConvertible {
        var id: String
        var title: String
        var detail: String?
        var enabled: Bool
        var action: MenuAction?
        var on: Bool = false

        init(_ id: String, _ title: String, _ detail: String?, enabled: Bool = true, _ action: MenuAction?,
             on: Bool = false) {
            self.id = id
            self.title = title
            self.detail = detail
            self.enabled = enabled
            self.action = action
            self.on = on
        }

        init(_ entry: MenuEntry) {
            self.init(entry.id, entry.title, entry.detail, enabled: entry.isEnabled, entry.action, on: entry.isOn)
        }

        var description: String {
            "\(id): \"\(title)\" · \(detail ?? "—") · \(enabled ? "enabled" : "disabled") · \(action.map { "\($0)" } ?? "no action")\(on ? " · on" : "")"
        }
    }

    typealias ID = StatusMenuSpec.ID

    static func status(_ title: String, _ detail: String) -> Row { Row(ID.status, title, detail, enabled: false, nil) }
    static let mic = Row(ID.microphone, "Mic: MacBook Pro Microphone ✓", nil, enabled: false, nil)
    static let start = Row(ID.dictate, "Start dictation", "Menu capture has an explicit Stop control.", .startDictation)
    static func startDisabled(_ reason: String) -> Row {
        Row(ID.dictate, "Start dictation (\(reason))", "Menu capture has an explicit Stop control.", enabled: false, nil)
    }
    static let stop = Row(ID.dictate, "Stop", nil, .stopDictation)
    static func mute(on: Bool = false) -> Row {
        Row(ID.mute, "Mute microphone", "Close every active capture.", .toggleMute, on: on)
    }
    static let tail = [
        Row(ID.openWindow, "Open VoicePlus", "Today and all settings.", .openWindow),
        Row(ID.settings, "Settings…", nil, .openSettings),
        Row(ID.quit, "Quit VoicePlus", "Protect active capture and unsaved text.", .quit),
    ]

    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var state: StatusMenuState
        var rows: [Row]
        var testDescription: String { name }
    }

    static func state(_ status: MenuStatus, capturing: Bool = false, muted: Bool = false, micAvailable: Bool = true,
                      held: Int = 0) -> StatusMenuState {
        StatusMenuState(status: status, micName: "MacBook Pro Microphone", micStatus: .good, micAvailable: micAvailable,
                        isCapturing: capturing, isMuted: muted,
                        held: (0..<held).map { StatusMenuState.Held(id: UUID(), title: "“held \($0)” — Notes") })
    }

    static let cases: [Case] = [
        Case(name: "ready", state: state(.ready), rows: [
            status("VoicePlus · Ready", "Microphone is closed."), mic, start, mute(),
        ] + tail),
        Case(name: "ready, one held dictation", state: state(.ready, held: 1), rows: [
            status("VoicePlus · Ready", "Microphone is closed."), mic, start, mute(),
            Row(ID.held, "1 held dictation", "Saved until you resolve it.", .reviewHeld),
        ] + tail),
        Case(name: "ready, three held dictations", state: state(.ready, held: 3), rows: [
            status("VoicePlus · Ready", "Microphone is closed."), mic, start, mute(),
            Row(ID.held, "3 held dictations", "Saved until you resolve it.", .reviewHeld),
        ] + tail),
        Case(name: "starting", state: state(.starting, capturing: true), rows: [
            status("VoicePlus · Starting microphone…", "Recording starts when the microphone is open"), mic, stop, mute(),
        ] + tail),
        Case(name: "listening", state: state(.listening, capturing: true), rows: [
            status("VoicePlus · Listening", "Microphone is open."), mic, stop, mute(),
        ] + tail),
        Case(name: "latched", state: state(.latched, capturing: true), rows: [
            status("VoicePlus · Latched · hands-free", "Microphone is open."), mic, stop, mute(),
        ] + tail),
        Case(name: "finishing", state: state(.finishing), rows: [
            status("VoicePlus · Finishing…", "Microphone closed · nothing inserted yet"), mic,
            startDisabled("finishing your previous dictation"), mute(),
        ] + tail),
        Case(name: "meeting", state: state(.meeting), rows: [
            status("VoicePlus · Meeting · recording", "Capture is separate from dictation"), mic, start, mute(),
        ] + tail),
        Case(name: "muted", state: state(.muted, muted: true), rows: [
            status("VoicePlus · Muted", "The microphone stays closed until you unmute."), mic,
            startDisabled("VoicePlus is muted"), mute(on: true),
        ] + tail),
        Case(name: "muted, held text", state: state(.muted, muted: true, held: 2), rows: [
            status("VoicePlus · Muted", "The microphone stays closed until you unmute."), mic,
            startDisabled("VoicePlus is muted"), mute(on: true),
            Row(ID.held, "2 held dictations", "Saved until you resolve it.", .reviewHeld),
        ] + tail),
        Case(name: "paused", state: state(.paused), rows: [
            status("VoicePlus · Paused", "Microphone is closed."), mic, start, mute(),
        ] + tail),
        Case(name: "blocked: microphone", state: state(.blocked(.microphoneDenied), micAvailable: false), rows: [
            status("VoicePlus · Blocked", "Microphone access is off — Open Microphone settings"),
            Row(ID.microphone, "Mic: MacBook Pro Microphone — off", nil, enabled: false, nil),
            startDisabled("microphone access is off"), mute(),
        ] + tail),
        Case(name: "blocked: no speech model", state: state(.blocked(.modelMissing)), rows: [
            status("VoicePlus · Blocked", "Install a speech model — Open Models"), mic,
            startDisabled("install a speech model"), mute(),
        ] + tail),
        // The menu is the fallback when the key cannot be heard: Start stays enabled.
        Case(name: "blocked: shortcut permission", state: state(.blocked(.hotkeyUnavailable)), rows: [
            status("VoicePlus · Blocked", "The shortcut needs permission — Open Input Monitoring"), mic, start, mute(),
        ] + tail),
        Case(name: "blocked: relaunch", state: state(.blocked(.relaunchNeeded)), rows: [
            status("VoicePlus · Blocked", "Reopen VoicePlus to finish setup"), mic, start, mute(),
        ] + tail),
        Case(name: "blocked: model downloading", state: state(.blocked(.modelDownloading(0.42))), rows: [
            status("VoicePlus · Blocked", "Downloading the speech model — 42%"), mic, start, mute(),
        ] + tail),
        // A capture the user can see is always stoppable, whatever else is true.
        Case(name: "muted while a capture is still open", state: state(.muted, capturing: true, muted: true), rows: [
            status("VoicePlus · Muted", "The microphone stays closed until you unmute."), mic, stop, mute(on: true),
        ] + tail),
    ]

    @Test(arguments: cases)
    func itemTablePerState(_ c: Case) {
        let entries = StatusMenuSpec.entries(c.state)
        let rows = entries.filter { !$0.isSeparator }.map(Row.init)
        #expect(rows == c.rows)
        // Separators: after the microphone line, before Open VoicePlus, before Quit.
        #expect(entries.map(\.isSeparator) == c.rows.indices.flatMap { index -> [Bool] in
            let id = c.rows[index].id
            return (id == ID.dictate || id == ID.openWindow || id == ID.quit) ? [true, false] : [false]
        })
        // The glyph and the ready dot live on the status line only; the dot only when ready.
        let status = StatusMenuSpec.entry(ID.status, in: entries)
        #expect(status?.showsGlyph == true)
        #expect(status?.showsReadyDot == (c.state.status == .ready && !c.state.isMuted))
        #expect(entries.filter(\.showsGlyph).count == 1)
        // Key equivalents: ⌘D dictate, ⌘M mute, ⌘, settings, ⌘Q quit.
        #expect(StatusMenuSpec.entry(ID.dictate, in: entries)?.keyEquivalent == "d")
        #expect(StatusMenuSpec.entry(ID.mute, in: entries)?.keyEquivalent == "m")
        #expect(StatusMenuSpec.entry(ID.settings, in: entries)?.keyEquivalent == ",")
        #expect(StatusMenuSpec.entry(ID.quit, in: entries)?.keyEquivalent == "q")
    }

    /// Exactly the design's rows and nothing the design moved into the window.
    @Test func nothingElseIsInTheMenu() {
        let everything = Self.cases.flatMap { StatusMenuSpec.entries($0.state) }
        let ids = Set(everything.filter { !$0.isSeparator }.map(\.id))
        #expect(ids == [ID.status, ID.microphone, ID.dictate, ID.mute, ID.held, ID.openWindow, ID.settings, ID.quit])
        // Titles are compared by prefix: the status line ("VoicePlus · Latched · hands-free") may name
        // a state; no row may *be* one of these.
        let titles = everything.filter { !$0.isSeparator }.map(\.title)
        for gone in ["Latch", "Copy last text", "Start meeting", "Stop meeting", "Recover text", "Lab",
                     "Data Panel", "Feature flags", "Enroll voice", "Launch at login", "Check for updates",
                     "Check permissions", "Show indicator", "Dictation key", "Actions key", "Model:",
                     "Zero-edit", "Words today", "Pause VoicePlus", "Resume VoicePlus"] {
            #expect(!titles.contains { $0.hasPrefix(gone) }, "the menu still offers \(gone)")
        }
    }
}
