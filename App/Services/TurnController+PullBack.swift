import AppKit
import ApplicationServices
import Foundation
import Injection
import Shared

// Owner decision (2026-10-02, after Round 4) — switched apps mid-dictation → PULL BACK.
//
// The turn remembers the app, window and element at key-down. If something else has focus when the
// final text is ready, the original app is made frontmost, its window raised and the element
// re-focused, and only then is the text typed. The text is held (Insert / Copy) only when the
// original window is gone, the target is now a password field, or the refocus check fails.
// (Design note: FluidVoice does the same — design only, nothing copied.)

/// Where a turn was aimed at key-down: the app, its focused window's token (the same identity the
/// delivery ladder uses, `FocusedWindowReading`) and, live, the AX window and element to re-focus.
public final class PullBackAnchor: @unchecked Sendable {
    public let focus: FocusSnapshot
    public let windowToken: String?
    /// Live only: the key-down `AXFocusedWindow` / `AXFocusedUIElement`.
    let window: AXUIElement?
    let element: AXUIElement?

    public init(focus: FocusSnapshot, windowToken: String?, window: AXUIElement? = nil, element: AXUIElement? = nil) {
        self.focus = focus
        self.windowToken = windowToken
        self.window = window
        self.element = element
    }
}

/// What a pull-back attempt found.
public enum PullBackOutcome: Equatable, Sendable {
    /// The original app and window are focused again.
    case refocused
    /// The original window (or app) no longer exists.
    case windowGone
    /// Raised, but focus did not come back in time (or the raise was refused).
    case failed
}

/// Hold reasons the pull-back adds to `DeliveryReason`.
public enum PullBackReason {
    /// Worded so the recovery catalogue reads both as D01 (destination changed — text held).
    public static let windowGone = "destination window was closed"
    public static let refocusFailed = "could not refocus the destination window"
    public static let all: Set<String> = [windowGone, refocusFailed]
}

/// Owner decision — re-focus the key-down app and window before typing.
public protocol FocusPullBacking: AnyObject {
    /// Called at key-down (off the main thread) for the snapshot's app.
    func remember(_ focus: FocusSnapshot) -> PullBackAnchor
    /// The key-down window vs the anchor app's focused window now.
    func windowState(_ anchor: PullBackAnchor) -> DeliveryLadder.WindowState
    /// Raise the remembered app and window, re-focus the element, and wait (bounded) for focus to
    /// come back.
    func pullBack(_ anchor: PullBackAnchor) -> PullBackOutcome
}

/// The pull-back over `SystemAccess`: window identity from `FocusedWindowReading`, the raise from
/// `raise` (live: AX + NSRunningApplication; tests: a closure that moves the mock's focus).
public final class SystemFocusPullBack: FocusPullBacking {
    public enum RaiseResult: Equatable, Sendable { case raised, appGone, refused }

    private let system: SystemAccess
    private let raise: (PullBackAnchor) -> RaiseResult
    private let captureLive: Bool
    /// How long focus may take to come back after the raise (polled every `step`).
    public var settle: TimeInterval = 0.25
    public var step: TimeInterval = 0.02

    public init(system: SystemAccess, captureLive: Bool = false,
                raise: @escaping (PullBackAnchor) -> RaiseResult) {
        self.system = system
        self.captureLive = captureLive
        self.raise = raise
    }

    /// The live pull-back: AX references captured at key-down, `liveRaise` to return.
    public static func live(system: SystemAccess) -> SystemFocusPullBack {
        SystemFocusPullBack(system: system, captureLive: true, raise: SystemFocusPullBack.liveRaise)
    }

    private var windows: FocusedWindowReading? { system as? FocusedWindowReading }

    public func remember(_ focus: FocusSnapshot) -> PullBackAnchor {
        let token = windows?.focusedWindowToken(pid: focus.pid)
        // H26 — the key-down window token, logged (diagnostics: which window the turn aimed at).
        Log.app.info("key-down window token \(token ?? "none") in \(focus.bundleID)")
        guard captureLive, !OwnProcess.owns(focus) else { return PullBackAnchor(focus: focus, windowToken: token) }
        guard let app = AXGuard.application(pid: focus.pid) else { return PullBackAnchor(focus: focus, windowToken: token) }
        AXUIElementSetMessagingTimeout(app, 0.1)
        return PullBackAnchor(focus: focus, windowToken: token,
                              window: Self.element(app, kAXFocusedWindowAttribute),
                              element: Self.element(app, kAXFocusedUIElementAttribute))
    }

    public func windowState(_ anchor: PullBackAnchor) -> DeliveryLadder.WindowState {
        // H26 — VoicePlus's own windows skip the window-identity check: the pill, notch and our
        // panels take key status around a turn, so a "changed" window there means nothing. The
        // in-process writer decides: type into the field, or Notes (no text field).
        if OwnProcess.owns(anchor.focus) { return .unknown }
        guard let windows, let token = anchor.windowToken else { return .unknown }
        let current = windows.focusedWindowToken(pid: anchor.focus.pid)
        if current == token { return .same }
        return DeliveryLadder.windowState(expected: token, current: current,
                                          expectedStillExists: windows.windowExists(pid: anchor.focus.pid, token: token))
    }

    public func pullBack(_ anchor: PullBackAnchor) -> PullBackOutcome {
        if windowState(anchor) == .gone { return .windowGone }
        switch raise(anchor) {
        case .appGone: return .windowGone
        case .refused: return .failed
        case .raised: break
        }
        let deadline = Date().addingTimeInterval(settle)
        while true {
            if let front = system.frontmostApp(), front.pid == anchor.focus.pid, front.bundleID == anchor.focus.bundleID {
                switch windowState(anchor) {
                case .same, .unknown, .none: return .refocused
                case .gone: return .windowGone
                case .changed: break
                }
            }
            if Date() >= deadline { return .failed }
            Thread.sleep(forTimeInterval: step)
        }
    }

    // MARK: Live

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success, let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Frontmost app → raise and main the window → focus the element. AX first (it works for an
    /// accessory app under cooperative activation), `NSRunningApplication.activate` as backup.
    public static func liveRaise(_ anchor: PullBackAnchor) -> RaiseResult {
        guard let running = NSRunningApplication(processIdentifier: anchor.focus.pid), !running.isTerminated else { return .appGone }
        guard let app = AXGuard.application(pid: anchor.focus.pid) else { return .appGone }
        AXUIElementSetMessagingTimeout(app, 0.2)
        let frontmost = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        let activated = running.activate(options: [])
        if let window = anchor.window {
            var role: CFTypeRef?
            // A destroyed window answers "invalid element": it is gone, never "refused".
            if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .invalidUIElement { return .appGone }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        }
        if let element = anchor.element {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        return (frontmost == .success || activated) ? .raised : .refused
    }
}
