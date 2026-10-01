import Foundation
import GRDB
import Shared
import Testing
@testable import VoicePlusApp

@Suite("V5 Q13 — persisted turn diagnostics")
struct TurnDiagnosticsQ13Tests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date { get { lock.withLock { t } } set { lock.withLock { t = newValue } } }
    }

    @Test func recordsEveryEventKindAndRoundTrips() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try TurnDiagnostics(writer: try DatabaseQueue(), clock: { clock.now })
        let events: [TurnDiagnosticsEvent] = [
            .pillDisplay(reason: "caretFound", mouse: .init(x: 10, y: 20), frame: .init(x: 0, y: 0, width: 200, height: 40)),
            .orderFront(window: "pill", reason: "turnStarted"),
            .pause(reason: "pointerEnteredPill", pointer: .init(x: 1, y: 2), frame: nil),
            .resume(reason: "pointerLeft", pointer: .init(x: 3, y: 4), frame: .init(x: 1, y: 1, width: 2, height: 2)),
            .landing(verdict: "landed", appBundleID: "com.apple.TextEdit", method: "ax", settleMs: 140),
            .decision(.init(owner: "dictation", confidence: 0.92, band: "high", reason: "noTrigger",
                            questionProbabilities: ["isCommand": 0.04, "isQuestion": 0.1])),
            .orderOut(window: "pill", reason: "landed"),
        ]
        for e in events { store.record(e, turn: "t1") }
        store.record(.orderFront(window: "pill", reason: "x"), turn: "t2")
        let got = try store.entries(turn: "t1").map(\.event)
        #expect(got == events)
        #expect(try store.entries().count == 8)
        // Also opens on the app database beside the other tables.
        let onApp = try TurnDiagnostics(database: AppDatabase.inMemory())
        onApp.record(.orderOut(window: "pill", reason: "r"), turn: "x")
        #expect(try onApp.entries().count == 1)
    }

    @Test func retentionSweepDropsRowsOlderThanSevenDays() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try TurnDiagnostics(writer: try DatabaseQueue(), clock: { clock.now })
        store.record(.orderFront(window: "pill", reason: "old"), turn: "old")
        clock.now = clock.now.addingTimeInterval(6 * 86_400)
        store.record(.orderFront(window: "pill", reason: "recent"), turn: "recent")
        clock.now = clock.now.addingTimeInterval(1 * 86_400 + 60)
        let removed = try store.sweep()
        #expect(removed == 1)
        #expect(try store.entries().map(\.turnID) == ["recent"])
        // The export also sweeps first.
        clock.now = clock.now.addingTimeInterval(7 * 86_400)
        let json = try JSONSerialization.jsonObject(with: store.exportJSON()) as? [String: Any]
        #expect((json?["turns"] as? [Any])?.isEmpty == true)
        #expect(json?["retentionDays"] as? Int == 7)
    }

    @Test func exportGroupsByTurnAsJSON() throws {
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try TurnDiagnostics(writer: try DatabaseQueue(), clock: { clock.now })
        store.record(.orderFront(window: "pill", reason: "a"), turn: "t1")
        store.record(.landing(verdict: "landed", appBundleID: nil, method: "paste", settleMs: 80), turn: "t2")
        store.record(.orderOut(window: "pill", reason: "b"), turn: "t1")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("q13-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.exportJSON(to: url)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let turns = try #require(doc?["turns"] as? [[String: Any]])
        #expect(turns.map { $0["turnID"] as? String } == ["t1", "t2"])
        #expect((turns[0]["events"] as? [Any])?.count == 2)
        #expect(TurnDiagnostics.exportFileName(at: clock.now).hasSuffix(".json"))
    }

    @Test func reasonsAreClippedSoTextCannotBeSmuggled() throws {
        let store = try TurnDiagnostics(writer: try DatabaseQueue())
        let long = String(repeating: "word ", count: 200)
        store.record(.pause(reason: long, pointer: nil, frame: nil), turn: "t")
        guard case let .pause(reason, _, _) = try #require(store.entries().first?.event) else {
            Issue.record("wrong kind"); return
        }
        #expect(reason.count == TurnDiagnostics.maxReasonLength)
    }

    /// Source audit: the diagnostics module never references transcript/dictated-text types or fields.
    @Test func sourceAuditNoTranscriptTextStored() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Diagnostics")
        let files = ["TurnDiagnostics.swift", "TurnDiagnosticsExportAction.swift"]
        let banned = ["TranscriptSpan", "rawText", "finalText", "transcript:", "text:", "Utterance(", "spansJSON",
                      "dictation_history", "audioURL", "samples"]
        for f in files {
            let src = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
            let code = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for b in banned { #expect(!code.contains(b), "\(f) references \(b)") }
        }
        // The table schema has no text column for content.
        let db = try DatabaseQueue()
        _ = try TurnDiagnostics(writer: db)
        let cols = try db.read { try $0.columns(in: TurnDiagnostics.table).map(\.name) }
        #expect(Set(cols) == ["id", "turnID", "at", "kind", "payloadJSON"])
    }
}
