import CoreAudio
import Foundation
import Shared

// V5 M1–M4 — meeting capture modes.
//
// A meeting is one of three shapes, and each needs different legs:
//   * video call (M1)  — the user on the laptop, everyone else in system audio: both legs, the
//     system leg is the echo-cancellation reference for the mic, both legs diarized.
//   * in person (M2)   — everyone in the room: the microphone alone, diarized. System audio is not
//     opened at all (nothing to hear there, and nothing to capture that the user did not mean to).
//   * hybrid (M3)      — people in the room *and* on a call played through speakers: both legs, and
//     the room mic also hears the far end. The cross-leg echo veto drops a mic-leg line when the
//     system leg carried energy within 150 ms of it and said the same words.
// Auto-pick (M4): system audio playing ∧ a call app frontmost → video call; otherwise in person.
// The user overrides it from the meeting panel's header. Live transcript (M15) is unchanged.

/// How a meeting is captured (V5 M1 / M2 / M3).
public enum MeetingMode: String, Codable, CaseIterable, Sendable {
    case videoCall, inPerson, hybrid

    /// The panel header's pill.
    public var label: String {
        switch self {
        case .videoCall: return "Video call"
        case .inPerson: return "In person"
        case .hybrid: return "Hybrid"
        }
    }

    /// One line for the mode menu: what each mode records.
    public var explanation: String {
        switch self {
        case .videoCall: return "Your microphone and the call's audio."
        case .inPerson: return "Your microphone only — everyone in the room."
        case .hybrid: return "Room microphone and call audio; call voices heard twice are kept once."
        }
    }

    public var systemImage: String {
        switch self {
        case .videoCall: return "video"
        case .inPerson: return "person.2"
        case .hybrid: return "person.2.wave.2"
        }
    }

    /// The legs this mode opens and how they are treated.
    public var legs: MeetingLegConfig {
        switch self {
        case .videoCall: return MeetingLegConfig(capturesSystem: true, cancelsEcho: true, echoVeto: false)
        case .inPerson: return MeetingLegConfig(capturesSystem: false, cancelsEcho: false, echoVeto: false)
        case .hybrid: return MeetingLegConfig(capturesSystem: true, cancelsEcho: true, echoVeto: true)
        }
    }
}

/// What `DualCapture` and `MeetingSession` do for a mode.
public struct MeetingLegConfig: Equatable, Sendable {
    /// System audio is opened, chunked and transcribed (and is the AEC reference).
    public var capturesSystem: Bool
    /// The mic leg runs through the echo canceller with the system leg as reference.
    public var cancelsEcho: Bool
    /// Cross-leg echo veto on transcribed text (hybrid).
    public var echoVeto: Bool

    public init(capturesSystem: Bool, cancelsEcho: Bool, echoVeto: Bool) {
        self.capturesSystem = capturesSystem; self.cancelsEcho = cancelsEcho; self.echoVeto = echoVeto
    }

    /// The legs that carry audio in this mode (and are diarized, and saved by M5).
    public var channels: [MeetingChannel] { capturesSystem ? [.mic, .system] : [.mic] }
}

// MARK: - M4 auto-pick

/// What the auto-pick looks at when a meeting starts.
public struct MeetingModeSignals: Equatable, Sendable {
    /// Something is playing through the default output device.
    public var systemAudioActive: Bool
    /// The frontmost app is a call app (or a browser on a meeting tab).
    public var callAppFrontmost: Bool
    public init(systemAudioActive: Bool, callAppFrontmost: Bool) {
        self.systemAudioActive = systemAudioActive; self.callAppFrontmost = callAppFrontmost
    }
}

public enum MeetingModePicker {
    /// M4: system audio active ∧ call app frontmost → video call; else in person. Hybrid is only ever
    /// the user's choice (nothing on the Mac can tell that a call is also being heard by a room).
    public static func pick(_ signals: MeetingModeSignals) -> MeetingMode {
        signals.systemAudioActive && signals.callAppFrontmost ? .videoCall : .inPerson
    }

    /// The call-app half of the signal: the frontmost bundle id is a known call app, or a browser
    /// while the detected meeting came from a browser tab.
    public static func isCallAppFrontmost(bundleID: String?, detectedFromBrowser: Bool = false) -> Bool {
        guard let bundleID else { return false }
        if CallAppCatalog.app(for: bundleID) != nil { return true }
        return detectedFromBrowser && BrowserMeetingClassifier.isBrowser(bundleID)
    }
}

/// Is anything playing through the default output device? (`kAudioDevicePropertyDeviceIsRunningSomewhere`
/// on the default output: true while any process renders audio to it.) Hardware read — untested in CI.
public enum SystemOutputActivity {
    public static func isPlaying() -> Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

// MARK: - M3 cross-leg echo veto

/// Hybrid rooms hear the far end twice: clean in system audio, and again through the room mic. A
/// mic-leg line is a duplicate when the system leg carried energy within `window` (150 ms) of it
/// *and* a system-leg line overlapping it (± `window`) said the same words. Both are required: words
/// alone would veto a person in the room repeating the call; energy alone would veto someone talking
/// over the call.
public enum MeetingEchoVeto {
    public static let window: TimeInterval = 0.150
    /// Share of the mic line's words that must appear in the system line.
    public static let minimumOverlap: Double = 0.6

    /// Did the system leg have energy within `window` of `range`?
    public static func systemEnergyNear(_ range: ClosedRange<TimeInterval>, activity: [ClosedRange<TimeInterval>]) -> Bool {
        let lo = range.lowerBound - window, hi = range.upperBound + window
        return activity.contains { $0.lowerBound <= hi && $0.upperBound >= lo }
    }

    /// Is `mic` the same words as some system-leg line overlapping it in time (± `window`)?
    public static func duplicates(_ mic: MeetingUtterance, of system: [MeetingUtterance]) -> Bool {
        let micWords = words(mic.text)
        guard !micWords.isEmpty else { return false }
        let lo = mic.range.lowerBound - window, hi = mic.range.upperBound + window
        return system.contains { s in
            guard s.range.lowerBound <= hi, s.range.upperBound >= lo else { return false }
            let sys = Set(words(s.text))
            let shared = micWords.filter(sys.contains).count
            return Double(shared) / Double(micWords.count) >= minimumOverlap
        }
    }

    /// The veto: energy within the window and duplicated words.
    public static func vetoes(_ mic: MeetingUtterance, systemActivity: [ClosedRange<TimeInterval>],
                              systemLines: [MeetingUtterance]) -> Bool {
        systemEnergyNear(mic.range, activity: systemActivity) && duplicates(mic, of: systemLines)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }
}
