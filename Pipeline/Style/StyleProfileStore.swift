import Foundation
import Shared

/// Persistence for `StyleProfile`, keyed by app bundle ID.
public protocol StyleProfileStore: Sendable {
    func profile(for bundleID: String) throws -> StyleProfile?
    func save(_ profile: StyleProfile) throws
}

/// Test / preview store.
public final class InMemoryStyleProfileStore: StyleProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [String: StyleProfile] = [:]
    public init() {}
    public func profile(for bundleID: String) throws -> StyleProfile? { lock.lock(); defer { lock.unlock() }; return profiles[bundleID] }
    public func save(_ profile: StyleProfile) throws { lock.lock(); profiles[profile.appBundleID] = profile; lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return profiles.count }
}

/// Stores profiles in `AppDatabase`'s `personas` table as a `PersonaRecord` whose
/// `instructions` column holds the profile JSON. Rows are namespaced (`style:<bundleID>`)
/// so they never collide with Phase-2 persona instructions for the same app.
public struct DatabaseStyleProfileStore: StyleProfileStore {
    public static let keyPrefix = "style:"
    public let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    public static func key(for bundleID: String) -> String { keyPrefix + bundleID }

    public func profile(for bundleID: String) throws -> StyleProfile? {
        guard let record = try database.persona(forApp: Self.key(for: bundleID)) else { return nil }
        do { return try StyleProfile.decode(json: record.instructions) } catch {
            Log.pipeline.warning("style: unreadable profile for \(bundleID), discarding: \(error)")
            return nil
        }
    }

    public func save(_ profile: StyleProfile) throws {
        let key = Self.key(for: profile.appBundleID)
        try database.save(PersonaRecord(id: key, appBundleID: key, instructions: try profile.encodedJSON(),
                                        updatedAt: profile.updatedAt))
    }
}
