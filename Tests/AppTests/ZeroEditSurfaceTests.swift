import AppKit
import Foundation
import Lab
import Shared
import Testing
@testable import VoicePlusApp

/// I2 — the zero-edit counter surfaced: the 7-day rate from `dictation_history` (as
/// `DatabaseZeroEditSink` / `ZeroEditTracker` mark it), in the status menu and on Today.
@Suite("I2 — zero-edit counter")
struct ZeroEditSurfaceTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    static func insert(_ db: AppDatabase, _ text: String, daysAgo: Int, edited: Bool = false,
                       from base: Date = now) throws -> UUID {
        let at = Calendar.current.date(byAdding: .day, value: -daysAgo, to: base)!
        let id = UUID()
        var rec = DictationRecord(startedAt: at, endedAt: at, register: "chat", route: "dictate", appBundleID: "a",
                                  rawText: text, finalText: text, spansJSON: "[]")
        rec.id = id.uuidString
        try db.insert(rec)
        if edited { DatabaseZeroEditSink(database: db).markEdited(utteranceID: id, wordsEdited: 1, source: "test") }
        return id
    }

    @Test func weekIsTheLastSevenDaysOfTheTrend() {
        // Two five-word dictations a day for 14 days; every one in the older week edited, one today.
        var rows: [DictationRecord] = []
        for daysAgo in 0..<14 {
            let at = Self.calendar.date(byAdding: .day, value: -daysAgo, to: Self.now)!
            for k in 0..<2 {
                var rec = DictationRecord(startedAt: at, endedAt: at, register: "chat", route: "dictate", appBundleID: "a",
                                          rawText: "a b c d e", finalText: "a b c d e", spansJSON: "[]")
                rec.edited = daysAgo >= 7 || (daysAgo == 0 && k == 0)
                rows.append(rec)
            }
        }
        let stat = ZeroEditStats.rollup(rows, days: 14, now: Self.now, calendar: Self.calendar)
        let week = ZeroEditWeek.from(stat)
        #expect(week.dictations == 14 && week.editedDictations == 1 && week.words == 70)
        #expect(week.zeroEditDictations == 13)
        #expect(week.percent == 93)
    }

    @Test func emptyWeekClaimsNoRate() {
        let week = ZeroEditWeek(dictations: 0, editedDictations: 0, words: 0)
        #expect(week.rate == nil && week.percent == nil && week.isEmpty)
        #expect(ZeroEditCopy.headline(week) == nil && ZeroEditCopy.detail(week) == nil)
        #expect(ZeroEditCopy.accessibilityLabel(week) == "No dictations in the last 7 days")
    }

    @Test func copyReadsPlainly() {
        let week = ZeroEditWeek(dictations: 50, editedDictations: 4, words: 1234)
        #expect(ZeroEditCopy.headline(week) == "92% landed without edits this week")
        #expect(ZeroEditCopy.detail(week) == "46 of 50 dictations · 1,234 words · last 7 days")
        let one = ZeroEditWeek(dictations: 1, editedDictations: 0, words: 1)
        #expect(ZeroEditCopy.detail(one) == "1 of 1 dictation · 1 word · last 7 days")
    }

    @Test func loadsFromHistoryAndCountsSinkEdits() throws {
        let db = try AppDatabase.inMemory()
        try Self.insert(db, "one two three", daysAgo: 0)
        try Self.insert(db, "four five", daysAgo: 0, edited: true)          // a voice repair marked it
        try Self.insert(db, "six", daysAgo: 6)
        try Self.insert(db, "seven eight", daysAgo: 7)                      // outside the week
        try Self.insert(db, "nine", daysAgo: 30, edited: true)
        let week = try #require(ZeroEditWeek.load(from: db, now: Self.now, calendar: Self.calendar))
        #expect(week.dictations == 3 && week.editedDictations == 1 && week.words == 6)
        #expect(week.percent == 67)
        #expect(ZeroEditWeek.load(from: nil) == nil)
    }

    @Test @MainActor func surfaceModelReloadsFromTheSameRows() throws {
        let db = try AppDatabase.inMemory()
        let model = ZeroEditSurfaceModel(database: db)
        model.reload()
        #expect(model.week.isEmpty)
        try Self.insert(db, "hello there", daysAgo: 0, edited: false, from: Date())
        try Self.insert(db, "general kenobi", daysAgo: 0, edited: true, from: Date())
        model.reload()
        #expect(model.week.dictations == 2 && model.week.percent == 50)
        #expect(model.trend.stat.today.dictations == 2, "Lab's ZeroEditMenuView reads the same model")
    }

    // MARK: Status menu

    @Test @MainActor func headlessMenuKeepsTheSpecRowsUnlessAskedTo() throws {
        let db = try AppDatabase.inMemory()
        try Self.insert(db, "words", daysAgo: 0, from: Date())
        let rig = StatusMenuControllerTests.Rig(database: db)
        rig.controller.menuNeedsUpdate(rig.controller.menu)
        #expect(rig.controller.showsZeroEditCounter == false)
        #expect(rig.controller.menu.items.count == StatusMenuSpec.entries(rig.controller.menuState()).count)
    }

    @Test @MainActor func menuShowsTheWeekUnderTheMicrophone() throws {
        let db = try AppDatabase.inMemory()
        try Self.insert(db, "one two", daysAgo: 0, from: Date())
        try Self.insert(db, "three", daysAgo: 1, edited: true, from: Date())
        let rig = StatusMenuControllerTests.Rig(database: db)
        rig.controller.showsZeroEditCounter = true
        rig.controller.menuNeedsUpdate(rig.controller.menu)
        let ids = rig.controller.menu.items.map { $0.identifier?.rawValue }
        let mic = try #require(ids.firstIndex(of: StatusMenuSpec.ID.microphone))
        #expect(ids[mic + 1] == ZeroEditCopy.menuID)
        let item = rig.controller.menu.items[mic + 1]
        #expect(item.isEnabled == false && item.action == nil, "a stat, not an action")
        #expect(item.title == "50% landed without edits this week")
        #expect(item.view != nil, "hosts ZeroEditMenuView's trend")
        #expect(rig.controller.menu.items.count == StatusMenuSpec.entries(rig.controller.menuState()).count + 1)
    }

    @Test @MainActor func menuShowsNothingWithoutAWeekToCount() throws {
        let db = try AppDatabase.inMemory()
        try Self.insert(db, "long ago", daysAgo: 20, from: Date())
        let rig = StatusMenuControllerTests.Rig(database: db)
        rig.controller.showsZeroEditCounter = true
        rig.controller.menuNeedsUpdate(rig.controller.menu)
        #expect(!rig.controller.menu.items.contains { $0.identifier?.rawValue == ZeroEditCopy.menuID })
        let none = StatusMenuControllerTests.Rig(database: nil)
        none.controller.showsZeroEditCounter = true
        none.controller.menuNeedsUpdate(none.controller.menu)
        #expect(!none.controller.menu.items.contains { $0.identifier?.rawValue == ZeroEditCopy.menuID })
    }
}
