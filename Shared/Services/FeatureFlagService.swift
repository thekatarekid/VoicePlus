import Foundation

/// Where a flag override is persisted.
public protocol FeatureFlagStore: Sendable {
    func load() throws -> [String: Bool]
    func save(_ overrides: [String: Bool]) throws
}

/// Local JSON file under Application Support. No server.
public struct JSONFileFlagStore: FeatureFlagStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("feature_flags.json")
    }

    public func load() throws -> [String: Bool] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: url))
    }

    public func save(_ overrides: [String: Bool]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(overrides).write(to: url, options: .atomic)
    }
}

/// For tests. Nothing persisted.
public final class InMemoryFlagStore: FeatureFlagStore, @unchecked Sendable {
    private let lock = NSLock()
    private var overrides: [String: Bool]

    public init(_ overrides: [String: Bool] = [:]) { self.overrides = overrides }

    public func load() throws -> [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        return overrides
    }

    public func save(_ overrides: [String: Bool]) throws {
        lock.lock(); defer { lock.unlock() }
        self.overrides = overrides
    }
}

/// Resolves flags: override (if set) else `FeatureFlag.defaultOn`.
public final class FeatureFlagService: @unchecked Sendable {
    private let store: FeatureFlagStore
    private let lock = NSLock()
    private var overrides: [String: Bool]
    public private(set) var knownFlags: [FeatureFlag]

    public init(store: FeatureFlagStore, knownFlags: [FeatureFlag] = FeatureFlag.all) {
        self.store = store
        self.knownFlags = knownFlags
        self.overrides = (try? store.load()) ?? [:]
    }

    /// Production instance backed by the JSON file in Application Support.
    public static func local() -> FeatureFlagService {
        FeatureFlagService(store: JSONFileFlagStore(url: JSONFileFlagStore.defaultURL()))
    }

    public static func inMemory(_ overrides: [String: Bool] = [:]) -> FeatureFlagService {
        FeatureFlagService(store: InMemoryFlagStore(overrides))
    }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return overrides[flag.id] ?? flag.defaultOn
    }

    public func isEnabled(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let value = overrides[id] { return value }
        return knownFlags.first { $0.id == id }?.defaultOn ?? false
    }

    /// Explicit override; `nil` if the flag is at its default.
    public func override(for flag: FeatureFlag) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return overrides[flag.id]
    }

    public func setOverride(_ value: Bool?, for flag: FeatureFlag) throws {
        lock.lock(); defer { lock.unlock() }
        overrides[flag.id] = value
        try store.save(overrides)
    }

    public func resetAll() throws {
        lock.lock(); defer { lock.unlock() }
        overrides.removeAll()
        try store.save(overrides)
    }

    /// Snapshot suitable for `StageContext.flags`.
    public func snapshot() -> [String: Bool] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Bool] = [:]
        for flag in knownFlags { result[flag.id] = overrides[flag.id] ?? flag.defaultOn }
        for (id, value) in overrides where result[id] == nil { result[id] = value }
        return result
    }
}
