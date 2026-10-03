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
        /// X3-taps (owner round 3, "Short presses") — while the notch shows something that is not a
        /// live capture, a press up to this long is a tap (it dismisses), not a hold.
        public var visibleTapCeiling: TimeInterval
        public init(holdThreshold: TimeInterval = 0.250, tapGuard: TimeInterval = 0.180, doubleTapWindow: TimeInterval = 0.350,
                    visibleTapCeiling: TimeInterval = 0.800) {
            self.holdThreshold = holdThreshold
            self.tapGuard = tapGuard
            self.doubleTapWindow = doubleTapWindow
            self.visibleTapCeiling = visibleTapCeiling
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
    /// X3-taps — the current (or last) press went down while the notch showed something that is not
    /// a live capture. Such a press up to `visibleTapCeiling` ends as a tap that dismisses.
    public private(set) var pressOverSurface = false

    public init(timing: Timing = .default) { self.timing = timing }

    public var isCapturing: Bool {
        switch phase {
        case .idle: return false
        case .keyDown, .latched: return true
        }
    }

    /// `surfaceShowing`: X3-taps — the notch shows something that is not a live capture (a hint, a
    /// notice, an outcome row) as the key goes down.
    @discardableResult
    public mutating func keyDown(at t: TimeInterval, surfaceShowing: Bool = false) -> [Action] {
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
            pressOverSurface = surfaceShowing
            return [.startCapture]
        }
    }

    @discardableResult
    public mutating func keyUp(at t: TimeInterval) -> [Action] {
        guard case .keyDown(let since) = phase else { return [] }
        let duration = t - since
        // X3-taps — over a visible notch, a press up to ~0.8 s is a tap: it dismisses, never
        // finalizes and never arms a double-tap. Longer still holds (Q3.2: a hold always wins).
        if pressOverSurface, duration >= timing.holdThreshold, duration <= timing.visibleTapCeiling {
            phase = .idle
            lastTapUp = nil
            return [.cancelCapture]
        }
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

    /// K02 (design §5 "lost key-up", §13 scenario 9) — the key is no longer down but its key-up never
    /// arrived: a secure-input switch or a stalled listener swallowed it. Without this the machine
    /// would stay in `.keyDown` and drop every later key-down as key repeat, leaving capture open.
    /// Ends the press as its key-up would at `t` (when the real modifier state was read), except
    /// that a synthesized release never arms or enters Latch: a hold past the threshold finalizes
    /// (its words are kept), anything shorter cancels. Nothing outside `.keyDown`.
    @discardableResult
    public mutating func lostKeyUp(at t: TimeInterval) -> [Action] {
        guard case .keyDown(let since) = phase else { return [] }
        phase = .idle
        lastTapUp = nil
        return t - since >= timing.holdThreshold ? [.finalize] : [.cancelCapture]
    }

    /// External reset (e.g. engine error, permission lost).
    public mutating func reset() {
        phase = .idle
        lastTapUp = nil
        pressOverSurface = false
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

        /// The key in running copy. Spelled the way the design's prose names keys ("Right Control",
        /// "Control + Option + D"), so the design's own default renders its fixture strings
        /// verbatim; fn keeps the build doc's "fn / 🌐". `displayName` stays the compact picker form.
        public var label: String {
            switch self {
            case .rightOption: return "Right Option"
            case .leftOption: return "Left Option"
            case .rightCommand: return "Right Command"
            case .rightControl: return "Right Control"
            case .fn: return "fn / 🌐"
            case .controlOptionD: return "Control + Option + D"
            case .controlOptionA: return "Control + Option + A"
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
    public init(kind: Kind = .fn) { self.kind = kind }
    /// V4.51 (owner decision, build doc §0) — the dictation key an install with no stored choice
    /// gets is fn / 🌐: hold to dictate, double tap to latch. It was Right ⌥ through 1.10. A stored
    /// binding always wins (`HotkeyService.storedBinding`), so anyone who picked a key keeps it.
    public static let `default` = HotkeyBinding(kind: .fn)

    public var style: Style { kind.style }

    /// The key as every hint names it: "fn / 🌐", "Right Option", "Control + Option + D".
    public var label: String { kind.label }

    /// The I1 hover hint for this key — "Hold or Double Tap fn / 🌐 to dictate", or
    /// "Hold fn / 🌐 to dictate" when the double-tap latch is off (design §5).
    public func readyHint(latchEnabled: Bool = true) -> String {
        PillState.readyHint(key: label, latchEnabled: latchEnabled)
    }

    /// Prototype copy with its "Right Control" replaced by this key's label and nothing else
    /// changed (owner decision, build doc §0). Identity for a Right Control binding.
    public func rendering(_ prototypeCopy: String) -> String {
        PillState.withHotkey(prototypeCopy, key: label)
    }

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

// MARK: - fn / 🌐 as the dictation key (V4.51)

/// What macOS itself does when 🌐 / fn is pressed — System Settings › Keyboard › "Press 🌐 key to",
/// stored as `AppleFnUsageType` in the `com.apple.HIToolbox` domain.
///
/// Anything but "Do Nothing" fights the fn binding: a double tap (Latch) opens the emoji picker,
/// switches the input source or starts Apple Dictation on top of VoicePlus. Onboarding and Settings
/// (S8 / S7g) show the conflict prompt when `conflictsWithDictationKey` is true.
public enum FnKeySystemAction: Equatable, Sendable {
    /// 0 — the only value that leaves fn to VoicePlus.
    case doNothing
    /// 1
    case changeInputSource
    /// 2
    case showEmojiAndSymbols
    /// 3
    case startDictation
    /// No value stored: macOS applies its own default, which is an action, never "Do Nothing".
    case systemDefault
    /// A value this build does not know. Still not 0, so still a conflict.
    case unrecognised(Int)

    public static let defaultsDomain = "com.apple.HIToolbox"
    public static let defaultsKey = "AppleFnUsageType"

    public init(usageType: Int?) {
        switch usageType {
        case nil: self = .systemDefault
        case 0?: self = .doNothing
        case 1?: self = .changeInputSource
        case 2?: self = .showEmojiAndSymbols
        case 3?: self = .startDictation
        case let other?: self = .unrecognised(other)
        }
    }

    /// The raw `AppleFnUsageType` value, nil when none is stored.
    public var usageType: Int? {
        switch self {
        case .doNothing: return 0
        case .changeInputSource: return 1
        case .showEmojiAndSymbols: return 2
        case .startDictation: return 3
        case .systemDefault: return nil
        case .unrecognised(let value): return value
        }
    }

    /// `AppleFnUsageType != 0` (a missing value counts: the system default is an action).
    public var conflictsWithDictationKey: Bool { self != .doNothing }

    /// What the key does besides dictation, as the end of "The 🌐 key also …".
    var clause: String {
        switch self {
        case .doNothing: return "does nothing"
        case .changeInputSource: return "changes the input source"
        case .showEmojiAndSymbols: return "shows Emoji & Symbols"
        case .startDictation: return "starts Apple Dictation"
        case .systemDefault, .unrecognised: return "runs a macOS action"
        }
    }
}

/// The one-line prompt S7g / S8 render when fn is the dictation key and macOS also acts on it.
/// Problem — Action copy (DESIGN.md §7.1); the button opens the Keyboard pane.
public struct FnKeyConflict: Equatable, Sendable {
    public let systemAction: FnKeySystemAction

    /// nil when there is nothing to warn about.
    public init?(_ systemAction: FnKeySystemAction) {
        guard systemAction.conflictsWithDictationKey else { return nil }
        self.systemAction = systemAction
    }

    public var headline: String { "The 🌐 key also \(systemAction.clause)" }
    public var detail: String { "Set “Press 🌐 key to” to Do Nothing so a double tap starts Latch." }
    public static let actionTitle = "Open Keyboard settings"
    /// System Settings › Keyboard (macOS 13+ settings-extension URL; the app targets 14+).
    public static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
}

/// Onboarding's key test for fn (S8 renders it). External, non-Apple keyboards often handle fn in
/// their own firmware and never report it to macOS, so a user can press it forever and nothing
/// arrives. After `attemptsBeforeFallback` prompted presses with no fn event at all, the test
/// offers Right ⌥ instead. One fn event anywhere confirms the key for good.
///
/// An *attempt* is counted by the key test (one prompt cycle: the user was asked to press and the
/// window elapsed, or they said they pressed) — an unreported fn press has no event to count.
public struct FnKeyProbe: Equatable, Sendable {
    public static let attemptsBeforeFallback = 3
    public static let fallback: HotkeyBinding.Kind = .rightOption

    public enum Verdict: Equatable, Sendable {
        /// Keep asking; `attempts` prompted presses so far without an fn event.
        case waiting(attempts: Int)
        /// fn events arrive: keep fn.
        case confirmed
        /// No fn event in `attemptsBeforeFallback` presses: offer this key instead.
        case offerFallback(HotkeyBinding.Kind)
    }

    public private(set) var attempts = 0
    public private(set) var fnSeen = false

    public init() {}

    public var verdict: Verdict {
        if fnSeen { return .confirmed }
        if attempts >= Self.attemptsBeforeFallback { return .offerFallback(Self.fallback) }
        return .waiting(attempts: attempts)
    }

    /// An fn `flagsChanged` edge arrived (`HotkeyService.onFnEvent`).
    @discardableResult
    public mutating func noteFnEvent() -> Verdict {
        fnSeen = true
        return verdict
    }

    /// One prompted press elapsed. Ignored once fn is confirmed or the fallback is already offered.
    @discardableResult
    public mutating func notePromptedPress() -> Verdict {
        if case .waiting = verdict { attempts += 1 }
        return verdict
    }

    /// "Try again": forget the attempts, keep a confirmation.
    public mutating func reset() { attempts = 0 }
}
