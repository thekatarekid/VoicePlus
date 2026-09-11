import Foundation
import GRDB
import Testing
@testable import Shared

/// R8.2 — the ambient Timeline's search index, and the migration that added it.
///
/// Two properties matter here. **Deletion really empties it**: the transcript lives on disk and the
/// tokens live in SQLite, so a delete that cleared one and not the other would leave deleted words
/// findable (V3 §8: "expiry clears indexes"). And **the migration is additive**: V3 §1.6 — an install
/// that already has dictation history must keep every row of it.
///
/// The index holds tokens and never the transcript itself: ambient text is not in any table that
/// history export, diagnostics or sync reads.
@Suite("Ambient search index and its migration (R8.2)")
struct AmbientSearchIndexTests {

    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Tokenizing

    @Test("tokens are lowercased words; punctuation is dropped and short words are kept")
    func tokenizing() {
        #expect(AmbientSearchIndex.tokens("The standup is at 10:30, Ravi!")
                == ["the", "standup", "is", "at", "10", "30", "ravi"])
        #expect(AmbientSearchIndex.tokens("I'm fine") == ["i'm", "fine"])
        #expect(AmbientSearchIndex.tokens("") == [])
        #expect(AmbientSearchIndex.tokens("   ") == [])
        // No stopword list on purpose: searching for "the" must find the sentence with "the" in it.
        #expect(AmbientSearchIndex.tokens("the the the") == ["the", "the", "the"])
        #expect(AmbientSearchIndex.uniqueTokens("the the the") == ["the"])
        #expect(AmbientSearchIndex.uniqueTokens("one two one three") == ["one", "two", "three"],
                "unique tokens are not in first-seen order")
    }

    // MARK: Indexing and searching

    @Test("indexing then searching is an AND over tokens, newest first")
    func indexAndSearch() throws {
        let db = try AppDatabase.inMemory()
        try db.indexAmbientEntry(entryID: "a#1", recordID: "a", capturedAt: Self.capturedAt,
                                text: "the standup is at ten")
        try db.indexAmbientEntry(entryID: "a#2", recordID: "a", capturedAt: Self.capturedAt.addingTimeInterval(60),
                                text: "the review is at four")

        #expect(try db.ambientEntryIDs(matchingAll: ["standup"]) == ["a#1"])
        #expect(try db.ambientEntryIDs(matchingAll: ["STANDUP"]) == ["a#1"], "search became case-sensitive")
        #expect(try db.ambientEntryIDs(matchingAll: ["is", "at"]) == ["a#2", "a#1"], "not newest first")
        #expect(try db.ambientEntryIDs(matchingAll: ["standup", "review"]).isEmpty, "the index ORed its tokens")
        #expect(try db.ambientEntryIDs(matchingAll: []).isEmpty)
        #expect(try db.ambientEntryIDs(matchingAll: ["nothinglikethis"]).isEmpty)
        #expect(try db.ambientIndexedEntryIDs() == ["a#1", "a#2"])
    }

    @Test("re-indexing an entry replaces its tokens instead of adding a second set")
    func reindexingReplaces() throws {
        let db = try AppDatabase.inMemory()
        try db.indexAmbientEntry(entryID: "a#1", recordID: "a", capturedAt: Self.capturedAt, text: "the first wording")
        let first = try db.ambientSearchIndexCount()
        try db.indexAmbientEntry(entryID: "a#1", recordID: "a", capturedAt: Self.capturedAt, text: "corrected wording")

        #expect(try db.ambientSearchIndexCount() < first + 3, "the old tokens were left behind")
        #expect(try db.ambientEntryIDs(matchingAll: ["first"]).isEmpty, "a replaced entry is still findable by its old words")
        #expect(try db.ambientEntryIDs(matchingAll: ["corrected"]) == ["a#1"])
    }

    @Test("every delete path really empties the index")
    func everyDeletePathClearsTheIndex() throws {
        let db = try AppDatabase.inMemory()
        try db.indexAmbientEntry(entryID: "a#1", recordID: "a", capturedAt: Self.capturedAt, text: "monday words")
        try db.indexAmbientEntry(entryID: "a#2", recordID: "a", capturedAt: Self.capturedAt, text: "more monday words")
        try db.indexAmbientEntry(entryID: "b#1", recordID: "b", capturedAt: Self.capturedAt.addingTimeInterval(86_400),
                                text: "tuesday words")

        // One entry.
        #expect(try db.deleteAmbientIndex(entryID: "a#1") == 2)
        #expect(try db.ambientIndexedEntryIDs() == ["a#2", "b#1"])
        #expect(try db.ambientEntryIDs(matchingAll: ["monday"]) == ["a#2"])

        // A whole day.
        #expect(try db.deleteAmbientIndex(recordID: "a") > 0)
        #expect(try db.ambientIndexedEntryIDs() == ["b#1"])
        #expect(try db.ambientEntryIDs(matchingAll: ["monday"]).isEmpty)

        // Everything.
        #expect(try db.deleteAllAmbientIndex() > 0)
        #expect(try db.ambientSearchIndexCount() == 0)
        #expect(try db.ambientIndexedEntryIDs().isEmpty)
        // Deleting again is a no-op, not an error.
        #expect(try db.deleteAllAmbientIndex() == 0)
        #expect(try db.deleteAmbientIndex(entryID: "gone") == 0)
    }

    @Test("the retention sweep deletes tokens by age, and leaves newer ones alone")
    func retentionSweepByAge() throws {
        let db = try AppDatabase.inMemory()
        let cutoff = Self.capturedAt
        try db.indexAmbientEntry(entryID: "old#1", recordID: "old", capturedAt: cutoff.addingTimeInterval(-3600),
                                text: "expired words")
        try db.indexAmbientEntry(entryID: "new#1", recordID: "new", capturedAt: cutoff.addingTimeInterval(3600),
                                text: "surviving words")

        #expect(try db.deleteAmbientIndex(before: cutoff) == 2)
        #expect(try db.ambientIndexedEntryIDs() == ["new#1"])
        #expect(try db.ambientEntryIDs(matchingAll: ["expired"]).isEmpty)
        #expect(try db.ambientEntryIDs(matchingAll: ["surviving"]) == ["new#1"])
    }

    // MARK: The migration (V3 §1.6 — an upgrade must not lose data)

    @Test("v2 adds only the ambient index, and every existing row survives the upgrade")
    func migrationIsAdditiveAndPreservesData() throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        // An install from before R8.2: only the v1 schema exists.
        try AppDatabase.migrator.migrate(queue, upTo: "v1_phase1_core")
        #expect(try queue.read { try AppDatabase.migrator.appliedIdentifiers($0) } == ["v1_phase1_core"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dictation_history
                    (id, startedAt, register, route, rawText, finalText, spansJSON, edited)
                VALUES ('kept-1', ?, 'chat', 'dictate', 'raw', 'text the user already had', '[]', 0)
                """, arguments: [Self.capturedAt])
            try db.execute(sql: """
                INSERT INTO dictionary (id, term, spokenForms, weight, createdAt)
                VALUES ('d1', 'Kothari', '', 1.0, ?)
                """, arguments: [Self.capturedAt])
        }
        let tablesBefore = try queue.read { try Self.tables($0) }
        #expect(!tablesBefore.contains("ambient_search_index"))

        // Upgrading is what `AppDatabase.init` does on every launch.
        let db = try AppDatabase(writer: queue)

        #expect(try db.reader.read { try AppDatabase.migrator.appliedIdentifiers($0) }
                == Set(AppDatabase.migrationIdentifiers))
        let tablesAfter = try db.reader.read { try Self.tables($0) }
        #expect(Set(tablesAfter).subtracting(tablesBefore) == ["ambient_search_index"],
                "the ambient migration added or removed something else: \(tablesAfter)")

        // The user's data is still there, unchanged.
        let kept = try db.reader.read { try String.fetchAll($0, sql: "SELECT finalText FROM dictation_history") }
        #expect(kept == ["text the user already had"], "the upgrade lost dictation history")
        let terms = try db.reader.read { try String.fetchAll($0, sql: "SELECT term FROM dictionary") }
        #expect(terms == ["Kothari"], "the upgrade lost the user's dictionary")

        // And the new table works.
        try db.indexAmbientEntry(entryID: "a#1", recordID: "a", capturedAt: Self.capturedAt, text: "after the upgrade")
        #expect(try db.ambientEntryIDs(matchingAll: ["upgrade"]) == ["a#1"])

        // Re-opening an already-migrated database is a no-op that loses nothing either.
        let again = try AppDatabase(writer: queue)
        #expect(try again.ambientEntryIDs(matchingAll: ["upgrade"]) == ["a#1"])
        #expect(try again.reader.read { try String.fetchAll($0, sql: "SELECT finalText FROM dictation_history") }
                == ["text the user already had"])
    }

    @Test("the ambient table holds tokens and their ids, and no transcript column")
    func theIndexHoldsNoTranscript() throws {
        let db = try AppDatabase.inMemory()
        let columns = try db.reader.read { d -> [String] in
            try Row.fetchAll(d, sql: "PRAGMA table_info(ambient_search_index)").compactMap { $0["name"] as String? }
        }
        #expect(Set(columns) == ["id", "entryID", "recordID", "capturedAt", "token"])
        #expect(!columns.contains { $0.lowercased().contains("text") },
                "ambient transcript text was given a column in SQLite")
        #expect(!columns.contains { $0.lowercased().contains("audio") })
    }

    static func tables(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%' ORDER BY name
            """)
    }
}
