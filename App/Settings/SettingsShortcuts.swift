import AppKit
import Foundation

// S7g — Settings › Shortcuts (design §8.6): the key recorder and its conflict result, and the
// shortcut test area. The rules are pure (`ShortcutRecorder`, `ShortcutTestProbe`) so they are unit
// tests; `ShortcutsPageModel` only feeds them key events from a *local* monitor, which sees keys
// only while the VoicePlus window is key — no permission, and nothing reaches other apps.

// MARK: - Recorder

/// What one key press meant to the recorder.
public enum ShortcutCapture: Equatable, Sendable {
    /// A key VoicePlus can bind.
    case key(HotkeyBinding.Kind)
    /// A key it cannot, named the way a person would ("Left Command").
    case unsupported(String)
    /// Escape: stop recording, change nothing.
    case cancelled
}

/// The recorder's result, said in the Shortcuts row.
public enum ShortcutChange: Equatable, Sendable {
    /// The same key again — nothing to change.
    case unchanged(HotkeyBinding.Kind)
    case changed(from: HotkeyBinding.Kind, to: HotkeyBinding.Kind)
    /// Design §8.6: "A conflict keeps your previous shortcut active." (K01)
    case conflict(attempted: HotkeyBinding.Kind, kept: HotkeyBinding.Kind, reason: String)
    /// A key that cannot be held for dictation; the previous shortcut stays.
    case unsupported(name: String, kept: HotkeyBinding.Kind)

    /// The binding in force after this result.
    public var active: HotkeyBinding.Kind {
        switch self {
        case .unchanged(let kind): return kind
        case .changed(_, let to): return to
        case .conflict(_, let kept, _), .unsupported(_, let kept): return kept
        }
    }

    public var isRefusal: Bool {
        switch self {
        case .conflict, .unsupported: return true
        case .unchanged, .changed: return false
        }
    }

    /// The row's banner for a refusal: K01's headline and consequence, and why.
    public var banner: SectionBanner? {
        let k01 = RecoveryCatalog.entry(.K01)
        switch self {
        case .conflict(_, _, let reason):
            return SectionBanner(headline: k01.headline, body: "\(reason) \(k01.consequence)", recoveryID: .K01)
        case .unsupported(let name, _):
            return SectionBanner(headline: ShortcutCopy.cannotHold(name),
                                 body: "\(ShortcutCopy.distinctModifiers) \(k01.consequence)", recoveryID: .K01)
        case .unchanged, .changed:
            return nil
        }
    }

    /// The confirmation line for a success.
    public var confirmation: String? {
        switch self {
        case .changed(_, let to): return ShortcutCopy.nowDictationKey(to.label)
        case .unchanged(let kind): return ShortcutCopy.alreadyDictationKey(kind.label)
        case .conflict, .unsupported: return nil
        }
    }
}

public enum ShortcutRecorder {
    /// `NSEvent.modifierFlags` / `CGEventFlags` bits (the same word; `HotkeyBackendFlagWordTests`).
    static let shiftMask: UInt64 = 0x0002_0000
    static let controlMask: UInt64 = 0x0004_0000
    static let optionMask: UInt64 = 0x0008_0000
    static let commandMask: UInt64 = 0x0010_0000
    static let capsLockMask: UInt64 = 0x0001_0000

    /// Modifier keys that exist but cannot be the dictation key: key code → (name, flag bit).
    /// Left and right modifiers are distinct (design §8.6), so Left Command is not Right Command.
    static let otherModifiers: [Int64: (name: String, mask: UInt64)] = [
        55: ("Left Command", commandMask),
        59: ("Left Control", controlMask),
        56: ("Left Shift", shiftMask),
        60: ("Right Shift", shiftMask),
        57: ("Caps Lock", capsLockMask),
    ]

    /// Escape's virtual key code.
    static let escapeKeyCode: UInt16 = 53

    /// A `flagsChanged` event: the press of a bindable modifier, the press of one that is not, or
    /// nil (a release, or a key the recorder ignores).
    public static func capture(flagsChangedKeyCode keyCode: Int64, flags: UInt64) -> ShortcutCapture? {
        if let kind = HotkeyBinding.Kind.allCases.first(where: { $0.style == .bareModifier && $0.keyCode == keyCode }) {
            return (flags & kind.flagMask) != 0 ? .key(kind) : nil
        }
        if let other = otherModifiers[keyCode] {
            return (flags & other.mask) != 0 ? .unsupported(other.name) : nil
        }
        return nil
    }

    /// A `keyDown` event: Escape cancels; a chord VoicePlus registers is bound; anything else is a
    /// key that types text and cannot be held for dictation. `characters` names it when known.
    public static func capture(keyDownKeyCode keyCode: UInt16, flags: UInt64, characters: String? = nil) -> ShortcutCapture {
        if keyCode == escapeKeyCode && carbonModifiers(flags) == 0 { return .cancelled }
        for kind in HotkeyBinding.Kind.allCases {
            if let chord = kind.chord, chord.keyCode == UInt32(keyCode), chord.carbonModifiers == carbonModifiers(flags) {
                return .key(kind)
            }
        }
        return .unsupported(describe(flags: flags, characters: characters))
    }

    /// The release of a modifier the recorder knows (bindable or not).
    public static func isRelease(flagsChangedKeyCode keyCode: Int64, flags: UInt64) -> Bool {
        if let kind = HotkeyBinding.Kind.allCases.first(where: { $0.style == .bareModifier && $0.keyCode == keyCode }) {
            return (flags & kind.flagMask) == 0
        }
        if let other = otherModifiers[keyCode] { return (flags & other.mask) == 0 }
        return false
    }

    /// The Carbon mask a chord registers with, from an event's flag word.
    static func carbonModifiers(_ flags: UInt64) -> UInt32 {
        var mask: UInt32 = 0
        if flags & controlMask != 0 { mask |= HotkeyBinding.Chord.control }
        if flags & optionMask != 0 { mask |= HotkeyBinding.Chord.option }
        if flags & commandMask != 0 { mask |= HotkeyBinding.Chord.command }
        if flags & shiftMask != 0 { mask |= HotkeyBinding.Chord.shift }
        return mask
    }

    static func describe(flags: UInt64, characters: String?) -> String {
        var symbols = ""
        if flags & controlMask != 0 { symbols += "⌃" }
        if flags & optionMask != 0 { symbols += "⌥" }
        if flags & shiftMask != 0 { symbols += "⇧" }
        if flags & commandMask != 0 { symbols += "⌘" }
        let key = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let name = symbols + key
        return name.isEmpty ? "That key" : name
    }

    /// Decides what a capture does to the binding. The Actions key is the one binding the dictation
    /// key must not take (both would arm on one key and dictation would silently win), so that is a
    /// conflict and the previous shortcut stays active.
    public static func resolve(_ capture: ShortcutCapture, current: HotkeyBinding.Kind,
                               actKey: ActKeyChoice) -> ShortcutChange? {
        switch capture {
        case .cancelled:
            return nil
        case .unsupported(let name):
            return .unsupported(name: name, kept: current)
        case .key(let kind):
            if kind == current { return .unchanged(kind) }
            if actKey == .key(HotkeyChoice(binding: kind)) {
                return .conflict(attempted: kind, kept: current, reason: ShortcutCopy.isActionsKey(kind.label))
            }
            return .changed(from: current, to: kind)
        }
    }
}

/// One recording session. A modifier counts only once it is released with no key typed while it
/// was down — so ⌃ then ⌥ then D records the chord ⌃⌥D rather than stopping at ⌃.
public struct ShortcutRecording: Equatable, Sendable {
    /// The last modifier pressed, waiting for its release.
    public private(set) var pending: ShortcutCapture?
    private var pendingKeyCode: Int64?

    public init() {}

    /// A `flagsChanged` event; returns the capture once the pending modifier is released.
    public mutating func flagsChanged(keyCode: Int64, flags: UInt64) -> ShortcutCapture? {
        if let press = ShortcutRecorder.capture(flagsChangedKeyCode: keyCode, flags: flags) {
            pending = press
            pendingKeyCode = keyCode
            return nil
        }
        guard keyCode == pendingKeyCode, ShortcutRecorder.isRelease(flagsChangedKeyCode: keyCode, flags: flags) else { return nil }
        defer { pending = nil; pendingKeyCode = nil }
        return pending
    }

    /// A `keyDown` event: always decides (a chord, Escape, or a key that cannot be held).
    public mutating func keyDown(keyCode: UInt16, flags: UInt64, characters: String? = nil) -> ShortcutCapture {
        pending = nil
        pendingKeyCode = nil
        return ShortcutRecorder.capture(keyDownKeyCode: keyCode, flags: flags, characters: characters)
    }
}

// MARK: - Test area

/// The shortcut test (design §8.6 "Check both press and release feedback"): the real
/// `HotkeyStateMachine` timings applied to the bound key's edges, so what it reports is what a
/// dictation would do — hold, too short, double tap (Latch) — without opening the microphone.
public struct ShortcutTestProbe: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        /// Nothing pressed yet.
        case waiting
        /// Key is down.
        case pressed
        /// Released after a hold: a dictation would preview and insert.
        case hold(seconds: TimeInterval)
        /// Released before the hold threshold (K03).
        case tooShort
        /// Second quick tap: Latch.
        case latched
        /// A tap while latched finishes.
        case latchFinished
    }

    private var machine: HotkeyStateMachine
    private var downAt: TimeInterval?
    public private(set) var result: Result = .waiting

    public init(timing: HotkeyStateMachine.Timing = .default) { machine = HotkeyStateMachine(timing: timing) }

    public mutating func edge(_ edge: HotkeyBinding.Edge, at t: TimeInterval, latchEnabled: Bool) {
        switch edge {
        case .down:
            // X1 — a press while latched stops at its key-up; the test reports it on the press.
            let wasLatched = machine.phase == .latched
            let actions = LatchGestureSettings.filter(machine.keyDown(at: t), enabled: latchEnabled)
            if wasLatched || actions.contains(.finalize) { result = .latchFinished; downAt = nil; return }
            if actions.contains(.startCapture) { downAt = t; result = .pressed }
        case .up:
            let actions = LatchGestureSettings.filter(machine.keyUp(at: t), enabled: latchEnabled)
            defer { downAt = nil }
            if actions.contains(.enterLatch) {
                result = .latched
            } else if actions.contains(.finalize) {
                if result != .latchFinished { result = .hold(seconds: t - (downAt ?? t)) }
            } else if actions.contains(.cancelCapture) {
                // Latch off: the state machine may have latched; the filter turned it into a
                // cancel, so reset it rather than leave it waiting for a finishing tap.
                if !latchEnabled { machine.reset() }
                result = .tooShort
            }
        }
    }

    public func message(key: String, mode: ShortcutTestMode = .isolated) -> String {
        switch result {
        case .waiting: return ShortcutCopy.testPrompt(key, mode: mode)
        case .pressed: return ShortcutCopy.testPressed
        case .hold(let seconds): return ShortcutCopy.testHold(seconds)
        case .tooShort: return PillState.withHotkey(RecoveryCatalog.entry(.K03).headline, key: key)
        case .latched: return ShortcutCopy.testLatched
        case .latchFinished: return ShortcutCopy.testLatchFinished
        }
    }
}

/// How the test area can read the bound key.
///
/// The dictation key's default backend is a pair of `NSEvent` monitors; the global one never sees
/// VoicePlus's own events, so inside this window only its *local* monitor does. Local monitors run
/// newest first and a `nil` return ends the chain (checked on this Mac, macOS 26), so the page's
/// monitor — installed when a test starts, long after the service's — reads the key first and can
/// keep it to itself: a test press is not a dictation.
public enum ShortcutTestMode: Equatable, Sendable {
    /// A bare modifier on the default listener: the page reads it and nothing is dictated.
    case isolated
    /// A bare modifier the legacy event tap also sees (it reads events before any app does): the page
    /// reads the key and a dictation starts as well.
    case sharedWithEventTap
    /// A chord is a registered hot key: macOS hands it to VoicePlus only as a dictation, never as a
    /// key event this page could read.
    case chord

    public static func resolve(_ kind: HotkeyBinding.Kind, forceEventTap: Bool) -> ShortcutTestMode {
        if kind.style == .chord { return .chord }
        return forceEventTap ? .sharedWithEventTap : .isolated
    }

    public var canProbe: Bool { self != .chord }
}

/// Which of the bound key's edges the page keeps to itself while it records or tests. A release is
/// kept only when its press was: a press the dictation key already saw must reach it released, or it
/// would stay down and keep the microphone open.
public struct KeyIsolation: Equatable, Sendable {
    public private(set) var holdsPress = false

    public init() {}

    /// True when the page should swallow this edge.
    public mutating func swallow(_ edge: HotkeyBinding.Edge) -> Bool {
        switch edge {
        case .down:
            holdsPress = true
            return true
        case .up:
            defer { holdsPress = false }
            return holdsPress
        }
    }
}

// MARK: - Copy

public enum ShortcutCopy {
    public static let holdToTalk = "Hold to talk"
    public static let holdExplanation = "Hold while you speak. Let go to finish."
    public static let escapeCancels = "Escape cancels before insertion begins."
    public static let changeShortcut = "Change shortcut…"
    public static func recordingPrompt(_ key: String) -> String { "Press the key you want to hold. Escape keeps \(key)." }
    public static let stopRecording = "Stop"
    public static let distinctModifiers = "Left and right modifiers are distinct."
    public static let footnote = "Left and right modifiers are distinct. A conflict keeps your previous shortcut active."
    public static func cannotHold(_ name: String) -> String { "\(name) can’t be held for dictation" }
    public static func isActionsKey(_ key: String) -> String { "\(key) is your Actions key." }
    public static func nowDictationKey(_ key: String) -> String { "\(key) is now your dictation key." }
    public static func alreadyDictationKey(_ key: String) -> String { "\(key) is already your dictation key." }
    public static let latchTitle = "Double-tap to latch"
    public static let latchDetail = "Tap twice, speak hands-free, then tap to finish."
    public static let latchPauseTitle = "Insert after a pause of"
    public static let latchPauseDetail = "In Latch, this much silence ends a segment and inserts it."
    public static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }
    public static let drawTitle = "Draw without holding the key"
    public static let drawDetail = "In Latch, drag a box around what you mean. Hold-to-talk always needs the key held."
    public static let latchOffNote = "Turn on Double-tap to latch to use these."
    public static let testTitle = "Shortcut test"
    public static let testDetail = "Check both press and release feedback."
    public static let testStart = "Test the shortcut"
    public static let testStop = "Done"
    public static func testPrompt(_ key: String, mode: ShortcutTestMode = .isolated) -> String {
        switch mode {
        case .isolated:
            return "Hold \(key) here, then let go. While this test runs, the key doesn’t start a dictation in this window."
        case .sharedWithEventTap:
            return "Hold \(key) here, then let go. The legacy listener sees the key too, so a dictation starts as well."
        case .chord:
            return chordTestNote(key)
        }
    }
    public static func chordTestNote(_ key: String) -> String {
        "\(key) is a chord, which macOS hands to VoicePlus only as a dictation. Try it in any text field and watch the pill."
    }
    public static let testPressed = "Pressed — keep holding, then let go."
    public static func testHold(_ seconds: TimeInterval) -> String {
        String(format: "Released after %.1f s — a hold. Your words would preview, then insert.", seconds)
    }
    public static let testLatched = "Double tap — Latch. Tap once more to finish."
    public static let testLatchFinished = "Tap — Latch finished."
}

// MARK: - The page's live half

/// Settings › Shortcuts' key events. A local `NSEvent` monitor is installed only while recording or
/// testing, and removed on stop and when the page goes away.
@MainActor
public final class ShortcutsPageModel: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var lastChange: ShortcutChange?
    @Published public private(set) var isTesting = false
    @Published public private(set) var probe = ShortcutTestProbe()
    private var recording = ShortcutRecording()

    private let general: GeneralSettingsViewModel
    private let clock: () -> TimeInterval
    private let installMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void
    private var monitor: Any?

    public init(general: GeneralSettingsViewModel,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                installMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = {
                    NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: $0)
                },
                removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }) {
        self.general = general
        self.clock = clock
        self.installMonitor = installMonitor
        self.removeMonitor = removeMonitor
    }

    // MARK: Recording

    /// Recording and testing share one monitor: switching hands it over rather than reinstalling it.
    public func startRecording() {
        isTesting = false
        lastChange = nil
        recording = ShortcutRecording()
        isRecording = true
        ensureMonitor()
    }

    public func stopRecording() {
        isRecording = false
        releaseMonitorIfIdle()
    }

    /// One capture from the recorder (the monitor, or a test).
    public func record(_ capture: ShortcutCapture) {
        guard isRecording else { return }
        lastChange = general.apply(capture)
        stopRecording()
    }

    /// The picker beside the recorder goes through the same rule: a conflict keeps the previous key.
    public func choose(_ choice: HotkeyChoice) {
        stopAll()
        lastChange = general.apply(.key(choice.binding))
    }

    // MARK: Testing

    /// How the bound key can be tested right now (a chord cannot be read here at all).
    public var testMode: ShortcutTestMode {
        .resolve(general.hotkey.binding, forceEventTap: general.forceEventTap)
    }

    /// The test row's line: the prompt or the probe's last result, in the configured key's words.
    public var testLine: String {
        guard testMode.canProbe else { return ShortcutCopy.chordTestNote(general.hotkeyLabel) }
        return isTesting ? probe.message(key: general.hotkeyLabel, mode: testMode) : ShortcutCopy.testDetail
    }

    public func startTesting() {
        guard testMode.canProbe else { return }
        isRecording = false
        probe = ShortcutTestProbe()
        isTesting = true
        ensureMonitor()
    }

    public func stopTesting() {
        isTesting = false
        releaseMonitorIfIdle()
    }

    /// One edge of the bound key, at `t` (seconds).
    public func testEdge(_ edge: HotkeyBinding.Edge, at t: TimeInterval) {
        guard isTesting else { return }
        probe.edge(edge, at: t, latchEnabled: general.latchDoubleTap)
    }

    public func stopAll() {
        stopRecording()
        stopTesting()
    }

    // MARK: Events

    private func ensureMonitor() {
        guard monitor == nil else { return }
        monitor = installMonitor { [weak self] event in
            // A local monitor is called on the main thread with the app's own event.
            nonisolated(unsafe) let event = event
            let passThrough = MainActor.assumeIsolated { self?.handle(event) ?? true }
            return passThrough ? event : nil
        }
    }

    private func releaseMonitorIfIdle() {
        guard !isRecording, !isTesting, let monitor else { return }
        removeMonitor(monitor)
        self.monitor = nil
        // A press kept from the dictation key and released after this reaches it as a stray
        // release, which its state machine ignores while idle.
        isolation = KeyIsolation()
    }

    /// The bound key's edges the page is keeping from the dictation key's own monitor.
    private var isolation = KeyIsolation()

    /// One event from the page's local monitor. False swallows it: a key the recorder consumed (so
    /// it neither types nor beeps), and — on the default listener — the bound key's own press and
    /// release while recording or testing, so neither turns into a dictation (`ShortcutTestMode`).
    func handle(_ event: NSEvent) -> Bool {
        let flags = UInt64(event.modifierFlags.rawValue)
        let bound = HotkeyBinding(kind: general.hotkey.binding)
        var boundEdge: HotkeyBinding.Edge?
        if event.type == .flagsChanged { boundEdge = bound.edge(keyCode: Int64(event.keyCode), flags: flags) }
        let keepsToItself = boundEdge.map { edge in
            testMode == .isolated ? isolation.swallow(edge) : false
        } ?? false

        if isRecording {
            switch event.type {
            case .flagsChanged:
                if let capture = recording.flagsChanged(keyCode: Int64(event.keyCode), flags: flags) {
                    record(capture)
                }
                return !keepsToItself
            case .keyDown:
                record(recording.keyDown(keyCode: event.keyCode, flags: flags,
                                         characters: event.charactersIgnoringModifiers))
                return false
            default:
                return true
            }
        }
        if isTesting, let boundEdge {
            testEdge(boundEdge, at: clock())
        }
        return !keepsToItself
    }
}
