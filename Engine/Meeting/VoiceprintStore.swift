import Foundation
import Shared
import SQLite3

// V5 M10 — the voiceprint library. Mapping a meeting speaker to a person ("Others 2" → Priya)
// saves that cluster's embedding centroid under the person; the next meeting's clusters are matched
// against the library: cosine ≥ `appliedThreshold` → the name is applied, `suggestedThreshold` up
// to it → suggested ("maybe Priya"), else a new voice. Vectors from different embedding models
// (WeSpeaker / CAM++, M9) are stored and compared only within their own model.
//
// Local only: one SQLite file under Application Support, excluded from backups, never read by the
// sync layer; `syncAllowed` (off) is the explicit opt-in a sync feature must check.

/// A person in the library.
public struct VoiceprintPerson: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// One person's voice in one embedding space.
public struct Voiceprint: Equatable, Sendable {
    public var personID: String
    public var embedder: String
    /// L2-normalised, quality-weighted mean.
    public var centroid: [Float]
    /// Clusters / meetings averaged in.
    public var sampleCount: Int
    public var totalWeight: Float
    public var lastSeen: Date
}

/// What the library says about a cluster.
public enum VoiceprintMatch: Equatable, Sendable {
    /// High confidence: use the name.
    case applied(VoiceprintPerson, similarity: Float)
    /// Middle band: offer it ("maybe Priya"), never apply it.
    case suggested(VoiceprintPerson, similarity: Float)
    /// Nobody close enough.
    case new

    public var person: VoiceprintPerson? {
        switch self {
        case .applied(let p, _), .suggested(let p, _): return p
        case .new: return nil
        }
    }
}

public enum VoiceprintError: Error, Equatable { case open(String), sql(String), emptyEmbedding }

public final class VoiceprintStore: @unchecked Sendable {
    public static let appliedThreshold: Float = 0.75
    public static let suggestedThreshold: Float = 0.6
    /// Weight cap: past it each new mapping still moves the mean by ≥ w / cap (voices drift slowly).
    public static let maxTotalWeight: Float = 20

    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    public static func defaultURL() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("Voiceprints", isDirectory: true)
            .appendingPathComponent("voiceprints.sqlite")
    }

    public init(url: URL = VoiceprintStore.defaultURL()) throws {
        self.url = url
        var dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db); db = nil
            throw VoiceprintError.open(msg)
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL, created REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS voiceprints (
                person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                embedder TEXT NOT NULL, centroid BLOB NOT NULL, samples INTEGER NOT NULL,
                total_weight REAL NOT NULL, last_seen REAL NOT NULL,
                PRIMARY KEY (person_id, embedder));
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: people

    public func people() -> [VoiceprintPerson] {
        lock.withLock {
            (try? query("SELECT id, name FROM people ORDER BY name COLLATE NOCASE", []) { s in
                VoiceprintPerson(id: Self.text(s, 0), name: Self.text(s, 1))
            }) ?? []
        }
    }

    /// The person named `name` (case-insensitive), created if new.
    @discardableResult
    public func person(named name: String) throws -> VoiceprintPerson {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try lock.withLock {
            if let p = try query("SELECT id, name FROM people WHERE name = ? COLLATE NOCASE LIMIT 1", [.text(n)], {
                VoiceprintPerson(id: Self.text($0, 0), name: Self.text($0, 1))
            }).first { return p }
            let p = VoiceprintPerson(id: UUID().uuidString, name: n)
            try run("INSERT INTO people (id, name, created) VALUES (?, ?, ?)", [.text(p.id), .text(p.name), .real(Date().timeIntervalSince1970)])
            return p
        }
    }

    public func rename(_ personID: String, to name: String) throws {
        try lock.withLock { try run("UPDATE people SET name = ? WHERE id = ?", [.text(name), .text(personID)]) }
    }

    /// Removes the person and every voiceprint of theirs.
    public func forget(_ personID: String) throws {
        try lock.withLock {
            try run("DELETE FROM voiceprints WHERE person_id = ?", [.text(personID)])
            try run("DELETE FROM people WHERE id = ?", [.text(personID)])
        }
    }

    public func voiceprints(embedder: String) -> [Voiceprint] {
        lock.withLock {
            (try? query("SELECT person_id, embedder, centroid, samples, total_weight, last_seen FROM voiceprints WHERE embedder = ?",
                        [.text(embedder)]) { s in
                Voiceprint(personID: Self.text(s, 0), embedder: Self.text(s, 1), centroid: Self.floats(s, 2),
                           sampleCount: Int(sqlite3_column_int64(s, 3)), totalWeight: Float(sqlite3_column_double(s, 4)),
                           lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(s, 5)))
            }) ?? []
        }
    }

    // MARK: matching + mapping

    /// The library's verdict on a cluster's embedding (same embedder only).
    public func match(_ e: SpeakerEmbedding) -> VoiceprintMatch {
        guard !e.vector.isEmpty else { return .new }
        let names = Dictionary(people().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var best: (VoiceprintPerson, Float)?
        for v in voiceprints(embedder: e.embedder) where v.centroid.count == e.vector.count {
            guard let p = names[v.personID] else { continue }
            let s = EmbeddingMatch.cosine(v.centroid, e.vector)
            if s > (best?.1 ?? -2) { best = (p, s) }
        }
        guard let (p, s) = best else { return .new }
        if s >= Self.appliedThreshold { return .applied(p, similarity: s) }
        if s >= Self.suggestedThreshold { return .suggested(p, similarity: s) }
        return .new
    }

    /// Matches every speaker of a meeting. One person is applied to at most one speaker (the most
    /// similar); any other speaker that matched them is downgraded to a suggestion. The user's own
    /// slot (`.you`) is never matched — it already has a name.
    public func match(speakers: [MeetingSpeaker: SpeakerEmbedding]) -> [MeetingSpeaker: VoiceprintMatch] {
        var out: [MeetingSpeaker: VoiceprintMatch] = [:]
        for (speaker, e) in speakers where speaker != .you { out[speaker] = match(e) }
        var owner: [String: (MeetingSpeaker, Float)] = [:]
        for (speaker, m) in out {
            guard case .applied(let p, let s) = m else { continue }
            if let (other, os) = owner[p.id] {
                let (winner, loser, ls) = s > os ? (speaker, other, os) : (other, speaker, s)
                owner[p.id] = (winner, max(s, os))
                out[loser] = .suggested(p, similarity: ls)
            } else {
                owner[p.id] = (speaker, s)
            }
        }
        return out
    }

    /// Saves a mapped cluster: its centroid is averaged into the person's voiceprint for that
    /// embedder, weighted by `weight` (speech seconds × quality, capped at 1 per meeting by callers).
    @discardableResult
    public func map(_ e: SpeakerEmbedding, weight: Float = 1, to personID: String, at now: Date = Date()) throws -> Voiceprint {
        guard !e.vector.isEmpty else { throw VoiceprintError.emptyEmbedding }
        let w = max(0.05, min(1, weight))
        let existing = voiceprints(embedder: e.embedder).first { $0.personID == personID && $0.centroid.count == e.vector.count }
        var v = existing ?? Voiceprint(personID: personID, embedder: e.embedder, centroid: [], sampleCount: 0, totalWeight: 0, lastSeen: now)
        if v.centroid.isEmpty {
            v.centroid = e.vector
        } else {
            let total = min(v.totalWeight, Self.maxTotalWeight - w)
            let a = total / (total + w), b = w / (total + w)
            v.centroid = SpeakerEmbedding(vector: zip(v.centroid, e.vector).map { $0 * a + $1 * b }, embedder: e.embedder).vector
        }
        v.sampleCount += 1
        v.totalWeight = min(Self.maxTotalWeight, v.totalWeight + w)
        v.lastSeen = now
        try lock.withLock {
            try run("""
                INSERT INTO voiceprints (person_id, embedder, centroid, samples, total_weight, last_seen) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(person_id, embedder) DO UPDATE SET centroid = excluded.centroid, samples = excluded.samples,
                    total_weight = excluded.total_weight, last_seen = excluded.last_seen
                """, [.text(personID), .text(e.embedder), .blob(Self.blob(v.centroid)), .int(v.sampleCount),
                      .real(Double(v.totalWeight)), .real(now.timeIntervalSince1970)])
        }
        return v
    }

    /// Records that a matched person was heard again (last seen) without moving their centroid.
    public func touch(_ personID: String, at now: Date = Date()) {
        lock.withLock { try? run("UPDATE voiceprints SET last_seen = ? WHERE person_id = ?", [.real(now.timeIntervalSince1970), .text(personID)]) }
    }

    // MARK: sync opt-in

    /// Off unless the user chose it; a sync feature must check this before reading the file.
    public var syncAllowed: Bool {
        get { lock.withLock { (try? query("SELECT value FROM meta WHERE key = 'sync'", []) { Self.text($0, 0) })?.first == "1" } }
        set { lock.withLock { try? run("INSERT OR REPLACE INTO meta (key, value) VALUES ('sync', ?)", [.text(newValue ? "1" : "0")]) } }
    }

    // MARK: sqlite

    enum Value { case text(String), real(Double), int(Int), blob(Data) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VoiceprintError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw VoiceprintError.sql(String(cString: sqlite3_errmsg(db))) }
        for (i, v) in values.enumerated() {
            let k = Int32(i + 1)
            switch v {
            case .text(let t): sqlite3_bind_text(s, k, t, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(s, k, d)
            case .int(let n): sqlite3_bind_int64(s, k, Int64(n))
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(s, k, $0.baseAddress, Int32(d.count), Self.transient) }
            }
        }
        return s
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let s = try prepare(sql, values)
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw VoiceprintError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ row: (OpaquePointer?) -> T) throws -> [T] {
        let s = try prepare(sql, values)
        defer { sqlite3_finalize(s) }
        var out: [T] = []
        while sqlite3_step(s) == SQLITE_ROW { out.append(row(s)) }
        return out
    }

    private static func text(_ s: OpaquePointer?, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private static func floats(_ s: OpaquePointer?, _ i: Int32) -> [Float] {
        let n = Int(sqlite3_column_bytes(s, i)) / MemoryLayout<Float>.size
        guard n > 0, let p = sqlite3_column_blob(s, i) else { return [] }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: n))
    }

    private static func blob(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
}
