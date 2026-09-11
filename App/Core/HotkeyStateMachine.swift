import Foundation

/// Pure hotkey gesture recogniser (T3). Fed key-down/key-up timestamps, emits dictation actions.
/// Timing constants are Muesli-validated: hold threshold 250 ms, tap guard 180 ms, double-tap window 350 ms.
///
/// Gestures:
/// - Hold (≥ holdThreshold): capture starts on key-down, finalizes on key-up.
/// - Tap (< holdThreshold): capture is cancelled on key-up; a tap shorter than `tapGuard` counts toward a double-tap.
/// - Double-tap (two guarded taps within `doubleTapWindow`): **latch** — capture keeps running after
///   key-up, and endpoints close segments while listening continues (V3 §4.3).
/// - Any key-down while latched: a single tap stops and finalizes, leaving latch.
public struct HotkeyStateMachine: Equatable, Sendable {
    public struct Timing: Equatable, Sendable {
        public var holdThreshold: TimeInterval
        public var tapGuard: TimeInterval
        public var doubleTapWindow: TimeInterval
        public init(holdThreshold: TimeInterval = 0.250, tapGuard: TimeInterval = 0.180, doubleTapWindow: TimeInterval = 0.350) {
            self.holdThreshold = holdThreshold
            self.tapGuard = tapGuard
            self.doubleTapWindow = doubleTapWindow
        }
        public static let `default` = Timing()
    }

    public enum Action: Equatable, Sendable {
        /// Begin capture (key went down; pill should appear immediately).
        case startCapture
        /// Key released after a hold, or latch stopped: finalize the utterance.
        case finalize
        /// Key released too early: abort without text.
        case cancelCapture
        /// Second quick tap detected — latch: keep capturing until the next key-down. R3.1 renamed
        /// V3 §4.7 names this mode "latched" — the user-facing word is Latch.
        case enterLatch
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case keyDown(since: TimeInterval)
        /// Latched: capture continues with no key held (R3.1).
        case latched
    }

    public let timing: Timing
    public private(set) var phase: Phase = .idle
    /// Time of the last key-up that qualified as a guarded tap; `nil` once consumed or expired.
    public private(set) var lastTapUp: TimeInterval?

    public init(timing: Timing = .default) { self.timing = timing }

    public var isCapturing: Bool {
        switch phase {
        case .idle: return false
        case .keyDown, .latched: return true
        }
    }

    @discardableResult
    public mutating func keyDown(at t: TimeInterval) -> [Action] {
        switch phase {
        case .keyDown:
            return [] // key repeat — ignore
        case .latched:
            // A single tap while latched stops and finalizes (V3 §4.3).
            phase = .idle
            lastTapUp = nil
            return [.finalize]
        case .idle:
            phase = .keyDown(since: t)
            return [.startCapture]
        }
    }

    @discardableResult
    public mutating func keyUp(at t: TimeInterval) -> [Action] {
        guard case .keyDown(let since) = phase else { return [] }
        let duration = t - since
        if duration >= timing.holdThreshold {
            phase = .idle
            lastTapUp = nil
            return [.finalize]
        }
        if duration < timing.tapGuard {
            if let previous = lastTapUp, t - previous <= timing.doubleTapWindow {
                phase = .latched
                lastTapUp = nil
                return [.enterLatch]
            }
            lastTapUp = t
            phase = .idle
            return [.cancelCapture]
        }
        // Ambiguous press: neither a clean tap nor a hold. Cancel; does not arm a double-tap.
        phase = .idle
        lastTapUp = nil
        return [.cancelCapture]
    }

    /// External reset (e.g. engine error, permission lost).
    public mutating func reset() {
        phase = .idle
        lastTapUp = nil
    }
}

// MARK: - What triggers dictation, and what it costs in permissions

/// The system API a binding is delivered through.
///
/// This enum exists because the *mechanism* — not the gesture, not the key — is what decides whether
/// VoicePlus has to appear in Privacy & Security › Input Monitoring. All three deliver the same
/// down/up edges to the same `HotkeyStateMachine`; they differ only in what macOS charges for them.
///
/// Measured on this machine (macOS 26.6.2, arm64) from a throwaway ad-hoc-signed `LSUIElement`
/// bundle with **no TCC record at all** (`tccutil` answers "No such bundle identifier", and the
/// process reports `AXIsProcessTrusted()==false`, `CGPreflightListenEventAccess()==false`):
///
/// | mechanism                              | at zero grants                                   |
/// |----------------------------------------|--------------------------------------------------|
/// | `NSEvent.addGlobalMonitorForEvents`    | installs and **delivers** `flagsChanged`          |
/// | `RegisterEventHotKey` (chord)          | `status=0`; a duplicate returns `-9878`, so the   |
/// |                                        | registration is genuinely system-wide             |
/// | `CGEvent.tapCreate(.listenOnly)`       | non-NULL port, `tapIsEnabled == false`, 0 events  |
/// | `CGEvent.tapCreate(.defaultTap)`       | returns **NULL** outright (wants Accessibility)   |
///
/// The trap worth naming: `RegisterEventHotKey` accepts a *bare modifier* registration
/// (`kVK_RightOption`, no modifier mask) and returns `status=0` with a valid ref — and then never
/// fires. Anyone who tests only the return code concludes it works. Hence `HotkeyBackendSelector`
/// routes by `HotkeyBinding.Kind.style`, never by "did registration succeed".
public enum HotkeyBackendKind: String, Codable, Equatable, Sendable, CaseIterable {
    /// `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`. Sees bare modifier transitions
    /// in every app. No TCC service is consulted.
    case globalMonitor
    /// Carbon `RegisterEventHotKey` + `InstallEventHandler`, for chords only. Delivers
    /// `kEventHotKeyPressed` *and* `kEventHotKeyReleased`, so hold-to-talk works. No TCC service.
    case carbon
    /// `CGEvent.tapCreate(options: .listenOnly)` — what shipped through 1.6.7. The one global-input
    /// API gated on `kTCCServiceListenEvent`, and therefore the only one that costs the user a trip
    /// to Input Monitoring *and* a forced quit-and-relaunch.
    case eventTap

    /// The TCC service this mechanism needs, or nil when it needs none.
    public var requiredPermission: Permission? {
        switch self {
        case .globalMonitor, .carbon: return nil
        case .eventTap: return .inputMonitoring
        }
    }

    /// Does a grant for this backend only reach the app at launch? Only `kTCCServiceListenEvent`
    /// carries `quitAllowTitleForAppName` in Apple's own `PrivacyTCCServices.plist`, which is why
    /// this is a property of the backend and not of the app.
    public var needsRelaunchAfterGrant: Bool {
        requiredPermission?.grantReachesRunningApp == false
    }

    public var displayName: String {
        switch self {
        case .globalMonitor: return "Global key monitor"
        case .carbon: return "System hotkey"
        case .eventTap: return "Event tap"
        }
    }
}

/// Which key triggers dictation. Persisted in UserDefaults by `HotkeyService`.
public struct HotkeyBinding: Codable, Equatable, Sendable {
    /// Bare modifier vs. chord. The distinction is load-bearing: a chord can be registered with
    /// Carbon, a bare modifier cannot (it registers and silently never fires — measured).
    public enum Style: String, Codable, Equatable, Sendable { case bareModifier, chord }

    /// A Carbon hotkey: a virtual key code plus a Carbon modifier mask.
    ///
    /// The constants are spelled out rather than imported so `App/Core` stays free of Carbon;
    /// `HotkeyChordConstantsTests` asserts each one against the real `Carbon.HIToolbox` value, so a
    /// typo here is a test failure and not a hotkey that never fires.
    public struct Chord: Equatable, Sendable {
        /// `kVK_*`
        public var keyCode: UInt32
        /// `controlKey | optionKey | …`
        public var carbonModifiers: UInt32
        public init(keyCode: UInt32, carbonModifiers: UInt32) {
            self.keyCode = keyCode
            self.carbonModifiers = carbonModifiers
        }
        /// `cmdKey`
        public static let command: UInt32 = 0x0100
        /// `shiftKey`
        public static let shift: UInt32 = 0x0200
        /// `optionKey`
        public static let option: UInt32 = 0x0800
        /// `controlKey`
        public static let control: UInt32 = 0x1000
        /// `kVK_ANSI_D`
        public static let keyD: UInt32 = 0x02
        /// `kVK_ANSI_A`
        public static let keyA: UInt32 = 0x00
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rightOption, leftOption, rightCommand, rightControl, fn
        /// ⌃⌥D — a chord, so it runs on Carbon and needs no permission at all.
        case controlOptionD
        /// ⌃⌥A — the chord counterpart for the act key.
        case controlOptionA

        public var displayName: String {
            switch self {
            case .rightOption: return "Right ⌥"
            case .leftOption: return "Left ⌥"
            case .rightCommand: return "Right ⌘"
            case .rightControl: return "Right ⌃"
            case .fn: return "fn / 🌐"
            case .controlOptionD: return "⌃⌥D"
            case .controlOptionA: return "⌃⌥A"
            }
        }

        public var style: Style {
            switch self {
            case .rightOption, .leftOption, .rightCommand, .rightControl, .fn: return .bareModifier
            case .controlOptionD, .controlOptionA: return .chord
            }
        }

        /// macOS virtual key code delivered by `flagsChanged` events. Meaningless for a chord.
        public var keyCode: Int64 {
            switch self {
            case .rightOption: return 61
            case .leftOption: return 58
            case .rightCommand: return 54
            case .rightControl: return 62
            case .fn: return 63
            case .controlOptionD, .controlOptionA: return -1
            }
        }

        /// Bit in `CGEventFlags` / `NSEvent.modifierFlags` that is set while the key is held.
        ///
        /// `NSEvent.modifierFlags.rawValue` and `CGEventFlags.rawValue` are the same bit word — the
        /// device-independent masks occupy the same positions — which is what lets one
        /// `edge(keyCode:flags:)` serve both the global-monitor and the event-tap backend.
        /// `HotkeyBackendFlagWordTests` pins that equivalence.
        public var flagMask: UInt64 {
            switch self {
            case .rightOption, .leftOption: return 0x0008_0000 // maskAlternate
            case .rightCommand: return 0x0010_0000           // maskCommand
            case .rightControl: return 0x0004_0000           // maskControl
            case .fn: return 0x0080_0000                     // maskSecondaryFn
            case .controlOptionD, .controlOptionA: return 0
            }
        }

        /// The Carbon registration for a chord binding; nil for a bare modifier — and deliberately
        /// nil, because `RegisterEventHotKey` would *accept* a bare-modifier registration and then
        /// never fire.
        public var chord: Chord? {
            switch self {
            case .rightOption, .leftOption, .rightCommand, .rightControl, .fn: return nil
            case .controlOptionD: return Chord(keyCode: Chord.keyD, carbonModifiers: Chord.control | Chord.option)
            case .controlOptionA: return Chord(keyCode: Chord.keyA, carbonModifiers: Chord.control | Chord.option)
            }
        }
    }

    public var kind: Kind
    public init(kind: Kind = .rightOption) { self.kind = kind }
    public static let `default` = HotkeyBinding()

    public var style: Style { kind.style }

    /// Classifies a modifier `flagsChanged` event (key code + resulting flags) as press/release of
    /// this binding. Always nil for a chord: chords arrive as Carbon press/release callbacks, not as
    /// flag words.
    public func edge(keyCode: Int64, flags: UInt64) -> Edge? {
        guard kind.style == .bareModifier, keyCode == kind.keyCode else { return nil }
        return (flags & kind.flagMask) != 0 ? .down : .up
    }

    public enum Edge: Equatable, Sendable { case down, up }
}

// MARK: - Which mechanism serves which binding

/// Pure backend-selection rule — the whole of "does VoicePlus need Input Monitoring?" in one place.
///
/// Nothing the user can pick from the shipped picker selects `.eventTap`. It stays reachable only
/// through the `hotkeyForceEventTap` escape hatch, so an install that hits an unforeseen
/// global-monitor failure has a way back without a new build — and *that* is the only path on which
/// Input Monitoring is required.
public enum HotkeyBackendSelector {
    public static func kind(for binding: HotkeyBinding, forceEventTap: Bool = false) -> HotkeyBackendKind {
        switch binding.style {
        case .chord:
            // A chord cannot be read off a flags word, and an event tap on `.flagsChanged` would
            // never see it either. Carbon is the only mechanism that serves it.
            return .carbon
        case .bareModifier:
            return forceEventTap ? .eventTap : .globalMonitor
        }
    }

    /// The permission a given binding costs, under the current escape-hatch setting. nil for every
    /// binding the shipped UI can produce.
    public static func requiredPermission(for binding: HotkeyBinding, forceEventTap: Bool = false) -> Permission? {
        kind(for: binding, forceEventTap: forceEventTap).requiredPermission
    }
}
