import Engine
import Foundation
import Injection
import Shared

/// R2.2's segment surface, as the latch needs it.
///
/// `RealEngine` already has exactly these two members; this protocol exists so the latch can be
/// driven by a scripted engine in tests, and so the App layer does not have to know which concrete
/// engine is behind `EngineProtocol` today.
public protocol SegmentSessionEngine: AnyObject {
    func segmentEvents() -> AsyncStream<SegmentEvent>
    @discardableResult func closeSegmentAtEndpoint() async -> SegmentID?
}

extension RealEngine: SegmentSessionEngine {}

public extension EngineProtocol {
    /// The segment surface behind this engine, if it has one.
    ///
    /// `SwappableEngine` lives in `Shared` and forwards only `EngineEvent` — R2.2 deliberately kept
    /// `SegmentEvent` off the frozen contract. Rather than widen `Shared`, the box is unwrapped
    /// here, and it is unwrapped on **every** access so a model installed mid-run (which swaps the
    /// engine underneath) is picked up without re-attaching anything.
    var segmentSession: SegmentSessionEngine? {
        if let direct = self as? SegmentSessionEngine { return direct }
        if let swappable = self as? SwappableEngine { return swappable.current as? SegmentSessionEngine }
        return nil
    }
}

/// What the latch did with one closed segment. Every closure ends in exactly one of these, and
/// `delivered` is the only one that put characters in a field.
public enum LatchSegmentOutcome: Equatable, Sendable {
    /// Inserted (or posted — `Injection` owns the readback rule).
    case delivered(String)
    /// Committed text kept for the user, naming where it was meant to go (V3 §6, R2.3's held queue).
    case held(destination: String, reason: String)
    /// Speaker filtering refused it. Nothing was inserted and nothing was stored.
    case suppressed(SpeakerFilter.SuppressionReason)
    /// Ambient mode: transcript only, never typed and never acted on (V3 §8).
    case transcript(String)
    /// Nothing to deliver.
    case empty
    /// Escape, hard mute, lock or sleep dropped this segment before it was delivered.
    case cancelled
}

/// Where the latch sends committed text. The production implementation is
/// `LanderLatchDelivery` (pipeline → injector → history, plus `FocusGuard`'s held queue); tests
/// use a spy, which is what makes every V3 §8 row testable on a machine with no microphone,
/// no window server and no TCC grants.
public protocol LatchDelivering: AnyObject {
    /// Insert committed text for a closed segment. `true` when something was posted.
    func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool
    /// Keep committed text instead of inserting it. Returns the name of the destination it is held
    /// for, which is what the user has to name to resume into it.
    func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String
    /// The user asked, explicitly and by name, for held text to go somewhere. Returns how many
    /// items were inserted.
    func insertHeld(into target: String) -> Int
}

/// R3.2 — latch behaviour: endpoints close segments while listening continues, focus changes pause
/// delivery, and Escape / lock / sleep cancel what has not landed without touching what has.
///
/// The runtime owns three things and nothing else:
///
/// * **When to close a segment.** It runs its own `Endpointer` over VAD events (the audio pipeline
///   only emits `.endpoint` when its `handsFree` option is set, and that option is decided at
///   capture-graph construction), and calls R2.2's `closeSegmentAtEndpoint()`. It never segments
///   audio itself.
/// * **What happens to a closed segment.** Exactly one `LatchSegmentOutcome`, in `SegmentID` order,
///   through `LatchDelivering`. Segments that closed with `.keyRelease` are *not* delivered here:
///   `DictationCoordinator.finalize()` lands the segment that ended the session, as it always has,
///   so nothing is inserted twice.
/// * **The pause.** A focus change while latched stops delivery, holds what is already committed,
///   and waits for `resumeDelivery(into:)` with a named target. Returning to the app does nothing on
///   its own (R2.3's rule).
public final class LatchRuntime: @unchecked Sendable {
    /// Which speech this session is carrying. Ambient speech is transcript-only, forever.
    public enum Source: Equatable, Sendable { case dictation, ambient }

    private let lock = NSLock()
    private let delivery: any LatchDelivering

    /// Is the app latched right now? Wired to `DictationCoordinator.latched`.
    public var isLatched: () -> Bool = { false }
    /// R3.3 — asked once per closed segment while speaker filtering is on. `nil` means "no filter
    /// configured", which is not the same as "filter says yes": see `SpeakerFilter`.
    public var speakerGuard: (() -> SpeakerFilter.Decision)?
    /// Ambient transcript sink (V3 §8: into the Timeline, never typed). Set by the ambient item.
    public var onTranscript: ((String, SegmentID) -> Void)?
    /// Every outcome, for the pill and for tests.
    public var onOutcome: ((LatchSegmentOutcome, SegmentID) -> Void)?
    /// Called when delivery pauses or resumes, with the destination that is being waited on.
    public var onDeliveryPaused: ((String?) -> Void)?

    public var source: Source = .dictation

    /// Trailing silence and the hard segment bound. One endpointer, reset per segment.
    public var endpointer = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8.0, maxUtterance: 60)

    private var endpointState = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8.0, maxUtterance: 60)
    private var segmentStart: TimeInterval = 0
    private var engine: SegmentSessionEngine?
    private var events: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private var generation = 0
    private var queued = 0
    private var completed = 0

    // MARK: Observable state (tests and the pill read these)

    /// Committed text that reached a destination, in spoken order. Never retracted, never rewritten.
    public private(set) var deliveredText: [String] = []
    /// Segments closed by an endpoint that the runtime has seen.
    public private(set) var closedSegments: [SegmentID] = []
    /// Outcomes in order, one per closed segment.
    public private(set) var outcomes: [(segment: SegmentID, outcome: LatchSegmentOutcome)] = []
    /// True while a focus change (or anything else that names a destination) has suspended delivery.
    public private(set) var deliveryPaused = false
    /// The destination delivery is waiting to be resumed into, when it is known.
    public private(set) var awaitingDestination: String?
    /// How many closed segments were dropped without being delivered (Escape, mute, lock, sleep).
    public private(set) var cancelledSegments = 0
    /// Endpoint closures the runtime asked the engine for.
    public private(set) var endpointClosures = 0

    public init(delivery: any LatchDelivering) {
        self.delivery = delivery
    }

    deinit {
        events?.cancel()
    }

    // MARK: Attaching to a session

    /// Subscribes to R2.2's segment stream. Safe to call again; the previous subscription ends.
    public func attach(_ engine: any EngineProtocol) {
        attach(segments: engine.segmentSession)
    }

    public func attach(segments: SegmentSessionEngine?) {
        events?.cancel()
        lock.withLock { self.engine = segments }
        guard let segments else { return }
        let stream = segments.segmentEvents()
        events = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    public func detach() {
        events?.cancel()
        events = nil
        lock.withLock { engine = nil }
    }

    // MARK: Endpoints

    /// One VAD event from the capture pipeline. Positions are stream-relative seconds.
    public func noteVAD(_ event: VADEvent) {
        guard isLatched() else { return }
        lock.withLock {
            switch event {
            case .speechStart(let t): endpointState.speechStarted(at: t - segmentStart)
            case .speechEnd(let t): endpointState.speechEnded(at: t - segmentStart)
            }
        }
    }

    /// Call on every audio tick with the current stream position. Closes a segment when the
    /// endpointer says speech ended, or when the segment hit its hard bound.
    ///
    /// `.noSpeech` deliberately does **not** close anything: latch is an explicit session, and a
    /// user who is thinking has not stopped dictating. Only the user's single tap ends the session.
    public func tick(at position: TimeInterval) {
        guard isLatched() else { return }
        let decision: Endpointer.Decision? = lock.withLock { endpointState.tick(now: position - segmentStart) }
        switch decision {
        case .endpoint, .maxDuration:
            closeSegmentAtEndpoint(at: position)
        case .noSpeech:
            lock.withLock { endpointState.reset(); segmentStart = position }
        case nil:
            break
        }
    }

    /// The capture pipeline already decided (its `handsFree` option is on).
    public func noteEndpoint(_ decision: Endpointer.Decision, at position: TimeInterval) {
        guard isLatched() else { return }
        switch decision {
        case .endpoint, .maxDuration: closeSegmentAtEndpoint(at: position)
        case .noSpeech: lock.withLock { endpointState.reset(); segmentStart = position }
        }
    }

    /// Asks R2.2 to close the open segment while capture keeps running.
    public func closeSegmentAtEndpoint(at position: TimeInterval = 0) {
        let engine = lock.withLock { () -> SegmentSessionEngine? in
            endpointState = endpointer
            endpointState.reset()
            segmentStart = position
            endpointClosures += 1
            return self.engine
        }
        guard let engine else { return }
        Task { await engine.closeSegmentAtEndpoint() }
    }

    /// A fresh session: the endpointer starts from this position.
    public func sessionStarted(at position: TimeInterval = 0) {
        lock.withLock {
            endpointState = endpointer
            endpointState.reset()
            segmentStart = position
            generation += 1
        }
    }

    // MARK: Segment events

    public func handle(_ event: SegmentEvent) {
        switch event {
        case .opened, .preview, .rejected:
            break
        case .closed(let segment, let spans, _, let reason):
            switch reason {
            case .endpoint, .backlogBound:
                // A segment that closed while capture continued. This is the latch path, and the
                // only path this runtime delivers on.
                lock.withLock { closedSegments.append(segment) }
                enqueue(segment: segment, spans: spans)
            case .keyRelease:
                // The segment that ended the session. `DictationCoordinator.finalize()` lands it
                // through `UtteranceLander`, exactly as in hold mode — delivering it here as well
                // is how the same text would get typed twice.
                break
            case .cancelled:
                lock.withLock { cancelledSegments += 1 }
                record(.cancelled, for: segment)
            }
        }
    }

    // MARK: The pause (focus change while latched)

    /// Focus moved while latched (V3 §8). Delivery stops; anything already committed and anything
    /// that commits from now on is held and named. Nothing resumes on its own.
    public func pauseDelivery(awaiting destination: String?) {
        lock.withLock {
            deliveryPaused = true
            awaitingDestination = destination
        }
        onDeliveryPaused?(destination)
    }

    /// The user named where the held text should go. Only an explicit, named target resumes
    /// delivery: `resumeDelivery(into: "")` is refused, and so is a target that names nothing.
    @discardableResult
    public func resumeDelivery(into target: String) -> Int {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.app.notice("latch: refused to resume delivery into an unnamed target")
            return 0
        }
        let inserted = delivery.insertHeld(into: trimmed)
        lock.withLock {
            deliveryPaused = false
            awaitingDestination = nil
        }
        onDeliveryPaused?(nil)
        return inserted
    }

    // MARK: Cancelling pending work

    /// Escape (V3 §4.3), hard mute (§4.4) and lock/sleep (§8) all land here: everything that has
    /// closed but not been delivered is dropped, and **already-inserted text is untouched** — this
    /// is not an undo.
    @discardableResult
    public func cancelPending(reason: String) -> Int {
        let dropped = lock.withLock { () -> Int in
            generation += 1
            let outstanding = queued - completed
            cancelledSegments += max(0, outstanding)
            return max(0, outstanding)
        }
        if dropped > 0 { Log.app.notice("latch: dropped \(dropped) pending segment(s) — \(reason)") }
        return dropped
    }

    /// Tests only: run every queued delivery to completion.
    public func settle() async {
        while true {
            let (task, done) = lock.withLock { (chain, completed >= queued) }
            if done { return }
            await task?.value
        }
    }

    // MARK: Ordered delivery

    private func enqueue(segment: SegmentID, spans: [TranscriptSpan]) {
        lock.lock()
        let generation = self.generation
        let previous = chain
        queued += 1
        chain = Task { [weak self] in
            await previous?.value
            await self?.run(segment: segment, spans: spans, generation: generation)
        }
        lock.unlock()
    }

    private func run(segment: SegmentID, spans: [TranscriptSpan], generation: Int) async {
        defer { lock.withLock { completed += 1 } }
        // Cancelled behind our back (Escape, mute, lock, sleep). The text is dropped, never held:
        // the user asked for it to go away.
        guard lock.withLock({ self.generation == generation }) else {
            record(.cancelled, for: segment)
            return
        }
        let text = spans.joinedText
        guard !text.isEmpty else {
            record(.empty, for: segment)
            return
        }
        // Ambient speech is transcript-only, and that check comes before everything else: no gate
        // downstream can turn ambient audio into typing if it never reaches delivery.
        if source == .ambient {
            onTranscript?(text, segment)
            record(.transcript(text), for: segment)
            return
        }
        if let decision = speakerGuard?(), case .suppress(let reason) = decision {
            Log.app.notice("latch: insertion suppressed — \(reason.rawValue)")
            record(.suppressed(reason), for: segment)
            return
        }
        let paused = lock.withLock { (deliveryPaused, awaitingDestination) }
        if paused.0 {
            let reason = LatchReason.awaitingNamedDestination
            let named = delivery.hold(spans, segment: segment, reason: reason)
            let destination = named.isEmpty ? (paused.1 ?? "") : named
            record(.held(destination: destination, reason: reason), for: segment)
            return
        }
        if await delivery.deliver(spans, segment: segment) {
            lock.withLock { deliveredText.append(text) }
            record(.delivered(text), for: segment)
        } else {
            let reason = DeliveryReason.destinationChanged
            let destination = delivery.hold(spans, segment: segment, reason: reason)
            record(.held(destination: destination, reason: reason), for: segment)
        }
    }

    private func record(_ outcome: LatchSegmentOutcome, for segment: SegmentID) {
        lock.withLock { outcomes.append((segment, outcome)) }
        onOutcome?(outcome, segment)
    }
}

/// Why the latch held text. Deliberately *not* `DeliveryReason.destinationChanged`: the pill
/// suppresses the destination name for a changed destination (the snapshot is stale), and R3.2
/// requires the opposite — a held item from a latched session must **name** the target the user has
/// to resume into. `PillDelivery.headline(forHeld:destination:)` renders this one as "Held for Notes".
public enum LatchReason {
    /// Focus moved while latched: delivery is paused until the user names where the text goes.
    public static let awaitingNamedDestination = "latched: waiting for a named destination"
}

/// Production delivery: committed spans → `UtteranceLander` (pipeline → injection → history), held
/// text → R2.3's `FocusGuard` queue. There is no second holding mechanism here on purpose; the
/// pill's held row, the Recover-text menu and Insert here / Copy / Discard all already read that one.
public final class LanderLatchDelivery: LatchDelivering, @unchecked Sendable {
    private let lander: UtteranceLander
    private let focusGuard: FocusGuard
    /// Where the user was when the latched session started, so held text can name its destination.
    public var focusSnapshot: () -> FocusSnapshot?
    public var clock: () -> Date = Date.init
    /// Every landing, so the pill's delivery row works in latch exactly as it does in hold.
    public var onLanded: ((LandingResult) -> Void)?

    public init(lander: UtteranceLander, focusGuard: FocusGuard, focusSnapshot: @escaping () -> FocusSnapshot?) {
        self.lander = lander
        self.focusGuard = focusGuard
        self.focusSnapshot = focusSnapshot
    }

    public func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool {
        let result = await lander.land(spans, startedAt: clock(), focus: focusSnapshot())
        onLanded?(result)
        return result.landed
    }

    public func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String {
        let snapshot = focusSnapshot()
        let request = InjectionRequest(text: spans.joinedText, expectedFocus: snapshot)
        let item = focusGuard.hold(request, reason: reason, segmentID: segment, destination: snapshot)
        return item.destinationName
    }

    public func insertHeld(into target: String) -> Int {
        // Insert *the text the user named a target for*, oldest first, and only the items that were
        // held for that target. `FocusGuard.insertHere` re-runs the whole injection stack against
        // whatever has focus now, which is the only path that turns held into delivered.
        let matching = focusGuard.held.filter { $0.destinationName.caseInsensitiveCompare(target) == .orderedSame }
        let items = matching.isEmpty ? focusGuard.held : matching
        var inserted = 0
        for item in items {
            if let outcome = focusGuard.insertHere(item.id), outcome.succeeded { inserted += 1 }
        }
        return inserted
    }
}
