import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Shared

/// Global modifier-key listener (T3): a listen-only CGEvent tap on `flagsChanged`, feeding `HotkeyStateMachine`.
/// Requires Input Monitoring; `start()` returns false (and the app falls back to the menu item) without it.
public final class HotkeyService {
    public static let bindingDefaultsKey = "hotkeyBinding"

    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    public private(set) var machine: HotkeyStateMachine
    public private(set) var binding: HotkeyBinding
    public private(set) var isRunning = false
    public var isPaused = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, timing: HotkeyStateMachine.Timing = .default) {
        self.defaults = defaults
        self.machine = HotkeyStateMachine(timing: timing)
        if let raw = defaults.string(forKey: Self.bindingDefaultsKey), let kind = HotkeyBinding.Kind(rawValue: raw) {
            binding = HotkeyBinding(kind: kind)
        } else {
            binding = .default
        }
    }

    public func setBinding(_ kind: HotkeyBinding.Kind) {
        binding = HotkeyBinding(kind: kind)
        defaults.set(kind.rawValue, forKey: Self.bindingDefaultsKey)
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
        Log.app.info("hotkey: listening for \(binding.kind.displayName)")
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isRunning = false
        machine.reset()
    }
}
