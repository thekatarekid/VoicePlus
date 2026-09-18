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

/// Reads through to a real store but discards every write. For diagnostics that must report on
/// persisted state without being able to change it.
public final class ReadOnlySettingsStore: SettingsStore {
    private let backing: SettingsStore
    public init(_ backing: SettingsStore) { self.backing = backing }
    public func string(_ key: String) -> String? { backing.string(key) }
    public func bool(_ key: String) -> Bool? { backing.bool(key) }
    public func set(_ value: String?, for key: String) {}
    public func set(_ value: Bool, for key: String) {}
}

public enum SettingsKeys {
    public static let onboardingCompleted = "onboarding.completed"
    public static let hotkey = "hotkey.choice"
    public static let routingPrefix = "routing."
    /// Meeting capture is opt-in and defaults to OFF. Nothing that can raise a Calendar,
    /// Reminders or Notification dialog may run until the user has flipped this on.
    public static let meetingCaptureEnabled = "meeting.capture.enabled"
    /// P5 — the persistent presence indicator near the notch. Default ON: it is the app's only
    /// always-on affordance once macOS culls the status item from a crowded menu bar.
    public static let presenceIndicator = "presence.indicator.enabled"
    /// Hide it in a full-screen Space — quiet states ONLY. `listening`, `processing` and `muted`
    /// always draw: a hidden hot mic in full screen is exactly what the product spec forbids.
    public static let presenceHideInFullScreen = "presence.indicator.hideInFullScreen"
    /// P4.2 — whether the second (act) key is live at all. Default OFF; see `ActKeySettings`.
    public static let actKeyEnabled = "act.key.enabled"
    /// V4.33 — "Insert after a pause of" (seconds of trailing silence that close a latched
    /// segment). 1.0–5.0, default 2.0; read and written through `LatchSettings`.
    public static let latchPauseSeconds = "latch.pauseSeconds"
}

/// V4.33 — the latch pause, defaults and bounds included, in one place.
///
/// Stored as a decimal string because `SettingsStore` carries strings and booleans only. Writes go
/// through `setPauseSeconds(_:store:)`, which posts `didChangeNotification` so a latched session
/// picks the new pause up without being restarted.
public enum LatchSettings {
    public static let defaultPauseSeconds: TimeInterval = 2.0
    public static let pauseRange: ClosedRange<TimeInterval> = 1.0...5.0
    /// Latch is an explicit session: silence this long is reported, never a reason to close.
    public static let noSpeechTimeout: TimeInterval = 8
    /// A long monologue still lands in pieces (V4.33).
    public static let maxSegmentSeconds: TimeInterval = 30
    /// Posted after `setPauseSeconds(_:store:center:)` wrote a new value.
    public static let didChangeNotification = Notification.Name("VoicePlus.LatchSettings.didChange")

    /// The stored pause, clamped to `pauseRange`. Missing or unreadable → the default.
    public static func pauseSeconds(_ store: SettingsStore?) -> TimeInterval {
        guard let raw = store?.string(SettingsKeys.latchPauseSeconds),
              let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite else {
            return defaultPauseSeconds
        }
        return clamp(value)
    }

    public static func setPauseSeconds(_ seconds: TimeInterval, store: SettingsStore?,
                                       center: NotificationCenter = .default) {
        guard let store, seconds.isFinite else { return }
        store.set(String(clamp(seconds)), for: SettingsKeys.latchPauseSeconds)
        center.post(name: didChangeNotification, object: nil)
    }

    /// Bounded to the range and rounded to a tenth of a second — the precision the row offers.
    public static func clamp(_ seconds: TimeInterval) -> TimeInterval {
        let bounded = min(pauseRange.upperBound, max(pauseRange.lowerBound, seconds))
        return (bounded * 10).rounded() / 10
    }
}

/// The on/off switch for the act key, defaults included, in one place.
///
/// ## Why off is the default
/// Actions is the one feature in VoicePlus that cannot do anything useful until the user has
/// connected and pinned a cloud provider for `act.planner`. Before 1.7.11 the act key shipped live
/// on Right ⌘ with no UI to rebind or silence it, so the first thing a fresh install could do with
/// it was swallow a keypress the user meant for dictation and answer "Actions need a model set up
/// in Settings" — an error that was also unreachable, because `act.planner` had no Settings row.
/// A key that can only produce an error until configured has no business being armed by default.
/// Turning it on is now one picker away, and the picker is what pins the key.
public enum ActKeySettings {
    public static func isEnabled(_ store: SettingsStore?) -> Bool {
        guard let store else { return false }
        if let explicit = store.bool(SettingsKeys.actKeyEnabled) { return explicit }
        // No explicit choice. The only installs that can have an act binding without one are the
        // `defaults write in.adityakatare.voiceplus actHotkeyBinding …` era, before there was a
        // switch to flip — that write *was* the opt-in, so honour it.
        return store.string(HotkeyService.actBindingDefaultsKey) != nil
    }

    public static func setEnabled(_ enabled: Bool, store: SettingsStore?) {
        store?.set(enabled, for: SettingsKeys.actKeyEnabled)
    }
}

/// P5 — reading the two presence switches, defaults included, in one place.
public enum PresenceSettings {
    public static func isEnabled(_ store: SettingsStore?) -> Bool {
        guard let store else { return true }
        return store.bool(SettingsKeys.presenceIndicator) ?? true
    }

    public static func hidesInFullScreen(_ store: SettingsStore?) -> Bool {
        guard let store else { return true }
        return store.bool(SettingsKeys.presenceHideInFullScreen) ?? true
    }

    public static func setEnabled(_ enabled: Bool, store: SettingsStore?) {
        store?.set(enabled, for: SettingsKeys.presenceIndicator)
    }

    public static func setHidesInFullScreen(_ hide: Bool, store: SettingsStore?) {
        store?.set(hide, for: SettingsKeys.presenceHideInFullScreen)
    }
}
