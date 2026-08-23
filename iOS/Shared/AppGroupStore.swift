import Foundation
import KeyboardCore

/// App Group container helpers shared by app and keyboard. Falls back to the caches dir in
/// the simulator / when the entitlement is missing so the keyboard still types.
public enum AppGroupStore {
    public static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardProxyNames.appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
    public static var defaults: UserDefaults { UserDefaults(suiteName: KeyboardProxyNames.appGroup) ?? .standard }
    public static var hasAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardProxyNames.appGroup) != nil
    }

    public static func mailbox() throws -> FileKeyboardMailbox {
        try FileKeyboardMailbox(directory: containerURL.appendingPathComponent(KeyboardProxyNames.mailboxDirectory))
    }

    public static func loadPersonas() -> PersonaPicker {
        guard let data = defaults.data(forKey: KeyboardProxyNames.personasKey),
              let p = try? JSONDecoder().decode(PersonaPicker.self, from: data) else { return PersonaPicker() }
        return p
    }
    public static func savePersonas(_ p: PersonaPicker) {
        defaults.set(try? JSONEncoder().encode(p), forKey: KeyboardProxyNames.personasKey)
    }
}
