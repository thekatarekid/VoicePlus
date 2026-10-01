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

    /// What the policy picked and, when it mattered, what it deliberately walked away from.
    public struct Choice: Equatable, Sendable {
        public var device: AudioDeviceInfo?
        /// Set when the system default was a narrowband Bluetooth (HFP/SCO) mic and a better wired
        /// input was chosen instead. The UI says this out loud rather than silently doing it.
        public var avoidedNarrowbandBluetooth: AudioDeviceInfo?
        public init(device: AudioDeviceInfo?, avoidedNarrowbandBluetooth: AudioDeviceInfo? = nil) {
            self.device = device
            self.avoidedNarrowbandBluetooth = avoidedNarrowbandBluetooth
        }
    }

    public func choose(from devices: [AudioDeviceInfo], systemDefault: AudioDeviceInfo?, current: AudioDeviceInfo? = nil) -> AudioDeviceInfo? {
        decide(from: devices, systemDefault: systemDefault, current: current).device
    }

    public func decide(from devices: [AudioDeviceInfo], systemDefault: AudioDeviceInfo?, current: AudioDeviceInfo? = nil) -> Choice {
        let usable = devices.filter { $0.inputChannels > 0 && preference(for: $0.uid) != false }
        guard !usable.isEmpty else { return Choice(device: devices.first) }
        // An explicit choice always wins, narrowband or not. The user is allowed to be wrong.
        if let uid = preferredUID, let d = usable.first(where: { $0.uid == uid }) { return Choice(device: d) }
        if let d = usable.first(where: { preference(for: $0.uid) == true }) { return Choice(device: d) }
        // V5 C3 — keeping the current mic while macOS made a call-mode headset the default (AirPods
        // just connected) is an avoidance too, and is reported as one.
        if let current, let d = usable.first(where: { $0.uid == current.uid }) {
            let avoided = Self.isNarrowbandBluetooth(systemDefault) && d.uid != systemDefault?.uid ? systemDefault : nil
            return Choice(device: d, avoidedNarrowbandBluetooth: avoided)
        }
        let picked = usable.max { rank($0, systemDefault: systemDefault) < rank($1, systemDefault: systemDefault) }
        let avoided = Self.isNarrowbandBluetooth(systemDefault) && picked?.uid != systemDefault?.uid ? systemDefault : nil
        return Choice(device: picked, avoidedNarrowbandBluetooth: avoided)
    }

    /// A Bluetooth headset mic on macOS runs over HFP/SCO at 8 kHz (CVSD) or 16 kHz (mSBC) —
    /// telephony bandwidth, and the reason a competing app ships "system input, or the Mac mic with
    /// AirPods". `BluetoothInputDetector` owns the classification; this is the one-bit view of it.
    static func isNarrowbandBluetooth(_ d: AudioDeviceInfo?) -> Bool {
        guard let d else { return false }
        return BluetoothInputDetector.mode(for: d).isNarrowbandSpeech
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
        // Being the system default is normally decisive (+50 dwarfs every transport score). It is
        // withheld from a narrowband Bluetooth mic: macOS makes AirPods the default input the moment
        // they connect, which silently drops dictation onto an 8/16 kHz telephony link and costs far
        // more accuracy than honouring the system default is worth. The Bluetooth device still wins
        // when it is the only input there is, and an explicit user choice still overrides all of this.
        if d.uid == systemDefault?.uid, d.transport != .displayPort, d.transport != .virtual,
           !Self.isNarrowbandBluetooth(d) { r += 50 }
        return r
    }
}
