import Foundation
import GRDB
import Shared

public protocol PersonaStoring: Sendable {
    func persona(for bundleID: String) throws -> Persona?
    func save(_ persona: Persona) throws
    func delete(bundleID: String) throws
    func allBundleIDs() throws -> [String]
}

public final class InMemoryPersonaStore: PersonaStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Persona] = [:]
    public init() {}
    public func persona(for bundleID: String) throws -> Persona? { lock.lock(); defer { lock.unlock() }; return items[bundleID] }
    public func save(_ persona: Persona) throws { lock.lock(); items[persona.appBundleID] = persona; lock.unlock() }
    public func delete(bundleID: String) throws { lock.lock(); items[bundleID] = nil; lock.unlock() }
    public func allBundleIDs() throws -> [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
}

/// Persists in the `personas` table (`PersonaRecord`):
/// - the box text as the row Settings (P1.9) already reads/writes: `appBundleID = <bundle>`;
/// - draft state in `appBundleID = "persona-meta:<bundle>"` (`"auto"` / `"edited"`);
/// - each recipient override in `appBundleID = "persona-recipient:<bundle>:<recipientKey>"`.
/// Namespaced keys never collide with `DatabaseStyleProfileStore`'s `style:` rows.
public struct DatabasePersonaStore: PersonaStoring {
    public let database: AppDatabase
    public static let metaPrefix = "persona-meta:", recipientPrefix = "persona-recipient:"
    public init(database: AppDatabase) { self.database = database }

    static func metaKey(_ b: String) -> String { metaPrefix + b }
    static func recipientKey(_ b: String, _ r: String) -> String { "\(recipientPrefix)\(b):\(r)" }

    public func persona(for bundleID: String) throws -> Persona? {
        guard let main = try database.persona(forApp: bundleID) else { return nil }
        let meta = try database.persona(forApp: Self.metaKey(bundleID))
        let prefix = "\(Self.recipientPrefix)\(bundleID):"
        let overrides: [PersonaRecord] = try database.reader.read {
            try PersonaRecord.filter(Column("appBundleID").like(prefix.replacingOccurrences(of: "%", with: "\\%") + "%")).fetchAll($0)
        }
        var map: [String: String] = [:]
        for o in overrides { map[String(o.appBundleID.dropFirst(prefix.count))] = o.instructions }
        // V5 F1 — a box row written after its meta row was edited outside the manager (Settings saves
        // the `PersonaRecord` directly): that is a user edit, so it is never re-drafted.
        let auto = meta.map { $0.instructions == "auto" && main.updatedAt <= $0.updatedAt } ?? false
        return Persona(appBundleID: bundleID, text: main.instructions, isAutoDrafted: auto,
                       recipientOverrides: map, updatedAt: main.updatedAt)
    }

    public func save(_ persona: Persona) throws {
        let b = persona.appBundleID
        let existing = try database.persona(forApp: b)
        try database.save(PersonaRecord(id: existing?.id ?? UUID().uuidString, appBundleID: b,
                                        instructions: persona.text, updatedAt: persona.updatedAt))
        try database.save(PersonaRecord(id: Self.metaKey(b), appBundleID: Self.metaKey(b),
                                        instructions: persona.isAutoDrafted ? "auto" : "edited", updatedAt: persona.updatedAt))
        try deleteRecipients(b)
        for (k, v) in persona.recipientOverrides {
            let key = Self.recipientKey(b, k)
            try database.save(PersonaRecord(id: key, appBundleID: key, instructions: v, updatedAt: persona.updatedAt))
        }
    }

    public func delete(bundleID: String) throws {
        try deleteRecipients(bundleID)
        _ = try database.writer.write { db in
            try PersonaRecord.filter(Column("appBundleID") == bundleID || Column("appBundleID") == Self.metaKey(bundleID)).deleteAll(db)
        }
    }

    public func allBundleIDs() throws -> [String] {
        try database.reader.read { db in
            try PersonaRecord.select(Column("appBundleID"), as: String.self).order(Column("appBundleID")).fetchAll(db)
        }.filter { !$0.hasPrefix(Self.metaPrefix) && !$0.hasPrefix(Self.recipientPrefix) && !$0.hasPrefix(DatabaseStyleProfileStore.keyPrefix) }
    }

    /// True for the namespaced bookkeeping rows (`persona-meta:`, `persona-recipient:`, `style:`)
    /// that share the `personas` table; Settings lists only the app rows.
    public static func isBookkeepingKey(_ appBundleID: String) -> Bool {
        appBundleID.hasPrefix(metaPrefix) || appBundleID.hasPrefix(recipientPrefix)
            || appBundleID.hasPrefix(DatabaseStyleProfileStore.keyPrefix)
    }

    private func deleteRecipients(_ b: String) throws {
        let prefix = "\(Self.recipientPrefix)\(b):"
        _ = try database.writer.write { db in
            try PersonaRecord.filter(Column("appBundleID").like(prefix.replacingOccurrences(of: "%", with: "\\%") + "%")).deleteAll(db)
        }
    }
}
