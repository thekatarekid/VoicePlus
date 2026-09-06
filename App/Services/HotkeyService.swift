import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Shared

/// Global modifier-key listener (T3): a listen-only CGEvent tap on `flagsChanged`, feeding `HotkeyStateMachine`.
/// Requires Input Monitoring; `start()` returns false (and the app falls back to the menu item) without it.
public final class HotkeyService {
    public static let bindingDefaultsKey = "hotkeyBinding"
    /// P4.2 — the second (act) key persists under its own key; default Right ⌘.
    public static let actBindingDefaultsKey = "actHotkeyBinding"

    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    public private(set) var machine: HotkeyStateMachine
    public private(set) var binding: HotkeyBinding
    public private(set) var isRunning = false
    public var isPaused = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let defaults: UserDefaults
    private let bindingKey: String

    /// How many events the *tap* has delivered since it was last armed. `CGEvent.tapCreate` returns a
    /// valid-looking port with no Input Monitoring at all (measured on macOS 26.6.2: six creations,
    /// six non-NULL taps, `CGPreflightListenEventAccess()` false throughout), so "armed" is not
    /// "working" and this counter is the only thing that can tell them apart.
    public private(set) var eventsReceived = 0
    /// When the current tap was created; nil while disarmed.
    public private(set) var armedAt: Date?
    /// How many times the tap has been created in this process — asserted by the tests that a grant
    /// observed by the poll arms exactly once and never stacks a second tap on the run loop.
    public private(set) var armCount = 0
    /// Injectable for tests.
    public var clock: () -> Date = Date.init
    /// Seconds since the *system* last saw a `flagsChanged` event, from the HID event source. Needs
    /// no permission of any kind, which is what makes it usable as the control in the liveness test:
    /// silence from our tap only means something if the system itself saw modifier activity.
    public var systemModifierIdle: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged)
    }

    public init(defaults: UserDefaults = .standard, timing: HotkeyStateMachine.Timing = .default,
                bindingKey: String = HotkeyService.bindingDefaultsKey,
                defaultBinding: HotkeyBinding = .default) {
        self.defaults = defaults
        self.bindingKey = bindingKey
        self.machine = HotkeyStateMachine(timing: timing)
        if let raw = defaults.string(forKey: bindingKey), let kind = HotkeyBinding.Kind(rawValue: raw) {
            binding = HotkeyBinding(kind: kind)
        } else {
            binding = defaultBinding
        }
    }

    public func setBinding(_ kind: HotkeyBinding.Kind) {
        binding = HotkeyBinding(kind: kind)
        defaults.set(kind.rawValue, forKey: bindingKey)
        machine.reset()
    }

    /// Feed a raw modifier event. Public so tests can synthesize `CGEvent`s without a tap.
    public func handle(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        guard !isPaused, let edge = binding.edge(keyCode: keyCode, flags: flags) else { return }
        let actions: [HotkeyStateMachine.Action]
        switch edge {
        case .down: actions = machine.keyDown(at: timestamp)
        case .up: actions = machine.keyUp(at: timestamp)
        }
        for action in actions { onAction?(action) }
    }

    public func handle(event: CGEvent) {
        handle(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
               flags: event.flags.rawValue,
               timestamp: TimeInterval(event.timestamp) / 1_000_000_000)
    }

    /// Called by the coordinator when the engine failed so a stuck key-down doesn't leave us "capturing".
    public func resetGesture() { machine.reset() }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard CGPreflightListenEventAccess() else {
            Log.app.warning("hotkey: Input Monitoring not granted; falling back to menu item")
            return false
        }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = service.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    service.eventsReceived += 1
                    service.handle(event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            Log.app.error("hotkey: CGEvent.tapCreate failed")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        eventsReceived = 0
        armedAt = clock()
        armCount += 1
        // `.notice` (not `.info`): info-level lines are memory-only and had already aged out by the
        // time the 1.6.5 report was diagnosed, so the whole question "was the tap ever armed?" had to
        // be answered from tccd's log instead of ours. Arming is rare; persist it.
        Log.app.notice("hotkey: tap armed (#\(armCount)) for \(binding.kind.displayName)")
        return true
    }

    /// Tear the tap down. Invalidating the port and the run-loop source (rather than only dropping
    /// the references) is what guarantees a later `start()` cannot leave a second live tap behind.
    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
        armedAt = nil
        eventsReceived = 0
        machine.reset()
    }

    /// Drop the current tap and create a fresh one. Used when the liveness probe says the tap is
    /// armed but deaf — the state a grant made *after* `tapCreate` can leave it in.
    @discardableResult
    public func rearm() -> Bool {
        stop()
        return start()
    }

    /// Is the armed tap actually receiving events? See `TapLiveness`.
    public var livenessVerdict: TapLiveness.Verdict {
        guard isRunning, let armedAt else { return .unknown }
        return TapLiveness.verdict(armedFor: clock().timeIntervalSince(armedAt),
                                   eventsSinceArmed: eventsReceived,
                                   systemModifierIdle: systemModifierIdle())
    }
}
