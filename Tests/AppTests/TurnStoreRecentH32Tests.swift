import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// H32 — the menu's Recent rows, data side: 5 rows max, secure never listed (by outcome reason),
/// one line each, relative time, tooltip, and Copy that says "Copied" only on read-back.
@Suite("H32 Recent dictations (data)")
struct TurnStoreRecentH32Tests {
    final class Board: TodayPasteboard {
        var stored: String?
        var lies = false
        func write(_ text: String) -> Bool { stored = lies ? "other" : text; return true }
        func read() -> String? { stored }
    }

    static let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

    @discardableResult
    static func save(_ store: TurnStore, _ text: String, at s: TimeInterval, stage: TurnStage = .landed,
                     outcome: DeliveryOutcome? = .delivered(verified: true, method: "ax"),
                     _ extras: (inout TurnRecordExtras) -> Void = { _ in }) -> TurnID {
        var record = TurnRecord(turnID: TurnID(), startedAt: base.addingTimeInterval(s),
                                destination: .init(bundleID: "com.apple.Notes", appName: "Notes"),
                                rawText: text, finalText: text)
        record.outcome = outcome
        store.save(record, stage: stage)
        store.setExtras(record.turnID, save: false, extras)
        return record.turnID
    }

    @Test("spec: 5 rows max, secure never listed, Notes and cancelled-to-Notes rows listed")
    func spec() {
        let store = TurnStore(database: nil)
        NotesWiring.routeFormerHolds(turns: store, focusGuard: nil) { _, _, _ in .success("n") }
        for i in 0..<4 { Self.save(store, "line \(i)", at: Double(i)) }
        Self.save(store, "secret", at: 5, stage: .failed, outcome: .failed(reason: DeliveryReason.secureField))
        Self.save(store, "secret two", at: 6, stage: .held, outcome: .held(reason: DeliveryLadder.Reason.passwordField.rawValue))
        Self.save(store, "no field", at: 7, stage: .held, outcome: .held(reason: DeliveryReason.noDestination))
        Self.save(store, "changed my mind", at: 8, stage: .cancelled, outcome: nil)
        let rows = store.recentDictations(limit: 5)
        #expect(rows.count == 5)
        #expect(rows.map(\.text) == ["changed my mind", "no field", "line 3", "line 2", "line 1"])
        #expect(rows[0].outcome.text == "Cancelled · Saved to Notes")
        #expect(rows[1].outcome.text == "Saved to Notes · no text field")
        #expect(!rows.contains { $0.text.contains("secret") })
        #expect(rows.first?.bundleID == "com.apple.Notes")
    }

    @Test("one line each; tooltip carries the full words; relative time")
    func lineTooltipTime() throws {
        let store = TurnStore(database: nil)
        Self.save(store, "first line\nsecond   line", at: 0)
        let row = try #require(store.recentDictations().first)
        #expect(row.line == "first line second line")
        #expect(row.tooltip == "first line\nsecond   line")
        #expect(row.timeLabel(now: Self.base.addingTimeInterval(20)) == "now")
        #expect(row.timeLabel(now: Self.base.addingTimeInterval(125)) == "2 m")
        #expect(row.timeLabel(now: Self.base.addingTimeInterval(3 * 3600 + 5)) == "3 h")
        #expect(row.timeLabel(now: Self.base.addingTimeInterval(2 * 86_400)) == "2 d")
    }

    @Test("Copy: verified write, 'Copied' only on read-back; a secure turn copies nothing")
    func copyRecent() {
        let store = TurnStore(database: nil)
        let ok = Self.save(store, "copy me", at: 0)
        let secure = Self.save(store, "pw", at: 1, stage: .failed, outcome: .failed(reason: DeliveryReason.secureField))
        let board = Board()
        #expect(store.copyRecent(ok, pasteboard: board))
        #expect(board.stored == "copy me")
        board.lies = true
        #expect(!store.copyRecent(ok, pasteboard: board))
        board.lies = false
        board.stored = nil
        #expect(!store.copyRecent(secure, pasteboard: board))
        #expect(board.stored == nil)
    }

    @Test("a hands-free session copies as one row (its pieces joined, oldest first)")
    func sessionCopy() throws {
        let store = TurnStore(database: nil)
        var last = TurnID()
        for i in 0..<3 { last = Self.save(store, "piece\(i)", at: Double(i)) { $0.handsFreeSessionID = "S" } }
        let rows = store.recentDictations()
        #expect(rows.count == 1)
        #expect(rows[0].id == last)
        let board = Board()
        #expect(store.copyRecent(last, pasteboard: board))
        #expect(board.stored == "piece0 piece1 piece2")
    }
}
