import Foundation
import GRDB
import Shared
import Testing
@testable import VoicePlusApp

/// N21 + T-schema — one turn id across `turn_diagnostics` and `turn_records`, and the readable
/// columns that let every turn explain itself (round-3 §F confidence gate item 3).
@Suite("Turn schema (N21, T-schema)")
struct TurnSchemaN21Tests {
    static func record(at seconds: TimeInterval = 0) -> TurnRecord {
        var r = TurnRecord(turnID: TurnID(), startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + seconds),
                           destination: .init(bundleID: "com.apple.TextEdit", appName: "TextEdit", role: "AXTextArea",
                                              elementHash: 42, displayID: 1, selection: 3..<3, textVersion: 99),
                           rawText: "hello there", finalText: "Hello there.")
        let t0 = r.startedAt
        r.capture.captureOpened = t0.addingTimeInterval(0.05)
        r.capture.captureClosed = t0.addingTimeInterval(2.0)
        r.capture.finalPublished = t0.addingTimeInterval(2.3)
        r.capture.writeDispatched = t0.addingTimeInterval(2.6)
        return r
    }

    @Test("diagnostics and records join on one turn id")
    func joinOnTurnID() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        let diagnostics = try TurnDiagnostics(database: db)
        let rec = Self.record()
        store.save(rec, stage: .landed)
        diagnostics.record(.landing(verdict: "confirmed", appBundleID: "com.apple.TextEdit", method: "ax", settleMs: 40),
                           turnID: rec.turnID)
        diagnostics.record(TurnEventDiagnostics.pauseEvent("hover", resumed: false), turn: rec.turnID.diagnosticsKey)
        store.flush()

        let joined = try db.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM \(TurnStore.table) r JOIN \(TurnDiagnostics.table) d ON d.turnID = r.id
                WHERE r.id = ?
                """, arguments: [rec.turnID.rawValue.uuidString])
        }
        #expect(joined == 2)
        #expect(try diagnostics.entries(turnID: rec.turnID).count == 2)
        #expect(rec.turnID.diagnosticsKey == rec.turnID.rawValue.uuidString)
    }

    @Test("the controller's landing event and the live-turn key use the record's id")
    func controllerUsesFullKey() {
        let id = TurnID()
        #expect(id.diagnosticsKey.count == 36)
        #expect(id.diagnosticsKey != id.description)
    }

    @Test("rows an older build wrote under the short id are still found")
    func legacyShortIDs() throws {
        let db = try AppDatabase.inMemory()
        let diagnostics = try TurnDiagnostics(database: db)
        let id = TurnID()
        diagnostics.record(.orderOut(window: "pill", reason: "old"), turn: id.description)
        diagnostics.record(.orderOut(window: "pill", reason: "new"), turnID: id)
        #expect(try diagnostics.entries(turnID: id).count == 2)
    }

    @Test("turn_records gains every readable column")
    func columnsExist() throws {
        let db = try AppDatabase.inMemory()
        _ = TurnStore(database: db)
        let names = try db.reader.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(\(TurnStore.table))").map { $0["name"] as String }
        }
        for column in ["surface_kind", "surface_signals_json", "field_role", "write_method", "verification",
                       "stage_ms_json", "pre_boost_raw_text", "key_down_at", "key_up_at"] {
            #expect(names.contains(column), "missing \(column)")
        }
    }

    @Test("an older turn_records table is upgraded in place, its rows kept")
    func upgradesOldTable() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { db in
            try db.execute(sql: """
                CREATE TABLE \(TurnStore.table) (id TEXT PRIMARY KEY NOT NULL, startedAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL, stage TEXT NOT NULL, recordJSON TEXT NOT NULL)
                """)
        }
        let rec = Self.record()
        let json = String(decoding: try JSONEncoder().encode(rec), as: UTF8.self)
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO \(TurnStore.table) VALUES (?, ?, ?, ?, ?)",
                           arguments: [rec.turnID.rawValue.uuidString, 1.0, 1.0, "landed", json])
        }
        let store = TurnStore(database: db)
        #expect(store.entry(rec.turnID)?.record == rec)
        store.setExtras(rec.turnID) { $0.surfaceKind = "doc" }
        store.flush()
        let kind = try db.reader.read { try String.fetchOne($0, sql: "SELECT surface_kind FROM \(TurnStore.table)") }
        #expect(kind == "doc")
    }

    @Test("explicit extras from other lanes land in the columns; the rest is derived from the record")
    func extrasColumns() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        var rec = Self.record()
        // L2 sets timing and pre-boost text before the first save: kept and applied.
        store.setExtras(rec.turnID) { $0.preBoostRawText = "hello their"; $0.setStage("boost", ms: 120) }
        store.save(rec, stage: .inserting)
        rec.outcome = .delivered(verified: false, method: "paste")
        store.update(rec.turnID, stage: .landed) { $0.outcome = rec.outcome }
        // L6 and L4 fill theirs afterwards.
        store.setExtras(rec.turnID) {
            $0.surfaceKind = "chat"; $0.surfaceSignals = ["role": "AXTextArea", "web": "true"]
        }
        store.setExtras(rec.turnID) { $0.verification = .verified; $0.writeMethod = "ax" }
        store.flush()

        let row = try #require(try db.reader.read { try Row.fetchOne($0, sql: "SELECT * FROM \(TurnStore.table)") })
        #expect(row["surface_kind"] as String? == "chat")
        #expect(row["field_role"] as String? == "AXTextArea")
        #expect(row["write_method"] as String? == "ax")
        #expect(row["verification"] as String? == "verified")
        #expect(row["pre_boost_raw_text"] as String? == "hello their")
        #expect((row["key_down_at"] as Double?) == rec.startedAt.timeIntervalSinceReferenceDate)
        #expect((row["key_up_at"] as Double?) == rec.capture.captureClosed?.timeIntervalSinceReferenceDate)
        let signals = try JSONDecoder().decode([String: String].self, from: Data((row["surface_signals_json"] as String).utf8))
        #expect(signals["web"] == "true")
        let stages = try JSONDecoder().decode([String: Int].self, from: Data((row["stage_ms_json"] as String).utf8))
        #expect(stages["boost"] == 120)
        #expect(stages[TurnRecordExtras.Stage.captureOpen] == 50)
        #expect(stages[TurnRecordExtras.Stage.finalPass] == 300)
        #expect(stages[TurnRecordExtras.Stage.recognisedToTyped] == 300)

        // A second store reads the explicit extras back.
        let reopened = try #require(TurnStore(database: db).entry(rec.turnID))
        #expect(reopened.extras.surfaceKind == "chat")
        #expect(reopened.extras.verification == .verified)
    }

    @Test("verification vocabulary follows the outcome when no lane set it")
    func derivedVerification() {
        #expect(TurnVerification.from(.delivered(verified: true, method: "ax")) == .verified)
        #expect(TurnVerification.from(.delivered(verified: false, method: "ax")) == .unverified)
        #expect(TurnVerification.from(.partial(method: "ax")) == .unverified)
        #expect(TurnVerification.from(.held(reason: "x")) == .notLanded)
        #expect(TurnVerification.from(.failed(reason: "x")) == .notLanded)
        #expect(TurnVerification.from(nil) == nil)
        #expect(TurnVerification.notLanded.rawValue == "not landed")
        var rec = Self.record()
        rec.outcome = .held(reason: "focus moved")
        let x = TurnRecordExtras().resolved(for: rec)
        #expect(x.verification == .notLanded)
        #expect(x.writeMethod == nil)
    }

    @Test("history off: setting extras never writes a settled row back to the database")
    func historyOffRespected() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        store.historyEnabled = { false }
        var rec = Self.record()
        rec.outcome = .delivered(verified: true, method: "ax")
        store.save(rec, stage: .landed)
        store.setExtras(rec.turnID) { $0.preBoostRawText = "secret words" }
        store.flush()
        let rows = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(TurnStore.table)") }
        #expect(rows == 0)
        #expect(store.extras(rec.turnID)?.preBoostRawText == "secret words")
    }

    @Test("T-schema verify: the key-down surface is recorded into surface_kind and signals at key-up")
    func surfaceRecordedFromController() async throws {
        let h = TurnControllerTests.Harness(dwell: .immediate)
        h.controller.surfaceForTurn = {
            SurfaceResolution(kind: .chatComposer, confidence: 0.82, isWebArea: true, signals: ["role:AXTextArea", "runtime:electron"])
        }
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        await h.controller.finalize(id, spans: TurnControllerTests.words("hello there"))
        _ = await h.wait { h.events.landed.count == 1 }
        var extras: TurnRecordExtras?
        for _ in 0..<200 {
            extras = h.store.entry(id)?.resolvedExtras
            if extras?.surfaceKind != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(extras?.surfaceKind == "chatComposer")
        #expect(extras?.surfaceSignals?["web_area"] == "1")
        #expect(extras?.surfaceSignals?["signal1"] == "runtime:electron")
    }

    @Test("T-schema verify: no surface provider leaves the columns empty")
    func noSurfaceProvider() async throws {
        let h = TurnControllerTests.Harness(dwell: .immediate)
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        #expect(h.store.entry(id)?.resolvedExtras.surfaceKind == nil)
    }
}
