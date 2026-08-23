import Foundation
import Shared

/// What kind of Bluetooth input we are talking to. HFP/SCO links carry the mic at 8 kHz (CVSD) or
/// 16 kHz (mSBC) — narrow/wide-band telephony quality; A2DP has no mic at all. AirPods on macOS
/// surface as a Bluetooth-transport device whose nominal input rate drops to 8/16/24 kHz while
/// the link is in hands-free mode.
public enum BluetoothInputMode: String, Codable, Sendable, Equatable {
    case notBluetooth
    /// SCO narrow-band (≈8 kHz): clearly degraded.
    case scoNarrowband
    /// SCO wide-band / mSBC (≈16 kHz): usable, still telephony-grade.
    case scoWideband
    /// ≥24 kHz input on a Bluetooth device (LE Audio / proprietary high-quality modes).
    case highQuality
    /// Bluetooth device that exposes no input channels (A2DP-only headphones).
    case noInput
}

public struct BluetoothInputAssessment: Codable, Equatable, Sendable {
    public var mode: BluetoothInputMode
    public var sampleRate: Double
    public var deviceName: String
    public var isLowQuality: Bool { mode == .scoNarrowband || mode == .scoWideband }
    /// Verdict for the pill; nil when nothing needs saying.
    public var micQuality: MicQuality?
    /// Human message for the pill / settings ("AirPods in low-quality mode").
    public var warning: String?
}

/// Pure classifier over device properties (transport + nominal input sample rate + channels),
/// so it can be tested with mocked `AudioDeviceInfo` and reused by the route-change handler.
public enum BluetoothInputDetector {
    public static func mode(for device: AudioDeviceInfo) -> BluetoothInputMode {
        guard device.transport == .bluetooth else { return .notBluetooth }
        if device.inputChannels == 0 { return .noInput }
        switch device.sampleRate {
        case ..<12_000: return .scoNarrowband
        case ..<24_000: return .scoWideband
        default: return .highQuality
        }
    }

    public static func assess(_ device: AudioDeviceInfo?) -> BluetoothInputAssessment? {
        guard let device else { return nil }
        let m = mode(for: device)
        var a = BluetoothInputAssessment(mode: m, sampleRate: device.sampleRate, deviceName: device.name)
        let airpods = device.name.localizedCaseInsensitiveContains("airpods")
        let label = airpods ? "AirPods" : device.name
        switch m {
        case .scoNarrowband:
            a.micQuality = MicQuality(snr: 6, clipping: 0, lowLevel: false, verdict: .poor)
            a.warning = "\(label) in low-quality mode (8 kHz Bluetooth mic). Use the Mac's mic for better accuracy."
        case .scoWideband:
            a.micQuality = MicQuality(snr: 12, clipping: 0, lowLevel: false, verdict: .poor)
            a.warning = "\(label) in low-quality mode (16 kHz Bluetooth mic). Accuracy may drop."
        case .noInput:
            a.micQuality = MicQuality(snr: 0, clipping: 0, lowLevel: true, verdict: .bad)
            a.warning = "\(label) has no microphone input on this connection."
        case .highQuality, .notBluetooth:
            break
        }
        return a
    }

    /// Live query against the HAL for the current default input (nil when no device).
    public static func assessDefaultInput() -> BluetoothInputAssessment? {
        assess(AudioDeviceEnumerator.defaultInputDevice())
    }
}
