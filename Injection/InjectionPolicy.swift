import Foundation
import Shared

/// R2.3 — the user's standing answer to "may VoicePlus type into this app at all?".
///
/// `Injection` has no settings layer of its own and must not reach into `App/`, so the never-inject
/// list arrives through this one-property protocol. `App` owns the Settings UI and the persistence;
/// this module only ever reads.
public protocol InjectionPolicyProviding: AnyObject {
    /// Bundle IDs that must never receive injected text. Committed text for one of these is
    /// *held* (Insert here / Copy / Discard), never posted and never dropped.
    var neverInjectBundleIDs: Set<String> { get }
}

/// Where the list lives in settings. `App`'s `SettingsStore` is a string/bool store, so the value
/// is one string: bundle IDs separated by commas or newlines.
///
/// ```swift
/// settings.set("com.agilebits.onepassword7,com.apple.keychainaccess", for: InjectionSettingsKeys.neverInject)
/// ```
public enum InjectionSettingsKeys {
    public static let neverInject = "injection.neverInject"

    /// Parses the stored form. Tolerant of commas, newlines, spaces and empty entries so a
    /// hand-edited defaults value cannot break injection.
    public static func parseBundleIDs(_ raw: String?) -> Set<String> {
        guard let raw else { return [] }
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
        return Set(parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// The inverse, for whoever writes the setting.
    public static func format(_ bundleIDs: Set<String>) -> String {
        bundleIDs.sorted().joined(separator: ",")
    }
}

/// A list held in memory. What tests use, and what `App` can hand over after reading its own store.
public final class StaticInjectionPolicy: InjectionPolicyProviding {
    public var neverInjectBundleIDs: Set<String>
    public init(neverInject: Set<String> = []) { neverInjectBundleIDs = neverInject }
}

/// Reads `InjectionSettingsKeys.neverInject` out of `UserDefaults` on every call, so a change in
/// Settings takes effect on the next utterance with no wiring and no notification.
///
/// The default is empty: refusing to type into an app the user never named would be a surprise.
/// Password fields are handled separately and unconditionally (`FocusedElementInfo.isSecure`).
public final class UserDefaultsInjectionPolicy: InjectionPolicyProviding {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var neverInjectBundleIDs: Set<String> {
        if let list = defaults.stringArray(forKey: InjectionSettingsKeys.neverInject) {
            return Set(list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        return InjectionSettingsKeys.parseBundleIDs(defaults.string(forKey: InjectionSettingsKeys.neverInject))
    }
}
