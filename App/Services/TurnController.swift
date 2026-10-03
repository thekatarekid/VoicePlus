import AppKit
import Combine
import Engine
import Foundation
import Injection
import Shared

// S3 — the turn controller: preview before insert (design_v1 §5, §12; build doc S3).
//
// One turn is one press-to-outcome cycle with a `TurnID`: key down → snapshot of the destination →
// `starting` until capture is really open → `listening` / `listeningQuiet` → key up → `finishing`
// (microphone closed) → final pass + lander formatting → one immutable final payload →
// `finalPreview` for its dwell → revalidate the destination → insert once (commit guard keyed by
// `TurnID` + target revision) → `inserting` → outcome (`landed` verified / unverified / partial, or
// `held`). Every async result names its turn and is dropped when that turn has moved on (cancelled,
// "Use available text" taken, a new turn): clearing a timer is not enough (design §12).
//
// Latch segments and guided landings reach the same gate through `LandingGate.admit`: each is a
// turn of its own, serialized behind whatever is in the gate, so two payloads are never on screen
// or in flight at once, and a hold never inserts anything before release.
//
// Presentation is separate from the commit clock: the controller tells the pill what to show
// (`onPresent`), the pill tells the controller when the final frame rendered (`finalRendered`),
// and nothing about Spool or its animation ever triggers a write.

// MARK: - Clock

/// A cancellable scheduled callback.
public final class TurnTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let onCancel: () -> Void

    public init(onCancel: @escaping () -> Void = {}) { self.onCancel = onCancel }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let first = lock.withLock { () -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        if first { onCancel() }
    }
}

/// The turn's commit clock. Live: wall time and the main queue. Tests: a manual clock.
public protocol TurnClock: AnyObject {
    var now: Date { get }
    /// Runs `work` after `seconds` unless the returned timer is cancelled first.
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> TurnTimer
}

public final class MainQueueTurnClock: TurnClock {
    public init() {}
    public var now: Date { Date() }

    public func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) -> TurnTimer {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: item)
        return TurnTimer { item.cancel() }
    }
}

// MARK: - Destination snapshot

/// The key-down snapshot (design §5 step 1): app, element, selection, text version, display and
/// the secure flag. Revalidated before the one insert.
public struct TurnTarget: Equatable, Sendable {
    public var revision: TargetRevision
    public var displayID: UInt32?
    public var takenAt: Date

    public init(revision: TargetRevision, displayID: UInt32? = nil, takenAt: Date) {
        self.revision = revision
        self.displayID = displayID
        self.takenAt = takenAt
    }

    public var focus: FocusSnapshot? { revision.focus }

    /// The record's copy of it.
    public var destination: TurnRecord.Destination {
        TurnRecord.Destination(bundleID: revision.focus?.bundleID, appName: revision.focus?.appName,
                               role: revision.role, elementHash: revision.elementHash, displayID: displayID,
                               selection: revision.selection, textVersion: revision.textVersion,
                               isSecure: revision.isSecure)
    }

    /// The target revision a commit is keyed by: element, text version and selection together.
    public var commitRevision: Int {
        let selection = revision.selection.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "-"
        return TargetRevision.version(of: "\(revision.elementHash ?? 0)|\(revision.textVersion ?? 0)|\(selection)")
    }
}

/// Reads the destination now.
public protocol TurnTargetReading: AnyObject {
    func read(at date: Date) -> TurnTarget
}

/// The live reader: `FocusGuard.targetRevision()` (one AX round trip) plus the display under the
/// pointer, which is where the user is working when they press the key.
public final class FocusGuardTargetReader: TurnTargetReading {
    private let focusGuard: FocusGuard
    private let display: () -> UInt32?

    public init(focusGuard: FocusGuard, display: @escaping () -> UInt32? = FocusGuardTargetReader.pointerDisplay) {
        self.focusGuard = focusGuard
        self.display = display
    }

    public func read(at date: Date) -> TurnTarget {
        TurnTarget(revision: focusGuard.targetRevision(), displayID: display(), takenAt: date)
    }

    /// `CGDirectDisplayID` of the screen under the pointer.
    public static func pointerDisplay() -> UInt32? {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - Public vocabulary

/// What a key down turned into.
public enum TurnKeyDown: Equatable, Sendable {
    /// A new turn; open capture now.
    case began(TurnID)
    /// Key repeat or a second key-down for the turn already capturing: ignore it.
    case repeated(TurnID)
    /// K04 — a previous turn is still finishing, previewing or inserting. No second session.
    case busy(TurnID)
}

/// What freezes the dwell (design §5 step 4, §6 F1).
/// V5 Q8: `.emptyDraft` (folded into `.editing`) and `.hiddenApp` (Q9: the pill cannot be hidden)
/// are gone; every sensed reason is rebuilt from live state (`PauseSet`).
public enum DwellPause: String, CaseIterable, Sendable {
    case hover, focus, selection, review, editing, composition
}

/// The 10 s finishing offer (design §5): "Use available text" when a partial exists, else "Cancel".
public enum FinishingOffer: String, Equatable, Sendable {
    case useAvailableText
    case cancel

    public var label: String {
        switch self {
        case .useAvailableText: return "Use available text"
        case .cancel: return "Cancel"
        }
    }
}

/// How a payload leaves the preview.
enum DwellExit: Equatable {
    case insert
    case cancel
    case hold(reason: String)
}

// MARK: - The controller

public final class TurnController: LandingGate, @unchecked Sendable {
    // Timing (design §5).
    /// After this long finishing: "Still finishing your text".
    public var finishingWarningDelay: TimeInterval = PillState.finishingWarningDelay
    /// After this long finishing: "Use available text" / "Cancel".
    public var finishingOfferDelay: TimeInterval = 10
    /// VAD idle this long while capturing → `listeningQuiet`.
    public var quietAfter: TimeInterval = PillState.quietAfter
    /// C4 → idle.
    public var cancelledDwell: TimeInterval = EscapeResolution.cancelledDwell
    /// R2 — how long a safe Undo is offered after an Escape during the write.
    public var undoWindow: TimeInterval = 5
    /// A final frame the pill never acknowledged still starts the dwell after this long, so a pill
    /// that is not on screen cannot strand a payload. Logged when it happens.
    public var renderAckTimeout: TimeInterval = 1
    /// design §5 step 1: key down → capture open target.
    public static let captureOpenTarget: TimeInterval = 0.080

    // Collaborators.
    public let lander: UtteranceLander
    public let focusGuard: FocusGuard
    public let store: TurnStore
    public let clock: TurnClock
    private let targets: TurnTargetReading
    /// The dwell setting, read per payload.
    public var dwell: () -> PreviewDwell
    /// Owner decision — pull back to the key-down app and window before typing (nil: hold instead).
    public var pullBack: FocusPullBacking?
    /// Range-safe replace for Undo (`ReplaceRangeEditor` over the live `SystemAccess`).
    public var replaceRange: ((ReplaceRangeRequest) -> ReplaceRangeOutcome)?
    /// Where the key-down snapshot's AX read runs. Live: off the key-down path.
    public var snapshotQueue: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// Where `onPresent` / `onNotice` / `onOffer` / `onLanded` run. Live: the main queue, in order.
    public var ui: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    // Outputs.
    /// The pill state the turn wants shown now.
    public var onPresent: ((PillState) -> Void)?
    /// V5 Q8 — the pill's live state for the self-healing pause rebuild; nil = no rebuild input.
    public var liveState: (() -> PauseLiveState?)?
    /// The turn's own row is no longer true (a quiet end, the Cancelled or Undo row timing out):
    /// take the pill down *if it still shows a turn state*. A notice, an error or a transform that
    /// replaced it in the meantime is never taken down by this.
    public var onRetract: (() -> Void)?
    /// The final payload's spans and the text rendered from them, as it is published (the pill maps
    /// its red-dotted uncertain words onto exactly that text, S5).
    public var onFinalSpans: (([TranscriptSpan], String) -> Void)?
    /// A recovery-catalogue notice (K04 busy, A06 no speech, K02 interrupted, D10 stale undo).
    public var onNotice: ((RecoveryEntry) -> Void)?
    /// H1 — a quiet notice (A06 after a silent hold) and how long after it is shown it must fade.
    /// Unset: `onNotice` with the catalogue's own fade.
    public var onQuietNotice: ((RecoveryEntry, TimeInterval) -> Void)?
    /// N17 — a too-short tap: no turn was kept; show how to dictate instead of a failure.
    public var onTapHint: (() -> Void)?
    /// N17 — how long a tap waits before its hint, so the first tap of a double-tap never flashes it.
    public var tapHintDelay: TimeInterval = HotkeyStateMachine.Timing.default.doubleTapWindow
    /// H2 (owner Q2(a)) — how long the tap hint stays up.
    public static let tapHintDwellDefault: TimeInterval = 1.6
    public var tapHintDwell: TimeInterval = TurnController.tapHintDwellDefault
    /// X2 — a one-line informational note on the notch (the Option-tap fallback). Unset: logged.
    public var onNote: ((String) -> Void)?
    /// How long a note stays up.
    public static let noteDwell: TimeInterval = 6
    /// H29 — the hands-free session's pieces so far (the latch runtime's tally). Read when the
    /// session's last piece has ended. Unset: no summary line.
    public var handsFreeTally: (() -> HandsFreeTally?)?
    /// H29 — "Hands-free ended · 3 inserted in Claude": shown once per session, after the last
    /// piece's own brief outcome.
    public var onHandsFreeEnded: ((TurnOutcome) -> Void)?
    /// H29 — how long after the last piece ends the summary replaces its brief outcome row (Q8:
    /// each piece flashes where it went first). Pieces still queued in the runtime land meanwhile.
    public var handsFreeSummaryDelay: TimeInterval = TurnController.handsFreeSummaryDelayDefault
    public static let handsFreeSummaryDelayDefault: TimeInterval = 1.0
    /// How long the summary line stays up.
    public static let handsFreeSummaryDwell: TimeInterval = 3
    /// H2 — the tap hint's dwell is over: take it down if it is still what the notch shows.
    public var onTapHintExpired: (() -> Void)?
    /// H2 / X3-taps — a tap over a visible non-capture notch: take whatever it shows down.
    public var onTapDismiss: (() -> Void)?
    /// H2 / X3-taps — the notch shows something that is not a live capture (read at key-down).
    public var surfaceShowing: (() -> Bool)?
    /// X1 (owner round 4) — audio is buffered from key-down, but the notch shows only after this
    /// long with no other input (Option + a key must never flash it). 0 shows it at key-down
    /// (tests); the live wiring uses `holdPresentDelayDefault`. A latch shows it at once.
    public var holdPresentDelay: TimeInterval = 0
    public static let holdPresentDelayDefault: TimeInterval = 0.300
    /// H2 — bumped by every hint shown and every dismissing tap, so a stale hint expiry never fires.
    /// H3 — and by every key-down, so a tap's delayed hint never lands over (or after) a new hold.
    private var tapHintGeneration = 0
    /// H3 (owner Q3.2) — a new turn began: whatever the notch still shows (a hint, an outcome, an
    /// error, an edit row) yields to it. Runs on `ui` just before the turn's `.starting` row.
    public var onHoldYield: (() -> Void)?
    /// The 10 s finishing offer appeared (or went away: `nil`).
    public var onOffer: ((TurnID, FinishingOffer?) -> Void)?
    /// Escape or Cancel before the write: stop capture and drop what is in flight (the session
    /// owner's escape).
    public var onCancelCapture: (() -> Void)?
    /// A hold turn reached its outcome (the delivery row, the held queue). Segments and guided
    /// landings return their result to their caller instead.
    public var onLanded: ((LandingResult) -> Void)?
    /// Any turn ended, with its final stage (deixis clears the turn's boxes on it).
    public var onTurnEnded: ((TurnID, TurnStage) -> Void)?
    /// T-schema verify — the turn's key-down surface resolution (N9 resolver, via the app's
    /// `TurnSurfaceContext`). Read off the key-up thread (it may wait for an in-flight resolve) and
    /// recorded into `turn_records.surface_kind` / `surface_signals_json`. `nil` = not wired.
    public var surfaceForTurn: (() -> SurfaceResolution?)?

    // State.
    private let lock = NSLock()
    private var turns: [TurnID: Turn] = [:]
    private var captureID: TurnID?
    private var gateOwner: TurnID?
    private var gateWaiters: [(TurnID, CheckedContinuation<Void, Never>)] = []
    private var undo: UndoOffer?
    /// A transient row (Cancelled, Undo) is on the pill: engine states must not take it down.
    private var holdingPresentation = false
    /// Async work under way (formatting, writing). Parked turns (dwelling, queued) do not count.
    private var busyCount = 0

    public init(lander: UtteranceLander, focusGuard: FocusGuard, store: TurnStore, clock: TurnClock = MainQueueTurnClock(),
                targets: TurnTargetReading? = nil, dwell: @escaping () -> PreviewDwell = { .immediate }) {
        self.lander = lander
        self.focusGuard = focusGuard
        self.store = store
        self.clock = clock
        self.targets = targets ?? FocusGuardTargetReader(focusGuard: focusGuard)
        self.dwell = dwell
        // Held text the user resolves later updates the turn it came from.
        let previous = focusGuard.onResolved
        focusGuard.onResolved = { [weak self] item, how in
            previous?(item, how)
            self?.heldResolved(item, how)
        }
    }

    /// Undo edits through `ReplaceRangeEditor` over `system` (range-safe: it only replaces a range
    /// that still holds the expected text).
    public func useReplaceRange(over system: SystemAccess) {
        let editor = ReplaceRangeEditor(system: system)
        replaceRange = { editor.replace($0) }
    }

    // MARK: Reading

    /// The stage of `id`, while the controller still tracks it.
    public func stage(of id: TurnID) -> TurnStage? { lock.withLock { turns[id]?.stage } }

    /// The turn bound to capture (hold, or the latched session's trailing turn).
    public var captureTurn: TurnID? { lock.withLock { captureID } }

    /// The turn in the preview → insert gate.
    public var gateTurn: TurnID? { lock.withLock { gateOwner } }

    /// A payload is on screen or being written: the latch timer must not replace it.
    public var isGateBusy: Bool {
        lock.withLock { gateOwner.flatMap { turns[$0]?.stage }.map { $0 == .finalPreview || $0 == .inserting } ?? false }
    }

    /// The finishing offer on the capture turn, if one is up.
    public var finishingOffer: FinishingOffer? {
        lock.withLock { turns.values.first { $0.origin == .hold && $0.stage == .finishing && $0.offer != nil }?.offer }
    }

    /// Whether an Undo is on offer.
    public var isUndoAvailable: Bool { lock.withLock { undo != nil } }

    /// I2 — what an Escape press means right now, from the turns themselves (the pill's state
    /// cannot say: live words are drawn as `.preview`, which is also the notice channel).
    public var escapePhase: EscapeTurnPhase {
        lock.withLock {
            // N23 — a new capture that began while the previous text was being typed: Escape
            // cancels the capture, never the write behind it.
            if let id = captureID, turns[id]?.stage.isCapturing == true { return .beforeWrite }
            if turns.values.contains(where: { $0.stage == .inserting }) { return .writing }
            return turns.values.contains(where: { $0.stage.isBeforeWrite }) ? .beforeWrite : .none
        }
    }

    /// The turn an Escape acts on first: the one capturing, else the one in the gate.
    public var currentTurn: TurnID? { lock.withLock { captureID ?? gateOwner } }

    /// The destination's name from the key-down snapshot of the turn capturing (else the one in
    /// the gate), once the snapshot has been read.
    public var currentDestinationName: String? {
        lock.withLock { (captureID ?? gateOwner).flatMap { turns[$0]?.destinationName } }
    }

    /// The live preview's info, for tests and surfaces.
    public var previewInfo: FinalPreviewInfo? {
        lock.withLock { previewTurnLocked().map(previewInfoLocked) }
    }

    /// The pill filter (`DictationCoordinator`): does an engine state get to the pill right now?
    /// While a turn owns the pill (starting → finishing → preview → inserting, a Cancelled or Undo
    /// row) engine states that would contradict it are dropped. Errors always pass.
    public func admitsEngineState(_ state: EngineState) -> Bool {
        switch state {
        case .error, .unavailable: return true
        default: break
        }
        return lock.withLock {
            if let owner = gateOwner, let stage = turns[owner]?.stage, stage == .finalPreview || stage == .inserting {
                return false
            }
            if turns.values.contains(where: { $0.origin == .hold && $0.stage == .finishing }) { return false }
            guard let id = captureID, let turn = turns[id] else { return !holdingPresentation }
            if turn.presentDeferred, turn.stage.isCapturing { return false }
            switch turn.stage {
            case .starting, .listening:
                switch state {
                case .listening, .previewing, .warning: return true
                default: return false
                }
            case .listeningQuiet:
                if case .warning = state { return true }
                return false
            default:
                return false
            }
        }
    }

    // MARK: Capture — key down

    /// Key down. Snapshot the destination and start a turn — or refuse (K04) while another is
    /// finishing, previewing or inserting, or ignore a repeat of the key already down.
    @discardableResult
    public func keyDown(latched: Bool = false) -> TurnKeyDown {
        let now = clock.now
        var fx = Effects()
        let overSurface = surfaceShowing?() ?? false
        let verdict = lock.withLock { () -> TurnKeyDown in
            if let id = captureID, let turn = turns[id], turn.stage.isCapturing { return .repeated(id) }
            if let busy = busyTurnLocked(), !latched { return .busy(busy) }
            undo?.timer.cancel()
            undo = nil
            let turn = Turn(id: TurnID(), origin: .hold, startedAt: now)
            turn.latched = latched
            turn.overSurface = overSurface
            turns[turn.id] = turn
            captureID = turn.id
            holdingPresentation = false
            tapHintGeneration &+= 1
            fx.save(turn)
            if holdPresentDelay > 0, !latched {
                turn.presentDeferred = true
            } else {
                fx.yieldToHold()
                fx.present(.starting)
            }
            return .began(turn.id)
        }
        switch verdict {
        case .began(let id):
            fx.run(self)
            if holdPresentDelay > 0, !latched {
                _ = clock.schedule(after: holdPresentDelay) { [weak self] in self?.revealDeferred(id) }
            }
            Log.app.info("turn \(id.description): key down")
            snapshotQueue { [weak self] in
                guard let self else { return }
                let target = self.targets.read(at: now)
                self.applySnapshot(id, target, anchor: self.anchor(for: target))
            }
        case .busy(let id):
            Log.app.notice("turn: key down while \(id.description) is still in progress — K04")
            notice(.K04)
            // K04 keeps the current turn's true pose: the acknowledgment, then the turn again.
            _ = clock.schedule(after: RecoveryCatalog.fadeWindow.upperBound) { [weak self] in self?.representBusyTurn(id) }
        case .repeated:
            break
        }
        return verdict
    }

    /// Owner decision — what to pull back to: the snapshot's app and window (nil without a pull-back).
    private func anchor(for target: TurnTarget) -> PullBackAnchor? {
        target.focus.flatMap { pullBack?.remember($0) }
    }

    private func applySnapshot(_ id: TurnID, _ target: TurnTarget, anchor: PullBackAnchor?) {
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id], turn.target == nil else { return }
            turn.target = target
            turn.anchor = anchor
            turn.record.destination = target.destination
            fx.save(turn)
        }
        fx.run(self)
    }

    /// C0 → C1: capture is really open. "Listening" may be claimed from here.
    public func captureOpened(_ id: TurnID) {
        let now = clock.now
        var fx = Effects()
        let latency = lock.withLock { () -> TimeInterval? in
            guard let turn = turns[id], turn.stage == .starting else { return nil }
            turn.stage = .listening
            turn.record.capture.captureOpened = now
            fx.save(turn)
            if !turn.latched { armQuietLocked(turn) }
            return now.timeIntervalSince(turn.record.startedAt)
        }
        fx.run(self)
        if let latency {
            let ms = Int((latency * 1000).rounded())
            let met = latency <= Self.captureOpenTarget
            Log.app.info("turn \(id.description): capture open \(ms) ms after key down (target ≤ 80 ms: \(met ? "met" : "missed"))")
        }
    }

    /// Capture never opened (the engine could not start). The turn ends; nothing to land. The
    /// engine's own error row (which passes `admitsEngineState`) is left standing; a bare
    /// "Starting…" is taken down.
    ///
    /// BUG B — and the user is told. `.starting` suppresses the presence chin, so retracting it with
    /// nothing in its place was the one press that could leave no surface on screen at all. `reason`
    /// is the catalogue entry for whatever refused the start (A03 "Couldn’t start this microphone ·
    /// Nothing was recorded." when the caller knows nothing more specific) — catalogue copy only,
    /// exactly like K04 on the admission gate above.
    public func captureFailed(_ id: TurnID, reason: RecoveryID = .A03) {
        guard lock.withLock({ turns[id] != nil }) else { return }
        end(id, stage: .failed)
        retract()
        notice(reason)
    }

    /// Capture opened and then produced nothing usable — no audio blocks at all, or nothing but
    /// digital silence (`AudioPipeline`'s two watchdogs, reported as `.captureFailed`).
    ///
    /// This is the one exit `listeningQuiet` never had. "Listening · quiet" is the honest row for a
    /// quiet *room*, and nothing about it is time-bounded: `quietElapsed` sets the stage and no
    /// later event can clear it except speech that, in this failure, can never arrive. So a turn
    /// could sit there for the whole hold with no levels, no partials and no explanation. A capture
    /// that is silent for a knowable reason now ends the turn and says A05 instead.
    ///
    /// Unlike `captureFailed(_:reason:)` this takes no id: the pipeline's watchdogs fire from the
    /// audio side and know nothing about turns, so the live capture turn is looked up here.
    public func captureSilent(reason: RecoveryID = .A05) {
        let id = lock.withLock { () -> TurnID? in
            guard let id = captureID, turns[id]?.stage.isCapturing == true else { return nil }
            return id
        }
        guard let id else { return }
        end(id, stage: .failed)
        notice(reason)
        // Closing capture is the coordinator's (it owns the engine session), exactly as for
        // `captureFailed` and `captureCancelled`. This only ends the turn and says why.
    }

    /// Capture was cancelled without Escape (a too-short tap, a preemption, mute): the capture turn
    /// ends quietly. A turn already past key-up is left alone — it is no longer capture.
    public func captureCancelled(_ id: TurnID) {
        guard lock.withLock({ turns[id]?.stage.isCapturing ?? false }) else { return }
        end(id, stage: .cancelled)
        retract()
    }

    /// X2 — shows `text` as a transient note when no turn owns the notch (else it is only logged).
    public func showNote(_ text: String) {
        Log.app.notice("turn: note — \(text)")
        guard !hasOpenCapture else { return }
        ui { [weak self] in self?.onNote?(text) }
    }

    /// X1 (owner round 4) — the dictation key became a chord (Option + key, click or scroll): the
    /// capture turn vanishes with no record, no row, no hint, nothing saved. The combo itself went
    /// to the app in front untouched.
    public func captureAborted(_ id: TurnID) {
        guard lock.withLock({ turns[id]?.stage.isCapturing ?? false }) else { return }
        Log.app.info("turn \(id.description): dictation key chorded with another input — silent cancel")
        end(id, stage: .cancelled)
        store.remove(id)
        lock.withLock { tapHintGeneration &+= 1 }
        retract()
    }

    /// N17 — the key came up before the hold threshold (a tap, or the first tap of a double-tap).
    /// Not a failure and not a turn: the turn is dropped from the store (no "cancelled" row in
    /// history or `turn_records`), and once the double-tap window has passed with no new press the
    /// pill says how to dictate. Key down/up times stay in the log only.
    ///
    /// H2 (owner Q2(a), Q3.1) — a tap while the notch showed anything that is not a live capture
    /// (the hint itself, a notice, an outcome row) dismisses it and schedules nothing new. A hint
    /// that is shown goes after `tapHintDwell` on its own.
    public func captureTapped(_ id: TurnID) {
        guard let overSurface = lock.withLock({ turns[id].flatMap { $0.stage.isCapturing ? $0.overSurface : nil } })
        else { return }
        end(id, stage: .cancelled)
        store.remove(id)
        retract()
        if overSurface {
            Log.app.info("turn \(id.description): tap over a visible notch — dismiss, no turn record")
            lock.withLock { tapHintGeneration &+= 1 }
            if !hasOpenCapture { ui { [weak self] in self?.onTapDismiss?() } }
            return
        }
        Log.app.info("turn \(id.description): tap under the hold threshold — hint, no turn record")
        let tapGeneration = lock.withLock { () -> Int in tapHintGeneration &+= 1; return tapHintGeneration }
        _ = clock.schedule(after: tapHintDelay) { [weak self] in
            // H3 — a key-down since this tap (a hold, a double tap) owns the notch: no hint.
            guard let self, self.lock.withLock({ self.captureID == nil && self.tapHintGeneration == tapGeneration })
            else { return }
            let generation = self.lock.withLock { () -> Int in
                self.tapHintGeneration &+= 1
                return self.tapHintGeneration
            }
            self.ui { [weak self] in self?.onTapHint?() }
            _ = self.clock.schedule(after: self.tapHintDwell) { [weak self] in
                guard let self, self.lock.withLock({ self.tapHintGeneration == generation }) else { return }
                self.ui { [weak self] in self?.onTapHintExpired?() }
            }
        }
    }

    /// The session entered latch. Sticky for the turn: the latched session's last words are aimed
    /// at where focus is when it stops, and a latched turn shows the latch timer, not "quiet".
    public func noteLatched(_ latched: Bool) {
        guard latched else { return }
        let id = lock.withLock { () -> TurnID? in
            guard let id = captureID, let turn = turns[id] else { return nil }
            turn.latched = true
            turn.quietTimer?.cancel()
            turn.quietTimer = nil
            return id
        }
        // X1 — hands-free shows at once, not after the hold delay.
        if let id { revealDeferred(id) }
    }

    /// X1 — the hold delay passed with the key still down and no other input: show the notch now
    /// (the stage it has reached), yielding whatever it showed (H3).
    func revealDeferred(_ id: TurnID) {
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id], turn.presentDeferred else { return }
            turn.presentDeferred = false
            guard captureID == id, turn.stage.isCapturing else { return }
            fx.yieldToHold()
            switch turn.stage {
            case .listening: fx.present(.listening(level: 0))
            case .listeningQuiet: fx.present(.listeningQuiet)
            default: fx.present(.starting)
            }
        }
        fx.run(self)
    }

    /// VAD: speech started (`true`) or ended (`false`).
    public func noteVoiceActivity(speech: Bool) {
        var fx = Effects()
        lock.withLock {
            guard let id = captureID, let turn = turns[id], turn.stage == .listening || turn.stage == .listeningQuiet,
                  !turn.latched else { return }
            if speech {
                turn.quietTimer?.cancel()
                turn.quietTimer = nil
                turn.speaking = true
                if turn.stage == .listeningQuiet {
                    turn.stage = .listening
                    fx.save(turn)
                    // Back to "Listening"; the pill keeps the turn's live words, and the engine's
                    // next preview (admitted again from here) updates them. Never `.preview(text:)`
                    // from here: with capture open the pill reads that as a lane note, not words.
                    fx.present(.listening(level: 0))
                }
            } else {
                turn.speaking = false
                armQuietLocked(turn)
            }
        }
        fx.run(self)
    }

    private func armQuietLocked(_ turn: Turn) {
        turn.quietTimer?.cancel()
        let id = turn.id
        turn.quietTimer = clock.schedule(after: quietAfter) { [weak self] in self?.quietElapsed(id) }
    }

    private func quietElapsed(_ id: TurnID) {
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id], turn.stage == .listening, !turn.speaking, !turn.latched else { return }
            turn.stage = .listeningQuiet
            fx.save(turn)
            fx.present(.listeningQuiet)
        }
        fx.run(self)
    }

    /// The live words so far (engine preview). Kept for "Use available text".
    public func notePartial(_ text: String) {
        lock.withLock {
            guard let id = captureID, let turn = turns[id], turn.stage.isCapturing else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { turn.partialText = trimmed }
        }
    }

    // MARK: Capture — key up and the final pass

    /// Key up: the microphone closes now, `finishing` begins. `false` for a duplicate key-up, or a
    /// turn that already moved on — the caller then does nothing.
    @discardableResult
    public func keyUp(_ id: TurnID) -> Bool {
        let now = clock.now
        var fx = Effects()
        let accepted = lock.withLock { () -> Bool in
            guard let turn = turns[id], turn.stage.isCapturing else { return false }
            turn.stage = .finishing
            turn.record.capture.captureClosed = now
            turn.quietTimer?.cancel()
            turn.quietTimer = nil
            if captureID == id { captureID = nil }
            fx.save(turn)
            fx.present(.finishing(elapsedWarning: false))
            turn.slowTimer = clock.schedule(after: finishingWarningDelay) { [weak self] in self?.finishingSlow(id) }
            turn.offerTimer = clock.schedule(after: finishingOfferDelay) { [weak self] in self?.finishingOffer(id) }
            return true
        }
        guard accepted else {
            Log.app.info("turn \(id.description): duplicate key up ignored")
            return false
        }
        fx.run(self)
        recordSurface(id)
        // A latched session's last words close now: aim them at where focus is now.
        if lock.withLock({ turns[id]?.latched ?? false }) {
            let target = targets.read(at: now)
            let anchor = self.anchor(for: target)
            lock.withLock {
                guard let turn = turns[id] else { return }
                turn.target = target
                turn.anchor = anchor
                turn.record.destination = target.destination
            }
        }
        return true
    }

    /// T-schema verify — the surface that chose this turn's write plan, so every turn explains
    /// itself. Kind plus signal labels only (never field contents); history-off rules are the
    /// store's. Taken at key-up, before a newer press can re-resolve (N23 waits for final text).
    private func recordSurface(_ id: TurnID) {
        guard let provider = surfaceForTurn else { return }
        let store = self.store
        DispatchQueue.global(qos: .utility).async {
            guard let surface = provider() else { return }
            store.setExtras(id) { extras in
                if extras.surfaceKind == nil { extras.surfaceKind = surface.kind.id }
                if extras.surfaceSignals == nil { extras.surfaceSignals = Self.signalMap(surface) }
            }
        }
    }

    static func signalMap(_ surface: SurfaceResolution) -> [String: String] {
        var map: [String: String] = [
            "confidence": String(format: "%.2f", surface.confidence),
            "web_area": surface.isWebArea ? "1" : "0",
        ]
        if surface.isFallback { map["fallback"] = surface.candidate.id }
        for (i, signal) in surface.signals.prefix(12).enumerated() { map["signal\(i)"] = signal }
        return map
    }

    private func finishingSlow(_ id: TurnID) {
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id], turn.stage == .finishing, !turn.payloadStarted else { return }
            turn.slow = true
            fx.present(.finishing(elapsedWarning: true))
        }
        fx.run(self)
    }

    private func finishingOffer(_ id: TurnID) {
        var fx = Effects()
        let offer = lock.withLock { () -> FinishingOffer? in
            guard let turn = turns[id], turn.stage == .finishing, !turn.payloadStarted else { return nil }
            let offer: FinishingOffer = (turn.partialText?.isEmpty == false) ? .useAvailableText : .cancel
            turn.offer = offer
            fx.present(.finishing(elapsedWarning: true))
            return offer
        }
        fx.run(self)
        guard let offer else { return }
        Log.app.notice("turn \(id.description): final pass past \(Int(finishingOfferDelay)) s — offering \(offer.label)")
        ui { [weak self] in self?.onOffer?(id, offer) }
    }

    /// 10 s offer → "Use available text": the live words become the final payload; the engine's
    /// late result for this turn is dropped when it arrives.
    public func useAvailableText() {
        // The user's explicit choice: honoured whenever the turn is still finishing and has words
        // (the pill draws the button on its own 10 s clock, which may run a frame ahead of ours).
        let picked = lock.withLock { () -> (TurnID, String)? in
            guard let turn = turns.values.first(where: { $0.origin == .hold && $0.stage == .finishing }),
                  !turn.payloadStarted,
                  let partial = turn.partialText, !partial.isEmpty else { return nil }
            return (turn.id, partial)
        }
        guard let (id, partial) = picked else { return }
        Log.app.notice("turn \(id.description): using the available text; the late final pass will be dropped")
        finalizeAvailable(id, partial: partial)
    }

    /// The live words become the turn's final payload (the late final pass is dropped).
    private func finalizeAvailable(_ id: TurnID, partial: String) {
        ui { [weak self] in self?.onOffer?(id, nil) }
        // Streaming words carry no final confidence: they are neither flagged nor claimed as checked.
        let spans = [TranscriptSpan(text: partial, confidence: 0.5, audioRange: 0...0, provenance: [.asr], stability: .committed)]
        busy(+1)
        Task { [weak self] in
            await self?.finalize(id, spans: spans, source: .available)
            self?.busy(-1)
        }
    }

    /// Cancel on a finishing turn (or the 10 s offer's Cancel). N2 — once words exist (the payload
    /// started, or live words were heard) Cancel means "don't type here": the text is kept as held
    /// text (history, Insert here / Copy), never dropped. Only a turn with no words at all is
    /// cancelled outright, its late result dropped.
    public func cancelFinishing() {
        guard let id = lock.withLock({ turns.values.first { $0.origin == .hold && $0.stage == .finishing }?.id }) else { return }
        if keepWithoutTyping(id, awaitFinalPass: false) { return }
        cancelBeforeWrite(id, showCancelled: true)
        ui { [weak self] in self?.onOffer?(id, nil) }
        ui { [weak self] in self?.onCancelCapture?() }
    }

    /// N2 — "don't type here" after capture closed: the turn's words are held (saved to history with
    /// Insert here / Copy) instead of typed. A preview is held now; a payload being formatted is held
    /// when it reaches the gate; a turn still waiting for its final pass keeps the live words, or
    /// (`awaitFinalPass`, Escape with no live words yet) keeps whatever the final pass returns.
    /// `false` when there is nothing to keep (no words), so the caller cancels as before.
    @discardableResult
    func keepWithoutTyping(_ id: TurnID, awaitFinalPass: Bool) -> Bool {
        enum Plan { case none, preview, atGate, available(String) }
        let reason = DeliveryReason.keptByUser
        let plan = lock.withLock { () -> Plan in
            guard let turn = turns[id] else { return .none }
            switch turn.stage {
            case .finalPreview:
                let text = turn.payload?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return text.isEmpty ? .none : .preview
            case .finishing:
                if turn.payloadStarted {
                    turn.holdWhenReady = reason
                    return .atGate
                }
                if let partial = turn.partialText, !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turn.holdWhenReady = reason
                    return .available(partial)
                }
                guard awaitFinalPass else { return .none }
                turn.holdWhenReady = reason
                return .atGate
            default:
                return .none
            }
        }
        switch plan {
        case .none: return false
        case .preview: exitDwell(id, .hold(reason: reason))
        case .atGate: ui { [weak self] in self?.onOffer?(id, nil) }
        case .available(let partial): finalizeAvailable(id, partial: partial)
        }
        Log.app.notice("turn \(id.description): cancelled after recognition — kept, not typed (N2)")
        return true
    }

    /// The engine's final pass for turn `id`. Formats it into the final payload and hands it to the
    /// gate; returns once the payload is on screen or queued for it (or the turn ended). A result
    /// for a turn that was cancelled, or whose available text was already taken, is dropped here.
    public func finalize(_ id: TurnID, spans: [TranscriptSpan], stopReason: EngineStopReason? = nil) async {
        await finalize(id, spans: spans, source: .engine, stopReason: stopReason)
    }

    enum PayloadSource { case engine, available }

    private func finalize(_ id: TurnID, spans: [TranscriptSpan], source: PayloadSource,
                          stopReason: EngineStopReason? = nil) async {
        let claimed = lock.withLock { () -> Turn? in
            guard let turn = turns[id], turn.stage == .finishing, !turn.payloadStarted else { return nil }
            turn.payloadStarted = true
            turn.slowTimer?.cancel()
            turn.offerTimer?.cancel()
            turn.offer = nil
            return turn
        }
        guard let turn = claimed else {
            Log.app.notice("turn \(id.description): late \(source == .engine ? "final pass" : "result") dropped")
            return
        }
        busy(+1)
        defer { busy(-1) }
        let heard = spans.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard.isEmpty || stopReason?.isQuietReturn == true {
            Log.app.info("turn \(id.description): nothing to insert (\(stopReason.map { String(describing: $0) } ?? "empty"))")
            end(id, stage: .empty) { $0.rawText = spans.joinedText }
            // A latched session's trailing audio is usually empty (its last segment already closed
            // on an endpoint): that is the normal end of a latch, not "No speech detected".
            if turn.latched { retract() } else { silentHold(turn) }
            return
        }
        var fx = Effects()
        let focus = lock.withLock { () -> FocusSnapshot? in
            turn.record.rawText = spans.joinedText
            fx.save(turn)
            return turn.target?.focus
        } ?? focusGuard.snapshot()
        fx.run(self)
        let payload = await lander.land(spans, startedAt: turn.record.startedAt, focus: focus, inject: false)
        // N7 — the context step is bounded by the turn snapshot; its time goes in stage_ms.
        store.setExtras(id, save: false) {
            $0.setStage(TurnRecordExtras.Stage.context, ms: Int(payload.contextMs.rounded()))
            if let edit = payload.edit { $0.edit = edit }   // H12 — the edit's facts, never text
        }
        // Escape, Cancel or an interruption may have ended the turn while it was being formatted.
        guard lock.withLock({ turns[id]?.stage == .finishing }) else {
            Log.app.notice("turn \(id.description): payload dropped — the turn ended while it was formatted")
            return
        }
        guard payload.isAwaitingInsertion, !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishWithoutInsert(id, payload, latched: turn.latched)
            return
        }
        busy(+1)
        let lander = self.lander
        Task { [weak self] in
            guard let self else { return }
            let result = await self.runGate(id, payload: payload, lander: lander)
            self.busy(-1)
            // The outcome row first, then (Escape during the write) the Undo offer over it. A
            // payload that never reached the injector (cancelled, interrupted) has no outcome row.
            guard result.injection != nil else { return }
            self.ui { [weak self] in
                self?.onLanded?(result)
                self?.presentUndo(for: id)
            }
        }
        // Back to the caller once the payload is on screen or waiting for the gate.
        await previewReached(id)
    }

    /// The final pass threw. Nothing was written; the turn ends.
    public func finishFailed(_ id: TurnID, error: Error) {
        let entry = RecoveryCatalog.report(error)
        Log.app.notice("turn \(id.description): final pass failed — \(entry.id.rawValue)")
        end(id, stage: .failed)
    }

    /// Capture ended with nothing captured (released during warm-up, a start that failed).
    public func nothingCaptured(_ id: TurnID) {
        guard lock.withLock({ turns[id]?.stage.isBeforeWrite ?? false }) else { return }
        end(id, stage: .empty)
        retract()
    }

    /// A payload that is not text to insert: a command (repair, transform, act), a refusal (a
    /// password field), or nothing.
    private func finishWithoutInsert(_ id: TurnID, _ payload: LandingResult, latched: Bool) {
        let stage: TurnStage
        if let delivery = payload.delivery {
            stage = delivery.isHeld ? .held : (delivery.writeReachedDestination ? .landed : .failed)
        } else if payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stage = .empty
        } else {
            stage = .consumed
        }
        end(id, stage: stage) { record in
            record.finalText = payload.text
            record.outcome = payload.delivery
        }
        // A command's own surface (the transform pill, a repair notice) is left alone: `retract`
        // only takes down a turn row still showing "Finishing…".
        if stage == .empty, !latched, let turn = lock.withLock({ turns[id] }) {
            silentHold(turn)
        } else if stage == .consumed || stage == .empty { retract() }
        ui { [weak self] in self?.onLanded?(payload) }
    }

    // MARK: The gate (LandingGate)

    /// A latch segment or a guided landing: a turn of its own through the same preview → insert gate.
    public func admit(_ payload: LandingResult, from lander: UtteranceLander) async -> LandingResult {
        // Nothing to preview (formatting left no words): nothing to insert either.
        guard payload.isAwaitingInsertion,
              !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return payload }
        busy(+1)
        defer { busy(-1) }
        let now = clock.now
        let read = targets.read(at: now)
        let anchor = (payload.pending?.focus ?? read.focus).flatMap { pullBack?.remember($0) }
        var fx = Effects()
        let id = lock.withLock { () -> TurnID in
            let turn = Turn(id: TurnID(), origin: .admitted, startedAt: payload.pending?.startedAt ?? now)
            // The segment was aimed where focus was when it closed; the AX revision is read now.
            var revision = read.revision
            if let focus = payload.pending?.focus { revision.focus = focus }
            let target = TurnTarget(revision: revision, displayID: read.displayID, takenAt: now)
            turn.target = target
            turn.anchor = anchor
            turn.record.destination = target.destination
            turn.record.rawText = payload.pending?.rawText ?? ""
            turn.record.capture.captureClosed = now
            turn.stage = .finishing
            turn.payloadStarted = true
            turns[turn.id] = turn
            fx.save(turn)
            return turn.id
        }
        fx.run(self)
        Log.app.info("turn \(id.description): admitted to the gate")
        let result = await runGate(id, payload: payload, lander: lander)
        // The caller shows its own outcome; an Undo offer (Escape during the write) follows it.
        ui { [weak self] in self?.presentUndo(for: id) }
        return result
    }

    /// Serialize → preview → dwell → revalidate → insert once, through `lander` (the one that
    /// formatted the payload). The caller holds one busy token; waiting for the gate and dwelling
    /// release it.
    private func runGate(_ id: TurnID, payload: LandingResult, lander: UtteranceLander) async -> LandingResult {
        busy(-1)
        await acquireGate(id)
        busy(+1)
        defer { releaseGate(id) }
        let holdReason = lock.withLock { () -> String?? in
            guard let turn = turns[id], turn.stage == .finishing else { return .none }
            return .some(turn.holdWhenReady)
        }
        guard let holdReason else {
            reachPreview(id)
            return payload
        }
        if let reason = holdReason {
            // Interrupted (lock, sleep) before it reached the screen: keep it, do not insert it.
            reachPreview(id)
            return hold(id, payload, lander: lander, reason: reason, actual: focusGuard.snapshot())
        }
        publishPreview(id, payload)
        busy(-1)
        let decided = await dwellExit(id)
        busy(+1)
        // Freeze the latest reviewed revision only after the insertion decision.
        let payload = lock.withLock { turns[id]?.payload ?? payload }
        // N2 — a "don't type here" that raced the preview still wins over an insert.
        var exit = decided
        if case .insert = exit, let kept = lock.withLock({ turns[id]?.holdWhenReady }) { exit = .hold(reason: kept) }
        switch exit {
        case .cancel:
            return payload
        case .hold(let reason):
            return hold(id, payload, lander: lander, reason: reason, actual: focusGuard.snapshot())
        case .insert:
            return await insert(id, payload, lander: lander)
        }
    }

    private func acquireGate(_ id: TurnID) async {
        let free = lock.withLock { () -> Bool in
            guard gateOwner == nil else { return false }
            gateOwner = id
            return true
        }
        if free { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if gateOwner == nil { gateOwner = id; return true }
                gateWaiters.append((id, continuation))
                return false
            }
            if now { continuation.resume() } else { reachPreview(id) }
        }
    }

    private func releaseGate(_ id: TurnID) {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard gateOwner == id else { return nil }
            gateOwner = nil
            guard !gateWaiters.isEmpty else { return nil }
            let (nextID, continuation) = gateWaiters.removeFirst()
            gateOwner = nextID
            return continuation
        }
        next?.resume()
    }

    /// Resolves `previewReached(_:)` for `id`: the payload is on screen, queued, or the turn is over.
    private func reachPreview(_ id: TurnID) {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let turn = turns[id] else { return nil }
            turn.previewReached = true
            let waiter = turn.previewWaiter
            turn.previewWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    private func previewReached(_ id: TurnID) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                guard let turn = turns[id], !turn.previewReached else { return true }
                turn.previewWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    // MARK: Final preview and dwell

    private func publishPreview(_ id: TurnID, _ payload: LandingResult) {
        let now = clock.now
        let setting = dwell()
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id] else { return }
            // S5 — the marks the pill draws, mapped through formatting by the lander: their count is
            // "N words to review" (T05 "Review this phrase"), their ranges the record's. A removed
            // filler has no mark and is not counted; confidence never changes the V3 delay.
            let uncertain = payload.pending?.uncertainCount ?? 0
            let lowConfidence = uncertain > 0 || (payload.pending?.spans.contains { $0.isLowConfidence } ?? false)
            turn.payload = payload
            turn.stage = .finalPreview
            turn.manual = setting == .manual
            turn.immediate = setting == .immediate
            turn.dwellTotal = setting.seconds(lowConfidence: lowConfidence)
            turn.dwellRemaining = turn.dwellTotal ?? 0
            turn.uncertainCount = uncertain
            turn.phraseReview = payload.pending?.needsPhraseReview ?? false
            turn.record.finalText = payload.text
            turn.record.uncertainSpans = payload.pending?.uncertainRanges ?? []
            turn.record.capture.finalPublished = now
            fx.save(turn)
            fx.present(.finalPreview(previewInfoLocked(turn)))
            if turn.immediate {
                // N8 / owner decision — no preview pause: the preview may show, but the insert is
                // decided now, not after a rendered frame or a dwell.
                if turn.pendingExit == nil { turn.pendingExit = .insert }
            } else {
                turn.renderTimer = clock.schedule(after: renderAckTimeout) { [weak self] in self?.renderAckTimedOut(id) }
            }
        }
        // The spans reach the pill before the preview that draws them (its red-dotted words).
        if let spans = payload.pending?.spans {
            let text = payload.text
            ui { [weak self] in self?.onFinalSpans?(spans, text) }
        }
        fx.run(self)
        reachPreview(id)
    }

    private func previewInfoLocked(_ turn: Turn) -> FinalPreviewInfo {
        FinalPreviewInfo(text: turn.payload?.text ?? "", uncertainCount: turn.uncertainCount,
                         dwellRemaining: turn.manual ? 0 : turn.dwellRemaining, paused: !turn.pauses.isEmpty,
                         manual: turn.manual, destination: turn.destinationName,
                         needsPhraseReview: turn.phraseReview,
                         pauseReason: DwellPause.pauseReason(for: turn.pauses))
    }

    /// The pill drew the final payload's first frame: the dwell starts now (design §5 step 4).
    public func finalRendered(_ id: TurnID) {
        let now = clock.now
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id], turn.stage == .finalPreview, !turn.rendered else { return }
            turn.rendered = true
            turn.renderTimer?.cancel()
            turn.renderTimer = nil
            turn.record.capture.finalRendered = now
            fx.save(turn)
            startDwellLocked(turn)
        }
        fx.run(self)
    }

    /// Acknowledges the turn previewing `text` — for a pill that reports frames by content.
    public func finalRendered(text: String) {
        guard let id = lock.withLock({ previewTurnLocked().flatMap { $0.payload?.text == text ? $0.id : nil } }) else { return }
        finalRendered(id)
    }

    private func renderAckTimedOut(_ id: TurnID) {
        guard lock.withLock({ turns[id].map { $0.stage == .finalPreview && !$0.rendered } ?? false }) else { return }
        Log.app.notice("turn \(id.description): no rendered-final acknowledgment in \(renderAckTimeout) s; dwell starts now")
        finalRendered(id)
    }

    private func startDwellLocked(_ turn: Turn) {
        guard turn.rendered, !turn.manual, turn.pauses.isEmpty, turn.dwellTimer == nil else { return }
        let id = turn.id
        turn.dwellStartedAt = clock.now
        turn.dwellTimer = clock.schedule(after: turn.dwellRemaining) { [weak self] in self?.dwellElapsed(id) }
    }

    private func stopDwellLocked(_ turn: Turn) {
        guard let timer = turn.dwellTimer else { return }
        timer.cancel()
        turn.dwellTimer = nil
        if let started = turn.dwellStartedAt {
            turn.dwellRemaining = max(0, turn.dwellRemaining - clock.now.timeIntervalSince(started))
        }
        turn.dwellStartedAt = nil
    }

    private func dwellElapsed(_ id: TurnID) {
        let due = lock.withLock { () -> Bool in
            guard let turn = turns[id], turn.stage == .finalPreview, turn.pauses.isEmpty, !turn.manual else { return false }
            turn.dwellTimer = nil
            turn.dwellRemaining = 0
            return true
        }
        if due { exitDwell(id, .insert) }
    }

    /// Hover, focus, selection or Review freezes the dwell (design §5 step 4).
    public func pauseDwell(_ reason: DwellPause) {
        var fx = Effects()
        var logTurn: TurnID?
        lock.withLock {
            guard let turn = previewTurnLocked() else { return }
            if !turn.pauses.contains(reason) { logTurn = turn.id }
            let wasPaused = !turn.pauses.isEmpty
            let before = DwellPause.pauseReason(for: turn.pauses)
            turn.pauses.insert(reason)
            turn.pausesCauseless[reason] = nil
            stopDwellLocked(turn)
            // Q12 — the helper names the pause, so a change of reason redraws the row too.
            if !wasPaused || before != DwellPause.pauseReason(for: turn.pauses) {
                fx.present(.finalPreview(previewInfoLocked(turn)))
            }
            schedulePauseTickLocked(turn)
        }
        fx.run(self)
        // V5 Q13 — every pause with its reason and the pointer.
        if let logTurn { TurnEventDiagnostics.record(TurnEventDiagnostics.pauseEvent(reason.rawValue, resumed: false), turn: logTurn.diagnosticsKey) }
    }

    public func resumeDwell(_ reason: DwellPause) {
        var fx = Effects()
        var logTurn: TurnID?
        defer { if let logTurn { TurnEventDiagnostics.record(TurnEventDiagnostics.pauseEvent(reason.rawValue, resumed: true), turn: logTurn.diagnosticsKey) } }
        lock.withLock {
            guard let turn = previewTurnLocked() else { return }
            let before = DwellPause.pauseReason(for: turn.pauses)
            guard turn.pauses.remove(reason) != nil else { return }
            logTurn = turn.id
            turn.pausesCauseless[reason] = nil
            guard turn.pauses.isEmpty else {
                if before != DwellPause.pauseReason(for: turn.pauses) { fx.present(.finalPreview(previewInfoLocked(turn))) }
                return
            }
            turn.pauseTick?.cancel()
            turn.pauseTick = nil
            turn.dwellRemaining = max(0.15, turn.dwellRemaining)
            fx.present(.finalPreview(previewInfoLocked(turn)))
            startDwellLocked(turn)
        }
        fx.run(self)
    }

    /// V5 Q8 — rebuild the preview's pauses from live state: sensed reasons with a live cause are
    /// (re)applied, and one without a live cause for more than `PauseSet.grace` is dropped and logged.
    /// Called when a preview is presented and on a 100 ms tick while it is paused.
    public func rebuildPauses() {
        guard let live = liveState?() else { return }
        var fx = Effects()
        lock.withLock {
            guard let turn = previewTurnLocked() else { return }
            let wasPaused = !turn.pauses.isEmpty
            let before = DwellPause.pauseReason(for: turn.pauses)
            var set = PauseSet(reasons: turn.pauses, causelessSince: turn.pausesCauseless)
            let dropped = set.rebuild(from: live, now: clock.now)
            turn.pauses = set.reasons
            turn.pausesCauseless = set.causelessSince
            for reason in dropped {
                Log.app.fault("turn \(turn.id.description): dropped '\(reason.rawValue)' dwell pause — no live cause for > \(PauseSet.grace) s")
            }
            if wasPaused, turn.pauses.isEmpty {
                turn.pauseTick?.cancel()
                turn.pauseTick = nil
                turn.dwellRemaining = max(0.15, turn.dwellRemaining)
                fx.present(.finalPreview(previewInfoLocked(turn)))
                startDwellLocked(turn)
            } else if !wasPaused, !turn.pauses.isEmpty {
                stopDwellLocked(turn)
                fx.present(.finalPreview(previewInfoLocked(turn)))
            } else if before != DwellPause.pauseReason(for: turn.pauses) {
                fx.present(.finalPreview(previewInfoLocked(turn)))
            }
            schedulePauseTickLocked(turn)
        }
        fx.run(self)
    }

    private func schedulePauseTickLocked(_ turn: Turn) {
        guard !turn.pauses.isEmpty, turn.pauseTick == nil, turn.stage == .finalPreview, liveState != nil else { return }
        let id = turn.id
        turn.pauseTick = clock.schedule(after: PauseSet.tick) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.turns[id]?.pauseTick = nil }
            self.rebuildPauses()
        }
    }

    /// A correction in the preview (F2) starts the dwell over.
    public func resetDwell() {
        var fx = Effects()
        lock.withLock {
            guard let turn = previewTurnLocked() else { return }
            stopDwellLocked(turn)
            turn.dwellRemaining = turn.dwellTotal ?? 0
            fx.present(.finalPreview(previewInfoLocked(turn)))
            startDwellLocked(turn)
        }
        fx.run(self)
    }

    /// Retained drafts stay retained after editing; only an explicit delivery action can insert.
    public func reviseRetainedDraft(shown: PillState, original: String, edited: String, mapping: MarkMapping) -> Bool {
        guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch shown {
        case .held(let info):
            guard let held = focusGuard.heldText(id: info.id),
                  focusGuard.reviseHeld(info.id, expected: original, text: edited) else { return false }
            if let id = held.turnID {
                store.update(id) { $0.finalText = edited; $0.uncertainSpans = mapping.uncertainRanges }
            }
            return true
        case .error:
            guard let entry = store.recent(limit: 50).first(where: {
                $0.record.finalText == original && ($0.stage == .failed || $0.stage == .held)
            }) else { return false }
            store.update(entry.id) { $0.finalText = edited; $0.uncertainSpans = mapping.uncertainRanges }
            return true
        default: return false
        }
    }

    /// An accepted in-notch edit replaces the pending payload, before the single commit gate.
    @discardableResult
    public func revisePreview(text: String, mapping: MarkMapping, spans: [TranscriptSpan]) -> Bool {
        var fx = Effects()
        let accepted = lock.withLock { () -> Bool in
            guard let turn = previewTurnLocked(), turn.pendingExit == nil,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  var payload = turn.payload else { return false }
            stopDwellLocked(turn)
            payload.text = text
            payload.pending?.spans = spans
            payload.pending?.uncertainRanges = mapping.uncertainRanges
            payload.pending?.needsPhraseReview = mapping.needsPhraseReview
            turn.payload = payload
            turn.uncertainCount = mapping.count
            turn.phraseReview = mapping.needsPhraseReview
            turn.record.finalText = text
            turn.record.uncertainSpans = mapping.uncertainRanges
            turn.dwellRemaining = turn.dwellTotal ?? 0
            fx.save(turn)
            fx.present(.finalPreview(previewInfoLocked(turn)))
            startDwellLocked(turn)
            return true
        }
        fx.run(self)
        return accepted
    }

    /// "Insert text" — the manual-review action, or skipping the rest of the dwell.
    public func insertNow() {
        guard let id = lock.withLock({ () -> TurnID? in
            guard let turn = previewTurnLocked(), !turn.pauses.contains(.editing), !turn.pauses.contains(.composition),
                  !(turn.payload?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { return nil }
            return turn.id
        }) else { return }
        exitDwell(id, .insert)
    }

    /// "Cancel" on the preview. N2 — the words are recognised: kept as held text (history, Insert
    /// here / Copy), not typed. An empty draft (nothing to keep) is cancelled.
    public func cancelPreview() {
        guard let id = lock.withLock({ previewTurnLocked()?.id }) else { return }
        if keepWithoutTyping(id, awaitFinalPass: false) { return }
        cancelBeforeWrite(id, showCancelled: true)
    }

    /// V5 Q12 — the user emptied the draft and left the editor: there is nothing to keep, so the
    /// preview is cancelled ("Nothing was typed.").
    public func discardPreview() {
        guard let id = lock.withLock({ previewTurnLocked()?.id }) else { return }
        cancelBeforeWrite(id, showCancelled: true)
    }

    private func previewTurnLocked() -> Turn? {
        guard let id = gateOwner, let turn = turns[id], turn.stage == .finalPreview else { return nil }
        return turn
    }

    private func dwellExit(_ id: TurnID) async -> DwellExit {
        await withCheckedContinuation { (continuation: CheckedContinuation<DwellExit, Never>) in
            let ready = lock.withLock { () -> DwellExit? in
                guard let turn = turns[id] else { return .cancel }
                if let exit = turn.pendingExit { return exit }
                turn.exit = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Decides how the payload leaves the preview. First decision wins.
    private func exitDwell(_ id: TurnID, _ exit: DwellExit) {
        let continuation = lock.withLock { () -> CheckedContinuation<DwellExit, Never>? in
            guard let turn = turns[id], turn.pendingExit == nil else { return nil }
            if case .insert = exit {
                guard !turn.pauses.contains(.editing), !turn.pauses.contains(.composition),
                      !(turn.payload?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { return nil }
            }
            turn.pendingExit = exit
            turn.dwellTimer?.cancel()
            turn.dwellTimer = nil
            turn.pauseTick?.cancel()
            turn.pauseTick = nil
            turn.renderTimer?.cancel()
            turn.renderTimer = nil
            let continuation = turn.exit
            turn.exit = nil
            return continuation
        }
        continuation?.resume(returning: exit)
    }

    // MARK: Revalidate and insert once

    private func insert(_ id: TurnID, _ payload: LandingResult, lander: UtteranceLander) async -> LandingResult {
        let started = clock.now
        guard let (target, reviewed, anchor) = lock.withLock({ turns[id].flatMap { t in t.target.map { ($0, !t.immediate, t.anchor) } } }) else {
            // No snapshot ever arrived (the read is still running, or AX was unreadable): aim at the
            // payload's own focus; the injector still refuses a moved focus before posting.
            let fallback = TurnTarget(revision: TargetRevision(focus: payload.pending?.focus), takenAt: clock.now)
            return await write(id, payload, lander: lander, target: fallback)
        }
        // X3-handsfree (owner round 3) — the stop tap of a hands-free session: a focused text box
        // takes the last piece; nothing focused → the last piece goes to Notes ("no text field").
        if lock.withLock({ turns[id]?.latched ?? false }) {
            let now = focusGuard.targetRevision()
            if !Self.textBoxFocused(now) {
                Log.app.notice("turn \(id.description): hands-free stop with no text box focused — last piece to Notes")
                return hold(id, payload, lander: lander, reason: DeliveryReason.noDestination, actual: now.focus)
            }
        }
        let check = preWriteCheck(id, target: target, reviewed: reviewed, anchor: anchor, lander: lander)
        store.setExtras(id, save: false) { extras in
            extras.setStage(TurnRecordExtras.Stage.preWriteCheck, ms: Self.ms(started, self.clock.now))
            if let pulled = check.pullBackMs { extras.setStage(TurnRecordExtras.Stage.pullBack, ms: pulled) }
        }
        if let reason = check.holdReason {
            return hold(id, payload, lander: lander, reason: reason, actual: focusGuard.snapshot())
        }
        // H26 — no text field focused in a native app or one of our own windows → Notes ("no text
        // field"). Web/Electron content keeps N3's "deliver unverified".
        if let now = noTextField(payload) {
            Log.app.notice("turn \(id.description): no text field in \(now.bundleID) — saved to Notes (H26)")
            return hold(id, payload, lander: lander, reason: DeliveryReason.noDestination, actual: now)
        }
        // Aim the write at the key-down destination (the app may have been switched before key-up)
        // and its window, so the delivery ladder's window check compares against the right one.
        var aimed = payload
        if check.pulledBack, let focus = target.focus { aimed.pending?.focus = focus; aimed.pending?.bundleID = focus.bundleID }
        if let token = anchor?.windowToken { aimed.pending?.windowToken = token }
        return await write(id, aimed, lander: lander, target: target)
    }

    struct PreWriteCheck {
        var holdReason: String?
        var pulledBack = false
        var pullBackMs: Int?
    }

    /// N8 + owner decision — the ONE check right before the write: same app and window as the
    /// key-down snapshot (else pull back), not a password field. Text- and caret-changed holds only
    /// protect a review window, so they apply only when there was one (Manual review; the legacy
    /// timed dwell) — never to a turn typed right away. Secure input and the
    /// readable-field question stay with the injector's delivery ladder (N3/N4).
    private func preWriteCheck(_ id: TurnID, target: TurnTarget, reviewed: Bool, anchor: PullBackAnchor?,
                               lander: UtteranceLander) -> PreWriteCheck {
        var check = PreWriteCheck()
        let own = !reviewed || ownLandingSince(target, lander: lander)
        var verdict = focusGuard.revalidate(target.revision, ownLandingSinceSnapshot: own)
        if verdict == .unchanged, let anchor, let pullBack {
            switch pullBack.windowState(anchor) {
            case .changed, .gone: verdict = .focusChanged
            case .same, .none, .unknown: break
            }
        }
        if verdict == .focusChanged {
            guard let anchor, let pullBack else {
                Log.app.notice("turn \(id.description): destination changed and no pull-back — held (D01)")
                check.holdReason = DeliveryReason.destinationChanged
                return check
            }
            let t0 = clock.now
            let outcome = pullBack.pullBack(anchor)
            check.pullBackMs = Self.ms(t0, clock.now)
            Log.app.notice("turn \(id.description): pull back to \(anchor.focus.bundleID) — \(String(describing: outcome))")
            switch outcome {
            case .windowGone:
                check.holdReason = PullBackReason.windowGone
                return check
            case .failed:
                check.holdReason = PullBackReason.refocusFailed
                return check
            case .refocused:
                check.pulledBack = true
                // The refocus check: the same app is focused again, and it is not a password field.
                verdict = focusGuard.revalidate(target.revision, ownLandingSinceSnapshot: true)
                if verdict == .focusChanged { check.holdReason = PullBackReason.refocusFailed; return check }
            }
        }
        switch verdict {
        case .unchanged: break
        case .secureField: check.holdReason = DeliveryReason.secureField
        case .focusChanged: check.holdReason = DeliveryReason.destinationChanged
        case .textChanged, .selectionChanged:
            Log.app.notice("turn \(id.description): destination \(verdict.rawValue) during the preview — held (D01)")
            check.holdReason = DeliveryReason.destinationChanged
        }
        return check
    }

    /// X3-handsfree — is a text box focused? Nothing focused, or a known non-text role (a button,
    /// a list, the desktop) is "no". An unreadable or unfamiliar role (AXGroup, AXWebArea — web and
    /// Electron content whose AX tree lies, N3) is given the benefit of the doubt: the injector
    /// still refuses where it cannot type. Same rule as H26's `DeliveryLadder.fieldPresence`.
    static func textBoxFocused(_ revision: TargetRevision) -> Bool {
        guard revision.focus != nil else { return false }
        return DeliveryLadder.fieldPresence(role: revision.role, isSecure: revision.isSecure) != .none
    }

    /// H26 — the focus now (same app as key-down: the pre-write check passed) when it has no text
    /// field and the no-field rule applies to it (own window or native app); `nil` = write as usual.
    private func noTextField(_ payload: LandingResult) -> FocusSnapshot? {
        guard payload.pending != nil, !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let now = focusGuard.targetRevision()
        guard let focus = now.focus else { return nil }
        let own = OwnProcess.owns(focus)
        var field = DeliveryLadder.fieldPresence(role: now.role, isSecure: now.isSecure)
        if own, let reader = lander.system as? OwnTextFieldReading, let editable = reader.ownEditableTextFocused() {
            field = editable ? .textField : .none
        }
        let runtime = own ? nil : (lander.system as? AppRuntimeReading)?.appRuntime(pid: focus.pid)
        return DeliveryLadder.noFieldGoesToNotes(ownProcess: own, runtime: runtime, field: field) ? focus : nil
    }

    static func ms(_ a: Date, _ b: Date) -> Int { max(0, Int((b.timeIntervalSince(a) * 1000).rounded())) }

    /// "Caret still inside our landing memory": our own landing into this same element happened
    /// after the snapshot and nothing has touched the field since (`LandingMemory` is cleared by any
    /// click, key, scroll or app switch, and after 30 s). The element is matched by app and AX
    /// identity only: the role the landing was formatted for may be unknown.
    private func ownLandingSince(_ target: TurnTarget, lander: UtteranceLander) -> Bool {
        guard let last = lander.landingMemory.last, last.at >= target.takenAt,
              let now = focusGuard.snapshot(), let token = now.elementToken, !token.isEmpty,
              now.bundleID == target.focus?.bundleID else { return false }
        return last.element.bundleID == now.bundleID && last.element.elementToken == token
    }

    private func write(_ id: TurnID, _ payload: LandingResult, lander: UtteranceLander, target: TurnTarget) async -> LandingResult {
        let now = clock.now
        let key = TurnCommitKey(turnID: id, revision: target.commitRevision)
        var fx = Effects()
        let proceed = lock.withLock { () -> Bool in
            guard let turn = turns[id], turn.stage == .finalPreview else { return false }
            turn.stage = .inserting
            turn.commitKey = key
            turn.record.writeAttempted = true
            turn.record.capture.writeDispatched = now
            fx.save(turn)
            if !newerCaptureOpenLocked(than: id) { fx.present(.inserting(text: payload.text)) }
            return true
        }
        guard proceed else { return payload }
        fx.run(self)
        // FX1 — the watchdog's breadcrumb: if the main thread stops during the write, the fault
        // names this turn, this stage and this destination.
        MainThreadWatchdog.note(turn: id.description, stage: TurnStage.inserting.rawValue, destination: target.focus)
        let result = await lander.inject(payload: payload, commit: key)
        let delivery = result.delivery
        // V5 Q13 — how it landed: verdict, app, method, settle ms (no text).
        TurnEventDiagnostics.record(TurnEventDiagnostics.landingEvent(
            delivery: delivery,
            verdict: LandingVerdictLedger.shared.verdict(forText: result.text, utteranceID: result.utteranceID.uuidString),
            appBundleID: target.focus?.bundleID,
            settleMs: Int((clock.now.timeIntervalSince(now) * 1000).rounded())), turn: id.diagnosticsKey)
        let stage: TurnStage
        switch delivery {
        case .some(.held): stage = .held
        case .some(.delivered), .some(.partial): stage = .landed
        case .some(.failed), .none: stage = .failed
        }
        MainThreadWatchdog.note(turn: id.description, stage: stage.rawValue, destination: target.focus)
        let escaped = lock.withLock { turns[id]?.escapeDuringWrite ?? false }
        end(id, stage: stage) { $0.outcome = delivery }
        // Escape arrived after the write began: the outcome is resolved (above); now a safe Undo.
        // The inserted text ends at the caret the write left; `ReplaceRange` re-checks that the
        // range still holds exactly that text before removing anything.
        if escaped, let delivery, delivery.writeReachedDestination {
            let now = focusGuard.targetRevision()
            let length = result.text.utf16.count
            if let caret = now.selection, caret.isEmpty, caret.lowerBound >= length {
                offerUndo(id, range: (caret.lowerBound - length)..<caret.lowerBound, text: result.text, focus: now.focus)
            }
        }
        return result
    }

    private func hold(_ id: TurnID, _ payload: LandingResult, lander: UtteranceLander, reason: String, actual: FocusSnapshot?) -> LandingResult {
        // H23 — a password field is refused outright: nothing held, nothing to Notes, nothing in
        // history, and the turn keeps no words (finalText / rawText cleared).
        if FocusGuard.isSecureReason(reason) {
            var refused = payload
            refused.injection = .refused(.secureField)
            end(id, stage: .failed) { record in
                record.finalText = ""
                record.rawText = ""
                record.uncertainSpans = []
                record.outcome = refused.delivery
            }
            lock.withLock { turns[id]?.partialText = nil }
            Log.app.notice("turn \(id.description): password field — refused, nothing kept (H23)")
            return refused
        }
        let result = lander.hold(payload: payload, reason: reason, in: focusGuard, actual: actual, turnID: id)
        end(id, stage: .held) { $0.outcome = result.delivery }
        return result
    }

    // MARK: Escape, cancel, interruption

    /// Escape (I2, design §5). Before any write: cancel capture and preview, nothing inserted,
    /// "Cancelled" for 800 ms. After the write began: never claim a cancellation — the outcome is
    /// resolved first, then a safe Undo is offered for 5 s. Returns what it did.
    ///
    /// N2 — Escape discards only during capture. A turn whose capture already closed (finishing,
    /// formatting, previewing) is kept as held text instead: "don't type here", never dropped.
    @discardableResult
    public func escape() -> EscapeResolution? {
        let (candidates, writing) = lock.withLock { () -> ([TurnID], Bool) in
            var cancel: [TurnID] = []
            var writing = false
            for turn in turns.values {
                if turn.stage.isBeforeWrite { cancel.append(turn.id) }
                else if turn.stage == .inserting {
                    turn.escapeDuringWrite = true
                    writing = true
                }
            }
            return (cancel, writing)
        }
        if writing { Log.app.notice("turn: Escape during the write — resolving the outcome, then offering Undo") }
        let cancel = candidates.filter { id in
            let capturing = lock.withLock { turns[id]?.stage.isCapturing ?? true }
            return capturing || !keepWithoutTyping(id, awaitFinalPass: true)
        }
        let kept = candidates.count - cancel.count
        // Only kept turns: capture is already closed and their final pass must finish — nothing to
        // stop, nothing to show as cancelled (the held row follows).
        if cancel.isEmpty, kept > 0 { return nil }
        for id in cancel { cancelBeforeWrite(id, showCancelled: true) }
        // Stop capture and drop whatever the latch had closed but not delivered. Nothing that has
        // already been written is touched (V3 §4.3).
        if !cancel.isEmpty || !writing { ui { [weak self] in self?.onCancelCapture?() } }
        if !cancel.isEmpty { return .cancel }
        return writing ? .resolveWriteThenOfferUndo : nil
    }

    private func cancelBeforeWrite(_ id: TurnID, showCancelled: Bool) {
        guard lock.withLock({ turns[id]?.stage.isBeforeWrite ?? false }) else { return }
        // The gate task first (it is parked on the dwell or the gate), then the record.
        exitDwell(id, .cancel)
        wakeWaiter(id)
        // H23 (Q6) — Escape after words: the words recognised so far go to Notes ("Cancelled ·
        // Saved to Notes", `TurnStore.settleForNotes`). A password-field turn keeps nothing.
        let partial = lock.withLock { turns[id]?.partialText }
        end(id, stage: .cancelled) { record in
            let secure = record.outcome?.reason.map(FocusGuard.isSecureReason) == true
            if !secure, record.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let partial {
                record.finalText = partial
            }
        }
        if showCancelled { self.showCancelled() }
    }

    /// A cancelled turn still queued for the gate must not wait for it.
    private func wakeWaiter(_ id: TurnID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            guard let index = gateWaiters.firstIndex(where: { $0.0 == id }) else { return nil }
            return gateWaiters.remove(at: index).1
        }
        continuation?.resume()
    }

    private func showCancelled() {
        lock.withLock { holdingPresentation = true }
        present(.cancelled)
        _ = clock.schedule(after: cancelledDwell) { [weak self] in
            guard let self else { return }
            let idle = self.lock.withLock { () -> Bool in
                guard self.undo == nil else { return false }
                self.holdingPresentation = false
                return self.turns.isEmpty
            }
            // Idle: the Cancelled row goes. A latched session still capturing takes the pill back
            // on its own (its timer, its live words).
            if idle { self.retract() }
        }
    }

    /// Lock / sleep (`holdPreview: true`): capture closes (the session owner does that); a payload
    /// on screen, or one still being finished, is kept as held text — a completed segment is
    /// recoverable (design §5 "macOS lock / sleep", K02). Hard mute (`holdPreview: false`): pending
    /// insertion is cancelled.
    public func interrupt(holdPreview: Bool) {
        let live = lock.withLock { turns.values.filter { $0.stage.isBeforeWrite }.map { ($0.id, $0.stage) } }
        var kept = false
        for (id, stage) in live {
            if holdPreview, stage == .finalPreview {
                exitDwell(id, .hold(reason: DeliveryReason.destinationChanged))
                kept = true
            } else if holdPreview, stage == .finishing {
                lock.withLock { turns[id]?.holdWhenReady = DeliveryReason.destinationChanged }
                kept = true
            } else {
                exitDwell(id, .cancel)
                wakeWaiter(id)
                end(id, stage: .cancelled)
            }
        }
        if kept { notice(.K02) }
    }

    /// The display hosting this turn disappeared. Capture may finish, but its text must not follow
    /// a window macOS moved elsewhere: a preview is held immediately and an earlier stage is marked
    /// to enter held recovery as soon as formatting completes. The recovery surface itself is moved
    /// by `PillPanelController`; reinsertion requires the existing explicit “Insert here” retarget.
    public func pinnedDisplayWasLost() {
        let reason = DeliveryReason.destinationChanged
        var previews: [TurnID] = []
        var deferred: [TurnID] = []
        lock.withLock {
            for turn in turns.values where turn.stage.isBeforeWrite {
                switch turn.stage {
                case .finalPreview:
                    previews.append(turn.id)
                case .starting, .listening, .listeningQuiet, .finishing:
                    turn.holdWhenReady = reason
                    deferred.append(turn.id)
                default:
                    break
                }
            }
        }
        previews.forEach { exitDwell($0, .hold(reason: reason)) }
        if !previews.isEmpty || !deferred.isEmpty {
            Log.app.notice("display removed: \(previews.count) preview(s) held, \(deferred.count) active turn(s) require retarget")
        }
    }

    // MARK: Undo (R2)

    private func offerUndo(_ id: TurnID, range: Range<Int>, text: String, focus: FocusSnapshot?) {
        let timer = clock.schedule(after: undoWindow) { [weak self] in self?.undoExpired(id) }
        lock.withLock {
            undo?.timer.cancel()
            undo = UndoOffer(turnID: id, range: range, text: text, focus: focus, timer: timer)
            holdingPresentation = true
        }
        Log.app.info("turn \(id.description): Undo offered for \(Int(undoWindow)) s")
    }

    /// Draws the Undo row for `id` once its outcome row is up (called on the UI queue right after
    /// the outcome is handed over), so the order on screen is outcome → Undo, never the reverse.
    private func presentUndo(for id: TurnID) {
        guard lock.withLock({ undo?.turnID == id && !newerCaptureOpenLocked(than: id) }) else { return }
        onPresent?(.undoAvailable)
    }

    private func undoExpired(_ id: TurnID) {
        let expired = lock.withLock { () -> Bool in
            guard undo?.turnID == id else { return false }
            undo = nil
            holdingPresentation = false
            return true
        }
        if expired { retract() }
    }

    /// R2 — remove exactly the inserted text, only while the range still holds it (`ReplaceRange`).
    /// A stale range changes nothing and says so (D10).
    @discardableResult
    public func performUndo() -> Bool {
        guard let offer = lock.withLock({ () -> UndoOffer? in
            let offer = undo
            undo = nil
            holdingPresentation = false
            return offer
        }) else { return false }
        offer.timer.cancel()
        // Only in the field the text went into: another app's field is never edited by this Undo.
        let outcome = focusGuard.matches(offer.focus)
            ? replaceRange?(ReplaceRangeRequest(range: offer.range, expected: offer.text, replacement: ""))
            : nil
        guard case .replaced = outcome else {
            Log.app.notice("turn \(offer.turnID.description): Undo refused — the range no longer holds the inserted text")
            notice(.D10)
            return false
        }
        store.update(offer.turnID, stage: .resolved)
        Log.app.info("turn \(offer.turnID.description): undone")
        retract()
        return true
    }

    // MARK: Held text resolved later

    private func heldResolved(_ item: HeldText, _ how: HeldResolution) {
        guard let id = item.turnID else { return }
        switch how {
        case .inserted(let outcome):
            let delivery = outcome.delivery
            store.update(id, stage: delivery.isHeld ? .held : (delivery.writeReachedDestination ? .landed : .failed)) {
                $0.outcome = delivery
                if delivery.writeReachedDestination { $0.writeAttempted = true }
            }
        case .copied, .discarded:
            store.update(id, stage: .resolved)
        }
    }

    // MARK: Turn bookkeeping

    private func end(_ id: TurnID, stage: TurnStage, _ change: (inout TurnRecord) -> Void = { _ in }) {
        var fx = Effects()
        typealias Parked = (preview: CheckedContinuation<Void, Never>?, exit: CheckedContinuation<DwellExit, Never>?,
                            gate: CheckedContinuation<Void, Never>?)
        var summary: HandsFreeTally.LastPiece?
        let ended = lock.withLock { () -> Parked? in
            guard let turn = turns[id] else { return nil }
            change(&turn.record)
            if turn.latched, turn.origin == .hold {
                summary = HandsFreeTally.LastPiece(stage: stage, app: TurnOutcome.clean(turn.record.destination.appName))
            }
            turn.stage = stage
            turn.cancelTimers()
            turns[id] = nil
            if captureID == id { captureID = nil }
            fx.save(turn)
            // Nothing a finished turn parked may stay parked: a gate task waiting on its dwell or
            // its place in the queue is released (and finds the turn over).
            let parked: Parked = (turn.previewWaiter, turn.exit,
                                  gateWaiters.firstIndex { $0.0 == id }.map { gateWaiters.remove(at: $0).1 })
            turn.previewWaiter = nil
            turn.exit = nil
            if turn.pendingExit == nil { turn.pendingExit = .cancel }
            return parked
        }
        guard let parked = ended else { return }
        parked.preview?.resume()
        parked.exit?.resume(returning: .cancel)
        parked.gate?.resume()
        fx.run(self)
        Log.app.info("turn \(id.description): \(stage.rawValue)")
        ui { [weak self] in self?.onTurnEnded?(id, stage) }
        if let summary { scheduleHandsFreeSummary(summary) }
    }

    /// H29 — the hands-free session's last piece ended: after `handsFreeSummaryDelay`, one line
    /// for the whole session (pieces typed, pieces saved to Notes, the app when there was one).
    /// Escape / Cancel / a failure say their own thing instead; a new capture by then keeps the notch.
    private func scheduleHandsFreeSummary(_ last: HandsFreeTally.LastPiece) {
        guard last.endsWithSummary, let tallyReader = handsFreeTally else { return }
        _ = clock.schedule(after: handsFreeSummaryDelay) { [weak self] in
            guard let self else { return }
            var tally = tallyReader() ?? HandsFreeTally()
            tally.note(last)
            guard let outcome = tally.outcome else { return }
            if self.lock.withLock({ self.captureID != nil }) { return }
            Log.app.notice("turn: \(outcome.text)")
            self.ui { [weak self] in self?.onHandsFreeEnded?(outcome) }
        }
    }

    private func busyTurnLocked() -> TurnID? {
        turns.values.first { turn in
            switch turn.stage {
            // N23 — once the previous text is final and its write is decided (no dwell: typed as
            // soon as ready, or already being typed), a new press is allowed; its own text queues
            // behind at the gate, so landings stay in start order. A preview still waiting on the
            // user (Manual, or a dwell) or a final pass still running refuses (K04).
            case .finalPreview: return !(turn.immediate && !turn.manual)
            case .inserting: return false
            case .finishing: return turn.origin == .hold
            default: return false
            }
        }?.id
    }

    /// N23 — a capture that began after `id`: the pill belongs to it. H28 — a hands-free (latched)
    /// session's capture counts too: an older turn's "being typed" row and its Undo offer are never
    /// drawn over the hands-free row (the notch stays put for the whole session).
    private func newerCaptureOpenLocked(than id: TurnID) -> Bool {
        guard let open = captureID, open != id, let turn = turns[open] else { return false }
        return turn.stage.isCapturing
    }

    /// N23 — a hold capture is open (the pill shows it; an older turn's ending must not touch it).
    public var hasOpenCapture: Bool {
        lock.withLock {
            guard let id = captureID, let turn = turns[id] else { return false }
            return turn.stage.isCapturing && !turn.latched
        }
    }

    private func representBusyTurn(_ id: TurnID) {
        let state = lock.withLock { () -> PillState? in
            guard let turn = turns[id] else { return nil }
            switch turn.stage {
            case .finishing: return .finishing(elapsedWarning: turn.slow || turn.offer != nil)
            case .finalPreview: return .finalPreview(previewInfoLocked(turn))
            case .inserting: return .inserting(text: turn.payload?.text ?? "")
            default: return nil
            }
        }
        if let state { present(state) }
    }

    private func notice(_ id: RecoveryID) {
        let entry = RecoveryCatalog.entry(id)
        ui { [weak self] in self?.onNotice?(entry) }
    }

    /// H1 (owner Q3) — a hold that heard nothing. Under 0.6 s the pill just goes; 0.6 s or longer
    /// shows A06 "Didn’t hear anything", gone 1.5 s after key-up. Never X08, never sticky.
    private func silentHold(_ turn: Turn) {
        let now = clock.now
        let (held, sinceKeyUp) = lock.withLock { () -> (TimeInterval, TimeInterval) in
            let up = turn.record.capture.captureClosed ?? now
            return (up.timeIntervalSince(turn.record.startedAt), now.timeIntervalSince(up))
        }
        guard PillDwell.silentHoldShowsRow(held: held) else {
            Log.app.info("turn \(turn.id.description): silent hold under \(PillDwell.silentHoldVanish)s — vanish")
            retract()
            return
        }
        let entry = RecoveryCatalog.entry(.A06)
        let fade = PillDwell.silentHoldFade(sinceKeyUp: sinceKeyUp)
        ui { [weak self] in
            guard let self else { return }
            if let quiet = self.onQuietNotice { quiet(entry, fade) } else { self.onNotice?(entry) }
        }
    }

    private func present(_ state: PillState) {
        ui { [weak self] in self?.onPresent?(state) }
    }

    private func retract() {
        // N23 — an older turn's quiet end never takes down a newer, open capture's row.
        guard !hasOpenCapture else { return }
        ui { [weak self] in self?.onRetract?() }
    }

    private func busy(_ delta: Int) { lock.withLock { busyCount += delta } }

    /// Waits until nothing is being formatted or written: every turn is parked (dwelling, queued
    /// for the gate) or over. Tests use it after driving a step.
    public func settle() async {
        var quiet = 0
        for _ in 0..<50_000 {
            if lock.withLock({ busyCount == 0 }) {
                quiet += 1
                if quiet >= 3 { return }
            } else {
                quiet = 0
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 100_000)
        }
    }

    // MARK: Effects (run outside the lock, in order)

    struct Effects {
        private var steps: [(TurnController) -> Void] = []

        mutating func save(_ turn: Turn) {
            let record = turn.record, stage = turn.stage
            steps.append { $0.store.save(record, stage: stage) }
        }

        mutating func present(_ state: PillState) {
            steps.append { $0.present(state) }
        }

        /// H3 — whatever the notch shows gives way to the new turn (in `ui` order, before `.starting`).
        mutating func yieldToHold() {
            steps.append { c in c.ui { [weak c] in c?.onHoldYield?() } }
        }

        func run(_ controller: TurnController) { steps.forEach { $0(controller) } }
    }
}

// MARK: - One turn

final class Turn {
    enum Origin { case hold, admitted }

    let id: TurnID
    let origin: Origin
    var stage: TurnStage = .starting
    var record: TurnRecord
    var target: TurnTarget?
    /// Owner decision — the key-down app/window/element to pull back to.
    var anchor: PullBackAnchor?
    var latched = false
    /// X1 — the notch is not shown yet (inside `holdPresentDelay`); engine states are held back.
    var presentDeferred = false
    /// H2 — the key went down while the notch showed something that is not a live capture.
    var overSurface = false
    var speaking = false
    var partialText: String?
    var payloadStarted = false
    var payload: LandingResult?
    var slow = false
    var offer: FinishingOffer?
    var manual = false
    /// N8 — typed as soon as the final text is ready (no dwell).
    var immediate = false
    var dwellTotal: TimeInterval?
    var dwellRemaining: TimeInterval = 0
    var dwellStartedAt: Date?
    var pauses: Set<DwellPause> = []
    /// V5 Q8 — when each sensed pause first lost its live cause.
    var pausesCauseless: [DwellPause: Date] = [:]
    /// V5 Q8 — the 100 ms self-healing tick, running only while paused in the final preview.
    var pauseTick: TurnTimer?
    var rendered = false
    var uncertainCount = 0
    /// S5 — the payload's marks include a phrase (T05 "Review this phrase").
    var phraseReview = false
    var pendingExit: DwellExit?
    var exit: CheckedContinuation<DwellExit, Never>?
    var previewReached = false
    var previewWaiter: CheckedContinuation<Void, Never>?
    /// Interrupted while finishing: hold the payload instead of previewing it.
    var holdWhenReady: String?
    var commitKey: TurnCommitKey?
    var escapeDuringWrite = false
    var quietTimer: TurnTimer?
    var slowTimer: TurnTimer?
    var offerTimer: TurnTimer?
    var dwellTimer: TurnTimer?
    var renderTimer: TurnTimer?

    init(id: TurnID, origin: Origin, startedAt: Date) {
        self.id = id
        self.origin = origin
        self.record = TurnRecord(turnID: id, startedAt: startedAt)
    }

    /// "Mail" — the key-down snapshot's app name, else the name the lander gave the destination.
    var destinationName: String? {
        if let name = target?.focus?.appName, !name.isEmpty { return name }
        return payload?.focusDestination
    }

    func cancelTimers() {
        [quietTimer, slowTimer, offerTimer, dwellTimer, renderTimer].forEach { $0?.cancel() }
        quietTimer = nil; slowTimer = nil; offerTimer = nil; dwellTimer = nil; renderTimer = nil
    }
}

struct UndoOffer {
    let turnID: TurnID
    let range: Range<Int>
    let text: String
    /// The app and element the text went into.
    let focus: FocusSnapshot?
    let timer: TurnTimer
}

// MARK: - App wiring

/// H29 — one hands-free session, counted for its end line ("Hands-free ended · 3 inserted in
/// Claude · 1 saved to Notes"). Counts only; never any text.
public struct HandsFreeTally: Equatable, Sendable {
    public private(set) var inserted = 0
    public private(set) var savedToNotes = 0
    /// Distinct apps typed into, in order.
    public private(set) var apps: [String] = []

    public init() {}

    /// The session's last piece (the one the stop tap closed), as its turn ended.
    public struct LastPiece: Equatable, Sendable {
        public var stage: TurnStage
        public var app: String?
        public init(stage: TurnStage, app: String?) {
            self.stage = stage
            self.app = app
        }
        /// Escape / Cancel and failures say their own thing; every other end gets the summary.
        public var endsWithSummary: Bool {
            switch stage {
            case .landed, .held, .empty, .consumed, .resolved: return true
            default: return false
            }
        }
    }

    public mutating func noteInserted(app: String?) {
        inserted += 1
        if let app = TurnOutcome.clean(app), !apps.contains(app) { apps.append(app) }
    }

    public mutating func noteSavedToNotes() { savedToNotes += 1 }

    public mutating func note(_ last: LastPiece) {
        switch last.stage {
        case .landed: noteInserted(app: last.app)
        case .held: noteSavedToNotes()
        default: break
        }
    }

    /// The one app every piece went to; nil for none or several.
    public var app: String? { apps.count == 1 ? apps[0] : nil }
    public var isEmpty: Bool { inserted == 0 && savedToNotes == 0 }
    /// The end line's outcome; nil when nothing was typed or saved (the notch just goes).
    public var outcome: TurnOutcome? {
        isEmpty ? nil : .handsFreeEnded(app: app, inserted: inserted, savedToNotes: savedToNotes)
    }
}

/// S3 — the composition root's one call: builds the turn store and controller over the container,
/// makes the controller the lander's gate and the dictation coordinator's turn owner, and connects
/// the pill (present, retract, rendered-final acknowledgment, hover, the turn's buttons), notices,
/// Escape (I2), lock/sleep/mute and deixis. Kept here so `AppDelegate` carries one call for it.
public final class TurnWiring {
    /// The live wiring (the app keeps exactly one).
    public private(set) static var current: TurnWiring?

    public let controller: TurnController
    public let store: TurnStore
    public let escape: EscapeHotkey
    private var subscriptions: Set<AnyCancellable> = []
    private var noticeFade: DispatchWorkItem?
    /// H3 / old H6 — the edit pill gives the notch up to a new hold (`TransformPillDriver`'s
    /// reducer ends: no warm row, no ghost, no tick that could redraw it over the listening row).
    /// `attach` routes it as `.ended` through the transform landing's event sink; the app may
    /// replace it with the driver's own `yieldToHold()`.
    public var onTransformYield: (() -> Void)?

    /// H3 (owner Q3.2) — a hold in any state starts a fresh dictation. The turn's `.starting` row
    /// replaces a hint, outcome or error row outright (a visible state never waits, `PillPresenter`);
    /// taking the old row down first would only order the panel out and back in. What must go here
    /// is what could act on the pill *after* that: a pending notice fade, and the edit pill, whose
    /// warm ticks would otherwise redraw it over the listening row.
    func yieldToHold() {
        noticeFade?.cancel()
        noticeFade = nil
        onTransformYield?()
    }

    public init(controller: TurnController, store: TurnStore, escape: EscapeHotkey) {
        self.controller = controller
        self.store = store
        self.escape = escape
    }

    /// V4.41 — the pauses a final preview must be under *now*, and the ones it must be released
    /// from, when a preview is (re)published.
    ///
    /// It is a pair, not a single "pause if": pausing without ever resuming is what parked the
    /// payload at "Ready for <app> · Insert now" and inserted nothing. Two one-way pauses could each
    /// strand a preview for the rest of its life — a hover flag SwiftUI never retracts (the pill
    /// stops accepting the mouse, so no `onHover(false)` ever arrives) and an `NSApplication`
    /// `didHide` with no matching `didUnhide`. design_v3 §4.1 is explicit that leftover
    /// mouse-acquired hover/focus after the pointer has left is to be ignored.
    /// V5 Q9 — the hidden-app input is gone: the pill and chin panels cannot be hidden.
    static func previewPauses(pointerInside: Bool) -> (pause: Set<DwellPause>, resume: Set<DwellPause>) {
        var pause: Set<DwellPause> = []
        var resume: Set<DwellPause> = []
        if pointerInside { pause.insert(.hover) } else { resume.insert(.hover) }
        return (pause, resume)
    }

    /// V5 Q8 — what the pill really is right now: pointer hit-test, key window + first responder,
    /// editor state. Main thread (AppKit).
    @MainActor
    static func liveState(of pill: PillViewModel) -> PauseLiveState {
        PauseLiveState(pointerInside: pill.isPointerReallyInside,
                       keyboardFocus: pill.isKeyboardFocusReallyInside,
                       editing: pill.isEditingDraft,
                       composing: pill.hasMarkedText)
    }

    /// Keyboard / VoiceOver focus on the pill's final text or its actions freezes the dwell like
    /// hover (build doc §2, design §5 step 4, §11): `PillViewModel.onKeyboardFocusChange` →
    /// `pauseDwell(.focus)` / `resumeDwell(.focus)`. A preview that opens with focus already on the
    /// text lane (the VoiceOver cursor was reading the live words) starts frozen. The pill's final
    /// text is not selectable, so the pill reports no `.selection`.
    @MainActor
    public static func wireFocusPause(pill: PillViewModel, controller: TurnController,
                                      scheduler: DispatchQueue = .main) -> AnyCancellable {
        let previousFocus = pill.onKeyboardFocusChange
        pill.onKeyboardFocusChange = { [weak controller] focused in
            previousFocus?(focused)
            if focused { controller?.pauseDwell(.focus) } else { controller?.resumeDwell(.focus) }
        }
        return pill.$state
            .receive(on: scheduler)
            .sink { [weak controller, weak pill] state in
                guard case .finalPreview = state else { return }
                // V4.41 — symmetric, for the same reason as the hover pause above: a `.focus` pause
                // with no resume parks the payload at "Insert now" for the rest of the preview.
                if pill?.focusInside == true { controller?.pauseDwell(.focus) }
                else { controller?.resumeDwell(.focus) }
            }
    }

    /// `finishLatch`: the latched pill's "Finish dictation" (the same as a tap while latched).
    @MainActor
    @discardableResult
    public static func attach(container: AppContainer, pill: PillViewModel, coordinator: DictationCoordinator,
                              session: SessionCoordinator, escape: EscapeHotkey = EscapeHotkey(),
                              finishLatch: (() -> Void)? = nil) -> TurnWiring {
        let settings = container.settings
        let store = TurnStore(database: container.database, persistsRecovery: { TurnSettings.persistsRecovery(settings) })
        TurnStore.current = store
        let controller = TurnController(lander: container.lander, focusGuard: container.injector.focusGuard, store: store,
                                        dwell: { TurnSettings.landingDwell(settings) })
        controller.useReplaceRange(over: container.system)
        // Owner decision — switched apps mid-dictation: pull back to the key-down window, then type.
        controller.pullBack = SystemFocusPullBack.live(system: container.system)
        // T-schema verify — the key-down surface lands in turn_records (surface_kind, signals).
        controller.surfaceForTurn = { [turnSurface = container.turnSurface] in turnSurface.surface() }
        let wiring = TurnWiring(controller: controller, store: store, escape: escape)
        current = wiring

        // What the turn shows, and taking it down only while the pill still shows the turn.
        controller.onPresent = { [weak pill, weak controller] state in
            pill?.present(state)
            if case .finalPreview = state, let controller {
                let resolution = Self.previewPauses(pointerInside: pill?.isPointerReallyInside == true)
                resolution.pause.forEach(controller.pauseDwell)
                resolution.resume.forEach(controller.resumeDwell)
                controller.rebuildPauses()
            }
        }
        pill.onDraftPause = { [weak controller] reason, paused in
            if paused { controller?.pauseDwell(reason) } else { controller?.resumeDwell(reason) }
        }
        pill.onApplyDraft = { [weak controller] text, mapping, spans in
            controller?.revisePreview(text: text, mapping: mapping, spans: spans) ?? false
        }
        pill.onApplyRetainedDraft = { [weak controller] shown, original, edited, mapping in
            controller?.reviseRetainedDraft(shown: shown, original: original, edited: edited, mapping: mapping) ?? false
        }
        // V5 Q12 — an empty draft left in the editor cancels the turn ("Nothing was typed.").
        pill.onEmptyDraftLeft = { [weak controller] in controller?.discardPreview() }
        let learner = DraftVocabularyLearner(database: container.database)
        pill.onLearnDraft = { [weak pill] original, edited in
            if !learner.learn(original: original, edited: edited) {
                pill?.showLaneNote("Learned spelling is kept for this session only")
            }
        }
        // V5 K19 — pill order-in/out and retention backstops go to the Q13 diagnostics store.
        if let database = container.database, PillDiagnostics.store == nil {
            PillDiagnostics.store = try? TurnDiagnostics(database: database)
        }
        PillDiagnostics.turnID = { [weak controller] in controller?.currentTurn?.diagnosticsKey }
        // V5 HW3 — "Running lighter models — memory is low" chip while memory pressure is critical.
        LighterModelsChip.wire(pill: pill)
        // V5 Q8 — the self-healing tick reads the pill's real state (main queue clock).
        controller.liveState = { [weak pill] in
            guard let pill else { return nil }
            return MainActor.assumeIsolated { Self.liveState(of: pill) }
        }
        controller.onRetract = { [weak pill] in
            guard let pill else { return }
            switch Self.retractAction(pill.state, captureOpen: pill.turn.captureOpen, latched: pill.latched) {
            case .leave: break
            case .hide: pill.hide()
            case .returnToLatched:
                // An outcome-style turn row (Cancelled, Undo) goes back through the delivery path,
                // which routes to the hands-free row; a live-turn row is replaced by it.
                if PillViewModel.isOutcomeRow(pill.state) { pill.retractDelivery(immediately: true) }
                else { pill.present(.latched(elapsed: pill.turn.latchElapsed ?? 0)) }
            }
        }
        controller.onFinalSpans = { [weak pill] spans, text in pill?.setFinalSpans(spans, text: text) }
        // N2 — the finishing row's buttons come from the turn's own offer, never the pill's clock.
        controller.onOffer = { [weak pill] _, offer in pill?.setFinishingOffer(offer) }
        // N17 — a tap shows how to dictate (a transient line that fades), never a failure.
        controller.onTapHint = { [weak pill] in
            pill?.present(.preview(text: Self.tapHint(latchEnabled: LatchGestureSettings.isEnabled(settings))))
        }
        // H2 — the hint goes after 1.6 s; a tap over a visible non-capture notch takes it down.
        controller.onTapHintExpired = { [weak pill] in
            guard let pill, Self.isTapHint(pill.state) else { return }
            pill.hide()
        }
        controller.onTapDismiss = { [weak pill] in
            pill?.hide()
        }
        // X2 — the Option-tap fallback note: a transient line, gone after `noteDwell`.
        controller.onNote = { [weak pill] text in
            pill?.present(.preview(text: text))
            DispatchQueue.main.asyncAfter(deadline: .now() + TurnController.noteDwell) { [weak pill] in
                guard let pill, pill.state == .preview(text: text) else { return }
                pill.hide()
            }
        }
        // H29 — the session's summary line ("Hands-free ended · 3 inserted in Claude"), then gone.
        controller.handsFreeTally = { [weak session] in session?.latch?.sessionTally }
        controller.onHandsFreeEnded = { [weak pill] outcome in
            let text = outcome.pillLine
            pill?.present(.preview(text: text))
            DispatchQueue.main.asyncAfter(deadline: .now() + TurnController.handsFreeSummaryDwell) { [weak pill] in
                guard let pill, pill.state == .preview(text: text) else { return }
                pill.hide()
            }
        }
        controller.surfaceShowing = { PillSurfaceVisibility.isShowing }
        controller.holdPresentDelay = TurnController.holdPresentDelayDefault
        pill.$state
            .sink { [weak pill] state in
                PillSurfaceVisibility.isShowing = PillSurfaceVisibility.isNonCaptureSurface(
                    state, captureOpen: pill?.turn.captureOpen ?? false)
            }
            .store(in: &wiring.subscriptions)
        controller.onNotice = { [weak wiring, weak pill] entry in
            wiring?.show(entry, on: pill)
            // N20 — a refused press names why: the previous text is still being typed.
            if let note = Self.noticeNote(for: entry) { pill?.showLaneNote(note) }
        }
        controller.onQuietNotice = { [weak wiring, weak pill] entry, fade in
            wiring?.show(entry, on: pill, fadeAfter: fade)
        }
        controller.onCancelCapture = { [weak session] in session?.escape() }
        // H3 (Q3.2) — a new hold clears whatever the notch shows and the edit pill stands down.
        wiring.onTransformYield = { [weak transform = container.transform] in transform?.onEvent?(.ended) }
        controller.onHoldYield = { [weak wiring] in wiring?.yieldToHold() }

        // I2 — Escape is registered only while a turn is live (its phase read from the controller
        // on every pill change and every turn end), and goes to the turn controller.
        let refreshEscape: () -> Void = { [weak controller, weak escape, weak pill] in
            guard let controller, let escape else { return }
            // A selected-text transform's preview borrows Escape itself (S12): never compete with it.
            let phase: EscapeTurnPhase
            switch pill?.state {
            case .transform?, .editing?: phase = .none
            default: phase = controller.escapePhase
            }
            escape.update(phase: phase, turn: controller.currentTurn)
        }
        escape.bindDraftEditor(to: pill)
        escape.onEscape = { [weak controller] _ in controller?.escape() }
        escape.observeMenuTracking()
        pill.$state
            .receive(on: DispatchQueue.main)
            .sink { _ in refreshEscape() }
            .store(in: &wiring.subscriptions)

        let deixis = container.deixis
        controller.onTurnEnded = { [weak session] _, stage in
            refreshEscape()
            // Cancel is the deixis key controller's own; a latch keeps its boxes per segment.
            guard stage != .cancelled, !(session?.isLatched ?? false) else { return }
            // N23 — the previous turn ended under a newer capture: its boxes are the new turn's.
            if controller.hasOpenCapture { return }
            deixis.endTurn()
        }
        container.lander.gate = controller
        coordinator.turns = controller

        // The turn's buttons (Insert text, Cancel, Use available text, Undo, Review, Finish) and
        // hover. Anything else goes to whoever handled the pill's actions before.
        let previousAction = pill.onAction
        pill.onAction = { [weak controller] action, shown in
            if let controller, Self.route(action, shown: shown, to: controller, finishLatch: finishLatch) { return }
            previousAction?(action, shown)
        }
        MenuCapturePillWiring.attach(session, pill: pill)
        let previousHover = pill.onPointerInsideChange
        pill.onPointerInsideChange = { [weak controller] inside in
            previousHover?(inside)
            if inside { controller?.pauseDwell(.hover) } else { controller?.resumeDwell(.hover) }
        }
        Self.wireFocusPause(pill: pill, controller: controller).store(in: &wiring.subscriptions)
        if pill.destinationProvider == nil {
            pill.destinationProvider = { [weak controller] in
                controller?.currentDestinationName ?? NSWorkspace.shared.frontmostApplication?.localizedName
            }
        }

        // Dwell starts at the first rendered final frame: the pill acknowledges the payload the
        // run-loop pass after it drew it.
        pill.$state
            .sink { [weak controller] state in
                guard case .finalPreview(let info) = state else { return }
                DispatchQueue.main.async { controller?.finalRendered(text: info.text) }
            }
            .store(in: &wiring.subscriptions)

        // Lock and sleep keep a previewed payload as held text; hard mute cancels it.
        let stopped = session.onStopped
        session.onStopped = { [weak controller] requester, reason in
            stopped?(requester, reason)
            switch reason {
            case .locked, .slept: controller?.interrupt(holdPreview: true)
            case .muted: controller?.interrupt(holdPreview: false)
            default: break
            }
        }
        return wiring
    }

    /// N20 — the line under a turn notice: a press refused while the previous turn is finishing,
    /// previewing or inserting (K04) says "Previous text still landing" instead of failing silently.
    static func noticeNote(for entry: RecoveryEntry) -> String? {
        entry.id == .K04 ? PillDeck.previousStillLanding : nil
    }

    /// N17 — the row a notice draws: A06 (no speech) reads "Didn’t hear anything"; every other
    /// entry its catalogue headline.
    static func noticeHeadline(for entry: RecoveryEntry) -> String {
        entry.id == .A06 ? PillDeck.didntHearAnything : entry.headline
    }

    /// H2 — is this state the tap hint (either wording)?
    static func isTapHint(_ state: PillState) -> Bool {
        guard case .preview(let text) = state else { return false }
        return text == tapHint(latchEnabled: true) || text == tapHint(latchEnabled: false)
    }

    /// N17 — the tap hint, naming the latch only when the double-tap latch is on.
    static func tapHint(latchEnabled: Bool) -> String {
        latchEnabled ? PillDeck.tapHint : PillDeck.tapHintNoLatch
    }

    /// A pill button the turn owns. `true` when it was the turn's.
    static func route(_ action: PillActionKind, shown: PillState, to controller: TurnController,
                      finishLatch: (() -> Void)?) -> Bool {
        switch (action, shown) {
        case (.commit, .finalPreview), (.insert, .finalPreview):
            controller.insertNow()
        case (.cancel, .finalPreview):
            controller.cancelPreview()
        case (.cancel, .finishing), (.cancel, .landing):
            controller.cancelFinishing()
        case (.useAvailable, _):
            controller.useAvailableText()
        case (.review, .finalPreview):
            controller.pauseDwell(.review)
        case (.undo, .undoAvailable) where controller.isUndoAvailable:
            controller.performUndo()
        case (.finish, .latched):
            guard let finishLatch else { return false }
            finishLatch()
        default:
            return false
        }
        return true
    }

    /// What `onRetract` does to the pill. H28 — while a hands-free session is open (latched, capture
    /// open) a turn row is never ordered out: the pill goes back to the hands-free row (timer
    /// counting). Once the session has ended (capture closed) a turn row retracts as before.
    enum RetractAction: Equatable { case leave, hide, returnToLatched }

    static func retractAction(_ state: PillState, captureOpen: Bool, latched: Bool) -> RetractAction {
        guard isTurnRow(state, captureOpen: captureOpen) else { return .leave }
        if latched, captureOpen {
            if case .preview = state { return .leave }   // a lane note on the live row, not a row
            return .returnToLatched
        }
        return .hide
    }

    /// The rows a turn puts up itself (and the live capture rows), which `onRetract` may take down.
    /// A delivery row, a held row, an error or notice raised by anything else, a transform or the
    /// latched row are never taken down by a turn that ended quietly.
    static func isTurnRow(_ state: PillState, captureOpen: Bool) -> Bool {
        switch state {
        case .idle, .starting, .listening, .listeningQuiet, .finishing, .landing, .finalPreview, .inserting,
             .cancelled, .undoAvailable:
            return true
        case .preview:
            return captureOpen
        case .error(let message):
            // K04 lasts only while the previous turn does (`RecoveryDismissal.whileConditionHolds`).
            return message == RecoveryCatalog.entry(.K04).headline
        default:
            return false
        }
    }

    /// A notice on the pill: the headline as the notice row. A fading entry (A06 "No speech
    /// detected") goes after its fade; the rest stay until the next state or the user. Main queue.
    private func show(_ entry: RecoveryEntry, on pill: PillViewModel?,
                      fadeAfter: TimeInterval = EngineStopReason.quietReturnFade) {
        guard let pill else { return }
        let headline = Self.noticeHeadline(for: entry)
        pill.present(.error(message: headline))
        noticeFade?.cancel()
        guard entry.dismissal == .fades else { return }
        let fade = DispatchWorkItem { [weak pill] in
            guard let pill, case .error(let message) = pill.state, message == headline else { return }
            pill.retractDelivery()
        }
        noticeFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeAfter, execute: fade)
    }
}
