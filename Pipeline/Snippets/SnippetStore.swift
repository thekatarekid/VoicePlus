import Foundation
import GRDB
import Shared

/// P2.6 — trigger phrase → expansion. `Snippet` is the in-memory face of `SnippetRecord`.
public struct Snippet: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var trigger: String
    public var body: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, trigger: String, body: String, createdAt: Date = Date()) {
        self.id = id; self.trigger = trigger; self.body = body; self.createdAt = createdAt
    }
    public init(record: SnippetRecord) { self.init(id: record.id, trigger: record.trigger, body: record.body, createdAt: record.createdAt) }
    public var record: SnippetRecord { SnippetRecord(id: id, trigger: trigger, body: body, createdAt: createdAt) }
    /// Normalized trigger used for matching.
    public var key: String { SnippetNormalizer.normalize(trigger) }
}

/// Spoken-text normalization so "Sig.", "sig" and "  SIG " all hit the same trigger:
/// lower-cased, punctuation stripped (apostrophes/hyphens kept), whitespace collapsed.
public enum SnippetNormalizer {
    public static func normalize(_ text: String) -> String {
        GatekeeperTokenizer.words(text).joined(separator: " ")
    }
}

public enum SnippetError: Error, Equatable, Sendable {
    case emptyTrigger, emptyBody, duplicateTrigger(String), notFound(String)
}

/// CRUD over snippets with normalized exact matching. Conformers must be safe to call from any thread.
public protocol SnippetStoring: Sendable {
    func all() throws -> [Snippet]
    func save(_ snippet: Snippet) throws
    func delete(id: String) throws
}

public extension SnippetStoring {
    /// Exact (normalized) match; `nil` when the phrase is not a trigger. Empty text never matches.
    func match(_ text: String) -> Snippet? {
        let key = SnippetNormalizer.normalize(text)
        guard !key.isEmpty, let all = try? all() else { return nil }
        return all.first { $0.key == key }
    }

    /// Validates then saves. Rejects empty triggers/bodies and triggers that normalize to an
    /// existing snippet's key (unless it's the same snippet being updated).
    func upsert(_ snippet: Snippet) throws {
        let key = snippet.key
        guard !key.isEmpty else { throw SnippetError.emptyTrigger }
        guard !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SnippetError.emptyBody }
        if let clash = try all().first(where: { $0.key == key && $0.id != snippet.id }) {
            throw SnippetError.duplicateTrigger(clash.trigger)
        }
        try save(snippet)
    }

    func create(trigger: String, body: String) throws -> Snippet {
        let s = Snippet(trigger: trigger, body: body)
        try upsert(s)
        return s
    }

    func update(id: String, trigger: String? = nil, body: String? = nil) throws -> Snippet {
        guard var s = try all().first(where: { $0.id == id }) else { throw SnippetError.notFound(id) }
        if let trigger { s.trigger = trigger }
        if let body { s.body = body }
        try upsert(s)
        return s
    }
}

public final class InMemorySnippetStore: SnippetStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Snippet] = [:]
    public init(_ seed: [Snippet] = []) { for s in seed { items[s.id] = s } }
    public func all() throws -> [Snippet] { lock.lock(); defer { lock.unlock() }; return items.values.sorted { $0.key < $1.key } }
    public func save(_ snippet: Snippet) throws { lock.lock(); items[snippet.id] = snippet; lock.unlock() }
    public func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard items.removeValue(forKey: id) != nil else { throw SnippetError.notFound(id) }
    }
}

/// Persists in `AppDatabase.snippets` (`SnippetRecord`). Settings (P1.9) edits the same table.
public struct DatabaseSnippetStore: SnippetStoring {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }
    public func all() throws -> [Snippet] { try database.snippets().map(Snippet.init(record:)) }
    public func save(_ snippet: Snippet) throws { try database.save(snippet.record) }
    public func delete(id: String) throws {
        let deleted = try database.writer.write { try SnippetRecord.deleteOne($0, key: id) }
        guard deleted else { throw SnippetError.notFound(id) }
    }
}
