import ApplicationServices
import CoreGraphics
import Foundation
import Shared

/// X2 (owner round 4) — the active `CGEventTap` that serves an Option dictation key.
///
/// * Reads Option `flagsChanged` edges **before** any app, feeding them to `HotkeyService`
///   (including the presses it drops, which the passive monitors never see).
/// * Asks `OptionDoubleTapSuppressor` per event: the second press of a clean double tap is dropped
///   so Claude's own double-tap-Option shortcut sees a single tap; VoicePlus latches hands-free.
/// * Every key-down, other modifier, mouse button and scroll is "other input": Option + anything
///   cancels silently (X1) and passes through. During a dropped press it is re-posted after the
///   held-back Option-down, both tagged with `userDataTag` so this tap lets them through.
/// * Re-enables itself on `tapDisabledByTimeout` / `tapDisabledByUserInput`.
///
/// `.defaultTap` needs Accessibility (granted for insertion). When creation fails the service
/// falls back to its passive monitors and the one-time `OptionTapFallbackNotice` is offered.
/// The decision logic is pure and tested (`OptionDoubleTapSuppressor`); this file is the thin
/// live adapter and is not exercised by tests (no live tap in tests).
public final class OptionKeyEventTap {
    /// `eventSourceUserData` on every event VoicePlus posts itself ("VOICPLUS").
    public static let userDataTag: Int64 = 0x564F_4943_504C_5553

    private weak var service: HotkeyService?
    private var suppressor: OptionDoubleTapSuppressor
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let token: Int
    /// The Option-down flag word last dropped, re-posted when the press turns into a chord.
    private var heldDown: (keyCode: Int64, flags: CGEventFlags)?

    private static let lock = NSLock()
    private static var nextToken = 1
    private static var live: [Int: OptionKeyEventTap] = [:]

    private init(service: HotkeyService, timing: HotkeyStateMachine.Timing) {
        self.service = service
        suppressor = OptionDoubleTapSuppressor(timing: timing)
        token = Self.lock.withLock { () -> Int in
            defer { Self.nextToken += 1 }
            return Self.nextToken
        }
    }

    /// nil when Accessibility is not granted or macOS refuses the tap.
    public static func install(for service: HotkeyService) -> OptionKeyEventTap? {
        guard AXIsProcessTrusted() else { return nil }
        let object = OptionKeyEventTap(service: service, timing: service.machine.timing)
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        lock.withLock { live[object.token] = object }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let token = Int(bitPattern: userInfo)
                guard let tap = OptionKeyEventTap.lock.withLock({ OptionKeyEventTap.live[token] }) else {
                    return Unmanaged.passUnretained(event)
                }
                return tap.handle(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(bitPattern: object.token)
        ) else {
            lock.withLock { _ = live.removeValue(forKey: object.token) }
            return nil
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        object.tap = port
        object.source = runLoopSource
        guard CGEvent.tapIsEnabled(tap: port) else {
            object.invalidate()
            return nil
        }
        Log.app.notice("hotkey: Option event tap armed (double tap kept from other apps)")
        return object
    }

    public func invalidate() {
        Self.lock.withLock { _ = Self.live.removeValue(forKey: token) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    deinit { invalidate() }

    // MARK: The callback (main run loop)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.app.notice("hotkey: Option event tap was disabled by the system — re-enabled")
            suppressor.reset()
            service?.checkForLostKeyUp()
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.userDataTag, let service else {
            return Unmanaged.passUnretained(event)
        }
        let t = TimeInterval(event.timestamp) / 1_000_000_000
        let decision: OptionDoubleTapSuppressor.Decision
        if type == .flagsChanged {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            if let edge = service.binding.edge(keyCode: keyCode, flags: flags) {
                service.receiveTapped(keyCode: keyCode, flags: flags, timestamp: t)
                decision = suppressor.option(edge, at: t)
                if decision == .drop, edge == .down { heldDown = (keyCode, event.flags) }
            } else if HotkeyBinding.Kind.option.keyCodes.contains(keyCode) {
                // The Option side this binding does not serve: not ours, not a chord.
                decision = .pass
            } else {
                decision = suppressor.otherInput(at: t)
                service.noteOtherInput(at: t)
            }
        } else {
            decision = suppressor.otherInput(at: t)
            service.noteOtherInput(at: t)
        }
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .drop:
            return nil
        case .repostOptionDownThenEvent:
            repostHeldDown()
            if let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: Self.userDataTag)
                copy.post(tap: .cgSessionEventTap)
            }
            return nil
        }
    }

    private func repostHeldDown() {
        guard let held = heldDown else { return }
        heldDown = nil
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(held.keyCode), keyDown: true) else { return }
        down.type = .flagsChanged
        down.flags = held.flags
        down.setIntegerValueField(.eventSourceUserData, value: Self.userDataTag)
        down.post(tap: .cgSessionEventTap)
    }
}
