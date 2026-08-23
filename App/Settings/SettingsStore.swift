import Foundation

/// Minimal key-value persistence for settings (hotkey, per-stage routing, onboarding flags).
public protocol SettingsStore: AnyObject {
    func string(_ key: String) -> String?
    func bool(_ key: String) -> Bool?
    func set(_ value: String?, for key: String)
    func set(_ value: Bool, for key: String)
}

public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func string(_ key: String) -> String? { defaults.string(forKey: key) }
    public func bool(_ key: String) -> Bool? { defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key) }
    public func set(_ value: String?, for key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Bool, for key: String) { defaults.set(value, forKey: key) }
}

public final class InMemorySettingsStore: SettingsStore {
    public private(set) var values: [String: Any] = [:]
    public init() {}
    public func string(_ key: String) -> String? { values[key] as? String }
    public func bool(_ key: String) -> Bool? { values[key] as? Bool }
    public func set(_ value: String?, for key: String) { values[key] = value }
    public func set(_ value: Bool, for key: String) { values[key] = value }
}

public enum SettingsKeys {
    public static let onboardingCompleted = "onboarding.completed"
    public static let hotkey = "hotkey.choice"
    public static let routingPrefix = "routing."
}
