import Actions
import Combine
import Foundation
import Injection
import Shared

/// S4 — one drawn flight: its path, and when it started. `start` is when the pill showed `.inserting`,
/// the clock Spool's clockwise reels run on (the prototype's `t` for both). Main thread.
final class TapeFlightRun {
    let id = UUID()
    let start: Date
    let text: String
    /// Updated when the verified field reflows (design §4: "geometry reflows within the same verified
    /// field update the endpoints").
    fileprivate(set) var path: TapeFlightPath
    /// Spool's mouth on screen now, read every frame so a pill that moves or resizes is followed.
    private let mouth: () -> CGPoint?

    init(start: Date, text: String, path: TapeFlightPath, mouth: @escaping () -> CGPoint?) {
        self.start = start
        self.text = text
        self.path = path
        self.mouth = mouth
    }

    /// Nothing is drawn from here on.
    var end: Date { start.addingTimeInterval(SpoolFlight.duration) }

    /// The ribbon at `date`, in the path's display overlay space; `nil` once the tail has fed in.
    func frame(at date: Date) -> SpoolFlight.Frame? {
        path.frame(t: date.timeIntervalSince(start), mouth: currentMouth())
    }

    private func currentMouth() -> CGPoint? {
        guard let point = mouth(), path.display.frame.contains(point) else { return nil }
        return TapeFlightGeometry.local(point, in: path.display)
    }
}

/// Draws a flight. Live: `TapeFlightOverlay`, a pointer-transparent `OverlayWindow` instance.
protocol TapeFlightSurface: AnyObject {
    func show(_ run: TapeFlightRun)
    /// Takes the ribbon down at once.
    func clear()
    /// The destination tape cue under the landed text (design §13 scenario 4); it fades on its own time.
    func showCue(_ cue: TapeFieldCue)
    /// Takes the cue down at once.
    func clearCue()
}

extension TapeFlightSurface {
    func showCue(_ cue: TapeFieldCue) {}
    func clearCue() {}
}

/// Where the reads run and where their results come back.
struct TapeFlightQueues {
    var read: (@escaping () -> Void) -> Void
    var deliver: (@escaping () -> Void) -> Void

    static var live: TapeFlightQueues {
        let queue = DispatchQueue(label: "voiceplus.tapeflight.ax", qos: .userInitiated)
        return TapeFlightQueues(read: { queue.async(execute: $0) }, deliver: { DispatchQueue.main.async(execute: $0) })
    }
}

/// S4 — the mouth-to-caret tape flight (design §4, §5 step 6), subscribed to the pill.
///
/// * `.finalPreview`: sample the destination and its pre-insertion caret (no write has happened).
/// * `.inserting`: verify the destination is still that element and caret, measure the caret there,
///   and fly from Spool's mouth to it while the reels turn clockwise (S1 pose `inserting`). The flight's
///   clock starts with the state, like the reels'.
/// * `.landed` (the outcome of that same write): the flight runs on — the acknowledgement never waits
///   for the flourish (design §5 step 6), and the flourish is not what the acknowledgement cuts short.
///   After a *verified* landing the same write's tail — its Undo row, the pill retracting (`.hidden`,
///   `.ready`) — does not cut it short either.
/// * A flight that finishes on a verified `.landed` leaves the destination tape cue (the prototype's
///   `.field-line`, `TapeFieldCue`): a flat tape-coloured line under the landed text that fades in 1.2 s
///   while any uncertainty mark stays (design §13 scenario 4). It is never drawn over a mark.
/// * Anything else — held, failed, cancelled, a new turn: the ribbon and the cue are taken down at once.
///
/// Suppressed (no flight; the label and the outcome as they would be anyway) when the caret rect is
/// unavailable, the target changed, the field is secure, the caret is on another display, or Reduce
/// Motion is on. It never calls into the turn: it cannot delay or trigger the write. Main thread.
final class TapeFlightController {
    enum Phase: Equatable {
        case idle
        /// The final preview's pre-insertion sample has been asked for.
        case armed
        /// `.inserting`: verifying the destination and measuring the caret.
        case locating
        case flying(TapeFlightPath)
        /// The ribbon fed in; nothing more for this insertion.
        case finished
        case suppressed(TapeFlightSuppression)
    }

    /// Refresh cadence while flying: the caret is re-measured so reflow and scroll move the endpoint,
    /// and a target that changes or loses its geometry takes the ribbon down.
    static let refreshInterval: TimeInterval = 0.15

    private(set) var phase: Phase = .idle
    /// Every suppression, in order (diagnostics; tests).
    private(set) var suppressions: [TapeFlightSuppression] = []
    private(set) var run: TapeFlightRun?
    /// The destination tape cue on screen, if any.
    private(set) var cue: TapeFieldCue?
    /// Why a cue was not drawn after a verified landing, in order (diagnostics; tests).
    private(set) var cueSuppressions: [TapeFlightSuppression] = []

    private let reader: TapeFlightReader
    private let mouth: () -> CGPoint?
    private let displays: () -> [DisplayFrame]
    private let reduceMotion: () -> Bool
    private let surface: TapeFlightSurface
    private let clock: TurnClock
    private let queues: TapeFlightQueues
    /// The destination uncertainty marks on screen (their strips, AppKit screen coordinates).
    private let markStrips: () -> [CGRect]
    private var generation = 0
    private var insertedLength = 0
    private var endTimer: TurnTimer?
    private var refreshTimer: TurnTimer?
    private var cueTimer: TurnTimer?
    private var subscription: AnyCancellable?
    /// This insertion's write landed verified (`.landed(verified: true)`).
    private var landedVerified = false
    /// The display this insertion's flight ran on.
    private var flightDisplay: DisplayFrame?
    /// A cue was asked for this insertion (at most one).
    private var cueRequested = false

    init(reader: TapeFlightReader, mouth: @escaping () -> CGPoint?, displays: @escaping () -> [DisplayFrame],
         reduceMotion: @escaping () -> Bool, surface: TapeFlightSurface, clock: TurnClock, queues: TapeFlightQueues,
         markStrips: @escaping () -> [CGRect] = { [] }) {
        self.reader = reader
        self.mouth = mouth
        self.displays = displays
        self.reduceMotion = reduceMotion
        self.surface = surface
        self.clock = clock
        self.queues = queues
        self.markStrips = markStrips
    }

    /// Subscribes to the pill's state (delivered on the main thread, as `PillViewModel` publishes it).
    func follow(_ states: AnyPublisher<PillState, Never>) {
        subscription = states.sink { [weak self] state in self?.stateChanged(state) }
    }

    func stateChanged(_ state: PillState) {
        switch state {
        case .finalPreview:
            switch phase {
            case .armed, .suppressed(.reduceMotion): return   // the same preview, re-published
            default: break
            }
            stop()
            if reduceMotion() { return suppress(.reduceMotion) }
            phase = .armed
            queues.read { [reader] in _ = reader.arm() }
        case .inserting(let text):
            switch phase {
            case .locating, .flying, .finished, .suppressed(.reduceMotion): return   // the same insertion, re-published
            default: break
            }
            let armed = phase == .armed
            generation += 1
            landedVerified = false
            cueRequested = false
            flightDisplay = nil
            takeDownCue()
            if reduceMotion() { return suppress(.reduceMotion) }
            // No pre-insertion sample: the caret the text goes in at was never seen; aim at nothing.
            guard armed else { return suppress(.caretUnavailable) }
            phase = .locating
            insertedLength = text.utf16.count
            let turn = generation, start = clock.now, length = insertedLength
            queues.read { [reader, queues] in
                let fix = reader.locate(insertedLength: length)
                queues.deliver { [weak self] in self?.located(fix, generation: turn, start: start, text: text) }
            }
        case .landed(let info):
            switch phase {
            case .locating, .flying, .finished:
                guard info.verified else { return }
                landedVerified = true
                if phase == .finished { requestCue(generation) }
            default: stop()
            }
        case .undoAvailable, .hidden, .ready:
            // The tail of a verified landing: its Undo row, the pill retracting. The ribbon finishes and
            // the cue fades on their own time; before a verified landing these are interruptions.
            if landedVerified, isFollowingThisWrite { return }
            stop()
        default:
            stop()
        }
    }

    /// Still showing (or about to show) something for the current insertion.
    private var isFollowingThisWrite: Bool {
        switch phase {
        case .locating, .flying, .finished: return true
        default: return cue != nil
        }
    }

    // MARK: Flying

    private func located(_ fix: Result<CGRect, TapeFlightSuppression>, generation turn: Int, start: Date, text: String) {
        guard turn == generation, phase == .locating else { return }
        switch plan(fix) {
        case .failure(let reason):
            suppress(reason)
        case .success(let path):
            let remaining = start.addingTimeInterval(SpoolFlight.duration).timeIntervalSince(clock.now)
            guard remaining > 0 else {
                phase = .finished
                return
            }
            let run = TapeFlightRun(start: start, text: text, path: path, mouth: mouth)
            self.run = run
            flightDisplay = path.display
            phase = .flying(path)
            surface.show(run)
            endTimer = clock.schedule(after: remaining) { [weak self] in self?.finished(turn) }
            scheduleRefresh(turn)
        }
    }

    private func plan(_ fix: Result<CGRect, TapeFlightSuppression>) -> Result<TapeFlightPath, TapeFlightSuppression> {
        fix.flatMap { TapeFlightGeometry.path(mouth: mouth(), caretAX: $0, displays: displays()) }
    }

    private func scheduleRefresh(_ turn: Int) {
        refreshTimer = clock.schedule(after: Self.refreshInterval) { [weak self] in
            guard let self, turn == self.generation, case .flying = self.phase else { return }
            let length = self.insertedLength
            self.queues.read { [reader = self.reader, queues = self.queues] in
                let fix = reader.locate(insertedLength: length)
                queues.deliver { [weak self] in self?.refreshed(fix, generation: turn) }
            }
        }
    }

    private func refreshed(_ fix: Result<CGRect, TapeFlightSuppression>, generation turn: Int) {
        guard turn == generation, case .flying = phase, let run else { return }
        switch plan(fix) {
        case .failure(let reason):
            takeDown()
            suppress(reason)
        case .success(let path):
            run.path = path
            phase = .flying(path)
            scheduleRefresh(turn)
        }
    }

    private func finished(_ turn: Int) {
        guard turn == generation, case .flying = phase else { return }
        takeDown()
        phase = .finished
        if landedVerified { requestCue(turn) }
    }

    // MARK: The destination tape cue

    /// The flight finished on a verified landing: measure the landed text (same element, caret inside
    /// what this write put there) and lay the cue under it. Once per insertion.
    private func requestCue(_ turn: Int) {
        guard turn == generation, phase == .finished, !cueRequested, let display = flightDisplay else { return }
        cueRequested = true
        let length = insertedLength
        queues.read { [reader, queues] in
            let fix = reader.landedRect(insertedLength: length)
            queues.deliver { [weak self] in self?.cueLocated(fix, generation: turn, display: display) }
        }
    }

    private func cueLocated(_ fix: Result<CGRect, TapeFlightSuppression>, generation turn: Int, display: DisplayFrame) {
        guard turn == generation, phase == .finished, cue == nil else { return }
        let planned = fix.flatMap {
            TapeFieldCue.plan(textAX: $0, flightDisplay: display, displays: displays(), strips: markStrips())
        }
        switch planned {
        case .failure(let reason):
            cueSuppressions.append(reason)
            Log.app.info("tape cue not drawn: \(reason.rawValue)")
        case .success(let rect):
            let cue = TapeFieldCue(display: display, rect: rect, start: clock.now)
            self.cue = cue
            surface.showCue(cue)
            cueTimer = clock.schedule(after: TapeFieldCue.lifetime) { [weak self] in
                guard let self, self.cue == cue else { return }
                self.takeDownCue()
            }
        }
    }

    private func takeDownCue() {
        cueTimer?.cancel()
        cueTimer = nil
        if cue != nil {
            cue = nil
            surface.clearCue()
        }
    }

    // MARK: Stopping

    /// Any other state: the ribbon comes down at once and every pending read is ignored.
    private func stop() {
        guard phase != .idle || run != nil || cue != nil else { return }
        generation += 1
        takeDown()
        takeDownCue()
        landedVerified = false
        phase = .idle
        queues.read { [reader] in reader.disarm() }
    }

    private func takeDown() {
        endTimer?.cancel()
        refreshTimer?.cancel()
        endTimer = nil
        refreshTimer = nil
        if run != nil {
            run = nil
            surface.clear()
        }
    }

    private func suppress(_ reason: TapeFlightSuppression) {
        phase = .suppressed(reason)
        suppressions.append(reason)
        Log.app.info("tape flight suppressed: \(reason.rawValue)")
    }
}

/// Installs the live flight on the pill. The pill's `SpoolView` calls this through its anchor tracker the
/// first time it is drawn in a window, so nothing at the composition root has to remember it, and no
/// view model built in a test ever reads Accessibility or opens a window. Idempotent.
enum TapeFlightWiring {
    static func installLive(on pill: PillViewModel) {
        let tracker = pill.spoolAnchors
        guard tracker.subscriber == nil else { return }
        let controller = TapeFlightController(
            reader: TapeFlightReader(probe: AXTapeFlightProbe(), caret: AXTapeFlightCaret()),
            mouth: { [weak tracker] in tracker?.mouthOnScreen },
            displays: { DisplayNormalizer.current().displays },
            reduceMotion: { AppearanceSettings.effectiveReduceMotion(UserDefaultsSettingsStore()) },
            surface: TapeFlightOverlay(),
            clock: MainQueueTurnClock(),
            queues: .live,
            markStrips: { DestinationMarksOverlay.visibleStrips })
        controller.follow(pill.$state.eraseToAnyPublisher())
        tracker.subscriber = controller
    }
}
