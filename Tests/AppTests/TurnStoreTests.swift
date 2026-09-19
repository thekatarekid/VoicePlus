import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// S11 — the turn record store: one row per turn, written at the snapshot and updated at every
/// transition; recovery persistence independent of history; never claims a save that did not happen.
@Suite("Turn store (S11)")
struct TurnStoreTests {
    static func record(_ text: String = "hello there", at seconds: TimeInterval = 0) -> TurnRecord {
        TurnRecord(turnID: TurnID(), startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000 + seconds),
                   destination: .init(bundleID: "com.apple.TextEdit", appName: "TextEdit", role: "AXTextArea",
                                      elementHash: 42, displayID: 1, selection: 3..<3, textVersion: 99),
                   rawText: text, finalText: text)
    }

    @Test("a row round-trips through the database with its stage")
    func roundTrip() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        var record = Self.record()
        record.uncertainSpans = [0..<5]
        store.save(record, stage: .finalPreview)
        store.flush()

        // A second store over the same database sees what the first wrote.
        let reopened = TurnStore(database: db)
        let entry = try #require(reopened.entry(record.turnID))
        #expect(entry.record == record)
        #expect(entry.stage == .finalPreview)
        #expect(entry.persisted)
        #expect(entry.retentionLabel == TurnStore.keptUntilResolvedLabel)
    }

    @Test("updates replace the row; the stage follows each transition")
    func updatesReplace() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        let record = Self.record()
        store.save(record, stage: .starting)
        store.update(record.turnID, stage: .inserting) { $0.writeAttempted = true }
        store.update(record.turnID, stage: .landed) { $0.outcome = .delivered(verified: true, method: "ax") }
        store.flush()

        let rows = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(TurnStore.table)") }
        #expect(rows == 1, "one turn is one row")
        let entry = try #require(TurnStore(database: db).entry(record.turnID))
        #expect(entry.stage == .landed)
        #expect(entry.record.writeAttempted)
        #expect(entry.record.outcome == .delivered(verified: true, method: "ax"))
        #expect(entry.evidence == .inserted)
    }

    @Test("recent is newest first and recoverable lists held and partial turns")
    func recentAndRecoverable() throws {
        let store = TurnStore(database: try AppDatabase.inMemory())
        let old = Self.record("old", at: 0)
        let held = Self.record("held words", at: 10)
        var partial = Self.record("partial words", at: 20)
        partial.outcome = .partial(method: "keystroke")
        var unconfirmed = Self.record("unconfirmed", at: 30)
        unconfirmed.outcome = .delivered(verified: false, method: "paste")
        store.save(old, stage: .landed)
        store.save(held, stage: .held)
        store.save(partial, stage: .landed)
        store.save(unconfirmed, stage: .landed)
        store.flush()

        #expect(store.recent().map(\.record.finalText) == ["unconfirmed", "partial words", "held words", "old"])
        #expect(store.recoverable().map(\.record.finalText) == ["partial words", "held words"])
        #expect(store.entry(unconfirmed.turnID)?.evidence == .unconfirmed)
        #expect(store.entry(partial.turnID)?.evidence == .partial)
        #expect(store.entry(held.turnID)?.evidence == .held)
    }

    @Test("an uncertain inserted turn reads as '1 to review'")
    func uncertaintyEvidence() {
        let store = TurnStore(database: nil)
        var record = Self.record()
        record.uncertainSpans = [2..<6]
        record.outcome = .delivered(verified: true, method: "ax")
        let entry = store.save(record, stage: .landed)
        #expect(entry.evidence == .toReview(1))
        #expect(entry.evidence.label == "1 to review")
    }

    @Test("recovery persistence off: nothing is written, and the row says session only")
    func persistenceOffIsSessionOnly() throws {
        let db = try AppDatabase.inMemory()
        var persists = false
        let store = TurnStore(database: db, persistsRecovery: { persists })
        let record = Self.record()
        let entry = store.save(record, stage: .held)
        store.flush()

        #expect(store.persistence == .sessionOnly)
        #expect(store.retentionLabel == "Kept for this session only")
        #expect(entry.persisted == false)
        #expect(entry.retentionLabel == "Kept for this session only")
        #expect(store.entry(record.turnID)?.record == record, "the session still has it")
        let rows = try db.reader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(TurnStore.table)") }
        #expect(rows == 0)

        persists = true
        #expect(store.retentionLabel == "Kept until resolved")
    }

    @Test("no database: session only, and reads still work")
    func noDatabase() {
        let store = TurnStore(database: nil)
        let record = Self.record()
        store.save(record, stage: .finalPreview)
        #expect(store.persistence == .sessionOnly)
        #expect(store.entry(record.turnID)?.stage == .finalPreview)
        #expect(store.recent().count == 1)
    }

    @Test("a save that fails never claims to be saved")
    func failedSaveIsReported() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        var failures: [TurnID] = []
        store.onPersistFailure = { id, _ in failures.append(id) }
        // Pull the table out from under the store: every write now fails.
        try db.writer.write { try $0.execute(sql: "DROP TABLE \(TurnStore.table)") }
        let record = Self.record()
        let first = store.save(record, stage: .held)
        #expect(first.persisted == false, "not claimed before the database confirmed it")
        store.flush()

        #expect(failures == [record.turnID])
        let entry = try #require(store.entry(record.turnID))
        #expect(entry.persisted == false)
        #expect(entry.retentionLabel == TurnStore.sessionOnlyLabel)
    }

    @Test("a successful save flips the row to persisted and says so")
    func persistedAfterWrite() throws {
        let store = TurnStore(database: try AppDatabase.inMemory())
        var seen: [Bool] = []
        store.onChange = { seen.append($0.persisted) }
        let record = Self.record()
        store.save(record, stage: .starting)
        store.flush()
        #expect(seen == [false, true])
        #expect(store.entry(record.turnID)?.persisted == true)
    }

    @Test("remove and removeAll delete rows everywhere")
    func removal() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        let a = Self.record("a", at: 1), b = Self.record("b", at: 2)
        store.save(a, stage: .landed)
        store.save(b, stage: .held)
        store.flush()
        store.remove(a.turnID)
        store.flush()
        #expect(store.entry(a.turnID) == nil)
        #expect(TurnStore(database: db).entry(a.turnID) == nil)
        store.removeAll()
        #expect(store.recent().isEmpty)
        #expect(TurnStore(database: db).recent().isEmpty)
    }

    @Test("settled rows beyond the limit are pruned; held rows never are")
    func pruning() throws {
        let db = try AppDatabase.inMemory()
        let store = TurnStore(database: db)
        store.databaseLimit = 3
        let held = Self.record("held", at: 0)
        store.save(held, stage: .held)
        for i in 1...5 { store.save(Self.record("r\(i)", at: TimeInterval(i)), stage: .landed) }
        store.flush()
        let fresh = TurnStore(database: db)
        let texts = fresh.recent(limit: 10).map(\.record.finalText)
        #expect(texts == ["r5", "r4", "r3", "held"])
    }

    @Test("the settings: dwell defaults to 900 ms, low confidence extends to 1800, persistence defaults on")
    func settings() {
        let store = InMemorySettingsStore()
        #expect(TurnSettings.previewDwell(store) == .standard)
        #expect(PreviewDwell.standard.seconds(lowConfidence: false) == 0.9)
        #expect(PreviewDwell.standard.seconds(lowConfidence: true) == 1.8)
        #expect(PreviewDwell.short.seconds(lowConfidence: true) == 1.8)
        #expect(PreviewDwell.long.seconds(lowConfidence: false) == 1.5)
        #expect(PreviewDwell.manual.seconds(lowConfidence: true) == nil)
        TurnSettings.setPreviewDwell(.manual, store: store)
        #expect(TurnSettings.previewDwell(store) == .manual)
        store.set("bogus", for: SettingsKeys.previewDwell)
        #expect(TurnSettings.previewDwell(store) == .standard)
        #expect(TurnSettings.persistsRecovery(store))
        TurnSettings.setPersistsRecovery(false, store: store)
        #expect(!TurnSettings.persistsRecovery(store))
    }
}
