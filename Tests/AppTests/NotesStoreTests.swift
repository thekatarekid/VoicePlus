import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 N4 — one store for Notes and the ambient Timeline: migration, retention, and the search index
/// cleared on every delete.
@Suite("Notes store (V5 N4)")
struct NotesStoreTests {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    struct Rig {
        let store: NotesStore
        let database: AppDatabase
        let root: URL
        let now: Date

        init(noteDays: Int? = 30, ambientDays: Int = 7, now: Date = NotesStoreTests.now) throws {
            self.now = now
            root = FileManager.default.temporaryDirectory.appendingPathComponent("n4-\(UUID().uuidString)", isDirectory: true)
            database = try AppDatabase.inMemory()
            store = NotesStore(root: root, database: database,
                               retention: { NotesRetentionPolicy(days: noteDays) },
                               ambientRetention: { AmbientRetentionPolicy(days: ambientDays) },
                               clock: { now })
        }

        @discardableResult
        func note(_ text: String, _ source: NoteSource = .latch, daysAgo: Double = 0) throws -> String {
            try #require(try store.add(text, source: source, at: now.addingTimeInterval(-daysAgo * 86_400)))
        }

        var indexed: Set<String> { Set((try? database.ambientIndexedEntryIDs()) ?? []) }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static func tempDir(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("n4-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: One store

    @Test("the ambient store's default root is the Notes root")
    func oneRoot() {
        #expect(AmbientTranscriptStore.defaultRoot().lastPathComponent == "Notes")
        #expect(NotesStore.defaultRoot().lastPathComponent == "Notes")
        #expect(NotesStore.legacyAmbientRoot().lastPathComponent == "Ambient")
    }

    @Test("notes and ambient entries share one directory and one list; the Timeline still sees only ambient")
    func sharedDirectory() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.note("call the dentist", .wakeVerb)
        try rig.store.add("overheard bit", source: .ambient, at: rig.now.addingTimeInterval(-60))
        let all = rig.store.entries()
        #expect(all.count == 2)
        #expect(Set(all.map(\.source)) == [.wakeVerb, .ambient])
        #expect(rig.store.notes().map(\.text) == ["call the dentist"])
        #expect(rig.store.ambient.entries().map(\.text) == ["overheard bit"])
        let dirs = try FileManager.default.contentsOfDirectory(atPath: rig.root.path)
        #expect(dirs.contains { $0.hasPrefix("notes-") } && dirs.contains { $0.hasPrefix("ambient-") })
        // Same MeetingRecord shape on disk, source in the labeler.
        let record = try #require(rig.store.meetings.list().first { $0.id.hasPrefix("notes-") })
        #expect(record.labeler == "note:wake-verb")
    }

    @Test("empty text is not a note")
    func emptyIsNotANote() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        #expect(try rig.store.add("   ", source: .latch) == nil)
        #expect(rig.store.entries().isEmpty)
    }

    // MARK: Migration

    @Test("first launch moves …/Ambient days into …/Notes and removes the legacy directory")
    func migrationMoves() throws {
        let legacy = Self.tempDir("legacy"), root = Self.tempDir("notes")
        defer { try? FileManager.default.removeItem(at: legacy); try? FileManager.default.removeItem(at: root) }
        let db = try AppDatabase.inMemory()
        let old = AmbientTranscriptStore(meetings: MeetingStore(root: legacy), database: db, clock: { Self.now })
        let id = try old.store(AmbientEntry(speaker: .you, text: "legacy words", capturedAt: Self.now))

        let result = NotesStore.migrateLegacyAmbient(from: legacy, to: root)
        #expect(result.moved == 1 && result.merged == 0 && result.removedLegacyRoot)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        let store = NotesStore(root: root, database: db, clock: { Self.now })
        #expect(store.entries().map(\.id) == [id])
        // Ids did not change, so the old index rows still find it.
        #expect(store.entries(matching: "legacy").map(\.id) == [id])

        // Idempotent.
        #expect(NotesStore.migrateLegacyAmbient(from: legacy, to: root) == NotesMigrationResult())
    }

    @Test("a day present in both roots is merged, not overwritten")
    func migrationMerges() throws {
        let legacy = Self.tempDir("legacy"), root = Self.tempDir("notes")
        defer { try? FileManager.default.removeItem(at: legacy); try? FileManager.default.removeItem(at: root) }
        let old = AmbientTranscriptStore(meetings: MeetingStore(root: legacy), database: nil, clock: { Self.now })
        let new = AmbientTranscriptStore(meetings: MeetingStore(root: root), database: nil, clock: { Self.now })
        try old.store(AmbientEntry(speaker: .you, text: "morning", capturedAt: Self.now.addingTimeInterval(-120)))
        try new.store(AmbientEntry(speaker: .you, text: "afternoon", capturedAt: Self.now))

        let result = NotesStore.migrateLegacyAmbient(from: legacy, to: root)
        #expect(result.merged == 1 && result.moved == 0 && result.removedLegacyRoot)
        #expect(Set(new.entries().map(\.text)) == ["morning", "afternoon"])
    }

    @Test("no legacy directory: nothing to do")
    func migrationNoop() {
        let result = NotesStore.migrateLegacyAmbient(from: Self.tempDir("absent"), to: Self.tempDir("notes"))
        #expect(result == NotesMigrationResult())
    }

    // MARK: Retention

    @Test("notes expire on the notes window, ambient on its own; index rows go with them")
    func retention() throws {
        let rig = try Rig(noteDays: 30, ambientDays: 7); defer { rig.cleanUp() }
        let fresh = try rig.note("fresh note", daysAgo: 1)
        let old = try rig.note("stale note", daysAgo: 31)
        let tenDayNote = try rig.note("ten day note", daysAgo: 10)
        let ambientOld = try #require(try rig.store.add("old ambient", source: .ambient, at: rig.now.addingTimeInterval(-8 * 86_400)))
        #expect(rig.indexed.isSuperset(of: [fresh, old, tenDayNote, ambientOld]))

        let result = try rig.store.sweepExpired(now: rig.now)
        #expect(result.entriesDeleted == 2)
        #expect(Set(rig.store.entries().map(\.id)) == [fresh, tenDayNote])
        #expect(!rig.indexed.contains(old) && !rig.indexed.contains(ambientOld))
        // A note older than the ambient window is still findable even though the ambient backstop
        // cleared index rows by date.
        #expect(rig.store.entries(matching: "ten day").map(\.id) == [tenDayNote])
    }

    @Test("forever keeps notes; the setting round-trips")
    func retentionForever() throws {
        let rig = try Rig(noteDays: nil); defer { rig.cleanUp() }
        try rig.note("keep me", daysAgo: 400)
        try rig.store.sweepExpired(now: rig.now)
        #expect(rig.store.notes().count == 1)

        let settings = InMemorySettingsStore()
        #expect(NotesRetentionPolicy.fromSettings(settings).days == 30)
        NotesRetentionPolicy.save(NotesRetentionPolicy(days: nil), to: settings)
        #expect(NotesRetentionPolicy.fromSettings(settings).days == nil)
        NotesRetentionPolicy.save(NotesRetentionPolicy(days: 90), to: settings)
        #expect(NotesRetentionPolicy.fromSettings(settings).days == 90)
        settings.set("garbage", for: NotesRetentionPolicy.key)
        #expect(NotesRetentionPolicy.fromSettings(settings).days == 30)
    }

    // MARK: Delete clears the index

    @Test("deleting a note removes it from disk and from the search index")
    func deleteClearsIndex() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let a = try rig.note("buy oat milk")
        let b = try rig.note("buy bread", daysAgo: 0.01)
        #expect(Set(rig.store.entries(matching: "buy").map(\.id)) == [a, b])
        try rig.store.delete(id: a)
        #expect(!rig.indexed.contains(a))
        #expect(rig.indexed.contains(b))
        #expect(rig.store.entries(matching: "oat").isEmpty)
        try rig.store.delete(id: b)
        #expect(rig.indexed.isEmpty)
        #expect(rig.store.notes().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.root.path).filter { $0.hasPrefix("notes-") }.isEmpty)
    }

    @Test("deleting an ambient row through Notes clears its index row too; delete-all notes leaves ambient")
    func deleteAmbientAndAll() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let amb = try #require(try rig.store.add("ambient thing", source: .ambient, at: rig.now))
        let n = try rig.note("note thing", .noField, daysAgo: 0.001)
        try rig.store.deleteAllNotes()
        #expect(!rig.indexed.contains(n))
        #expect(rig.store.entries().map(\.id) == [amb])
        try rig.store.delete(id: amb)
        #expect(rig.indexed.isEmpty)
        #expect(rig.store.entries().isEmpty)
    }

    // MARK: Search, unread, export

    @Test("search is token AND over the Timeline tokenizer")
    func search() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        let a = try rig.note("Email Priya about the launch")
        try rig.note("launch checklist", daysAgo: 0.01)
        #expect(rig.store.entries(matching: "priya launch").map(\.id) == [a])
        #expect(rig.store.entries(matching: "  ").count == 2)
    }

    @Test("unread counts notes after last seen; ambient rows never count")
    func unread() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.note("one", daysAgo: 2)
        try rig.note("two", daysAgo: 0.1)
        try rig.store.add("ambient", source: .ambient, at: rig.now)
        #expect(rig.store.unreadCount(since: nil) == 2)
        #expect(rig.store.unreadCount(since: rig.now.addingTimeInterval(-86_400)) == 1)
        let settings = InMemorySettingsStore()
        #expect(NotesStore.lastSeen(settings) == nil)
        NotesStore.markSeen(settings, at: rig.now)
        #expect(NotesStore.lastSeen(settings) == rig.now)
        #expect(rig.store.unreadCount(since: NotesStore.lastSeen(settings)) == 0)
    }

    @Test("Markdown export groups by day, oldest first within a day, with the source tag")
    func markdown() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        try rig.note("second", .wakeVerb, daysAgo: 0)
        try rig.note("first", .noField, daysAgo: 0.01)
        let md = NotesStore.markdown(rig.store.entries())
        #expect(md.hasPrefix("# Notes\n"))
        #expect(md.contains("## "))
        let first = try #require(md.range(of: "No field — first"))
        let second = try #require(md.range(of: "“Note …” — second"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test("every add and delete posts didChange")
    func notifies() throws {
        let rig = try Rig(); defer { rig.cleanUp() }
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: NotesStore.didChange, object: rig.store, queue: nil) { _ in counter.n += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let id = try rig.note("x")
        try rig.store.delete(id: id)
        #expect(counter.n == 2)
    }
}
