import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Shared

// MARK: - Addressing a tap without a pointer

/// Resolves the integer token a live CGEvent tap carries in its `userInfo` back to the service that
/// created it.
///
/// Until 1.6.6 the tap's `userInfo` was `Unmanaged.passUnretained(self).toOpaque()` — a raw pointer
/// to an object the tap does not own, in a class with no `deinit`. Nothing but luck kept the run
/// loop from calling into freed memory: both `HotkeyService` instances happen to be stored
/// properties of `AppDelegate` and live for the whole process. Any future owner with a shorter life
/// (a settings sheet that makes one to preview a binding, a re-created service after a binding
/// change) turned that into a use-after-free reachable from any keypress.
///
/// A token cannot dangle. A retired token resolves to nil; a freed pointer resolves to a crash.
/// That difference is the entire reason for the indirection — and it is what lets
/// `HotkeyTapRegistry.isLive(_:)` make "teardown leaves nothing callable" an assertion instead of a
/// hope.
enum HotkeyTapRegistry {
    /// Weak, so a service that is released while a tap is somehow still installed resolves to nil
    /// rather than being resurrected by its own callback.
    private final class Entry {
        weak var service: HotkeyService?
        init(_ service: HotkeyService) { self.service = service }
    }

    private static let lock = NSLock()
    /// Starts at 1: `UnsafeMutableRawPointer(bitPattern:)` is nil for 0, and a nil `userInfo` is
    /// indistinguishable from "no context".
    private static var nextToken = 1
    private static var entries: [Int: Entry] = [:]

    static func register(_ service: HotkeyService) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(service)
        return token
    }

    static func retire(_ token: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: token)
    }

    static func service(for token: Int) -> HotkeyService? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.service
    }

    /// Would a callback carrying this token still reach a service? False the instant the tap that
    /// owns it is torn down, and false forever after.
    static func isLive(_ token: Int) -> Bool { service(for: token) != nil }
}

// MARK: - The CoreGraphics seam

/// A tap that has been created, enabled and added to the main run loop, addressed only through
/// closures so no CF object escapes `HotkeyService`.
public struct InstalledEventTap {
    public var setEnabled: (Bool) -> Void
    /// Disable, remove from the run loop and invalidate. Must be safe to call twice.
    public var invalidate: () -> Void

    public init(setEnabled: @escaping (Bool) -> Void, invalidate: @escaping () -> Void) {
        self.setEnabled = setEnabled
        self.invalidate = invalidate
    }
}

/// Everything `HotkeyService.start()` needs from CoreGraphics, in one injectable value.
///
/// A `swift test` process has no Input Monitoring and can never create a working tap, so without
/// this seam the arm → re-arm → stop lifecycle — the part that went wrong — would be the one part
/// of the hotkey path with no test at all.
public struct EventTapInstaller {
    /// `CGPreflightListenEventAccess()` in production.
    public var preflight: () -> Bool
    /// Create the tap whose `userInfo` is `token`. nil when it could not be created.
    public var install: (_ token: Int) -> InstalledEventTap?

    public init(preflight: @escaping () -> Bool, install: @escaping (Int) -> InstalledEventTap?) {
        self.preflight = preflight
        self.install = install
    }

    public static let system = EventTapInstaller(preflight: { CGPreflightListenEventAccess() },
                                                 install: HotkeyService.installSystemTap)
}

/// Records installs and teardowns instead of touching CoreGraphics. Lives beside the real installer
/// (like `MockHotkeyArming` beside `CapabilityWatcher`) so the tests need no event tap.
public final class StubEventTap {
    public var preflightResult = true
    public var installSucceeds = true
    public private(set) var installed: [Int] = []
    public private(set) var invalidated: [Int] = []
    public private(set) var enableCalls: [(token: Int, enabled: Bool)] = []

    public init() {}

    /// Tokens whose tap was created and never invalidated. Must never exceed 1 for one service.
    public var liveTaps: [Int] { installed.filter { !invalidated.contains($0) } }

    public var installer: EventTapInstaller {
        EventTapInstaller(preflight: { [weak self] in self?.preflightResult ?? false }) { [weak self] token in
            guard let self, self.installSucceeds else { return nil }
            self.installed.append(token)
            return InstalledEventTap(
                setEnabled: { [weak self] on in self?.enableCalls.append((token, on)) },
                invalidate: { [weak self] in
                    guard let self, !self.invalidated.contains(token) else { return }
                    self.invalidated.append(token)
                }
            )
        }
    }
}

// MARK: - The service

/// Global modifier-key listener (T3): a listen-only CGEvent tap on `flagsChanged`, feeding
/// `HotkeyStateMachine`. Requires Input Monitoring; `start()` returns false (and the app falls back
/// to the menu item) without it.
///
/// ## Thread and lifetime discipline
/// * The tap callback is a **non-capturing** C function. It touches no Swift object directly: it
///   copies the three scalars it needs out of the `CGEvent` (valid only for the duration of the
///   callback) and hands them, plus the token, to `deliver(token:…)`.
/// * `deliver` re-resolves the token and applies the event **on the main thread**. The run-loop
///   source is added to `CFRunLoopGetMain()`, so today that is already true and the hop is a no-op;
///   the check is what keeps it true if the source is ever moved to another run loop, since
///   everything downstream of `onAction` — the pill, the overlay, the coordinator — is main-actor.
/// * There is exactly one live tap per service at a time: `start()` tears down any leftover before
///   creating one, and `stop()`/`deinit` invalidate the port *and* retire the token.
public final class HotkeyService {
    public static let bindingDefaultsKey = "hotkeyBinding"
    /// P4.2 — the second (act) key persists under its own key; default Right ⌘.
    public static let actBindingDefaultsKey = "actHotkeyBinding"

    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    public private(set) var machine: HotkeyStateMachine
    public private(set) var binding: HotkeyBinding
    public private(set) var isRunning = false
    public var isPaused = false

    /// Swappable so the lifecycle is testable without Input Monitoring. Changing it while armed does
    /// nothing until the next `start()`.
    public var installer: EventTapInstaller = .system

    private var installedTap: InstalledEventTap?
    /// The token the live tap carries, or nil while disarmed. Internal so the tests can prove that a
    /// torn-down tap's token no longer resolves.
    private(set) var tapToken: Int?

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
    /// observed by the poll arms exactly once and never stacks a second tap.
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

    /// The tap outlives the object unless something tears it down, and a run loop holding a port
    /// whose owner is gone is exactly the shape of a use-after-free. There was no `deinit` here
    /// until 1.6.7.
    deinit { teardownTap() }

    public func setBinding(_ kind: HotkeyBinding.Kind) {
        binding = HotkeyBinding(kind: kind)
        defaults.set(kind.rawValue, forKey: bindingKey)
        machine.reset()
    }

    /// Feed a raw modifier event. Public so tests can synthesize `CGEvent`s without a tap.
    /// Main thread only when it is reached from a tap — see `deliver(token:…)`.
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

    // MARK: Tap lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        // A half-torn state — a tap installed while `isRunning` is false — must never survive into a
        // second creation. One service, one live tap, always.
        teardownTap()
        guard installer.preflight() else {
            Log.app.warning("hotkey: Input Monitoring not granted; falling back to menu item")
            return false
        }
        let token = HotkeyTapRegistry.register(self)
        guard let tap = installer.install(token) else {
            HotkeyTapRegistry.retire(token)
            Log.app.error("hotkey: CGEvent.tapCreate failed")
            return false
        }
        installedTap = tap
        tapToken = token
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

    /// Tear the tap down. Invalidating the port and the run-loop source, and retiring the token
    /// (rather than only dropping the references) is what guarantees a later `start()` cannot leave a
    /// second live tap behind and that an event already queued on the run loop reaches nothing.
    public func stop() {
        teardownTap()
        isRunning = false
        armedAt = nil
        eventsReceived = 0
        machine.reset()
    }

    /// Idempotent, and safe from `deinit` (it touches only CF objects and the registry).
    private func teardownTap() {
        installedTap?.setEnabled(false)
        installedTap?.invalidate()
        installedTap = nil
        if let tapToken { HotkeyTapRegistry.retire(tapToken) }
        tapToken = nil
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

    // MARK: The callback path

    /// The one place a tap callback becomes state. Called on the tap's callback thread.
    ///
    /// A callback for a tap that has been torn down resolves to nil and does nothing — a dictionary
    /// miss, never a touch of freed memory, because a token is not a pointer. The hop re-resolves
    /// rather than capturing the service, so a tap torn down *between* the callback and the next
    /// main-queue turn delivers nothing either (and the queued block cannot keep a dead service
    /// alive to be delivered to).
    static func deliver(token: Int, keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        guard let service = HotkeyTapRegistry.service(for: token) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                HotkeyTapRegistry.service(for: token)?.receiveFromTap(keyCode: keyCode, flags: flags,
                                                                     timestamp: timestamp)
            }
            return
        }
        service.receiveFromTap(keyCode: keyCode, flags: flags, timestamp: timestamp)
    }

    /// macOS disables a tap that took too long or that the user's input disturbed. Re-enabling it is
    /// the documented recovery, and it happens on the main thread like everything else.
    static func reenable(token: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { HotkeyService.reenable(token: token) }
            return
        }
        guard let service = HotkeyTapRegistry.service(for: token), let tap = service.installedTap else { return }
        Log.app.notice("hotkey: tap was disabled by the system — re-enabling")
        tap.setEnabled(true)
    }

    /// Counts the event for the liveness probe, then runs the gesture recogniser. Main thread only.
    private func receiveFromTap(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        eventsReceived += 1
        handle(keyCode: keyCode, flags: flags, timestamp: timestamp)
    }

    /// The production installer. The callback below is intentionally non-capturing: a capturing
    /// closure cannot be converted to `CGEventTapCallBack`, and more importantly there is nothing to
    /// capture — the token is the whole context.
    static func installSystemTap(token: Int) -> InstalledEventTap? {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let token = Int(bitPattern: userInfo)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    HotkeyService.reenable(token: token)
                } else {
                    HotkeyService.deliver(token: token,
                                          keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                          flags: event.flags.rawValue,
                                          timestamp: TimeInterval(event.timestamp) / 1_000_000_000)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(bitPattern: token)
        ) else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return InstalledEventTap(
            setEnabled: { CGEvent.tapEnable(tap: tap, enable: $0) },
            invalidate: {
                CGEvent.tapEnable(tap: tap, enable: false)
                if let source {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                    CFRunLoopSourceInvalidate(source)
                }
                CFMachPortInvalidate(tap)
            }
        )
    }
}
