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
public enum DwellPause: String, CaseIterable, Sendable {
    case hover, focus, selection, review
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
    /// Range-safe replace for Undo (`ReplaceRangeEditor` over the live `SystemAccess`).
    public var replaceRange: ((ReplaceRangeRequest) -> ReplaceRangeOutcome)?
    /// Where the key-down snapshot's AX read runs. Live: off the key-down path.
    public var snapshotQueue: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// Where `onPresent` / `onNotice` / `onOffer` / `onLanded` run. Live: the main queue, in order.
    public var ui: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    // Outputs.
    /// The pill state the turn wants shown now.
    public var onPresent: ((PillState) -> Void)?
    /// The turn's own row is no longer true (a quiet end, the Cancelled or Undo row timing out):
    /// take the pill down *if it still shows a turn state*. A notice, an error or a transform that
    /// replaced it in the meantime is never taken down by this.
    public var onRetract: (() -> Void)?
    /// The final payload's spans, as it is published (the pill's red-dotted uncertain words).
    public var onFinalSpans: (([TranscriptSpan]) -> Void)?
    /// A recovery-catalogue notice (K04 busy, A06 no speech, K02 interrupted, D10 stale undo).
    public var onNotice: ((RecoveryEntry) -> Void)?
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
                targets: TurnTargetReading? = nil, dwell: @escaping () -> PreviewDwell = { .standard }) {
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
        let verdict = lock.withLock { () -> TurnKeyDown in
            if let id = captureID, let turn = turns[id], turn.stage.isCapturing { return .repeated(id) }
            if let busy = busyTurnLocked(), !latched { return .busy(busy) }
            undo?.timer.cancel()
            undo = nil
            let turn = Turn(id: TurnID(), origin: .hold, startedAt: now)
            turn.latched = latched
            turns[turn.id] = turn
            captureID = turn.id
            holdingPresentation = false
            fx.save(turn)
            fx.present(.starting)
            return .began(turn.id)
        }
        switch verdict {
        case .began(let id):
            fx.run(self)
            Log.app.info("turn \(id.description): key down")
            snapshotQueue { [weak self] in
                guard let self else { return }
                self.applySnapshot(id, self.targets.read(at: now))
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

    private func applySnapshot(_ id: TurnID, _ target: TurnTarget) {
        var fx = Effects()
        lock.withLock {
            guard let turn = turns[id], turn.target == nil else { return }
            turn.target = target
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
    public func captureFailed(_ id: TurnID) {
        guard lock.withLock({ turns[id] != nil }) else { return }
        end(id, stage: .failed)
        retract()
    }

    /// Capture was cancelled without Escape (a too-short tap, a preemption, mute): the capture turn
    /// ends quietly. A turn already past key-up is left alone — it is no longer capture.
    public func captureCancelled(_ id: TurnID) {
        guard lock.withLock({ turns[id]?.stage.isCapturing ?? false }) else { return }
        end(id, stage: .cancelled)
        retract()
    }

    /// The session entered latch. Sticky for the turn: the latched session's last words are aimed
    /// at where focus is when it stops, and a latched turn shows the latch timer, not "quiet".
    public func noteLatched(_ latched: Bool) {
        guard latched else { return }
        lock.withLock {
            guard let id = captureID, let turn = turns[id] else { return }
            turn.latched = true
            turn.quietTimer?.cancel()
            turn.quietTimer = nil
        }
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
        // A latched session's last words close now: aim them at where focus is now.
        if lock.withLock({ turns[id]?.latched ?? false }) {
            let target = targets.read(at: now)
            lock.withLock {
                guard let turn = turns[id] else { return }
                turn.target = target
                turn.record.destination = target.destination
            }
        }
        return true
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
        ui { [weak self] in self?.onOffer?(id, nil) }
        // Streaming words carry no final confidence: they are neither flagged nor claimed as checked.
        let spans = [TranscriptSpan(text: partial, confidence: 0.5, audioRange: 0...0, provenance: [.asr], stability: .committed)]
        busy(+1)
        Task { [weak self] in
            await self?.finalize(id, spans: spans, source: .available)
            self?.busy(-1)
        }
    }

    /// 10 s offer → "Cancel", or Cancel on a finishing turn: nothing will be inserted, and the late
    /// result is dropped.
    public func cancelFinishing() {
        guard let id = lock.withLock({ turns.values.first { $0.origin == .hold && $0.stage == .finishing }?.id }) else { return }
        cancelBeforeWrite(id, showCancelled: true)
        ui { [weak self] in self?.onOffer?(id, nil) }
        ui { [weak self] in self?.onCancelCapture?() }
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
            if turn.latched { retract() } else { notice(.A06) }
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
        if stage == .empty, !latched { notice(.A06) } else if stage == .consumed || stage == .empty { retract() }
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
        var fx = Effects()
        let id = lock.withLock { () -> TurnID in
            let turn = Turn(id: TurnID(), origin: .admitted, startedAt: payload.pending?.startedAt ?? now)
            // The segment was aimed where focus was when it closed; the AX revision is read now.
            var revision = read.revision
            if let focus = payload.pending?.focus { revision.focus = focus }
            let target = TurnTarget(revision: revision, displayID: read.displayID, takenAt: now)
            turn.target = target
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
        let exit = await dwellExit(id)
        busy(+1)
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
            let uncertain = payload.pending?.uncertainCount ?? 0
            let lowConfidence = uncertain > 0 || (payload.pending?.spans.contains { $0.isLowConfidence } ?? false)
            turn.payload = payload
            turn.stage = .finalPreview
            turn.manual = setting == .manual
            turn.dwellTotal = setting.seconds(lowConfidence: lowConfidence)
            turn.dwellRemaining = turn.dwellTotal ?? 0
            turn.uncertainCount = max(uncertain, lowConfidence ? 1 : 0)
            turn.record.finalText = payload.text
            turn.record.uncertainSpans = payload.pending?.uncertainRanges ?? []
            turn.record.capture.finalPublished = now
            fx.save(turn)
            fx.present(.finalPreview(previewInfoLocked(turn)))
            turn.renderTimer = clock.schedule(after: renderAckTimeout) { [weak self] in self?.renderAckTimedOut(id) }
        }
        // The spans reach the pill before the preview that draws them (its red-dotted words).
        if let spans = payload.pending?.spans { ui { [weak self] in self?.onFinalSpans?(spans) } }
        fx.run(self)
        reachPreview(id)
    }

    private func previewInfoLocked(_ turn: Turn) -> FinalPreviewInfo {
        FinalPreviewInfo(text: turn.payload?.text ?? "", uncertainCount: turn.uncertainCount,
                         dwellRemaining: turn.manual ? 0 : turn.dwellRemaining, paused: !turn.pauses.isEmpty,
                         manual: turn.manual, destination: turn.destinationName)
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
        lock.withLock {
            guard let turn = previewTurnLocked() else { return }
            let wasPaused = !turn.pauses.isEmpty
            turn.pauses.insert(reason)
            stopDwellLocked(turn)
            if !wasPaused { fx.present(.finalPreview(previewInfoLocked(turn))) }
        }
        fx.run(self)
    }

    public func resumeDwell(_ reason: DwellPause) {
        var fx = Effects()
        lock.withLock {
            guard let turn = previewTurnLocked(), turn.pauses.remove(reason) != nil, turn.pauses.isEmpty else { return }
            fx.present(.finalPreview(previewInfoLocked(turn)))
            startDwellLocked(turn)
        }
        fx.run(self)
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

    /// "Insert text" — the manual-review action, or skipping the rest of the dwell.
    public func insertNow() {
        guard let id = lock.withLock({ previewTurnLocked()?.id }) else { return }
        exitDwell(id, .insert)
    }

    /// "Cancel" on the preview.
    public func cancelPreview() {
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
            turn.pendingExit = exit
            turn.dwellTimer?.cancel()
            turn.dwellTimer = nil
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
        guard let target = lock.withLock({ turns[id]?.target }) else {
            // No snapshot ever arrived (the read is still running, or AX was unreadable): aim at the
            // payload's own focus; the injector still refuses a moved focus before posting.
            let fallback = TurnTarget(revision: TargetRevision(focus: payload.pending?.focus), takenAt: clock.now)
            return await write(id, payload, lander: lander, target: fallback)
        }
        let verdict = focusGuard.revalidate(target.revision, ownLandingSinceSnapshot: ownLandingSince(target, lander: lander))
        guard verdict.isSafe else {
            Log.app.notice("turn \(id.description): destination \(verdict.rawValue) during the preview — held (D01)")
            return hold(id, payload, lander: lander, reason: DeliveryReason.destinationChanged, actual: focusGuard.snapshot())
        }
        return await write(id, payload, lander: lander, target: target)
    }

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
            fx.present(.inserting(text: payload.text))
            return true
        }
        guard proceed else { return payload }
        fx.run(self)
        let result = await lander.inject(payload: payload, commit: key)
        let delivery = result.delivery
        let stage: TurnStage
        switch delivery {
        case .some(.held): stage = .held
        case .some(.delivered), .some(.partial): stage = .landed
        case .some(.failed), .none: stage = .failed
        }
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
        let result = lander.hold(payload: payload, reason: reason, in: focusGuard, actual: actual, turnID: id)
        end(id, stage: .held) { $0.outcome = result.delivery }
        return result
    }

    // MARK: Escape, cancel, interruption

    /// Escape (I2, design §5). Before any write: cancel capture and preview, nothing inserted,
    /// "Cancelled" for 800 ms. After the write began: never claim a cancellation — the outcome is
    /// resolved first, then a safe Undo is offered for 5 s. Returns what it did.
    @discardableResult
    public func escape() -> EscapeResolution? {
        let (cancel, writing) = lock.withLock { () -> ([TurnID], Bool) in
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
        end(id, stage: .cancelled)
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
        guard lock.withLock({ undo?.turnID == id }) else { return }
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
        let ended = lock.withLock { () -> Parked? in
            guard let turn = turns[id] else { return nil }
            change(&turn.record)
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
    }

    private func busyTurnLocked() -> TurnID? {
        turns.values.first { turn in
            switch turn.stage {
            case .finalPreview, .inserting: return true
            case .finishing: return turn.origin == .hold
            default: return false
            }
        }?.id
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

    private func present(_ state: PillState) {
        ui { [weak self] in self?.onPresent?(state) }
    }

    private func retract() {
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
    var latched = false
    var speaking = false
    var partialText: String?
    var payloadStarted = false
    var payload: LandingResult?
    var slow = false
    var offer: FinishingOffer?
    var manual = false
    var dwellTotal: TimeInterval?
    var dwellRemaining: TimeInterval = 0
    var dwellStartedAt: Date?
    var pauses: Set<DwellPause> = []
    var rendered = false
    var uncertainCount = 0
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

    public init(controller: TurnController, store: TurnStore, escape: EscapeHotkey) {
        self.controller = controller
        self.store = store
        self.escape = escape
    }

    /// `finishLatch`: the latched pill's "Finish" (the same as a tap while latched).
    @MainActor
    @discardableResult
    public static func attach(container: AppContainer, pill: PillViewModel, coordinator: DictationCoordinator,
                              session: SessionCoordinator, escape: EscapeHotkey = EscapeHotkey(),
                              finishLatch: (() -> Void)? = nil) -> TurnWiring {
        let settings = container.settings
        let store = TurnStore(database: container.database, persistsRecovery: { TurnSettings.persistsRecovery(settings) })
        TurnStore.current = store
        let controller = TurnController(lander: container.lander, focusGuard: container.injector.focusGuard, store: store,
                                        dwell: { TurnSettings.previewDwell(settings) })
        controller.useReplaceRange(over: container.system)
        let wiring = TurnWiring(controller: controller, store: store, escape: escape)
        current = wiring

        // What the turn shows, and taking it down only while the pill still shows the turn.
        controller.onPresent = { [weak pill] state in pill?.present(state) }
        controller.onRetract = { [weak pill] in
            guard let pill, Self.isTurnRow(pill.state, captureOpen: pill.turn.captureOpen) else { return }
            pill.hide()
        }
        controller.onFinalSpans = { [weak pill] spans in pill?.setFinalSpans(spans) }
        controller.onNotice = { [weak wiring, weak pill] entry in wiring?.show(entry, on: pill) }
        controller.onCancelCapture = { [weak session] in session?.escape() }

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
        let previousHover = pill.onPointerInsideChange
        pill.onPointerInsideChange = { [weak controller] inside in
            previousHover?(inside)
            if inside { controller?.pauseDwell(.hover) } else { controller?.resumeDwell(.hover) }
        }
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
        case (.review, .finalPreview), (.reviewAll, .finalPreview):
            // The review surface (S5) resumes it with `resumeDwell(.review)` when it closes.
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
    private func show(_ entry: RecoveryEntry, on pill: PillViewModel?) {
        guard let pill else { return }
        pill.present(.error(message: entry.headline))
        noticeFade?.cancel()
        guard entry.dismissal == .fades else { return }
        let fade = DispatchWorkItem { [weak pill] in
            guard let pill, case .error(let message) = pill.state, message == entry.headline else { return }
            pill.retractDelivery()
        }
        noticeFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + EngineStopReason.quietReturnFade, execute: fade)
    }
}
