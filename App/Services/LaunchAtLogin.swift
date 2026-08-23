import Foundation
import ServiceManagement
import Shared

/// Launch-at-login via SMAppService (T1). Only meaningful inside a bundled .app; `swift run` reports unavailable.
public enum LaunchAtLogin {
    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    public static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func set(enabled: Bool) -> Bool {
        guard isAvailable else {
            Log.app.warning("launch-at-login unavailable outside an app bundle")
            return false
        }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            Log.app.error("launch-at-login: \(error)")
            return false
        }
    }
}
