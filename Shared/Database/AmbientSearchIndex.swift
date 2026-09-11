import Foundation
import GRDB

// R8.2 — the ambient Timeline's search index, and the only ambient data this database holds.
//
// Ambient *transcript* text is not stored here. It lives in the local meeting store (JSON +
// Markdown on disk, reused per the R8 build item) so ambient content never enters a table that
// history export, diagnostics or sync read. What lives here is a token index: one row per
// (entry, word), which is what makes "search the Timeline" fast.
//
// Tokens are still the user's words. That is exactly why V3 §8 says expiry and deletion must clear
// the index and not only the rows: a deleted entry whose tokens survived would still be findable,
// and a 7-day retention promise would be a promise about one of two stores. Every delete path in
// `AmbientTranscriptStore` clears both, the row table's tokens are deleted in the same transaction
// as the sweep, and `ambientSearchIndexCount()` exists so a test can prove the index is empty.

/// One indexed word of one Timeline entry.
public struct AmbientSearchTokenRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "ambient_search_index"

    public var id: Int64?
    /// Stable id of the Timeline entry the token came from (`<recordID>#<offsetMilliseconds>`).
    public var entryID: String
    /// The ambient record (one per day) the entry belongs to, so a whole day clears in one delete.
    public var recordID: String
    /// When the entry was spoken — the column retention sweeps on.
    public var capturedAt: Date
    public var token: String

    public init(id: Int64? = nil, entryID: String, recordID: String, capturedAt: Date, token: String) {
        self.id = id
        self.entryID = entryID
        self.recordID = recordID
        self.capturedAt = capturedAt
        self.token = token
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Tokenizing, in one place, so what is indexed and what is searched can never drift apart.
public enum AmbientSearchIndex {
    /// Lowercased word tokens, punctuation dropped, one-character tokens kept (initials, "I").
    /// Deliberately dumb: no stemming, no stopword list — a Timeline search for "the" should find
    /// the sentence with "the" in it rather than silently returning nothing.
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    /// Distinct tokens, in first-seen order.
    public static func uniqueTokens(_ text: String) -> [String] {
        var seen = Set<String>()
        return tokens(text).filter { seen.insert($0).inserted }
    }
}

public extension AppDatabase {
    /// Index one Timeline entry. Replaces any tokens already held for that entry, so re-indexing an
    /// edited entry cannot leave the old words behind.
    func indexAmbientEntry(entryID: String, recordID: String, capturedAt: Date, text: String) throws {
        let tokens = AmbientSearchIndex.uniqueTokens(text)
        try writer.write { db in
            try db.execute(sql: "DELETE FROM ambient_search_index WHERE entryID = ?", arguments: [entryID])
            for token in tokens {
                var row = AmbientSearchTokenRecord(entryID: entryID, recordID: recordID,
                                                  capturedAt: capturedAt, token: token)
                try row.insert(db)
            }
        }
    }

    /// Entry ids holding **every** token (AND search), newest first.
    func ambientEntryIDs(matchingAll tokens: [String]) throws -> [String] {
        let wanted = Array(Set(tokens.map { $0.lowercased() }))
        guard !wanted.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: wanted.count)
        return try reader.read { db in
            try String.fetchAll(db, sql: """
                SELECT entryID FROM ambient_search_index
                WHERE token IN (\(placeholders))
                GROUP BY entryID
                HAVING COUNT(DISTINCT token) = ?
                ORDER BY MAX(capturedAt) DESC
                """, arguments: StatementArguments(wanted) + [wanted.count])
        }
    }

    /// Every entry id the index knows about — the "did deletion really clear it?" read.
    func ambientIndexedEntryIDs() throws -> [String] {
        try reader.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT entryID FROM ambient_search_index ORDER BY entryID")
        }
    }

    func ambientSearchIndexCount() throws -> Int {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ambient_search_index") ?? 0
        }
    }

    @discardableResult
    func deleteAmbientIndex(entryID: String) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM ambient_search_index WHERE entryID = ?", arguments: [entryID])
            return db.changesCount
        }
    }

    @discardableResult
    func deleteAmbientIndex(recordID: String) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM ambient_search_index WHERE recordID = ?", arguments: [recordID])
            return db.changesCount
        }
    }

    /// Retention's own sweep: tokens for anything spoken before `cutoff`. Runs even when the entry
    /// it belonged to is already gone, so an interrupted delete cannot orphan searchable words.
    @discardableResult
    func deleteAmbientIndex(before cutoff: Date) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM ambient_search_index WHERE capturedAt < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    @discardableResult
    func deleteAllAmbientIndex() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM ambient_search_index")
            return db.changesCount
        }
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
