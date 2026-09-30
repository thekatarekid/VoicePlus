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
    private var previousPath: TapeFlightPath?
    private var transitionStart: Date?
    private var transitionDuration: TimeInterval = 0

    /// Acknowledgement and reflow never teleport the existing bridge to a new baseline.
    func update(path next: TapeFlightPath, at date: Date) {
        guard path != next else { return }
        previousPath = displayedPath(at: date)
        transitionStart = date
        transitionDuration = min(0.12, max(0, end.timeIntervalSince(date)))
        path = next
    }

    private func displayedPath(at date: Date) -> TapeFlightPath {
        guard let old = previousPath, let start = transitionStart, transitionDuration > 0 else { return path }
        let fraction = min(1, max(0, date.timeIntervalSince(start) / transitionDuration))
        let p = fraction * fraction * (3 - 2 * fraction)
        guard p < 1 else { return path }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * p }
        var value = path
        value.to = CGPoint(x: mix(old.to.x, path.to.x), y: mix(old.to.y, path.to.y))
        value.lines = path.lines.enumerated().map { index, line in
            let before: SpoolFlight.Line
            if index < old.lines.count { before = old.lines[index] }
            else if index == 0 { before = SpoolFlight.Line(x: old.to.x, y: old.to.y, width: 0) }
            else { before = SpoolFlight.Line(x: line.x, y: line.y, width: 0) }
            return SpoolFlight.Line(x: mix(before.x, line.x), y: mix(before.y, line.y), width: mix(before.width, line.width))
        }
        return value
    }

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
        let mouth = currentMouth()
        guard var frame = displayedPath(at: date).frame(t: date.timeIntervalSince(start), mouth: mouth) else { return nil }
        // New multiline connectors must appear with their measured lines, never flash at the old
        // caret when acknowledgement arrives after line travel has already begun.
        if previousPath?.lines.isEmpty == true, let transitionStart, transitionDuration > 0 {
            let fraction = min(1, max(0, date.timeIntervalSince(transitionStart) / transitionDuration))
            if fraction < 1 {
                let bridgeCount = frame.points.isEmpty ? 0 : 1
                let bridge = Array(frame.drawing.nodes.prefix(bridgeCount))
                let lines = Array(frame.drawing.nodes.dropFirst(bridgeCount))
                frame.drawing.nodes = bridge + [.group(attributes: [SpoolAttribute("opacity", number: fraction)],
                    transform: nil, children: lines)]
            }
        }
        return frame
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
///   `.field-line`, `TapeFieldCue`): a flat tape-coloured line under the landed text that fades in 1 s
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
    /// How often the final preview's pre-insertion sample is taken again while the preview is up.
    static let rearmInterval: TimeInterval = 0.25

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
    /// Keeps the preview's pre-insertion sample fresh (`scheduleRearm`).
    private var armTimer: TurnTimer?
    private var refreshTimer: TurnTimer?
    private var cueTimer: TurnTimer?
    private var subscription: AnyCancellable?
    /// This insertion's write landed verified (`.landed(verified: true)`).
    private var landedVerified = false
    /// The display this insertion's flight ran on.
    private var flightDisplay: DisplayFrame?
    /// A cue was asked for this insertion (at most one).
    private var cueRequested = false
    private struct Landing {
        var rects: [CGRect]
        var lines: [SpoolFlight.Line]
    }
    private var landing: Landing?
    private var lineReadPending = false
    private var cueRefreshTimer: TurnTimer?

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
            phase = .armed
            queues.read { [reader] in _ = reader.arm() }
            scheduleRearm()
            if reduceMotion() { suppress(.reduceMotion) }
        case .inserting(let text):
            // No re-arm may run once the write is on its way: the sample must be pre-insertion.
            armTimer?.cancel()
            armTimer = nil
            if phase == .suppressed(.reduceMotion), insertedLength > 0 { return }
            switch phase {
            case .locating, .flying, .finished: return   // the same insertion, re-published
            default: break
            }
            let armed = phase == .armed || phase == .suppressed(.reduceMotion)
            generation += 1
            landedVerified = false
            cueRequested = false
            landing = nil
            lineReadPending = false
            flightDisplay = nil
            takeDownCue()
            if reduceMotion(), armed {
                insertedLength = text.utf16.count
                suppress(.reduceMotion)
                let turn = generation, length = insertedLength
                queues.read { [reader, queues] in
                    let fix = reader.locate(insertedLength: length)
                    queues.deliver { [weak self] in
                        guard let self, turn == self.generation else { return }
                        if case .success(let path) = self.plan(fix) {
                            self.flightDisplay = path.display
                            if self.landedVerified { self.phase = .finished; self.requestCue(turn) }
                        }
                    }
                }
                return
            }
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
            guard info.verified else { return invalidate(.unconfirmed) }
            switch phase {
            case .suppressed(.reduceMotion):
                landedVerified = true
                if flightDisplay != nil { phase = .finished; requestCue(generation) }
            case .locating, .flying, .finished:
                landedVerified = true
                if phase == .finished { requestCue(generation) }
                else { requestLines(generation) }
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
            flightDisplay = path.display
            guard remaining > 0 else {
                phase = .finished
                if landedVerified { requestCue(turn) }
                return
            }
            let run = TapeFlightRun(start: start, text: text, path: path, mouth: mouth)
            self.run = run
            flightDisplay = path.display
            phase = .flying(path)
            surface.show(run)
            endTimer = clock.schedule(after: remaining) { [weak self] in self?.finished(turn) }
            scheduleRefresh(turn)
            if landedVerified { requestLines(turn) }
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
            invalidate(reason)
        case .success(var path):
            guard path.display == run.path.display else { return invalidate(.otherDisplay) }
            path.lines = run.path.lines
            path.verified = run.path.verified
            run.update(path: path, at: clock.now)
            phase = .flying(path)
            if landedVerified { requestLines(turn) }
            scheduleRefresh(turn)
        }
    }

    /// Use measured line geometry throughout flight and settlement, with at most one AX read pending.
    private func requestLines(_ turn: Int) {
        guard landedVerified, let run, turn == generation, !lineReadPending else { return }
        lineReadPending = true
        let length = insertedLength, display = run.path.display
        queues.read { [reader, queues] in
            let fix = reader.landedMeasurements(insertedLength: length)
            queues.deliver { [weak self] in
                guard let self, turn == self.generation else { return }
                self.lineReadPending = false
                guard let run = self.run, case .flying = self.phase else { return }
                switch self.planLines(fix, display: display) {
                case .failure(let reason): self.invalidate(reason)
                case .success(let landing):
                    // Different wrapping cannot be joined by interpolating unrelated lines.
                    if let previous = self.landing, previous.lines.count != landing.lines.count {
                        return self.invalidate(.geometryChanged)
                    }
                    self.landing = landing
                    var path = run.path
                    path.lines = landing.lines
                    path.verified = true
                    run.update(path: path, at: self.clock.now)
                    self.phase = .flying(path)
                }
            }
        }
    }

    private func planLines(_ fix: Result<[TapeFlightLineMeasurement], TapeFlightSuppression>, display: DisplayFrame)
        -> Result<Landing, TapeFlightSuppression> {
        fix.flatMap { measurements in
            var result = Landing(rects: [], lines: [])
            for measurement in measurements {
                switch TapeFieldCue.plan(textAX: measurement.rect, flightDisplay: display, displays: displays(), strips: markStrips()) {
                case .failure(let reason): return .failure(reason)
                case .success(let line):
                    // An incomplete paragraph is not presented as a fully measured landing.
                    guard CGRect(origin: .zero, size: display.frame.size).contains(line) else {
                        return .failure(.caretUnavailable)
                    }
                    result.rects.append(line)
                    result.lines.append(SpoolFlight.Line(x: measurement.rightToLeft ? line.maxX : line.minX,
                        y: line.midY, width: measurement.rightToLeft ? -line.width : line.width))
                }
            }
            return result.rects.isEmpty ? .failure(.caretUnavailable) : .success(result)
        }
    }

    private func finished(_ turn: Int) {
        guard turn == generation, case .flying = phase else { return }
        takeDown()
        phase = .finished
        if landedVerified { requestCue(turn) }
    }

    // MARK: The destination tape cue

    /// Validate the cached flight geometry before settling; never replace it with a newly measured
    /// endpoint in the same frame. Late acknowledgements / Reduce Motion have no prior line geometry.
    private func requestCue(_ turn: Int) {
        guard turn == generation, phase == .finished, !cueRequested, let display = flightDisplay else { return }
        cueRequested = true
        let length = insertedLength
        queues.read { [reader, queues] in
            let fix = reader.landedMeasurements(insertedLength: length)
            queues.deliver { [weak self] in self?.cueLocated(fix, generation: turn, display: display) }
        }
    }

    private func cueLocated(_ fix: Result<[TapeFlightLineMeasurement], TapeFlightSuppression>, generation turn: Int, display: DisplayFrame) {
        guard turn == generation, phase == .finished, cue == nil else { return }
        switch planLines(fix, display: display) {
        case .failure(let reason): invalidate(reason)
        case .success(let measured):
            if let landing, landing.rects != measured.rects || landing.lines != measured.lines {
                return invalidate(.geometryChanged)
            }
            let settled = landing ?? measured
            landing = settled
            let cue = TapeFieldCue(display: display, rects: settled.rects, start: clock.now, reduced: reduceMotion())
            self.cue = cue
            surface.showCue(cue)
            cueTimer = clock.schedule(after: TapeFieldCue.lifetime) { [weak self] in
                guard let self, self.cue == cue else { return }
                self.takeDownCue()
            }
            scheduleCueRefresh(turn)
        }
    }

    private func scheduleCueRefresh(_ turn: Int) {
        cueRefreshTimer = clock.schedule(after: Self.refreshInterval) { [weak self] in
            guard let self, turn == self.generation, let cue = self.cue else { return }
            let length = self.insertedLength
            self.queues.read { [reader = self.reader, queues = self.queues] in
                let fix = reader.landedMeasurements(insertedLength: length)
                queues.deliver { [weak self] in
                    guard let self, turn == self.generation, self.cue == cue else { return }
                    switch self.planLines(fix, display: cue.display) {
                    case .failure(let reason): self.invalidate(reason)
                    case .success(let measured):
                        guard measured.rects == cue.rects, measured.lines == self.landing?.lines else {
                            return self.invalidate(.geometryChanged)
                        }
                        self.scheduleCueRefresh(turn)
                    }
                }
            }
        }
    }

    /// Invalidate pending reads as well as all visible decoration; an unconfirmed write cannot
    /// finish later from a queued successful AX response.
    private func invalidate(_ reason: TapeFlightSuppression) {
        generation += 1
        if landedVerified { cueSuppressions.append(reason) }
        takeDown()
        takeDownCue()
        landing = nil
        lineReadPending = false
        landedVerified = false
        suppress(reason)
    }

    private func takeDownCue() {
        cueRefreshTimer?.cancel()
        cueRefreshTimer = nil
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
        landing = nil
        lineReadPending = false
        insertedLength = 0
        phase = .idle
        queues.read { [reader] in reader.disarm() }
    }

    /// V4.41 — keep the pre-insertion sample fresh while the final preview is up.
    ///
    /// `arm()` used to run exactly once, when the preview appeared. An auto preview inserts 600 ms
    /// later, so the sample was still true; a preview held for review — manual review, a hover pause,
    /// or "Insert now" pressed after a few seconds — insert against a sample whose caret and element
    /// token had moved on (Electron and Chromium re-create the focused element freely), so
    /// `TapeFlightPlanner.verify` answered `.targetChanged` and the landing ribbon was suppressed:
    /// the same insertion that animates on the automatic path animated nothing on the manual one.
    /// Re-arming is always pre-insertion (nothing has been written while the preview is up) and is
    /// cancelled the moment `.inserting` arrives.
    private func scheduleRearm() {
        armTimer?.cancel()
        let turn = generation
        armTimer = clock.schedule(after: Self.rearmInterval) { [weak self] in
            guard let self, turn == self.generation else { return }
            switch self.phase {
            case .armed, .suppressed(.reduceMotion): break
            default: return
            }
            self.queues.read { [reader = self.reader] in _ = reader.arm() }
            self.scheduleRearm()
        }
    }

    private func takeDown() {
        armTimer?.cancel()
        armTimer = nil
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
