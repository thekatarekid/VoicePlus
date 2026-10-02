import Foundation
import GRDB
import Shared

// S11 — the turn record store (build doc S3 + S11 store, design_v1 §12).
//
// One `TurnRecord` per turn: written at the key-down snapshot, updated at every transition
// (`TurnController`). Today (S7b) reads it — held and recoverable turns first, then the
// chronological rows (time · destination · excerpt · Inserted / Held / Unconfirmed / "1 to review").
//
// Recovery persistence is its own switch, independent of dictation history (design §8.1, §12):
// with it on (the default) rows go to the app database and survive a relaunch until resolved; with
// it off, or with no database, or after a write that failed, they live in memory for this session
// only and every surface says so ("Kept for this session only"). A row never claims to be saved
// when the save did not happen (design §13 scenario 14).

/// Where one turn is. Persisted next to the record: `TurnRecord.outcome` alone cannot tell a
/// cancelled turn from one still in flight (both have no outcome), and Today needs both.
public enum TurnStage: String, Codable, CaseIterable, Sendable {
    /// C0 — key down; capture not open yet.
    case starting
    /// C1 — capture open.
    case listening
    /// C2 — capture open, VAD idle longer than `PillState.quietAfter`.
    case listeningQuiet
    /// F0 — microphone closed; final pass and formatting running. Nothing written.
    case finishing
    /// F1 / F2 — the immutable final payload is on screen, dwelling. Nothing written.
    case finalPreview
    /// D0 — the one insertion attempt is in flight.
    case inserting
    /// D1 / D2 / D3 — a write happened: verified, unverified or partial (`record.outcome`).
    case landed
    /// H0 — final text with no safe destination; waits for Insert here / Copy / Discard.
    case held
    /// Held text the user copied or discarded, or an insertion the user undid (R2). Nothing
    /// further happens.
    case resolved
    /// Nothing written and nothing kept (the stop failed, every method threw, a secure field).
    case failed
    /// C4 — Escape or Cancel before any write. Nothing inserted.
    case cancelled
    /// A06 — no speech, or nothing to insert.
    case empty
    /// A command took the words (a spoken repair, a transform, the act domain): nothing typed.
    case consumed

    /// Still moving on its own.
    public var isLive: Bool {
        switch self {
        case .starting, .listening, .listeningQuiet, .finishing, .finalPreview, .inserting: return true
        default: return false
        }
    }

    /// Waiting for the user.
    public var needsUser: Bool { self == .held }

    /// Before any write was dispatched: Escape here cancels (design §5).
    public var isBeforeWrite: Bool {
        switch self {
        case .starting, .listening, .listeningQuiet, .finishing, .finalPreview: return true
        default: return false
        }
    }

    /// Microphone still open for this turn.
    public var isCapturing: Bool {
        switch self {
        case .starting, .listening, .listeningQuiet: return true
        default: return false
        }
    }
}

/// One row of the store: the record, its stage, and whether it is really on disk.
public struct TurnEntry: Equatable, Sendable, Identifiable {
    public var record: TurnRecord
    public var stage: TurnStage
    public var updatedAt: Date
    /// `true` only once the row was written to the database. `false` = session only: persistence
    /// is off, there is no database, or the write failed.
    public var persisted: Bool
    /// T-schema — what other lanes set beside the record (`TurnStore.setExtras`). Explicit values
    /// only; `resolvedExtras` completes them from the record.
    public var extras: TurnRecordExtras

    public init(record: TurnRecord, stage: TurnStage, updatedAt: Date, persisted: Bool,
                extras: TurnRecordExtras = TurnRecordExtras()) {
        self.record = record
        self.stage = stage
        self.updatedAt = updatedAt
        self.persisted = persisted
        self.extras = extras
    }

    /// The values `turn_records`' readable columns hold for this turn.
    public var resolvedExtras: TurnRecordExtras { extras.resolved(for: record) }

    public var id: TurnID { record.turnID }

    /// Held text or a write that may have gone only part of the way: shown first in Today.
    public var isRecoverable: Bool { stage == .held || record.outcome?.isPartial == true }

    /// "Inserted" / "Held" / "Unconfirmed" / "1 to review" — the evidence a Today row carries.
    public var evidence: TurnEvidence {
        switch stage {
        case .held: return .held
        case .landed:
            guard let outcome = record.outcome else { return .inserted }
            if outcome.isPartial { return .partial }
            if !outcome.isVerified { return .unconfirmed }
            return record.hasUncertainty ? .toReview(record.uncertainSpans.count) : .inserted
        case .cancelled: return .cancelled
        case .empty: return .nothingHeard
        case .failed: return .notInserted
        case .resolved: return .resolved
        case .consumed: return .command
        case .starting, .listening, .listeningQuiet, .finishing, .finalPreview, .inserting: return .inProgress
        }
    }

    /// What the row may say about keeping this text (design §8.1).
    public var retentionLabel: String { persisted ? TurnStore.keptUntilResolvedLabel : TurnStore.sessionOnlyLabel }
}

/// The delivery evidence of one turn, in Today's vocabulary.
public enum TurnEvidence: Equatable, Sendable {
    case inProgress, inserted, unconfirmed, partial, held, resolved, cancelled, nothingHeard, notInserted, command
    case toReview(Int)

    public var label: String {
        switch self {
        case .inProgress: return "In progress"
        case .inserted: return "Inserted"
        case .unconfirmed: return "Unconfirmed"
        case .partial: return "Partial"
        case .held: return "Held"
        case .resolved: return "Resolved"
        case .cancelled: return "Cancelled"
        case .nothingHeard: return "No speech"
        case .notInserted: return "Not inserted"
        case .command: return "Command"
        case .toReview(let n): return "\(n) to review"
        }
    }
}

/// S11 — every turn's record, in the app database (`turn_records`) or, when recovery persistence is
/// off, in memory for this session.
///
/// Thread-safe. Reads are served from memory first (this session's rows are always current there);
/// database writes run in order on a private serial queue so the key-down path never waits for
/// SQLite. `flush()` waits for them (tests, quit).
public final class TurnStore: @unchecked Sendable {
    public static let table = "turn_records"
    /// design §8.1 — persistence off, or a save that failed.
    public static let sessionOnlyLabel = "Kept for this session only"
    /// design §8.1 — the default: kept on this Mac until the user resolves it.
    public static let keptUntilResolvedLabel = "Kept until resolved"

    public enum Persistence: String, Equatable, Sendable {
        case keptUntilResolved
        case sessionOnly
    }

    /// The app's store, set once by the composition root (`TurnWiring.attach`). Today (S7b) and the
    /// turn detail read from it; `nil` in headless runs and tests that build their own.
    public static var current: TurnStore? {
        get { currentLock.withLock { _current } }
        set { currentLock.withLock { _current = newValue } }
    }
    private static let currentLock = NSLock()
    private static var _current: TurnStore?

    private let database: AppDatabase?
    private let persistsRecovery: () -> Bool
    private let clock: () -> Date
    private let queue = DispatchQueue(label: "VoicePlus.TurnStore", qos: .utility)
    private let lock = NSLock()
    private var memory: [TurnID: TurnEntry] = [:]
    /// Extras set before the turn's first save; applied by that save.
    private var pendingExtras: [TurnID: TurnRecordExtras] = [:]
    private var tableReady = false
    /// Settled rows kept in the database; unsettled (held) rows are never pruned.
    public var databaseLimit = 500
    /// Settled rows kept in memory for this session.
    public var memoryLimit = 300

    /// Every change, after it is in memory (and again if a write fails).
    public var onChange: ((TurnEntry) -> Void)?
    public var onRemove: ((TurnID) -> Void)?
    /// A save that failed: the row now reads "Kept for this session only".
    public var onPersistFailure: ((TurnID, String) -> Void)?
    /// W3H — Privacy's "Save dictation history" (`DictationHistoryGate`), read per save. Off: only a
    /// recoverable row (held, partial) is written, under recovery persistence; every other row lives
    /// in memory for this session, and a row written earlier leaves the database once it settles.
    public var historyEnabled: () -> Bool = { true }

    public init(database: AppDatabase?, persistsRecovery: @escaping () -> Bool = { true },
                clock: @escaping () -> Date = Date.init) {
        self.database = database
        self.persistsRecovery = persistsRecovery
        self.clock = clock
        tableReady = Self.prepareTable(database)
    }

    /// Creates `turn_records` in the shared database if it is not there. Additive and idempotent:
    /// no existing table is touched, so the app database's own migrations are unaffected.
    private static func prepareTable(_ database: AppDatabase?) -> Bool {
        guard let database else { return false }
        do {
            try database.writer.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS \(table) (
                        id TEXT PRIMARY KEY NOT NULL,
                        startedAt DOUBLE NOT NULL,
                        updatedAt DOUBLE NOT NULL,
                        stage TEXT NOT NULL,
                        recordJSON TEXT NOT NULL
                    )
                    """)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS \(table)_startedAt ON \(table)(startedAt)")
                // T-schema — additive columns; an older table gains them in place.
                let existing = Set(try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String })
                for (name, type) in extraColumns where !existing.contains(name) {
                    try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN \(name) \(type)")
                }
            }
            return true
        } catch {
            Log.db.error("turn store: could not prepare \(table): \(error)")
            return false
        }
    }

    // MARK: Persistence

    /// What a new row gets right now.
    public var persistence: Persistence {
        database != nil && tableReady && persistsRecovery() ? .keptUntilResolved : .sessionOnly
    }

    /// The sentence the recovery surfaces show for new rows.
    public var retentionLabel: String {
        persistence == .keptUntilResolved ? Self.keptUntilResolvedLabel : Self.sessionOnlyLabel
    }

    // MARK: Writes

    /// Writes (inserts or replaces) the row for `record.turnID`.
    @discardableResult
    public func save(_ record: TurnRecord, stage: TurnStage) -> TurnEntry {
        // W3H — with history off only a recoverable row reaches the database.
        let keepsRow = historyEnabled() || stage == .held || record.outcome?.isPartial == true
        let persisting = persistence == .keptUntilResolved && keepsRow
        let now = clock()
        var mayBeStored = false
        let entry = lock.withLock { () -> TurnEntry in
            // A row written before (or read from the database) that no longer qualifies must go.
            let previous = memory[record.turnID]
            mayBeStored = previous.map { $0.persisted || $0.isRecoverable } ?? !stage.isLive
            // Claimed only once the database has said so (`written`): until then, and for good
            // when persistence is off, the row is this session's only.
            let extras = previous?.extras ?? pendingExtras.removeValue(forKey: record.turnID) ?? TurnRecordExtras()
            let entry = TurnEntry(record: record, stage: stage, updatedAt: now,
                                  persisted: persisting && (previous?.persisted ?? false), extras: extras)
            memory[record.turnID] = entry
            pruneMemoryLocked()
            return entry
        }
        if persisting { write(entry) } else if !keepsRow, mayBeStored { forgetStored(entry.id) }
        onChange?(entry)
        return entry
    }

    /// W3H — history off: takes a settled row out of the database, after any write queued before it,
    /// and stops the in-memory row claiming to be on disk. The in-memory row stays for this session.
    private func forgetStored(_ id: TurnID) {
        guard let database, tableReady else { return }
        queue.async { [weak self] in
            do {
                try database.writer.write { db in
                    try db.execute(sql: "DELETE FROM \(Self.table) WHERE id = ?", arguments: [id.rawValue.uuidString])
                }
            } catch { Log.db.error("turn store: history-off delete failed: \(error)") }
            guard let self else { return }
            self.lock.withLock {
                guard var entry = self.memory[id], entry.persisted, !entry.isRecoverable else { return }
                entry.persisted = false
                self.memory[id] = entry
            }
        }
    }

    /// Changes the row for `id` in place. `nil` when the store has no such turn.
    @discardableResult
    public func update(_ id: TurnID, stage: TurnStage? = nil, _ change: (inout TurnRecord) -> Void = { _ in }) -> TurnEntry? {
        guard var entry = entry(id) else { return nil }
        change(&entry.record)
        return save(entry.record, stage: stage ?? entry.stage)
    }

    /// T-schema — the setter other lanes fill (L2 stage ms and pre-boost text, L4 write method and
    /// verification, L6 surface kind and signals). Before the turn's first save the change waits for
    /// it; afterwards the row is rewritten under the same rules as `save` (history off: only a
    /// recoverable row reaches the database).
    public func setExtras(_ id: TurnID, _ change: (inout TurnRecordExtras) -> Void) {
        // A row from an earlier session (database only) is brought into memory first.
        if lock.withLock({ memory[id] == nil }),
           let row = stored(where: "id = ?", arguments: [id.rawValue.uuidString], limit: 1).first {
            lock.withLock { if memory[id] == nil { memory[id] = row } }
        }
        let current = lock.withLock { () -> TurnEntry? in
            guard var entry = memory[id] else {
                var pending = pendingExtras[id] ?? TurnRecordExtras()
                change(&pending)
                pendingExtras[id] = pending
                if pendingExtras.count > 64, let oldest = pendingExtras.keys.first(where: { $0 != id }) {
                    pendingExtras[oldest] = nil
                }
                return nil
            }
            change(&entry.extras)
            memory[id] = entry
            return entry
        }
        guard let current else { return }
        save(current.record, stage: current.stage)
    }

    /// The explicit extras for `id` (memory, then database).
    public func extras(_ id: TurnID) -> TurnRecordExtras? {
        if let pending = lock.withLock({ pendingExtras[id] }) { return pending }
        return entry(id)?.extras
    }

    /// Deletes one turn everywhere (Today › Delete).
    public func remove(_ id: TurnID) {
        lock.withLock { memory[id] = nil; pendingExtras[id] = nil }
        if let database, tableReady {
            queue.async {
                do {
                    try database.writer.write { db in
                        try db.execute(sql: "DELETE FROM \(Self.table) WHERE id = ?", arguments: [id.rawValue.uuidString])
                    }
                } catch { Log.db.error("turn store: delete failed: \(error)") }
            }
        }
        onRemove?(id)
    }

    /// Deletes every turn (Privacy › delete history). Returns once the database is cleared.
    public func removeAll() {
        let ids = lock.withLock { () -> [TurnID] in
            let ids = Array(memory.keys)
            memory.removeAll()
            pendingExtras.removeAll()
            return ids
        }
        if let database, tableReady {
            queue.sync {
                do { try database.writer.write { try $0.execute(sql: "DELETE FROM \(Self.table)") } }
                catch { Log.db.error("turn store: clear failed: \(error)") }
            }
        }
        ids.forEach { onRemove?($0) }
    }

    /// Waits for every queued database write.
    public func flush() { queue.sync {} }

    private func write(_ entry: TurnEntry) {
        guard let database, tableReady else { return }
        let limit = databaseLimit
        queue.async { [weak self] in
            do {
                let json = String(decoding: try JSONEncoder().encode(entry.record), as: UTF8.self)
                let x = entry.resolvedExtras
                let extraNames = Self.extraColumns.map(\.0)
                let extraValues: [(any DatabaseValueConvertible)?] = [
                    x.surfaceKind, Self.json(x.surfaceSignals), x.fieldRole, x.writeMethod, x.verification?.rawValue,
                    Self.json(x.stageMs), x.preBoostRawText, x.keyDownAt?.timeIntervalSinceReferenceDate,
                    x.keyUpAt?.timeIntervalSinceReferenceDate, entry.extras.isEmpty ? nil : Self.json(entry.extras),
                ]
                try database.writer.write { db in
                    let columns = (["id", "startedAt", "updatedAt", "stage", "recordJSON"] + extraNames).joined(separator: ", ")
                    let marks = Array(repeating: "?", count: 5 + extraNames.count).joined(separator: ", ")
                    let updates = (["startedAt", "updatedAt", "stage", "recordJSON"] + extraNames)
                        .map { "\($0) = excluded.\($0)" }.joined(separator: ", ")
                    let base: [(any DatabaseValueConvertible)?] = [
                        entry.id.rawValue.uuidString, entry.record.startedAt.timeIntervalSinceReferenceDate,
                        entry.updatedAt.timeIntervalSinceReferenceDate, entry.stage.rawValue, json]
                    try db.execute(sql: "INSERT INTO \(Self.table) (\(columns)) VALUES (\(marks)) ON CONFLICT(id) DO UPDATE SET \(updates)",
                                   arguments: StatementArguments(base + extraValues))
                    // Settled rows beyond the limit go; a held row stays until the user resolves it.
                    try db.execute(sql: """
                        DELETE FROM \(Self.table) WHERE stage != ? AND id NOT IN (
                            SELECT id FROM \(Self.table) ORDER BY startedAt DESC LIMIT ?)
                        """, arguments: [TurnStage.held.rawValue, limit])
                }
                self?.written(entry.id)
            } catch {
                self?.writeFailed(entry.id, error: error)
            }
        }
    }

    private func written(_ id: TurnID) {
        let changed = lock.withLock { () -> TurnEntry? in
            guard var entry = memory[id], !entry.persisted else { return nil }
            entry.persisted = true
            memory[id] = entry
            return entry
        }
        if let changed { onChange?(changed) }
    }

    private func writeFailed(_ id: TurnID, error: Error) {
        Log.db.error("turn store: save failed for \(id.description): \(error)")
        let failed = lock.withLock { () -> TurnEntry? in
            guard var entry = memory[id] else { return nil }
            entry.persisted = false
            memory[id] = entry
            return entry
        }
        onPersistFailure?(id, String(describing: error))
        if let failed { onChange?(failed) }
    }

    private func pruneMemoryLocked() {
        let settled = memory.values.filter { !$0.stage.isLive && $0.stage != .held }
        guard settled.count > memoryLimit else { return }
        let drop = settled.sorted { $0.record.startedAt < $1.record.startedAt }.prefix(settled.count - memoryLimit)
        for entry in drop { memory[entry.id] = nil }
    }

    // MARK: Reads

    public func entry(_ id: TurnID) -> TurnEntry? {
        if let cached = lock.withLock({ memory[id] }) { return cached }
        return stored(where: "id = ?", arguments: [id.rawValue.uuidString], limit: 1).first
    }

    public func record(_ id: TurnID) -> TurnRecord? { entry(id)?.record }

    /// Newest first: this session's rows and the database's, the in-memory copy winning.
    public func recent(limit: Int = 50) -> [TurnEntry] {
        var byID: [TurnID: TurnEntry] = [:]
        for entry in stored(where: nil, arguments: [], limit: limit) { byID[entry.id] = entry }
        for entry in lock.withLock({ Array(memory.values) }) { byID[entry.id] = entry }
        return Array(byID.values.sorted { $0.record.startedAt > $1.record.startedAt }.prefix(max(0, limit)))
    }

    /// Held and partial turns, newest first — what Today lists before anything else.
    public func recoverable(limit: Int = 50) -> [TurnEntry] {
        var byID: [TurnID: TurnEntry] = [:]
        for entry in stored(where: "stage = ?", arguments: [TurnStage.held.rawValue], limit: limit) { byID[entry.id] = entry }
        for entry in recent(limit: max(limit, 200)) where entry.isRecoverable { byID[entry.id] = entry }
        for entry in lock.withLock({ Array(memory.values) }) { byID[entry.id] = entry }
        return Array(byID.values.filter(\.isRecoverable).sorted { $0.record.startedAt > $1.record.startedAt }.prefix(max(0, limit)))
    }

    /// Rows from the database (none when there is no database or no table).
    private func stored(where clause: String?, arguments: StatementArguments, limit: Int) -> [TurnEntry] {
        guard let database, tableReady, limit > 0 else { return [] }
        let sql = "SELECT stage, updatedAt, recordJSON, extras_json FROM \(Self.table)"
            + (clause.map { " WHERE \($0)" } ?? "") + " ORDER BY startedAt DESC LIMIT \(limit)"
        do {
            return try database.reader.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row -> TurnEntry? in
                    let json: String = row["recordJSON"]
                    guard let record = try? JSONDecoder().decode(TurnRecord.self, from: Data(json.utf8)) else { return nil }
                    let stageRaw: String = row["stage"]
                    let updated: Double = row["updatedAt"]
                    let extrasJSON: String? = row["extras_json"]
                    let extras = extrasJSON.flatMap { try? JSONDecoder().decode(TurnRecordExtras.self, from: Data($0.utf8)) }
                    return TurnEntry(record: record, stage: TurnStage(rawValue: stageRaw) ?? .failed,
                                     updatedAt: Date(timeIntervalSinceReferenceDate: updated), persisted: true,
                                     extras: extras ?? TurnRecordExtras())
                }
            }
        } catch {
            Log.db.error("turn store: read failed: \(error)")
            return []
        }
    }
}
