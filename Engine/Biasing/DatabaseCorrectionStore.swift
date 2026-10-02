import Foundation
import Shared
import GRDB

/// `CorrectionStore` over the app's SQLite (CorrectionRecord + DictionaryRecord).
public struct DatabaseCorrectionStore: CorrectionStore {
    public let database: AppDatabase
    public var limit: Int
    public init(database: AppDatabase, limit: Int = 2_000) {
        self.database = database
        self.limit = limit
    }

    public func correctedTerms() throws -> [(term: String, at: Date)] {
        try database.reader.read { db in
            try CorrectionRecord.order(Column("createdAt").desc).limit(limit).fetchAll(db)
                .map { (term: $0.corrected, at: $0.createdAt) }
        }
    }

    public func dictionaryTerms() throws -> [(term: String, weight: Double)] {
        try database.dictionaryTerms().map { (term: $0.term, weight: $0.weight) }
    }

    public func dictionaryEntries() throws -> [DictionaryEntry] {
        try DictionaryOrigins.entries(database)
    }
}
