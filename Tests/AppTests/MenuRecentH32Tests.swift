import AppKit
import Foundation
import Engine
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// H32 — the menu's "Recent" group: last 5 dictations at the top, one truncated line each, app icon,
/// time, tooltip; click = Copy via the verified copy ("Copied" only on read-back); password-field
/// turns never listed (filtered by `TurnStore.recentDictations`); a hands-free session is one row.
@Suite("H32 Recent dictations (menu)")
struct MenuRecentH32Tests {
    final class Board: TodayPasteboard {
        var stored: String?
        var lies = false
        func write(_ text: String) -> Bool { stored = lies ? "other" : text; return true }
        func read() -> String? { stored }
    }

    static let now = Date(timeIntervalSinceReferenceDate: 700_000_000)

    static func row(_ line: String, ago: TimeInterval = 120, bundle: String? = "com.apple.Notes") -> RecentMenu.Row {
        RecentMenu.Row(RecentDictation(id: TurnID(), time: now.addingTimeInterval(-ago), appName: "Notes",
                                       bundleID: bundle, text: line, line: RecentDictation.oneLine(line),
                                       outcome: .inserted(app: "Notes")), now: now)
    }

    static func save(_ store: TurnStore, _ text: String, at s: TimeInterval, stage: TurnStage = .landed,
                     outcome: DeliveryOutcome? = .delivered(verified: true, method: "ax"),
                     session: String? = nil) -> TurnID {
        var record = TurnRecord(turnID: TurnID(), startedAt: now.addingTimeInterval(s),
                                destination: .init(bundleID: "com.apple.Notes", appName: "Notes"),
                                rawText: text, finalText: text)
        record.outcome = outcome
        store.save(record, stage: stage)
        store.setExtras(record.turnID, save: false) { $0.handsFreeSessionID = session }
        return record.turnID
    }

    @Test("spec: Recent heads the menu, 5 rows max, copy action, tooltip, icon, time")
    func spec() {
        var state = StatusMenuState()
        state.recent = (0..<7).map { Self.row("words \($0)") }
        let entries = StatusMenuSpec.entries(state)
        #expect(entries.first?.id == StatusMenuSpec.ID.recentHeader)
        #expect(entries.first?.title == "Recent")
        let rows = entries.filter { if case .copyRecent? = $0.action { return true }; return false }
        #expect(rows.count == 5)
        #expect(rows[0].action == .copyRecent(state.recent[0].id))
        #expect(rows[0].toolTip == "words 0")
        #expect(rows[0].iconBundleID == "com.apple.Notes")
        #expect(rows[0].trailing == "2 m")
        // The status line follows the group, after a separator.
        let statusIndex = entries.firstIndex { $0.id == StatusMenuSpec.ID.status }
        #expect(statusIndex == 7)
        #expect(entries[6].isSeparator)
    }

    @Test("no dictations → no Recent group; the status line stays first")
    func empty() {
        let entries = StatusMenuSpec.entries(StatusMenuState())
        #expect(entries.first?.id == StatusMenuSpec.ID.status)
        #expect(!entries.contains { $0.id == StatusMenuSpec.ID.recentHeader })
    }

    @Test("one line, tail-truncated; tooltip keeps the full words")
    func truncation() {
        let long = String(repeating: "word ", count: 40) + "\nend"
        let entry = RecentMenu.entries([Self.row(long)])[1]
        #expect(!entry.title.contains("\n"))
        #expect(entry.title.hasSuffix("…"))
        #expect(entry.title.count <= RecentMenu.maxLineCharacters)
        #expect(entry.toolTip == long)
    }

    @Test("secure never listed; hands-free session is one row; through the store into the menu")
    func throughStore() {
        let store = TurnStore(database: nil)
        _ = Self.save(store, "first piece", at: 1, session: "s1")
        _ = Self.save(store, "second piece", at: 2, session: "s1")
        _ = Self.save(store, "secret", at: 3, stage: .failed, outcome: .failed(reason: DeliveryReason.secureField))
        _ = Self.save(store, "plain", at: 4)
        var state = StatusMenuState()
        state.recent = store.recentDictations(limit: RecentMenu.limit).map { RecentMenu.Row($0, now: Self.now) }
        let titles = RecentMenu.entries(state.recent).filter { $0.action != nil }.map(\.title)
        #expect(titles == ["plain", "first piece second piece"])
        #expect(!titles.contains { $0.contains("secret") })
    }

    @Test("click copies via the verified path; 'Copied' only on read-back")
    @MainActor
    func copyThroughController() {
        let controller = StatusItemController(flags: FeatureFlagService.inMemory(), database: nil,
                                              coordinator: DictationCoordinator(engine: MockEngine(fixture: TranscriptFixture(name: "h32", spans: []), delayScale: 0), database: nil,
                                                                                pill: PillPanelController()),
                                              hotkey: HotkeyService(defaults: UserDefaults(suiteName: "AppTests.h32.\(UUID())")!),
                                              updater: NoopUpdater(), statusBar: nil)
        let store = TurnStore(database: nil)
        let id = Self.save(store, "copy me", at: 1)
        let board = Board()
        var told: [Bool] = []
        controller.now = { Self.now.addingTimeInterval(10) }
        controller.recentDictations = { store.recentDictations(limit: RecentMenu.limit) }
        controller.copyRecent = { store.copyRecent($0, pasteboard: board) }
        controller.onRecentCopied = { _, ok in told.append(ok) }

        controller.run(.copyRecent(id))
        #expect(board.stored == "copy me")
        #expect(told == [true])
        var row = controller.menuEntries().first { $0.action == .copyRecent(id) }
        #expect(row?.trailing == RecentMenu.copied)
        #expect(row?.isOn == true)
        // Rendered: native header, tooltip, check.
        let item = controller.menu.items.first { $0.identifier?.rawValue == StatusMenuSpec.ID.recentRow(id) }
        #expect(item?.toolTip == "copy me")
        #expect(item?.state == .on)
        #expect(controller.menu.items.first?.identifier?.rawValue == StatusMenuSpec.ID.recentHeader)

        // A pasteboard that does not read back: no "Copied".
        board.lies = true
        controller.run(.copyRecent(id))
        #expect(told == [true, false])
        row = controller.menuEntries().first { $0.action == .copyRecent(id) }
        #expect(row?.trailing != RecentMenu.copied)
        #expect(row?.isOn == false)

        // "Copied" fades after the dwell.
        board.lies = false
        controller.run(.copyRecent(id))
        controller.now = { Self.now.addingTimeInterval(60) }
        row = controller.menuEntries().first { $0.action == .copyRecent(id) }
        #expect(row?.trailing != RecentMenu.copied)
    }

    @Test("a turn not listed (secure) copies nothing")
    func secureCopiesNothing() {
        let store = TurnStore(database: nil)
        let id = Self.save(store, "pw", at: 1, stage: .failed, outcome: .failed(reason: DeliveryReason.secureField))
        let board = Board()
        #expect(store.copyRecent(id, pasteboard: board) == false)
        #expect(board.stored == nil)
    }
}
