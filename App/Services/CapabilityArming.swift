import AppKit
import CoreGraphics
import Foundation
import Shared

// MARK: - Tap liveness

/// `CGEvent.tapCreate` is not a permission test. Measured on macOS 26.6.2 with a throwaway bundle id
/// that had no Input Monitoring at all: six creations, six non-NULL taps, `CGPreflightListenEventAccess()`
/// false every time. An unauthorized tap exists and delivers nothing, and the return value cannot
/// tell you which one you have.
///
/// So authorization is judged by preflight, and *working* is judged here: silence from our tap only
/// means something when the system itself saw modifier activity after we armed. `systemModifierIdle`
/// comes from `CGEventSource.secondsSinceLastEventType`, which needs no permission — that is what
/// makes it a valid control.
public enum TapLiveness {
    public enum Verdict: String, Equatable, Sendable {
        /// Events are arriving.
        case alive
        /// Not enough has happened to say — too soon, or the user has touched no modifier key since.
        case unknown
        /// The system saw modifier keys after we armed and our tap received none of them.
        case dead
    }

    /// Seconds a freshly armed tap is given before silence is allowed to mean anything.
    public static let grace: TimeInterval = 20

    public static func verdict(armedFor: TimeInterval, eventsSinceArmed: Int,
                               systemModifierIdle: TimeInterval,
                               grace: TimeInterval = TapLiveness.grace) -> Verdict {
        if eventsSinceArmed > 0 { return .alive }
        if armedFor < grace { return .unknown }
        // The last system-wide modifier event predates our tap, so there was nothing to receive.
        if systemModifierIdle >= armedFor { return .unknown }
        return .dead
    }
}

// MARK: - What the watcher drives

/// The part of `HotkeyService` the capability watcher owns. A protocol so the arming rules can be
/// tested without a real CGEvent tap (which a test process cannot create without Input Monitoring).
public protocol HotkeyArming: AnyObject {
    var isRunning: Bool { get }
    var livenessVerdict: TapLiveness.Verdict { get }
    @discardableResult func start() -> Bool
    @discardableResult func rearm() -> Bool
    func stop()
}

extension HotkeyService: HotkeyArming {}

/// Pure arming rule. Idempotent by construction: once armed, a granted permission produces `.hold`,
/// so a 1 s poll cannot stack a second tap, and a revoked permission tears exactly one down.
public enum CapabilityArming {
    public enum Decision: String, Equatable, Sendable { case arm, disarm, hold }

    public static func decision(canUseGlobalHotkey: Bool, isArmed: Bool) -> Decision {
        if canUseGlobalHotkey { return isArmed ? .hold : .arm }
        return isArmed ? .disarm : .hold
    }
}

// MARK: - The watcher

/// Re-reads the permission matrix continuously and arms/disarms the hotkey taps to match, for the
/// whole life of the process.
///
/// Why this exists: until 1.6.5 `hotkey.start()` was called from exactly one place — the completion
/// of `PermissionOrchestrator.run` — and that completion is withheld while a pre-prompt window is on
/// screen, and never runs at all while onboarding is up. On the reporting machine Input Monitoring
/// had been granted for twenty minutes and the tap had never been created, because the walk was
/// parked on the *Accessibility* pre-prompt: a permission the hotkey does not need. The app looked
/// like it required a relaunch when all it required was to try again.
///
/// ## What a running process can and cannot pick up (corrected in 1.6.7)
/// 1.6.6 claimed here that "the status APIs are live for all three services… nothing here needs a
/// restart". That was measured on a process which *already had* the grant when it launched, and it
/// does not generalise to a grant that lands mid-process. The corrected, per-service picture — see
/// `Permission.grantReachesRunningApp` for the full evidence:
/// * **Accessibility — live, and the 1.6.6 claim was right.** `AXIsProcessTrusted()` is cached per
///   process, but macOS drops that cache on the `com.apple.accessibility.api` distributed
///   notification, which this class observes. Measured 82–213 ms from the user's toggle to a fresh
///   tccd query inside the already-running app. macOS ships no "quit" string for it at all.
/// * **Microphone and Input Monitoring — not live, and the 1.6.6 claim was wrong.** Both status APIs
///   kept returning the pre-grant answer for the rest of the process's life (25 s and 18 s of
///   once-a-second polling respectively), while the very next process read the new value instantly.
///   macOS says so itself in the alert it shows when the switch moves.
/// So the watcher still arms the instant a grant becomes visible — that part was never the problem —
/// but for those two services it also has to be able to say "macOS is holding this until VoicePlus
/// restarts", which is what `onRelaunchAdvised` is for.
@MainActor
public final class CapabilityWatcher {
    public static let interval: TimeInterval = 1.0

    private let checker: PermissionChecking
    private let hotkeys: [HotkeyArming]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?
    /// Taps we have already tried to revive once, so a deaf tap produces one re-arm and then a
    /// verdict — never an endless arm/disarm loop.
    private var revived: Set<ObjectIdentifier> = []

    public private(set) var capabilities: PermissionPlanner.Capabilities?
    public private(set) var matrix: PermissionMatrix = [:]

    /// Fired on every *change* of the capability set (and once on the first read).
    public var onCapabilitiesChanged: ((PermissionPlanner.Capabilities, PermissionMatrix) -> Void)?
    /// Input Monitoring is granted, the tap has been armed and re-armed, and the system is still
    /// delivering modifier events to everyone but us. An honest restart recommendation — but a
    /// *narrow* one: it presupposes an armed tap, and `HotkeyService.start()` will not arm while
    /// preflight reads false. In the case the 1.6.6 user actually hit (grant made mid-session,
    /// "Later" pressed, preflight frozen at false) this can never fire. `onRelaunchAdvised` is the
    /// trigger that covers it.
    public var onTapProvenDead: (() -> Void)?
    /// A service macOS only hands over at launch (`Permission.grantReachesRunningApp == false`) is
    /// still not granted after the user was sent to System Settings for it and came back. Fires once
    /// per trip, per service, so a one-click "Quit & Reopen" can be offered without nagging.
    public var onRelaunchAdvised: ((Permission) -> Void)?

    /// Injectable so the advisor's grace period is testable without sleeping.
    public var clock: () -> Date = Date.init
    private var advisor = RelaunchAdvisor()

    public init(checker: PermissionChecking, hotkeys: [HotkeyArming]) {
        self.checker = checker
        self.hotkeys = hotkeys
    }

    /// The user has just been sent to System Settings for `permission`. Told to the watcher rather
    /// than inferred, because "the app is missing a permission" is the normal state of a fresh
    /// install and must never on its own produce a restart prompt.
    public func noteSentToSettings(_ permission: Permission) {
        advisor.noteSentToSettings(permission, at: clock())
    }

    /// VoicePlus came back to the foreground. Called from the `didBecomeActive` observer; exposed so
    /// tests need no notification.
    public func noteBecameActive() { advisor.noteBecameActive(at: clock()) }

    deinit {
        timer?.invalidate()
        // Observers are removed in `stop()`; a deinit without it would leak them, so mirror it here.
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
    }

    /// Begin watching. Safe to call twice.
    public func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteBecameActive()
                self?.refresh()
            }
        })
        // The signal HIServices itself uses to drop its cached `AXIsProcessTrusted()` answer. Every
        // VoicePlus process already registers for it; this is the first thing to act on it.
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.app.notice("capabilities: accessibility API notification — re-reading TCC")
                self?.refresh()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
            self.distributedObserver = nil
        }
    }

    /// One tick. Public so the permission walk, the menu item and the tests can force a read.
    public func refresh() {
        let current = checker.matrix()
        let caps = PermissionPlanner.capabilities(current)
        matrix = current
        if caps != capabilities {
            let previous = capabilities
            capabilities = caps
            // `.notice`, so it survives in the log the way the arming line does. A capability change
            // is exactly the transition the 1.6.5 report needed evidence of and had none.
            Log.app.notice("capabilities: capture=\(caps.canCapture) hotkey=\(caps.canUseGlobalHotkey) inject=\(caps.canInjectText)"
                + (previous == nil ? " (first read)" : "")
                + " [\(current.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: " "))]")
            onCapabilitiesChanged?(caps, current)
        }
        applyArming(canUseGlobalHotkey: caps.canUseGlobalHotkey)
        for permission in advisor.evaluate(matrix: current, now: clock()) {
            Log.app.notice("capabilities: \(permission.rawValue) still not granted after the trip to System Settings — macOS hands this one over only at launch, so offering a relaunch")
            onRelaunchAdvised?(permission)
        }
    }

    private func applyArming(canUseGlobalHotkey: Bool) {
        for hotkey in hotkeys {
            switch CapabilityArming.decision(canUseGlobalHotkey: canUseGlobalHotkey, isArmed: hotkey.isRunning) {
            case .arm:
                if hotkey.start() {
                    revived.remove(ObjectIdentifier(hotkey))
                } else {
                    // Preflight said granted but the tap could not be created — retried next tick.
                    Log.app.warning("capabilities: Input Monitoring is granted but the tap would not arm")
                }
            case .disarm:
                Log.app.notice("capabilities: Input Monitoring is no longer granted — tearing the tap down")
                hotkey.stop()
                revived.remove(ObjectIdentifier(hotkey))
            case .hold:
                checkLiveness(of: hotkey)
            }
        }
    }

    /// A tap that is armed but deaf gets exactly one silent re-arm; if it is still deaf after that,
    /// the caller is told, and *that* is when a restart may honestly be offered.
    private func checkLiveness(of hotkey: HotkeyArming) {
        guard hotkey.isRunning, hotkey.livenessVerdict == .dead else { return }
        let id = ObjectIdentifier(hotkey)
        guard revived.contains(id) else {
            revived.insert(id)
            Log.app.notice("hotkey: tap armed but receiving nothing while the system sees modifier keys — re-arming once")
            hotkey.rearm()
            return
        }
        Log.app.error("hotkey: tap still deaf after a re-arm; macOS is not delivering key events to this process")
        onTapProvenDead?()
    }
}

/// Records arming calls instead of touching CoreGraphics. Lives in the app target next to the other
/// mocks (`MockPermissionChecker`, `MockRelauncher`) so the tests need no CGEvent tap.
public final class MockHotkeyArming: HotkeyArming {
    public private(set) var isRunning = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var rearmCount = 0
    /// What `start()` should report; false models "preflight passed, tapCreate refused".
    public var startSucceeds = true
    public var livenessVerdict: TapLiveness.Verdict = .unknown

    public init() {}

    @discardableResult
    public func start() -> Bool {
        startCount += 1
        guard startSucceeds else { return false }
        isRunning = true
        return true
    }

    @discardableResult
    public func rearm() -> Bool {
        rearmCount += 1
        stop()
        return start()
    }

    public func stop() {
        stopCount += 1
        isRunning = false
    }
}
