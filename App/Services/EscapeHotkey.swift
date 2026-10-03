import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import Shared

// I2 — Escape during a turn (design §5 "Hotkey edge cases", §6 C1/C3/F1 "Esc").
//
// Escape is borrowed from the frontmost app only while a turn is live, through a Carbon
// `RegisterEventHotKey(kVK_Escape, 0)` — the same permission-free mechanism the chord backend uses.
// A registered hot key is taken system-wide, so it is registered on turn start (starting,
// listening, finishing, final preview, the write) and dropped on idle, held, error, and whenever a
// menu is tracking. It is never registered while idle: outside a turn Escape belongs to the user.

// MARK: - What Escape means right now

/// Where the current turn is, as far as Escape cares.
public enum EscapeTurnPhase: Equatable, Sendable {
    /// No turn, or a turn that is over or waiting on the user (held, error, landed, a notice).
    /// Escape stays with the frontmost app.
    case none
    /// Capture, finishing or final preview: nothing has been written.
    case beforeWrite
    /// The write has been attempted and its outcome is not known yet.
    case writing

    public var isTurn: Bool { self != .none }

    /// From the pill. Only the V4 turn states claim a turn. The legacy `.preview(text:)` is also
    /// the app's one-line notice channel ("Muted — …", deixis notes) and `.landing` covers both
    /// finalizing and landed, so neither can prove a turn is live; the engine mapping below covers
    /// the legacy path until the turn controller (S3) drives this directly.
    public init(_ state: PillState) {
        switch state {
        case .starting, .listening, .listeningQuiet, .latched, .warning, .finishing, .finalPreview:
            self = .beforeWrite
        case .inserting:
            self = .writing
        case .hidden, .idle, .ready, .muted, .unavailable, .error, .held, .landed, .landedPartial,
             .cancelled, .correcting, .editing, .undoAvailable, .transform, .meeting, .preview, .landing:
            self = .none
        }
    }

    /// From the engine. Legacy `.finalizing` is the final pass *and* the write in one step, so it
    /// cannot promise that nothing was written: it maps to `.writing`, which never claims a cancel.
    public init(_ state: EngineState) {
        switch state {
        case .starting, .listening, .previewing, .warning, .finishing:
            self = .beforeWrite
        case .finalizing:
            self = .writing
        case .idle, .prewarming, .landed, .error, .unavailable, .cancelled:
            self = .none
        }
    }
}

/// What the turn controller does with an Escape press (design §5).
public enum EscapeResolution: Equatable, Sendable {
    /// Before any write: cancel capture / preview, drop the turn's transient data, insert nothing,
    /// and show `.cancelled` ("Cancelled · nothing inserted") for `cancelledDwell`.
    case cancel
    /// The write has begun: never claim a cancellation. Resolve the write outcome first, then
    /// offer a safe Undo.
    case resolveWriteThenOfferUndo

    /// C4 → idle after 800 ms (design §6).
    public static let cancelledDwell: TimeInterval = 0.8

    public init?(_ phase: EscapeTurnPhase) {
        switch phase {
        case .none: return nil
        case .beforeWrite: self = .cancel
        case .writing: self = .resolveWriteThenOfferUndo
        }
    }
}

// MARK: - The backend seam

/// Installs the system-wide Escape hot key. Swappable so the lifecycle is testable without
/// registering a real hot key (which would take Escape from the whole machine for the test run).
public struct EscapeKeyBackend {
    /// Register Escape; presses carry `token`. nil when it could not be registered.
    public var install: (_ token: Int) -> InstalledHotkeySource?
    /// H11 — the key is one per process (Carbon refuses a second `kVK_Escape` registration with
    /// -9878): every controller on this backend shares one `EscapeOwnership` by default.
    public var isSystemWide: Bool

    public init(isSystemWide: Bool = false, install: @escaping (Int) -> InstalledHotkeySource?) {
        self.install = install
        self.isSystemWide = isSystemWide
    }

    /// Carbon `RegisterEventHotKey(kVK_Escape, 0)`. Needs no permission.
    public static let carbon = EscapeKeyBackend(isSystemWide: true, install: EscapeHotkey.installCarbonEscape)
}

/// H11 (old H8) — one Escape owner for the turn and the edit pill. Several `EscapeHotkey`s may
/// want Escape at once (the turn's, the transform preview's); only the newest claimant holds the
/// registration, so the system key is registered at most once (no -9878) and a press goes to the
/// surface on top. When it lets go, the previous claimant that still wants Escape gets it back.
/// Main thread, like `EscapeHotkey`.
public final class EscapeOwnership {
    /// The app's one owner for the system key.
    public static let shared = EscapeOwnership()

    private final class Weak {
        weak var hotkey: EscapeHotkey?
        init(_ hotkey: EscapeHotkey) { self.hotkey = hotkey }
    }
    private var claimants: [Weak] = []

    public init() {}

    /// The controller that holds Escape now (the newest live claimant).
    public var owner: EscapeHotkey? { claimants.last(where: { $0.hotkey != nil })?.hotkey }

    func claim(_ hotkey: EscapeHotkey) {
        claimants.removeAll { $0.hotkey == nil || $0.hotkey === hotkey }
        claimants.append(Weak(hotkey))
        arbitrate()
    }

    func release(_ hotkey: EscapeHotkey) {
        let before = claimants.count
        claimants.removeAll { $0.hotkey == nil || $0.hotkey === hotkey }
        if claimants.count != before || hotkey.isRegistered { hotkey.uninstall() }
        arbitrate()
    }

    /// A claimant went away without releasing (deinit): the next one takes Escape back.
    func prune() {
        claimants.removeAll { $0.hotkey == nil }
        arbitrate()
    }

    func isClaiming(_ hotkey: EscapeHotkey) -> Bool { claimants.contains { $0.hotkey === hotkey } }

    /// Everyone but the top lets go first; then the top registers.
    private func arbitrate() {
        let top = owner
        for entry in claimants { if let h = entry.hotkey, h !== top { h.uninstall() } }
        top?.install()
    }
}

/// Token → controller, so a Carbon callback never holds a pointer (same reasoning as
/// `HotkeyTapRegistry`): a retired token resolves to nil, a freed pointer to a crash.
enum EscapeHotkeyRegistry {
    private final class Entry {
        weak var owner: EscapeHotkey?
        init(_ owner: EscapeHotkey) { self.owner = owner }
    }

    private static let lock = NSLock()
    private static var nextToken = 1
    private static var entries: [Int: Entry] = [:]

    static func register(_ owner: EscapeHotkey) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(owner)
        return token
    }

    static func retire(_ token: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: token)
    }

    static func owner(for token: Int) -> EscapeHotkey? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.owner
    }
}

// MARK: - The controller

/// Holds Escape for exactly as long as a turn is live and turns a press into one call per turn.
///
/// Feed it the turn's state (`update(_:turn:)`, or `bind(to:)` a pill-state publisher) and whether
/// a menu is open; it registers and unregisters the hot key to match and calls `onEscape` with
/// what the press means. The turn controller (S3) owns the consequence — `TurnController.escape()`.
///
/// **Idempotent.** The first press of a turn fires; every later press of the same turn (a double
/// Escape, key repeat, a press that lands before the state has moved on) is swallowed. A turn is
/// one continuous stretch of turn states, or a new `TurnID` while in one.
///
/// Main thread only. Carbon hot-key handlers run there; `deliver(token:)` hops if it is not.
public final class EscapeHotkey {
    /// What the press means. Wired to `TurnController.escape()` (S3).
    public var onEscape: ((EscapeResolution) -> Void)?

    public private(set) var phase: EscapeTurnPhase = .none
    public private(set) var turn: TurnID?
    public private(set) var isMenuOpen = false
    /// Is the system-wide Escape hot key registered right now?
    public var isRegistered: Bool { installed != nil }
    /// Times the hot key has been registered; tests assert it never stacks.
    public private(set) var registrationCount = 0
    /// Presses that reached `onEscape`.
    public private(set) var firedCount = 0
    /// Presses swallowed because this turn already fired.
    public private(set) var swallowedCount = 0

    /// S10 — popovers and panels shown over the turn. A press closes the newest one first and
    /// stays with it (design §11: Escape dismisses a popover before cancelling a parent operation);
    /// the turn keeps its one Escape for the press after that.
    public var layers: EscapeLayerStack = .shared

    private let backend: EscapeKeyBackend
    private var installed: InstalledHotkeySource?
    private var token: Int?
    private var firedThisTurn = false
    private var menuDepth = 0
    private var menuObservers: [NSObjectProtocol] = []
    private var menuCenter: NotificationCenter?
    private var stateSubscription: AnyCancellable?
    private var draftSubscription: AnyCancellable?
    private var compositionOwnsEscape = false
    private var dismissDraft: (() -> Bool)?
    private var physicalKeyDown = false

    /// H11 — who holds the key among the controllers that want it.
    public let ownership: EscapeOwnership

    /// `ownership`: nil shares `EscapeOwnership.shared` for a system-wide backend (Carbon) and
    /// gives a test backend its own, so parallel tests never take Escape from each other.
    public init(backend: EscapeKeyBackend = .carbon, ownership: EscapeOwnership? = nil) {
        self.backend = backend
        self.ownership = ownership ?? (backend.isSystemWide ? .shared : EscapeOwnership())
    }

    deinit {
        uninstall()
        ownership.prune()
        stateSubscription?.cancel()
        if let menuCenter { menuObservers.forEach { menuCenter.removeObserver($0) } }
    }

    /// Would Escape be registered for this phase and menu state?
    public static func wantsRegistration(_ phase: EscapeTurnPhase, menuOpen: Bool) -> Bool {
        phase.isTurn && !menuOpen
    }

    // MARK: Inputs

    public func update(_ state: PillState, turn: TurnID? = nil) {
        update(phase: EscapeTurnPhase(state), turn: turn)
    }

    /// The legacy engine path (no turn controller yet). Labelled so `.idle` / `.listening` in a
    /// call site never has to guess which state type it means.
    public func update(engine state: EngineState, turn: TurnID? = nil) {
        update(phase: EscapeTurnPhase(state), turn: turn)
    }

    public func update(phase newPhase: EscapeTurnPhase, turn newTurn: TurnID? = nil) {
        if !newPhase.isTurn {
            // The turn is over: the next turn state starts a fresh one.
            firedThisTurn = false
            turn = nil
        } else if !phase.isTurn || (newTurn != nil && turn != nil && newTurn != turn) {
            // Entering a turn, or a different turn (a new latch segment) without passing idle.
            firedThisTurn = false
            turn = newTurn
        } else if turn == nil {
            turn = newTurn
        }
        phase = newPhase
        reconcile()
    }

    /// A menu is tracking (the status menu, a context menu): Escape must close it, so it goes back.
    public func setMenuOpen(_ open: Bool) {
        isMenuOpen = open
        reconcile()
    }

    /// Follows every menu the process tracks via `NSMenu.didBegin/EndTrackingNotification`, so the
    /// status menu needs no hook of its own. Nested menus count. Idempotent.
    public func observeMenuTracking(center: NotificationCenter = .default) {
        layers.observePopovers(center: center)
        guard menuObservers.isEmpty else { return }
        menuCenter = center
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] _ in
                self?.menuTracking(began: true)
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] _ in
                self?.menuTracking(began: false)
            },
        ]
    }

    /// Drives the registration from a pill-state stream (`PillViewModel.$state`).
    public func bind<P: Publisher>(to states: P) where P.Output == PillState, P.Failure == Never {
        stateSubscription = states.sink { [weak self] state in
            guard let self else { return }
            if Thread.isMainThread { self.update(state) } else { DispatchQueue.main.async { self.update(state) } }
        }
    }

    /// Inline editing consumes a press before the parent turn's once-only cancellation.
    /// During IME composition Carbon must release Escape to the native input context.
    public func bindDraftEditor(to pill: PillViewModel) {
        dismissDraft = { [weak pill] in
            guard let pill, pill.isEditingDraft else { return false }
            guard !pill.hasMarkedText else { return true }
            pill.cancelDraftEdits()
            return true
        }
        draftSubscription = pill.$isEditingDraft.combineLatest(pill.$hasMarkedText)
            .sink { [weak self] editing, composing in
                guard let self else { return }
                self.compositionOwnsEscape = editing && composing
                self.reconcile()
            }
    }

    private func menuTracking(began: Bool) {
        let apply = { [weak self] in
            guard let self else { return }
            self.menuDepth = max(0, self.menuDepth + (began ? 1 : -1))
            self.setMenuOpen(self.menuDepth > 0)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: The press

    /// One Escape press from the hot key. Internal so tests can press without Carbon.
    func press() {
        guard isRegistered, let resolution = EscapeResolution(phase) else { return }
        // S10 — an open popover takes this press; the turn is untouched and not marked as fired.
        if layers.dismissTop() {
            Log.app.notice("escape: closed a popover over the turn")
            return
        }
        if dismissDraft?() == true { return }
        guard !firedThisTurn else {
            swallowedCount += 1
            return
        }
        firedThisTurn = true
        firedCount += 1
        Log.app.notice("escape: \(resolution == .cancel ? "cancel before write" : "write under way — resolve, then offer Undo")")
        onEscape?(resolution)
    }

    // MARK: Registration

    private func reconcile() {
        if !compositionOwnsEscape, Self.wantsRegistration(phase, menuOpen: isMenuOpen) { register() } else { unregister() }
    }

    /// H11 — wants Escape: claim it (the newest claimant holds the one registration).
    private func register() {
        if ownership.isClaiming(self), ownership.owner === self, installed != nil { return }
        ownership.claim(self)
    }

    /// H11 — no longer wants Escape: hand it back to the previous claimant, if any.
    private func unregister() {
        guard ownership.isClaiming(self) || installed != nil else {
            physicalKeyDown = false
            return
        }
        ownership.release(self)
    }

    /// Wants Escape but another surface on top holds it (H11).
    public var isWaitingForEscape: Bool { ownership.isClaiming(self) && installed == nil }

    /// The physical registration (`EscapeOwnership` decides when).
    func install() {
        guard installed == nil else { return }
        let token = EscapeHotkeyRegistry.register(self)
        guard let source = backend.install(token) else {
            EscapeHotkeyRegistry.retire(token)
            // Another app may own a bare Escape hot key. The turn still works; only Escape is lost.
            Log.app.error("escape: could not register Escape for this turn")
            return
        }
        installed = source
        self.token = token
        registrationCount += 1
    }

    /// Idempotent, and safe from `deinit`.
    func uninstall() {
        physicalKeyDown = false
        installed?.invalidate()
        installed = nil
        if let token { EscapeHotkeyRegistry.retire(token) }
        token = nil
    }

    // MARK: Carbon

    /// 'VPES' — the signature on the Escape registration, distinct from the chord's 'VOIC'.
    static let carbonSignature = OSType(0x5650_4553)

    static func deliver(token: Int, pressed: Bool = true) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { deliver(token: token, pressed: pressed) }
            return
        }
        guard let owner = EscapeHotkeyRegistry.owner(for: token) else { return }
        if !pressed { owner.physicalKeyDown = false; return }
        guard !owner.physicalKeyDown else { return }
        owner.physicalKeyDown = true
        owner.press()
    }

    static func installCarbonEscape(token: Int) -> InstalledHotkeySource? {
        guard let handlerRef = installCarbonHandler(token: token) else { return nil }
        var hotKeyRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: carbonSignature, id: UInt32(token))
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            Log.app.error("escape: RegisterEventHotKey failed (\(status))")
            RemoveEventHandler(handlerRef)
            return nil
        }
        var removed = false
        return InstalledHotkeySource(
            setEnabled: { _ in },
            invalidate: {
                guard !removed else { return }
                removed = true
                UnregisterEventHotKey(hotKeyRef)
                RemoveEventHandler(handlerRef)
            }
        )
    }

    /// The press handler on the application target. Answers only for its own registration and
    /// passes every other hot key on (`eventNotHandledErr`) so the dictation and act chords keep
    /// working while Escape is held. Split from the registration so dispatch is testable.
    static func installCarbonHandler(token: Int) -> EventHandlerRef? {
        var handlerRef: EventHandlerRef?
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            let token = Int(bitPattern: userData)
            guard let event,
                  CarbonHotKeyEvent.matches(CarbonHotKeyEvent.id(of: event),
                                            signature: EscapeHotkey.carbonSignature, token: token) else {
                return OSStatus(eventNotHandledErr)
            }
            EscapeHotkey.deliver(token: token, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
            return noErr
        }, specs.count, &specs, UnsafeMutableRawPointer(bitPattern: token), &handlerRef)
        guard status == noErr, let handlerRef else {
            Log.app.error("escape: InstallEventHandler failed (\(status))")
            return nil
        }
        return handlerRef
    }
}
