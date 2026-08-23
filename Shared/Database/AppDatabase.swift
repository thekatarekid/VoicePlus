import Foundation
import GRDB

/// SQLite (WAL) via GRDB. One instance per process; tests use `AppDatabase.inMemory()`.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) ~/Library/Application Support/VoicePlus/voiceplus.sqlite.
    public static func open(at url: URL = AppPaths.databaseURL()) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.journalMode = .wal
        config.foreignKeysEnabled = true
        config.label = "VoicePlus"
        let pool = try DatabasePool(path: url.path, configuration: config)
        Log.db.info("opened database at \(url.path)")
        return try AppDatabase(writer: pool)
    }

    public static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(writer: try DatabaseQueue(configuration: config))
    }

    public var reader: any DatabaseReader { writer }

    // MARK: Migrations

    public static let migrationIdentifiers: [String] = ["v1_phase1_core"]

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = false
        #endif

        migrator.registerMigration("v1_phase1_core") { db in
            try db.create(table: "dictation_history") { t in
                t.column("id", .text).primaryKey()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("endedAt", .datetime)
                t.column("register", .text).notNull()
                t.column("route", .text).notNull()
                t.column("appBundleID", .text)
                t.column("rawText", .text).notNull()
                t.column("finalText", .text).notNull()
                t.column("spansJSON", .text).notNull()
                t.column("edited", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "corrections") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("utteranceID", .text).notNull().references("dictation_history", onDelete: .cascade).indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("original", .text).notNull()
                t.column("corrected", .text).notNull()
                t.column("audioStart", .double).notNull()
                t.column("audioEnd", .double).notNull()
                t.column("source", .text).notNull()
            }
            try db.create(table: "feature_flags") { t in
                t.column("id", .text).primaryKey()
                t.column("enabled", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "lab_runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("finishedAt", .datetime)
                t.column("name", .text).notNull()
                t.column("configJSON", .text).notNull()
                t.column("metricsJSON", .text).notNull()
                t.column("hardware", .text).notNull()
            }
            try db.create(table: "network_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("stage", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("host", .text).notNull()
                t.column("bytesOut", .integer).notNull()
                t.column("bytesIn", .integer).notNull()
                t.column("purpose", .text).notNull()
            }
            try db.create(table: "injection_outcomes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull().indexed()
                t.column("utteranceID", .text)
                t.column("appBundleID", .text).notNull()
                t.column("method", .text).notNull()
                t.column("succeeded", .boolean).notNull()
                t.column("latencyMs", .integer).notNull()
                t.column("detail", .text)
            }
            try db.create(table: "snippets") { t in
                t.column("id", .text).primaryKey()
                t.column("trigger", .text).notNull().unique()
                t.column("body", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "personas") { t in
                t.column("id", .text).primaryKey()
                t.column("appBundleID", .text).notNull().unique()
                t.column("instructions", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "dictionary") { t in
                t.column("id", .text).primaryKey()
                t.column("term", .text).notNull().unique()
                t.column("spokenForms", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1.0)
                t.column("createdAt", .datetime).notNull()
            }
        }
        return migrator
    }
}
