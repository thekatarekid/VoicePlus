import Foundation

/// Picks which input to capture from. Order: explicit per-device user preference (UserDefaults)
/// → keep the current device if still present → system default unless it is a display/virtual
/// device → built-in mic → anything else. Transport ranks are conservative on purpose: a
/// monitor's mic or a virtual loopback as system default is the classic silent failure.
public struct InputSelectionPolicy: @unchecked Sendable {
    public static let preferredUIDKey = "audio.input.preferredUID"
    public static let perDevicePrefix = "audio.input.pref."   // + uid -> Bool (true=prefer, false=avoid)

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: preferences

    public var preferredUID: String? {
        get { defaults.string(forKey: Self.preferredUIDKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.preferredUIDKey) }
    }

    /// Remembered opinion about one device: `true` = prefer whenever present, `false` = never auto-pick.
    public func preference(for uid: String) -> Bool? {
        defaults.object(forKey: Self.perDevicePrefix + uid) as? Bool
    }

    public func setPreference(_ value: Bool?, for uid: String) {
        if let value { defaults.set(value, forKey: Self.perDevicePrefix + uid) } else { defaults.removeObject(forKey: Self.perDevicePrefix + uid) }
    }

    // MARK: policy

    public func choose(from devices: [AudioDeviceInfo], systemDefault: AudioDeviceInfo?, current: AudioDeviceInfo? = nil) -> AudioDeviceInfo? {
        let usable = devices.filter { $0.inputChannels > 0 && preference(for: $0.uid) != false }
        guard !usable.isEmpty else { return devices.first }
        if let uid = preferredUID, let d = usable.first(where: { $0.uid == uid }) { return d }
        if let d = usable.first(where: { preference(for: $0.uid) == true }) { return d }
        if let current, let d = usable.first(where: { $0.uid == current.uid }) { return d }
        return usable.max { rank($0, systemDefault: systemDefault) < rank($1, systemDefault: systemDefault) }
    }

    func rank(_ d: AudioDeviceInfo, systemDefault: AudioDeviceInfo?) -> Int {
        var r = 0
        switch d.transport {
        case .builtIn: r += 40
        case .usb: r += 35
        case .bluetooth: r += 30
        case .other, .aggregate: r += 20
        case .displayPort: r += 5
        case .virtual: r += 0
        }
        if d.uid == systemDefault?.uid, d.transport != .displayPort, d.transport != .virtual { r += 50 }
        return r
    }
}
