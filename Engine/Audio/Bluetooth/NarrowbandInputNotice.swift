import Foundation
import Shared

/// V5 C3 — a capture source that can say which narrowband (HFP/SCO, 8/16 kHz) Bluetooth input the
/// `InputSelectionPolicy` walked away from on its last decision. Additive: sources that do not
/// conform simply never report an avoided headset.
public protocol NarrowbandInputReporting: AnyObject {
    /// The system-default headset mic the policy avoided on the last device decision, if any.
    var avoidedNarrowbandInput: AudioDeviceInfo? { get }
}

/// V5 C3 — "Headset is in call mode": the one-line pill chip shown when the input policy either
/// *lands on* a narrowband Bluetooth mic (dictation is running at telephony bandwidth) or *avoids*
/// one (the user's system input is a headset in call mode, and we are using another mic instead).
/// Both cases are said out loud — a silent substitution or a silent quality drop is the bug.
/// Pure and deterministic; the app decides where it is drawn (`DictationCoordinator`).
public struct NarrowbandInputNotice: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Capture is on the narrowband headset mic: accuracy is reduced.
        case capturing
        /// The headset is the system input but the policy chose `using` instead.
        case avoided
    }

    public var kind: Kind
    /// The narrowband headset.
    public var headset: AudioDeviceInfo
    /// The mic actually in use (for `.avoided`).
    public var using: AudioDeviceInfo?

    public init(kind: Kind, headset: AudioDeviceInfo, using: AudioDeviceInfo? = nil) {
        self.kind = kind; self.headset = headset; self.using = using
    }

    /// The build doc's chip copy (C3), verbatim.
    public static let capturingChip = "Headset is in call mode — quality reduced"

    /// The pill chip line.
    public var chip: String {
        switch kind {
        case .capturing:
            return Self.capturingChip
        case .avoided:
            guard let using else { return Self.capturingChip }
            return "Headset is in call mode — using \(using.name)"
        }
    }

    /// Reason code for diagnostics (no device names).
    public var reasonCode: String { "narrowbandInput.\(kind.rawValue)" }

    public var logLine: String {
        switch kind {
        case .capturing:
            return "audio: capturing from \(headset.name) at \(Int(headset.sampleRate)) Hz (Bluetooth call mode) — chip shown"
        case .avoided:
            return "audio: avoided \(headset.name) (\(Int(headset.sampleRate)) Hz Bluetooth call mode), using \(using?.name ?? "-") — chip shown"
        }
    }

    /// The notice for a capture on `device` after a decision that avoided `avoided` (nil = none).
    /// Landing on a narrowband mic wins: it is the case that costs the user accuracy.
    public static func evaluate(device: AudioDeviceInfo?, avoided: AudioDeviceInfo?) -> NarrowbandInputNotice? {
        if let device, BluetoothInputDetector.mode(for: device).isNarrowbandSpeech {
            return NarrowbandInputNotice(kind: .capturing, headset: device)
        }
        if let avoided, BluetoothInputDetector.mode(for: avoided).isNarrowbandSpeech, avoided.uid != device?.uid {
            return NarrowbandInputNotice(kind: .avoided, headset: avoided, using: device)
        }
        return nil
    }

    /// The notice for whatever `source` is capturing from right now.
    public static func evaluate(source: any AudioCaptureSource) -> NarrowbandInputNotice? {
        evaluate(device: source.device, avoided: (source as? NarrowbandInputReporting)?.avoidedNarrowbandInput)
    }
}

/// V5 C3 — how often the chip is shown. `.capturing` is shown on every turn (each one *is* reduced);
/// `.avoided` is informational, so once per headset per app session — and again if the headset is
/// later captured from and then avoided again. Not thread-safe: one owner (the main actor).
public struct NarrowbandNoticeGate: Sendable {
    private var announcedAvoided: Set<String> = []

    public init() {}

    public mutating func shouldShow(_ notice: NarrowbandInputNotice?) -> Bool {
        guard let notice else { return false }
        switch notice.kind {
        case .capturing:
            announcedAvoided.remove(notice.headset.uid)
            return true
        case .avoided:
            return announcedAvoided.insert(notice.headset.uid).inserted
        }
    }
}
