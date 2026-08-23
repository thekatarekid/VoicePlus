import Foundation
import GRDB

// Basic insert/fetch helpers. Modules add richer queries in their own targets via `writer`/`reader`.

public extension AppDatabase {
    // MARK: Dictation history

    func insert(_ record: DictationRecord) throws {
        try writer.write { try record.insert($0) }
    }

    func recentDictations(limit: Int = 50) throws -> [DictationRecord] {
        try reader.read {
            try DictationRecord.order(Column("startedAt").desc).limit(limit).fetchAll($0)
        }
    }

    func dictation(id: String) throws -> DictationRecord? {
        try reader.read { try DictationRecord.fetchOne($0, key: id) }
    }

    // MARK: Corrections

    @discardableResult
    func insert(_ record: CorrectionRecord) throws -> CorrectionRecord {
        var copy = record
        try writer.write { try copy.insert($0) }
        return copy
    }

    func corrections(forUtterance id: String) throws -> [CorrectionRecord] {
        try reader.read {
            try CorrectionRecord.filter(Column("utteranceID") == id).order(Column("createdAt")).fetchAll($0)
        }
    }

    // MARK: Feature flags (DB mirror; the source of truth is FeatureFlagService's JSON)

    func upsert(_ record: FeatureFlagRecord) throws {
        try writer.write { try record.save($0) }
    }

    func featureFlags() throws -> [FeatureFlagRecord] {
        try reader.read { try FeatureFlagRecord.order(Column("id")).fetchAll($0) }
    }

    // MARK: Lab runs

    @discardableResult
    func insert(_ record: LabRunRecord) throws -> LabRunRecord {
        var copy = record
        try writer.write { try copy.insert($0) }
        return copy
    }

    func labRuns(limit: Int = 50) throws -> [LabRunRecord] {
        try reader.read { try LabRunRecord.order(Column("startedAt").desc).limit(limit).fetchAll($0) }
    }

    // MARK: Network log

    @discardableResult
    func insert(_ record: NetworkLogRecord) throws -> NetworkLogRecord {
        var copy = record
        try writer.write { try copy.insert($0) }
        Log.network.notice("\(record.bytesOut)B -> \(record.host) [\(record.stage)/\(record.provider)] \(record.purpose)")
        return copy
    }

    func networkLog(since: Date? = nil, limit: Int = 500) throws -> [NetworkLogRecord] {
        try reader.read { db in
            var request = NetworkLogRecord.order(Column("timestamp").desc).limit(limit)
            if let since { request = request.filter(Column("timestamp") >= since) }
            return try request.fetchAll(db)
        }
    }

    /// Total bytes out since `since` — the Data Panel headline number.
    func bytesEgressed(since: Date) throws -> Int {
        try reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(bytesOut), 0) FROM network_log WHERE timestamp >= ?", arguments: [since]) ?? 0
        }
    }

    // MARK: Injection outcomes

    @discardableResult
    func insert(_ record: InjectionOutcomeRecord) throws -> InjectionOutcomeRecord {
        var copy = record
        try writer.write { try copy.insert($0) }
        return copy
    }

    func injectionOutcomes(appBundleID: String? = nil, limit: Int = 200) throws -> [InjectionOutcomeRecord] {
        try reader.read { db in
            var request = InjectionOutcomeRecord.order(Column("timestamp").desc).limit(limit)
            if let appBundleID { request = request.filter(Column("appBundleID") == appBundleID) }
            return try request.fetchAll(db)
        }
    }

    // MARK: Snippets / personas / dictionary

    func save(_ record: SnippetRecord) throws { try writer.write { try record.save($0) } }
    func snippets() throws -> [SnippetRecord] {
        try reader.read { try SnippetRecord.order(Column("trigger")).fetchAll($0) }
    }

    func save(_ record: PersonaRecord) throws { try writer.write { try record.save($0) } }
    func persona(forApp bundleID: String) throws -> PersonaRecord? {
        try reader.read { try PersonaRecord.filter(Column("appBundleID") == bundleID).fetchOne($0) }
    }

    func save(_ record: DictionaryRecord) throws { try writer.write { try record.save($0) } }
    func dictionaryTerms() throws -> [DictionaryRecord] {
        try reader.read { try DictionaryRecord.order(Column("term")).fetchAll($0) }
    }
    func deleteDictionaryTerm(id: String) throws {
        _ = try writer.write { try DictionaryRecord.deleteOne($0, key: id) }
    }
}
