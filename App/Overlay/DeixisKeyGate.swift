import Actions
import CoreGraphics
import Foundation

// G1 — the dictation key as the deixis trigger (V4.28, V4.31).
//
// Same trigger in both modes: a drag draws a box while the dictation key is physically down. In
// hold mode the key is down anyway. In latch the key is up, so a bare drag does nothing; pressing
// and holding the key while dragging draws the box — and that press is a *point*, not the tap that
// stops latch. The overlay is ordered front only while the key is down; `.enterLatch` releases the
// tap and hides it; a key-down inside latch re-arms both for the drag.

// MARK: - Is the key down?

extension HotkeyService {
    /// Reads the bound key off the system right now. Bare modifiers: the binding's flag bit in the
    /// session's modifier state — the same bit `HotkeyBinding.edge` classifies presses by. Chords:
    /// the chord's key. Neither read needs a permission. Swappable for tests.
    static var physicalKeyProbe: (HotkeyBinding) -> Bool = { binding in
        switch binding.style {
        case .bareModifier:
            return CGEventSource.flagsState(.combinedSessionState).rawValue & binding.kind.flagMask != 0
        case .chord:
            guard let chord = binding.kind.chord else { return false }
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(chord.keyCode))
        }
    }

    /// True between key-down and key-up of the bound dictation key: while the gesture recogniser
    /// holds a press, and also while latched (when the recogniser has already gone idle on the
    /// press) for as long as the key is physically held.
    public var isDictationKeyDown: Bool {
        if isGestureKeyHeld { return true }
        return Self.physicalKeyProbe(binding)
    }

    /// The gesture recogniser is holding a press (key-down seen, key-up not yet). For the act key,
    /// whose held press brackets deixis capture the same way.
    public var isGestureKeyHeld: Bool {
        if case .keyDown = machine.phase { return true }
        return false
    }
}

// MARK: - The rule, as a pure state machine

/// Interprets the hotkey's gesture stream for deixis: what reaches the session coordinator, when
/// the overlay is in front, and when the event tap is armed.
public struct DeixisKeyArbiter: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case idle
        /// The key is held from idle (a hold, or a tap on its way to latch).
        case holding
        /// Latched with the key up.
        case latched
        /// The key is held inside latch. `drew`: a box was dragged during this press, so it
        /// points rather than stops. `machineReportsRelease`: the gesture recogniser will emit an
        /// action at key-up; otherwise the release is found by polling the key.
        case latchPress(drew: Bool, machineReportsRelease: Bool)
    }

    /// What to do with the event tap / capture alignment.
    public enum Capture: Equatable, Sendable {
        /// A new turn: forget the last turn's boxes, pin the alignment, arm the tap.
        case beginTurn
        /// Arm the tap inside the running (latched) turn.
        case rearm
        /// Release the tap; a box still being dragged is kept.
        case release
        /// Release the tap and drop the turn's boxes (nothing will land).
        case cancel
    }

    public enum Overlay: Equatable, Sendable {
        case show
        case hide(fading: Bool)
    }

    public struct Effects: Equatable, Sendable {
        /// Actions for `SessionCoordinator.handle`, in order.
        public var forward: [HotkeyStateMachine.Action] = []
        public var overlay: Overlay?
        public var capture: Capture?
        /// Start watching for the physical key-up.
        public var pollRelease = false
        /// The tap stays armed in latch ("draw without a key"): watch for latch ending elsewhere
        /// (menu, mute, an error) so it is not left listening.
        public var watchLatch = false

        public init(forward: [HotkeyStateMachine.Action] = [], overlay: Overlay? = nil,
                    capture: Capture? = nil, pollRelease: Bool = false, watchLatch: Bool = false) {
            self.forward = forward; self.overlay = overlay; self.capture = capture; self.pollRelease = pollRelease
            self.watchLatch = watchLatch
        }
    }

    public private(set) var mode: Mode = .idle

    public init() {}

    public var isKeyDown: Bool {
        switch mode {
        case .holding, .latchPress: return true
        case .idle, .latched: return false
        }
    }

    /// One action from `HotkeyService.onAction`. `sessionLatched` is the session's own answer
    /// (latch can start and end from the menu, mute, sleep or an error, not only from the key).
    public mutating func handle(_ action: HotkeyStateMachine.Action, sessionLatched: Bool,
                                drawWithoutKey: Bool) -> Effects {
        sync(sessionLatched: sessionLatched)
        switch (mode, action) {
        case (.idle, .startCapture):
            mode = .holding
            return Effects(forward: [action], overlay: .show, capture: .beginTurn)

        case (.holding, .finalize):
            mode = .idle
            return Effects(forward: [action], overlay: .hide(fading: true), capture: .release)
        case (.holding, .cancelCapture):
            mode = .idle
            return Effects(forward: [action], overlay: .hide(fading: false), capture: .cancel)
        case (.holding, .enterLatch):
            // Latch ends deixis capture: tap released, overlay gone. "Draw without a key" keeps
            // the tap so a bare drag can still draw.
            mode = .latched
            return Effects(forward: [action], overlay: .hide(fading: false), capture: drawWithoutKey ? nil : .release,
                           watchLatch: drawWithoutKey)

        case (.latched, .finalize):
            // Key-down inside latch; the recogniser has already left latch. Hold the stop until we
            // know whether this press draws.
            mode = .latchPress(drew: false, machineReportsRelease: false)
            return Effects(overlay: .show, capture: .rearm, pollRelease: true)
        case (.latched, .startCapture):
            // Key-down inside latch after an earlier pointing press left the recogniser idle.
            mode = .latchPress(drew: false, machineReportsRelease: true)
            return Effects(overlay: .show, capture: .rearm)

        case (.latchPress(let drew, true), .finalize), (.latchPress(let drew, true), .cancelCapture),
             (.latchPress(let drew, true), .enterLatch):
            return release(drew: drew, drawWithoutKey: drawWithoutKey)

        default:
            // Nothing deixis cares about: pass it through unchanged.
            return Effects(forward: [action])
        }
    }

    /// A box started during the press (the drag reached box size).
    public mutating func regionStarted() {
        if case .latchPress(_, let reports) = mode { mode = .latchPress(drew: true, machineReportsRelease: reports) }
    }

    /// The physical key came up (found by polling) during a latch press the recogniser won't report.
    public mutating func keyReleased(sessionLatched: Bool, drawWithoutKey: Bool) -> Effects {
        guard case .latchPress(let drew, false) = mode else { return Effects() }
        guard sessionLatched else {
            mode = .idle
            return Effects(overlay: .hide(fading: false), capture: .release)
        }
        return release(drew: drew, drawWithoutKey: drawWithoutKey)
    }

    /// A look at the session while the tap is kept armed in latch. Latch ended without the key
    /// (menu, mute, an error): release the tap and fade what is left. `keepWatching` is false once
    /// there is nothing left to watch.
    public mutating func latchCheck(sessionLatched: Bool) -> (effects: Effects, keepWatching: Bool) {
        switch mode {
        case .latched:
            guard !sessionLatched else { return (Effects(), true) }
            mode = .idle
            return (Effects(overlay: .hide(fading: true), capture: .release), false)
        case .latchPress:
            return (Effects(), true)
        case .idle, .holding:
            return (Effects(), false)
        }
    }

    private mutating func release(drew: Bool, drawWithoutKey: Bool) -> Effects {
        if drew {
            // A press that overlapped a drag points: latch keeps listening, the box fades.
            mode = .latched
            return Effects(overlay: .hide(fading: true), capture: drawWithoutKey ? nil : .release,
                           watchLatch: drawWithoutKey)
        }
        // A plain press: the tap that stops latch.
        mode = .idle
        return Effects(forward: [.finalize], overlay: .hide(fading: true), capture: .release)
    }

    private mutating func sync(sessionLatched: Bool) {
        switch mode {
        case .latched, .latchPress:
            if !sessionLatched { mode = .idle }
        case .idle:
            if sessionLatched { mode = .latched }
        case .holding:
            break
        }
    }
}

// MARK: - The live controller

/// The capture side of the deixis service, as the key controller drives it.
public protocol DeixisCaptureControlling: AnyObject {
    func beginCapture(at instant: TimelineInstant?, newTurn: Bool)
    func endCapture(finishingDrag: Bool)
    func cancelTurn()
}

extension DeixisService: DeixisCaptureControlling {}

/// Runs `DeixisKeyArbiter` against the live pieces: forwards actions to the session coordinator
/// synchronously (as the hotkey block always did), arms and releases the tap, orders the overlay,
/// and polls the physical key while a latch press is open.
public final class DeixisKeyController: @unchecked Sendable {
    public private(set) var arbiter = DeixisKeyArbiter()
    private weak var capture: DeixisCaptureControlling?
    private let overlay: (DeixisKeyArbiter.Overlay) -> Void
    private let forward: (HotkeyStateMachine.Action) -> Void
    private let keyProbe: () -> Bool
    private let sessionLatched: () -> Bool
    private let drawWithoutKey: () -> Bool
    private let lock = NSLock()
    /// When false (tests), polling is driven by calling `pollRelease()`.
    public var autoPoll = true
    public var pollInterval: TimeInterval = 1.0 / 60
    /// A key that never reads as released (a stuck probe) is treated as released after this long.
    public var releaseTimeout: TimeInterval = 30
    private var timer: DispatchSourceTimer?
    private var pollStarted: Date?
    /// How often the session is looked at while the tap is kept armed in latch.
    public var latchWatchInterval: TimeInterval = 0.5
    private var latchTimer: DispatchSourceTimer?

    public init(capture: DeixisCaptureControlling?,
                overlay: @escaping (DeixisKeyArbiter.Overlay) -> Void,
                forward: @escaping (HotkeyStateMachine.Action) -> Void,
                keyProbe: @escaping () -> Bool,
                sessionLatched: @escaping () -> Bool,
                drawWithoutKey: @escaping () -> Bool) {
        self.capture = capture
        self.overlay = overlay
        self.forward = forward
        self.keyProbe = keyProbe
        self.sessionLatched = sessionLatched
        self.drawWithoutKey = drawWithoutKey
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        lock.lock()
        let effects = arbiter.handle(action, sessionLatched: sessionLatched(), drawWithoutKey: drawWithoutKey())
        lock.unlock()
        apply(effects)
    }

    /// A drag reached box size (`DeixisService.onRegionStarted`).
    public func regionStarted() {
        lock.lock(); arbiter.regionStarted(); lock.unlock()
    }

    /// One poll of the physical key. Returns true when the press was resolved.
    @discardableResult
    public func pollRelease(now: Date = Date()) -> Bool {
        lock.lock()
        guard case .latchPress(_, false) = arbiter.mode else { lock.unlock(); stopPolling(); return true }
        let timedOut = pollStarted.map { now.timeIntervalSince($0) > releaseTimeout } ?? false
        guard !keyProbe() || timedOut else { lock.unlock(); return false }
        let effects = arbiter.keyReleased(sessionLatched: sessionLatched(), drawWithoutKey: drawWithoutKey())
        lock.unlock()
        stopPolling()
        apply(effects)
        return true
    }

    /// One look at the session while the tap is kept in latch. Returns whether to keep watching.
    @discardableResult
    public func checkLatch() -> Bool {
        lock.lock()
        let (effects, keep) = arbiter.latchCheck(sessionLatched: sessionLatched())
        lock.unlock()
        if !keep { stopLatchWatch() }
        apply(effects)
        return keep
    }

    private func apply(_ effects: DeixisKeyArbiter.Effects) {
        switch effects.capture {
        case .beginTurn?: capture?.beginCapture(at: nil, newTurn: true)
        case .rearm?: capture?.beginCapture(at: nil, newTurn: false)
        case .release?: capture?.endCapture(finishingDrag: true)
        case .cancel?: capture?.cancelTurn()
        case nil: break
        }
        if let o = effects.overlay { overlay(o) }
        effects.forward.forEach(forward)
        if effects.pollRelease { startPolling() }
        if effects.watchLatch { startLatchWatch() }
    }

    private func startPolling() {
        lock.lock(); pollStarted = Date(); lock.unlock()
        guard autoPoll, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.pollRelease() }
        timer = t
        t.resume()
    }

    private func stopPolling() {
        timer?.cancel()
        timer = nil
    }

    private func startLatchWatch() {
        guard autoPoll, latchTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + latchWatchInterval, repeating: latchWatchInterval)
        t.setEventHandler { [weak self] in self?.checkLatch() }
        latchTimer = t
        t.resume()
    }

    private func stopLatchWatch() {
        latchTimer?.cancel()
        latchTimer = nil
    }
}
