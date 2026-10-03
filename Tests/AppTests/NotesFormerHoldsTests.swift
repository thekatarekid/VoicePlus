import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// H23 (store side) + H27 — the held queue is retired: every former hold goes to Notes with the
/// intended app and reason; a password field keeps nothing anywhere; Escape after words → Notes
/// (Q6); a failed Notes save keeps the words in history with Copy; stale held rows settle.
@Suite("H23 former holds → Notes")
struct NotesFormerHoldsTests {
    final class Sink: @unchecked Sendable {
        var saved: [(text: String, app: String?, reason: NoteReason)] = []
        var fails = false
        func save(_ text: String, _ app: String?, _ reason: NoteReason) -> Result<String, NotesFunnelError> {
            if fails { return .failure(.writeFailed("disk")) }
            saved.append((text, app, reason))
            return .success("note-\(saved.count)")
        }
    }

    static func record(_ text: String, reason: String?, app: String = "Claude") -> TurnRecord {
        var r = TurnRecord(turnID: TurnID(), startedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
                           destination: .init(bundleID: "com.anthropic.claude", appName: app),
                           rawText: text, finalText: text)
        r.outcome = reason.map { .held(reason: $0) }
        return r
    }

    static func wired(_ sink: Sink, database: AppDatabase? = nil) -> (TurnStore, FocusGuard) {
        let store = TurnStore(database: database)
        let guard_ = FocusGuard(system: MockSystemAccess())
        NotesWiring.routeFormerHolds(turns: store, focusGuard: guard_, save: sink.save)
        return (store, guard_)
    }

    @Test("held reasons map to the §2 Notes reasons; a password field maps to nothing")
    func reasonMapping() {
        #expect(NoteReason.forHeld(reason: DeliveryReason.destinationChanged) == .couldNotReturn)
        #expect(NoteReason.forHeld(reason: DeliveryLadder.Reason.windowGone.rawValue) == .windowClosed)
        #expect(NoteReason.forHeld(reason: DeliveryLadder.Reason.notEditable.rawValue) == .noTextField)
        #expect(NoteReason.forHeld(reason: DeliveryReason.noDestination) == .noTextField)
        #expect(NoteReason.forHeld(reason: DeliveryReason.neverInject) == .neverInject)
        #expect(NoteReason.forHeld(reason: nil) == .couldNotReturn)
        #expect(NoteReason.forHeld(reason: DeliveryReason.secureField) == nil)
        #expect(NoteReason.forHeld(reason: DeliveryLadder.Reason.passwordField.rawValue) == nil)
    }

    @Test("every FocusGuard hold goes to Notes, not the held queue; the turn records Saved to Notes")
    func focusGuardHoldToNotes() throws {
        let sink = Sink()
        let (store, guard_) = Self.wired(sink)
        let record = Self.record("ship it", reason: nil)
        store.save(record, stage: .inserting)
        var noted: [HeldText] = []
        guard_.onSavedToNotes = { noted.append($0) }
        var heldEvents = 0
        guard_.onHeld = { _ in heldEvents += 1 }
        let focus = FocusSnapshot(pid: 7, bundleID: "com.anthropic.claude", appName: "Claude")
        guard_.hold(InjectionRequest(text: "ship it", expectedFocus: focus), reason: DeliveryReason.destinationChanged,
                    turnID: record.turnID)
        #expect(guard_.held.isEmpty)
        #expect(heldEvents == 0)
        #expect(noted.count == 1)
        #expect(sink.saved.map(\.text) == ["ship it"])
        #expect(sink.saved.first?.app == "Claude")
        #expect(sink.saved.first?.reason == .couldNotReturn)
        // The turn controller then records the hold: it settles, never `.held`, and is not saved twice.
        var held = record
        held.outcome = .held(reason: DeliveryReason.destinationChanged)
        let entry = store.save(held, stage: .held)
        #expect(entry.stage == .resolved)
        #expect(entry.turnOutcome == .savedToNotes(intendedApp: "Claude", reason: .couldNotReturn))
        #expect(entry.turnOutcome.text == "Saved to Notes · couldn’t return to Claude")
        #expect(sink.saved.count == 1)
        #expect(store.recoverable().isEmpty)
    }

    @Test("a password field keeps nothing: not held, not in Notes, words cleared from the record")
    func secureKeepsNothing() throws {
        let sink = Sink()
        let (store, guard_) = Self.wired(sink)
        guard_.hold(InjectionRequest(text: "hunter2"), reason: DeliveryReason.secureField)
        #expect(guard_.held.isEmpty)
        // Even without a sink the guard never keeps a secure item.
        let bare = FocusGuard(system: MockSystemAccess())
        bare.hold(InjectionRequest(text: "hunter2"), reason: DeliveryReason.secureField)
        #expect(bare.held.isEmpty)

        var record = Self.record("hunter2", reason: nil)
        record.outcome = .failed(reason: DeliveryReason.secureField)
        let entry = store.save(record, stage: .held)
        #expect(entry.stage == .failed)
        #expect(entry.record.finalText.isEmpty && entry.record.rawText.isEmpty)
        #expect(entry.turnOutcome == .refusedSecure)
        #expect(entry.turnOutcome.text == "Not typed · password field")
        #expect(sink.saved.isEmpty)
        #expect(store.recentDictations().isEmpty)
    }

    @Test("Escape after words → 'Cancelled · Saved to Notes' (Q6); before words → nothing saved")
    func cancelAfterWords() {
        let sink = Sink()
        let (store, _) = Self.wired(sink)
        let words = store.save(Self.record("half a thought", reason: nil), stage: .cancelled)
        #expect(words.stage == .cancelled)
        #expect(words.turnOutcome == .cancelledToNotes(intendedApp: "Claude"))
        #expect(words.turnOutcome.text == "Cancelled · Saved to Notes")
        #expect(sink.saved.map(\.reason) == [.cancelled])
        // A second save of the same cancelled turn does not save it again.
        _ = store.save(words.record, stage: .cancelled)
        #expect(sink.saved.count == 1)
        let empty = store.save(Self.record("", reason: nil), stage: .cancelled)
        #expect(empty.turnOutcome == .cancelled)
        #expect(sink.saved.count == 1)
    }

    @Test("a held turn with no FocusGuard save goes to Notes from the store, with the mapped reason")
    func storeSavesHeldTurn() {
        let sink = Sink()
        let (store, _) = Self.wired(sink)
        let entry = store.save(Self.record("for the doc", reason: DeliveryLadder.Reason.windowGone.rawValue), stage: .held)
        #expect(entry.stage == .resolved)
        #expect(entry.turnOutcome.text == "Saved to Notes · Claude window closed")
        #expect(sink.saved.map(\.reason) == [.windowClosed])
    }

    @Test("a failed Notes save keeps the words in history with Copy, and in the guard's list")
    func failedSave() {
        let sink = Sink()
        sink.fails = true
        let (store, guard_) = Self.wired(sink)
        let record = Self.record("keep me", reason: DeliveryReason.destinationChanged)
        store.save(record, stage: .inserting)
        guard_.hold(InjectionRequest(text: "keep me"), reason: DeliveryReason.destinationChanged, turnID: record.turnID)
        #expect(guard_.held.map(\.text) == ["keep me"])
        let entry = store.save(record, stage: .held)
        #expect(entry.stage == .failed)
        #expect(entry.record.finalText == "keep me")
        #expect(entry.turnOutcome == .notesSaveFailed(intendedApp: "Claude"))
        #expect(entry.turnOutcome.text.hasPrefix("Couldn’t save to Notes") || entry.turnOutcome.text.hasPrefix("Couldn't save to Notes"))
        #expect(store.recentDictations().map(\.text) == ["keep me"])
    }

    @Test("without a sink (headless) the legacy held stage is kept")
    func noSinkLegacy() {
        let store = TurnStore(database: nil)
        #expect(store.save(Self.record("x", reason: DeliveryReason.destinationChanged), stage: .held).stage == .held)
    }

    @Test("H27: stale held rows from an earlier version are cleared on upgrade, not re-noted (duplicate of landed text)")
    func staleHeldRows() throws {
        let db = try AppDatabase.inMemory()
        let old = TurnStore(database: db)
        let legacy = Self.record("left behind", reason: DeliveryReason.destinationChanged)
        old.save(legacy, stage: .held)
        var secret = Self.record("pa55word", reason: nil)
        secret.outcome = .held(reason: DeliveryReason.secureField)
        old.save(secret, stage: .held)
        old.flush()

        // Simulate an earlier version that stored the password row as held, words and all.
        try db.writer.write { db in
            let json = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
            try db.execute(sql: "UPDATE \(TurnStore.table) SET stage = 'held', recordJSON = ? WHERE id = ?",
                           arguments: [json, secret.turnID.rawValue.uuidString])
        }
        let sink = Sink()
        let store = TurnStore(database: db)
        #expect(store.recoverable().count == 2)
        NotesWiring.routeFormerHolds(turns: store, focusGuard: nil, save: sink.save)
        store.flush()
        #expect(store.recoverable().isEmpty)
        #expect(sink.saved.isEmpty, "a stale held row duplicates landed text: no Notes copy")
        #expect(store.entry(legacy.turnID)?.record.finalText == "left behind", "history keeps the words with Copy")
        if case .held = store.entry(legacy.turnID)?.record.outcome { Issue.record("held outcome survived") }
        let reopened = TurnStore(database: db)
        #expect(reopened.recoverable().isEmpty)
        #expect(reopened.entry(secret.turnID)?.record.finalText == "")
        #expect(reopened.entry(legacy.turnID)?.stage == .resolved)
        #expect(reopened.entry(secret.turnID)?.record.rawText == "")
        // Idempotent.
        #expect(store.settleStaleHeldRows() == 0)
    }

    @Test("H27: with history off a stale held row leaves the database entirely")
    func staleHeldRowHistoryOff() throws {
        let db = try AppDatabase.inMemory()
        let old = TurnStore(database: db)
        let legacy = Self.record("already landed", reason: DeliveryReason.destinationChanged)
        old.save(legacy, stage: .held)
        old.flush()
        let store = TurnStore(database: db)
        store.historyEnabled = { false }
        #expect(store.settleStaleHeldRows() == 1)
        store.flush()
        let reopened = TurnStore(database: db)
        #expect(reopened.recoverable().isEmpty)
        #expect(reopened.entry(legacy.turnID) == nil)
    }

    @Test("a real NotesStore receives the intended app and reason")
    func realNotesStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("h23-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = NotesStore(root: root, database: try AppDatabase.inMemory())
        let store = TurnStore(database: nil)
        NotesWiring.routeFormerHolds(turns: store, focusGuard: nil) {
            NotesFunnel.save(text: $0, intendedApp: $1, reason: $2, store: notes)
        }
        _ = store.save(Self.record("into notes", reason: DeliveryReason.neverInject), stage: .held)
        let note = try #require(notes.notes().first)
        #expect(note.intendedApp == "Claude")
        #expect(note.reason == .neverInject)
    }
}
