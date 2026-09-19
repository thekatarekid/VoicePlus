import AppKit
import Foundation

// S7g — the Settings subpages' own keys (design §8.6, `DESIGN.md` §9.6). The V4 rows the owner added
// (preview dwell, spacing, unknown-caret style, latch pause, draw-without-key) already have keys and
// readers from wave 1 / S3 (`TurnSettings`, `FormattingSettings`, `LatchSettings`, `DeixisSettings`);
// this file holds only what the design's own rows need and nobody defined yet.
//
// Keys stay out of `SettingsStore.swift` (not S7g's file), in this extension, read and written
// through the `SettingsStore` protocol like every other setting.

public extension SettingsKeys {
    /// Design §8.6 "sound cues": off by default.
    static let soundCues = "sound.cues.enabled"
    /// Design §8.6 Shortcuts "Double-tap to latch": on by default (prototype `toggle('Latch',true)`).
    static let latchDoubleTap = "latch.doubleTap.enabled"
    /// Appearance: `WindowTheme.rawValue` — follow system (default) · light · dark. Windows only.
    static let windowTheme = "appearance.theme"
    /// Appearance: reduce motion in VoicePlus even while macOS's own switch is off. Default off.
    static let reduceMotion = "appearance.reduceMotion"
    /// Appearance: `WindowTextSize.rawValue` — default · large · larger.
    static let windowTextSize = "appearance.textSize"
    /// Models: the display name of the recogniser that was last verified *and* loaded.
    static let lastWorkingModel = "models.lastWorking"
    /// Sync: `SyncDevice` list (JSON) — the devices this Mac has paired with.
    static let syncDevices = "sync.devices"
    /// Sync: paused by the user. While paused nothing is pushed or pulled.
    static let syncPaused = "sync.paused"
    /// Sync: when the last successful round finished (ISO 8601).
    static let syncLastRound = "sync.lastRound"
}

// MARK: - Sound cues

/// Design §8.6 / `DESIGN.md` §9.6: sound cues are off by default, and there is no success sound before
/// a verified insertion. The policy is pure; `SoundCuePlayer` plays what it returns.
public enum SoundCueSettings {
    public static func isEnabled(_ store: SettingsStore?) -> Bool { store?.bool(SettingsKeys.soundCues) ?? false }
    public static func setEnabled(_ on: Bool, store: SettingsStore?) { store?.set(on, for: SettingsKeys.soundCues) }
}

/// The moments a cue may mark.
public enum SoundCueEvent: Equatable, Sendable {
    /// The microphone actually opened (not key-down: `Starting` is not listening).
    case captureOpened
    /// The microphone closed at the end of a turn.
    case captureClosed
    /// The turn's text landed; `verified` is the readback's answer.
    case delivered(verified: Bool)
    /// Anything that did not land (held, failed, cancelled, partial).
    case notDelivered
}

public enum SoundCue: String, CaseIterable, Sendable {
    case start, stop, success

    /// System sounds (`/System/Library/Sounds`), quiet and short.
    public var systemSoundName: String {
        switch self {
        case .start: return "Tink"
        case .stop: return "Pop"
        case .success: return "Glass"
        }
    }
}

public enum SoundCuePolicy {
    /// Nil when cues are off, and for every outcome that is not a verified insertion — an unconfirmed
    /// or held turn never sounds like success.
    public static func cue(for event: SoundCueEvent, enabled: Bool) -> SoundCue? {
        guard enabled else { return nil }
        switch event {
        case .captureOpened: return .start
        case .captureClosed: return .stop
        case .delivered(let verified): return verified ? .success : nil
        case .notDelivered: return nil
        }
    }
}

/// Plays the policy's cue. The composition root calls `play(_:store:)` at the turn's transitions.
public enum SoundCuePlayer {
    @discardableResult
    public static func play(_ event: SoundCueEvent, store: SettingsStore?,
                            sink: (SoundCue) -> Void = { NSSound(named: NSSound.Name($0.systemSoundName))?.play() }) -> SoundCue? {
        guard let cue = SoundCuePolicy.cue(for: event, enabled: SoundCueSettings.isEnabled(store)) else { return nil }
        sink(cue)
        return cue
    }
}

// MARK: - Double-tap to latch

/// Design §8.6 Shortcuts "Double-tap to latch". With it off, a double tap is two short taps: both
/// cancel, nothing latches. `filter` is what the hotkey path applies to the state machine's actions.
public enum LatchGestureSettings {
    public static func isEnabled(_ store: SettingsStore?) -> Bool { store?.bool(SettingsKeys.latchDoubleTap) ?? true }
    public static func setEnabled(_ on: Bool, store: SettingsStore?) { store?.set(on, for: SettingsKeys.latchDoubleTap) }

    public static func filter(_ actions: [HotkeyStateMachine.Action], enabled: Bool) -> [HotkeyStateMachine.Action] {
        guard !enabled else { return actions }
        return actions.map { $0 == .enterLatch ? .cancelCapture : $0 }
    }
}

// MARK: - Appearance (windows only; the pill stays dark)

/// Follow system / light / dark for VoicePlus's windows. The pill and Spool never follow it
/// (`Tokens.Pill` is fixed dark), and nothing moves: the pill keeps its top-centre place in every mode.
public enum WindowTheme: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "Follow system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` follows the system.
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

/// Larger Text for the window's type roles (`windowTextScale`). The pill keeps its sizes.
public enum WindowTextSize: String, CaseIterable, Identifiable, Sendable {
    case standard, large, larger

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Default"
        case .large: return "Large"
        case .larger: return "Larger"
        }
    }

    public var scale: CGFloat {
        switch self {
        case .standard: return 1
        case .large: return 1.15
        case .larger: return 1.3
        }
    }
}

public enum AppearanceSettings {
    public static func theme(_ store: SettingsStore?) -> WindowTheme {
        store?.string(SettingsKeys.windowTheme).flatMap(WindowTheme.init(rawValue:)) ?? .system
    }

    public static func setTheme(_ theme: WindowTheme, store: SettingsStore?) {
        store?.set(theme.rawValue, for: SettingsKeys.windowTheme)
    }

    /// The app's own switch. Motion is reduced when this *or* macOS's Reduce Motion is on.
    public static func reducesMotion(_ store: SettingsStore?) -> Bool { store?.bool(SettingsKeys.reduceMotion) ?? false }

    public static func setReducesMotion(_ on: Bool, store: SettingsStore?) { store?.set(on, for: SettingsKeys.reduceMotion) }

    /// What every animated surface should honour: never less than the system asks for.
    public static func effectiveReduceMotion(_ store: SettingsStore?,
                                             system: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> Bool {
        system || reducesMotion(store)
    }

    public static func textSize(_ store: SettingsStore?) -> WindowTextSize {
        store?.string(SettingsKeys.windowTextSize).flatMap(WindowTextSize.init(rawValue:)) ?? .standard
    }

    public static func setTextSize(_ size: WindowTextSize, store: SettingsStore?) {
        store?.set(size.rawValue, for: SettingsKeys.windowTextSize)
    }

    /// Applies the window theme app-wide. Menus, the onboarding window and popovers follow it; the
    /// pill does not (its colours are fixed dark). Safe with no `NSApp` (tests).
    @MainActor
    public static func apply(_ theme: WindowTheme) {
        guard let app = NSApp else { return }
        app.appearance = theme.appearanceName.flatMap(NSAppearance.init(named:))
    }

    public static var allKeys: [String] { [SettingsKeys.windowTheme, SettingsKeys.reduceMotion, SettingsKeys.windowTextSize] }
}
