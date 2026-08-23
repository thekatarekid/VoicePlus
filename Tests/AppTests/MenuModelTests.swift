import Foundation
import Shared
import Testing
@testable import VoicePlusApp

@Suite("Menu model (T4)")
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
        #expect(m.statusSymbol == "mic.slash")
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
}
