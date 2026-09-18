import Actions
import AppKit
import CoreGraphics
import Foundation
import Pipeline
import Shared

/// G3 — what the deixis service needs from the screen: one capture per box, recognition over it,
/// and the crop for the chip while the turn lasts. `ScreenTextService` is the live one.
public protocol ScreenRegionReading: AnyObject {
    var access: ScreenRecordingAccess { get }
    func capture(_ rect: CGRect, display: CGDirectDisplayID) async throws -> CapturedRegion
    func recognize(_ frame: CapturedRegion, role: FieldRole) async throws -> [ScreenTextLine]
    func image(for id: UUID) -> CGImage?
    func discardFrames()
    func discardFrame(_ id: UUID)
}

extension ScreenTextService: ScreenRegionReading {}

/// P3 integration — composition of the input timeline (P3.1), deixis/referent resolvers
/// (P3.3/P3.5) and reverse elicitation (P3.6) behind one seam the app and tests share; since G1–G3
/// also the drawn box: key-gated capture, AX hit-test and text, screenshot and OCR.
///
/// Lifecycle: `beginCapture()` at key-down pins a `CaptureAlignment` (same clock the timeline
/// events are stamped with) and starts the listen-only event tap when Input Monitoring is granted;
/// `endCapture()` at key release (or on entering latch) releases the tap; `augment(_:_:)` runs
/// inside `UtteranceLander.land` and injects `contextLine` (+ window text) into
/// `StageContext.extra` for the pipeline / transform, keeping `lastBindings` around for the act
/// path. Boxes drawn in the turn live in `currentRegions` (with their crop, by `imageID`) until
/// `endTurn()` — the next turn's key-down, a cancel, or the retention limit, whichever is first —
/// or, in latch, until the next segment lands (`augment`).
public final class DeixisService: @unchecked Sendable {
    public static let contextLineKey = "contextLine"
    public static let windowTextKey = "ax.windowText"

    public let timeline: InputTimeline
    public let clock: TimelineClock
    public let resolver: DeixisResolver
    public let referents = ReferentResolver()
    public let hitTester: AXHitTesting
    /// P3.5 providers (AX-backed in the app, static in tests).
    public var participants: ParticipantProviding?
    public var artifacts: ArtifactProviding?
    /// Focused-window text (P3.4) for the pipeline/transform prompt context.
    public var windowText: (() -> String?)?
    /// Fires on every elicitation state change (rings + pill are driven from here).
    public var onElicitationChange: ((ElicitationState) -> Void)?

    // MARK: G1–G3 wiring

    /// G1 — true between key-down and key-up of the dictation key (`HotkeyService.isDictationKeyDown`).
    public var isDictationKeyDown: () -> Bool = { false }
    /// G1 — the session is latched (the key is not held while it listens).
    public var isLatched: () -> Bool = { false }
    /// Where `deixis.drawWithoutKey` and the Screen Recording request flag are read and written.
    public var settings: SettingsStore? {
        didSet {
            lock.lock()
            consent = ScreenRecordingConsent(status: consent.status,
                                             hasRequested: consent.hasRequested || DeixisSettings.screenRecordingRequested(settings))
            lock.unlock()
        }
    }
    /// G3 — text inside a box from the AX tree (`kAXStringForRange` over the visible range).
    public var regionText: AXRegionTextReading?
    /// G2 — screenshot + OCR. nil: no screen text at all (boxes carry AX text only).
    public var screen: ScreenRegionReading?
    /// For the OCR language-correction rule: the app that owns the boxed element.
    public var bundleIDForPID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    /// A drag grew to box size (G1: the latch press it happens in points instead of stopping).
    public var onRegionStarted: (() -> Void)?
    /// Every change to `currentRegions` (S2's chip). Called off the main thread.
    public var onRegionsChanged: (([DeixisRegion]) -> Void)?
    /// A line for the pill: the one-line Screen Recording explanation the first time a box is
    /// drawn, "Screen text isn't available" when a box goes without screen text. Off-main.
    public var onNotice: ((String) -> Void)?
    /// Boxes and their crops are dropped this long after capture ends if nothing ended the turn
    /// first — the same 30 s horizon as the timeline, so a frame never outlives it.
    public var regionRetention: TimeInterval = 30
    /// How long `augment` waits for a box whose screenshot / OCR is still running before the
    /// utterance lands without that text.
    public var settleTimeout: TimeInterval = 0.5

    public private(set) var alignment: CaptureAlignment?
    public private(set) var lastBindings: [DeixisBinding] = []
    public private(set) var lastReferents: [ReferentBinding] = []
    public private(set) var elicitation = ReverseElicitation()
    public private(set) var consent: ScreenRecordingConsent
    private(set) var recorder: EventTapRecorder?
    private var regions: [DeixisRegion] = []
    private var consumed: Set<UUID> = []
    private var analyses: [UUID: Task<Void, Never>] = [:]
    private var noticeShownThisTurn = false
    private var turnGeneration = 0
    private let lock = NSLock()
    /// Signalled whenever a box finishes its analysis.
    private let settled = NSCondition()

    public init(hitTester: AXHitTesting, timeline: InputTimeline = InputTimeline(),
                clock: TimelineClock = .shared, config: DeixisConfig = DeixisConfig(),
                settings: SettingsStore? = nil) {
        self.timeline = timeline
        self.clock = clock
        self.hitTester = hitTester
        self.resolver = DeixisResolver(hitTester: hitTester, config: config)
        self.settings = settings
        self.consent = ScreenRecordingConsent(hasRequested: DeixisSettings.screenRecordingRequested(settings))
    }

    /// Wire the live CGEvent tap (P3.1). `inkSink` is the overlay that draws the box as it is
    /// dragged; safe to call once after launch.
    public func attachRecorder(normalizer: DisplayNormalizer, inkSink: RegionSink?) {
        let r = EventTapRecorder(timeline: timeline, normalizer: normalizer, clock: clock)
        r.regions.sink = inkSink
        r.regions.onRegion = { [weak self] region in self?.regionDrawn(region) }
        r.regions.onBoxStarted = { [weak self] _ in self?.onRegionStarted?() }
        r.gate = regionGate
        recorder = r
    }

    /// G1 — the gate the recorder reads when a drag starts (V4.28).
    public var regionGate: RegionGate {
        RegionGate(isDictationKeyDown: { [weak self] in self?.isDictationKeyDown() ?? false },
                   isLatched: { [weak self] in self?.isLatched() ?? false },
                   drawWithoutKey: { [weak self] in DeixisSettings.drawsWithoutKey(self?.settings) })
    }

    /// Key-down: alignment starts on the timeline clock; the tap records only while armed.
    /// `newTurn: false` re-arms the tap inside a running (latched) turn and keeps its alignment
    /// and boxes.
    public func beginCapture(at instant: TimelineInstant? = nil, newTurn: Bool = true) {
        if newTurn { endTurn() }
        lock.lock()
        if newTurn || alignment == nil { alignment = CaptureAlignment(captureStart: instant ?? clock.now()) }
        turnGeneration += 1
        lock.unlock()
        if let recorder, !recorder.isRecording, EventTapRecorder.hasListenAccess {
            do { try recorder.start() } catch { Log.app.warning("deixis: event tap unavailable: \(error)") }
        }
    }

    /// Key release / entering latch: release the tap; the ring buffer keeps its 30 s horizon for
    /// resolution. A box still being dragged is finished (the key came up just before the mouse).
    public func endCapture(finishingDrag: Bool = true) {
        recorder?.stop(finishingDrag: finishingDrag)
        scheduleRetention()
    }

    /// Whether the tap is armed.
    public var isCapturing: Bool { recorder?.isRecording ?? false }

    /// Turn over: forget every box, its crop and any analysis still running. Nothing was written.
    public func endTurn() {
        lock.lock()
        let running = Array(analyses.values)
        analyses.removeAll()
        regions.removeAll()
        consumed.removeAll()
        noticeShownThisTurn = false
        turnGeneration += 1
        lock.unlock()
        running.forEach { $0.cancel() }
        recorder?.regions.reset()
        screen?.discardFrames()
        onRegionsChanged?([])
        settled.lock(); settled.broadcast(); settled.unlock()
    }

    /// Cancel (a too-short press, Escape): the drag in progress is dropped and the turn's boxes go.
    public func cancelTurn() {
        endCapture(finishingDrag: false)
        endTurn()
    }

    // MARK: G3 — a box → element + text + image

    /// Boxes drawn this turn, in the order they were drawn. The chip reads these.
    public var currentRegions: [DeixisRegion] {
        lock.lock(); defer { lock.unlock() }
        return regions
    }

    /// The crop behind a region's `imageID`, while its turn lasts.
    public func image(for region: DeixisRegion) -> CGImage? {
        region.imageID.flatMap { screen?.image(for: $0) }
    }

    /// A box was finished. Registers it at once (element + AX text are read in the background
    /// with the screenshot) and returns the analysis so tests can await it.
    @discardableResult
    public func regionDrawn(_ drawn: DrawnRegion) -> Task<Void, Never> {
        let decision = screenDecision()
        lock.lock()
        let generation = turnGeneration
        regions.append(DeixisRegion(id: drawn.id, rect: drawn.rect, displayID: drawn.displayID,
                                    screenTextUnavailable: !decision.captures, isPending: true,
                                    drawnAt: drawn.ended ?? clock.now()))
        let notice = noticeShownThisTurn ? nil : decision.notice
        if notice != nil { noticeShownThisTurn = true }
        lock.unlock()
        publishRegions()
        if let notice { onNotice?(notice) }
        let task = Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.analyze(drawn, captures: decision.captures)
        }
        lock.lock()
        if generation == turnGeneration, regions.contains(where: { $0.id == drawn.id }) { analyses[drawn.id] = task }
        lock.unlock()
        return task
    }

    /// Screen Recording, decided per box (G2): capture when granted; the first box ever without
    /// the grant explains and asks once; after that, AX text only.
    private func screenDecision() -> (captures: Bool, notice: String?) {
        guard let screen else { return (false, ScreenRecordingConsent.unavailableNotice) }
        lock.lock()
        let decision = consent.boxDrawn(preflight: screen.access.preflight())
        lock.unlock()
        switch decision {
        case .capture:
            return (true, nil)
        case .explainAndRequest(let explanation):
            // The one-line explanation goes up first, then the system asks (once, ever).
            DeixisSettings.noteScreenRecordingRequested(store: settings)
            lock.lock(); noticeShownThisTurn = true; lock.unlock()
            onNotice?(explanation)
            let granted = screen.access.request()
            lock.lock(); consent.requestReturned(granted: granted); lock.unlock()
            return (granted, nil)
        case .axOnly(let notice):
            return (false, notice)
        }
    }

    private func analyze(_ drawn: DrawnRegion, captures: Bool) async {
        let centre = CGPoint(x: drawn.rect.midX, y: drawn.rect.midY)
        let element = DeixisResolver.coveredElements(bounds: drawn.rect, centroid: centre,
                                                     displayID: drawn.displayID, hitTester: hitTester).first
        let axText = regionText?.text(in: drawn.rect, displayID: drawn.displayID)
        update(drawn.id) {
            $0.element = element
            $0.text = axText ?? ""
            $0.source = .ax
            $0.isPending = captures
        }
        guard captures, let screen, !Task.isCancelled else { return }
        do {
            let frame = try await screen.capture(drawn.rect, display: drawn.displayID)
            // The box was cleared (turn over, cancel) while the screenshot was being taken: the
            // frame goes at once rather than waiting for the next turn.
            guard update(drawn.id, { $0.imageID = frame.id }), !Task.isCancelled else {
                screen.discardFrame(frame.id)
                update(drawn.id) { $0.imageID = nil; $0.isPending = false }
                return
            }
            if axText == nil {
                let lines = try await screen.recognize(frame, role: role(of: element))
                update(drawn.id) {
                    $0.lines = lines
                    $0.text = lines.text
                    $0.source = .ocr
                }
            }
        } catch ScreenTextError.permissionDenied {
            // Revoked between the preflight and the capture.
            update(drawn.id) { $0.screenTextUnavailable = true }
            if claimTurnNotice() { onNotice?(ScreenRecordingConsent.unavailableNotice) }
        } catch {
            Log.app.warning("deixis: screen text for a box failed: \(String(describing: error))")
        }
        update(drawn.id) { $0.isPending = false }
    }

    /// True the first time in a turn: the pill gets at most one screen-text line per turn.
    private func claimTurnNotice() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let first = !noticeShownThisTurn
        noticeShownThisTurn = true
        return first
    }

    /// The field role that decides OCR language correction for a box's element.
    func role(of element: ElementReference?) -> FieldRole {
        guard let element else { return .unknown }
        let field = FieldContext(appBundleID: element.pid > 0 ? bundleIDForPID(element.pid) : nil,
                                 axRole: element.role, hints: element.label.isEmpty ? [] : [element.label])
        return FieldRole.classify(field)
    }

    /// Apply an analysis result to a box that is still in the turn (a box cleared by `endTurn`
    /// stays cleared). False when the box is gone.
    @discardableResult
    private func update(_ id: UUID, _ change: (inout DeixisRegion) -> Void) -> Bool {
        lock.lock()
        guard let i = regions.firstIndex(where: { $0.id == id }) else { lock.unlock(); return false }
        change(&regions[i])
        let done = !regions[i].isPending
        if done { analyses[id] = nil }
        lock.unlock()
        publishRegions()
        if done { settled.lock(); settled.broadcast(); settled.unlock() }
        return true
    }

    /// Block (bounded by `timeout`) until no box of the turn is still being read.
    func waitForPendingRegions(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        settled.lock()
        defer { settled.unlock() }
        while currentRegions.contains(where: \.isPending), Date() < deadline {
            _ = settled.wait(until: deadline)
        }
    }

    private func publishRegions() {
        onRegionsChanged?(currentRegions)
    }

    private func scheduleRetention() {
        lock.lock()
        let generation = turnGeneration
        let delay = regionRetention
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stale = self.turnGeneration == generation && !self.regions.isEmpty && !(self.recorder?.isRecording ?? false)
            self.lock.unlock()
            if stale { self.endTurn() }
        }
    }

    // MARK: Resolution

    /// Resolve both kinds of referents for one utterance. Deixis needs the capture alignment;
    /// conversational referents only need the text.
    @discardableResult
    public func resolve(spans: [TranscriptSpan]) -> (deixis: [DeixisBinding], referents: [ReferentBinding]) {
        lock.lock()
        let pinned = alignment
        lock.unlock()
        let d = pinned.map { resolver.resolve(spans: spans, alignment: $0, timeline: timeline) } ?? []
        let r = referents.resolve(spans.joinedText,
                                  participants: participants?.participants() ?? ContextParticipants(),
                                  artifacts: artifacts?.visibleArtifacts() ?? [])
        lock.lock()
        lastBindings = d
        lastReferents = r
        lock.unlock()
        return (d, r)
    }

    /// `region 1 = <role> "<title>" text: "<…>"` for every box of the turn, numbered in drawing order.
    public var regionContextLines: [String] {
        currentRegions.enumerated().map { $0.element.contextLine(index: $0.offset + 1) }
    }

    /// Context lines for the act path (Phase 4 targets) from the most recent resolution.
    public var actContextLines: [String] {
        lock.lock()
        let bindings = lastBindings, refs = lastReferents
        lock.unlock()
        return bindings.map(\.contextLine) + refs.contextLines + regionContextLines
    }

    /// `UtteranceLander.contextAugmenter` — inject resolver output, the turn's boxes and window
    /// text into the stage context, and kick off reverse elicitation when a binding is ambiguous.
    /// A box goes into one utterance's context only. In latch every segment is its own turn: the
    /// boxes an earlier segment landed with (and their crops) are dropped when the next segment
    /// lands, and that segment's boxes are numbered from 1 again.
    public func augment(_ spans: [TranscriptSpan], _ context: StageContext) -> StageContext {
        var ctx = context
        let (d, r) = resolve(spans: spans)
        waitForPendingRegions(timeout: settleTimeout)
        lock.lock()
        let finished = regions.filter { consumed.contains($0.id) }
        regions.removeAll { consumed.contains($0.id) }
        consumed.removeAll()
        let fresh = regions
        fresh.forEach { consumed.insert($0.id) }
        lock.unlock()
        if !finished.isEmpty {
            finished.compactMap(\.imageID).forEach { screen?.discardFrame($0) }
            publishRegions()
        }
        let regionLines = fresh.enumerated().map { $0.element.contextLine(index: $0.offset + 1) }
        let lines = d.map(\.contextLine) + r.contextLines + regionLines
        if !lines.isEmpty { ctx.extra[Self.contextLineKey] = lines.joined(separator: "; ") }
        if let text = windowText?(), !text.isEmpty { ctx.extra[Self.windowTextKey] = String(text.prefix(2000)) }
        if let ambiguous = d.first(where: { ReverseElicitation.needsElicitation($0) }) {
            ask(about: ambiguous)
        }
        return ctx
    }

    // MARK: - Reverse elicitation (P3.6)

    /// Ring the candidates and ask "which one?". The app glue renders `state` and later feeds
    /// `.point` / `.speech` / `.tick` through `elicit(_:)`.
    public func ask(about binding: DeixisBinding, at instant: TimelineInstant? = nil) {
        let candidates = binding.candidates.prefix(4).enumerated()
            .map { ElicitationCandidate.from($0.element, id: "candidate-\($0.offset)") }
        let state = elicitation.handle(.ask(phrase: binding.word, candidates: Array(candidates),
                                            now: instant ?? clock.now()))
        onElicitationChange?(state)
    }

    @discardableResult
    public func elicit(_ event: ElicitationEvent) -> ElicitationState {
        let state = elicitation.handle(event)
        onElicitationChange?(state)
        return state
    }
}
