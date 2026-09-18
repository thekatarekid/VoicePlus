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

/// B1 — what the latch needs from live capture: the pipeline's VAD edges and endpoint decisions
/// (G0.2's forwards), the stream position to tick its own endpointer with, and the two switches
/// that make the pipeline endpoint at all (`setLatched`) and at the user's pause (`setLatchEndpointer`).
///
/// `PipelineAudioSource` is the production feed (conformance below). The callbacks fire on capture
/// threads, never the main thread; `LatchRuntime` hops them itself (`feedQueue`).
public protocol LatchAudioFeed: AnyObject {
    var onVAD: (@Sendable (VADEvent) -> Void)? { get set }
    var onEndpoint: (@Sendable (Endpointer.Decision) -> Void)? { get set }
    /// Turns the pipeline's endpointing on or off, live.
    func setLatched(_ on: Bool)
    /// The bounds the pipeline's endpointer runs with while latched (B2's pause).
    func setLatchEndpointer(_ endpointer: Endpointer)
    /// Stream seconds at the end of each processed block, in order, on the capture clock the VAD
    /// times use.
    func latchPositions() -> AsyncStream<TimeInterval>
}

extension PipelineAudioSource: LatchAudioFeed {
    public func setLatchEndpointer(_ endpointer: Endpointer) { pipeline.setEndpointer(endpointer) }

    public func latchPositions() -> AsyncStream<TimeInterval> {
        let events = pipeline.events()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task {
                for await event in events {
                    if case .audio(let samples, let position) = event {
                        continuation.yield(position + Double(samples.count) / 16_000)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public extension LatchSettings {
    /// B2 — the latch endpointer for a pause: the pause closes a segment, silence is reported but
    /// never closes one, and a segment is bounded so a long monologue still lands in pieces.
    static func endpointer(pauseSeconds: TimeInterval) -> Endpointer {
        Endpointer(trailingSilence: clamp(pauseSeconds), noSpeechTimeout: noSpeechTimeout,
                   maxUtterance: maxSegmentSeconds)
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
    /// A command took it (a spoken repair, a transform, the act domain, "not you"): nothing to type.
    case consumed
    /// The destination refused dictation outright (a password field). Nothing typed, nothing kept.
    case refused(String)
}

/// B1/B3 — what one delivery attempt came to, as the delivery itself saw it.
public enum LatchDeliveryResult: Equatable, Sendable {
    case delivered
    /// Kept as held text, by the delivery (the injector's focus guard, or a failed post).
    case held(destination: String, reason: String)
    /// A command consumed it; there was nothing to type.
    case consumed
    /// Refused by the destination; nothing typed and nothing kept.
    case refused(String)
    /// Nothing was posted and nothing was kept — the runtime holds it.
    case notDelivered
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

    // B1 — the latch path proper. Defaults below keep a delivery that implements only the three
    // members above working exactly as before.

    /// Where focus is now. Asked when a segment's speech begins and again when the segment closes.
    func currentFocus() -> FocusSnapshot?
    /// Insert a closed segment into `focus` — the snapshot taken when the segment closed.
    func deliver(_ spans: [TranscriptSpan], segment: SegmentID, focus: FocusSnapshot?) async -> LatchDeliveryResult
    /// Keep a closed segment for `destination`, formatted as it would have landed there.
    func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String,
              destination: FocusSnapshot?) async -> LatchDeliveryResult
}

public extension LatchDelivering {
    func currentFocus() -> FocusSnapshot? { nil }

    func deliver(_ spans: [TranscriptSpan], segment: SegmentID, focus: FocusSnapshot?) async -> LatchDeliveryResult {
        await deliver(spans, segment: segment) ? .delivered : .notDelivered
    }

    func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String,
              destination: FocusSnapshot?) async -> LatchDeliveryResult {
        .held(destination: hold(spans, segment: segment, reason: reason), reason: reason)
    }
}

/// B1 — "is this still where the words were going?" Same app, same process: the rule
/// `FocusGuard.matches` applies at injection with its default (element identity off, because many
/// apps re-create the focused element between reads and that would hold text for nothing).
public enum LatchFocus {
    public static func sameDestination(_ a: FocusSnapshot?, _ b: FocusSnapshot?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.pid == b.pid && a.bundleID == b.bundleID
    }

    /// The name a held row shows ("Notes"), as `HeldText.destinationName` spells it.
    public static func name(_ snapshot: FocusSnapshot?) -> String {
        guard let snapshot else { return "" }
        return snapshot.appName.isEmpty ? snapshot.bundleID : snapshot.appName
    }
}

/// R3.2 — latch behaviour: endpoints close segments while listening continues, focus changes pause
/// delivery, and Escape / lock / sleep cancel what has not landed without touching what has.
///
/// The runtime owns four things and nothing else:
///
/// * **When to close a segment.** V4.32/B1: on latch entry it connects to the live capture feed —
///   `setLatched(true)` at the user's pause (B2), VAD edges → `noteVAD`, the pipeline's endpoint
///   decisions → `noteEndpoint`, the stream position → `tick` — and each `.endpoint` closes the
///   segment through R2.2's `closeSegmentAtEndpoint()`. While a feed is connected the pipeline's
///   endpointer is the one that decides: it sees VAD edges and stream time in one ordered
///   sequence, whereas here they arrive over two independent hops, so a verdict reached here could
///   run ahead of a speech start not delivered yet and cut a segment on a pause shorter than the
///   setting. The runtime's own `Endpointer` decides only for a caller that drives `noteVAD` /
///   `tick` by hand (no feed). A repeated or late decision about speech already closed is stale.
///   It never segments audio itself.
/// * **What happens to a closed segment.** Exactly one `LatchSegmentOutcome`, in `SegmentID` order,
///   through `LatchDelivering`, with the focus snapshot taken **when the segment closed** (never the
///   key-release one). Focus that moved since the segment's speech began holds the segment (D01).
///   Segments that closed with `.keyRelease` are *not* delivered here:
///   `DictationCoordinator.finalize()` lands the segment that ended the session, as it always has,
///   so nothing is inserted twice.
/// * **The pause.** A focus change while latched stops delivery, holds what is already committed,
///   and waits for `resumeDelivery(into:)` with a named target. Returning to the app does nothing on
///   its own (R2.3's rule).
/// * **The timer (B4).** `elapsed` — audio time since latch entry — published for the pill.
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
    /// B4 — latch time for the pill's timer: `0` on entry, then once per whole second of audio.
    public var onElapsed: ((TimeInterval) -> Void)?
    /// Where feed callbacks run. The feed calls back on capture threads; `isLatched` and the pill
    /// live on the main thread, so by default every event hops there, in arrival order.
    public var feedQueue: (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async(execute: work) }

    public var source: Source = .dictation

    /// Trailing silence and the hard segment bound. One endpointer, reset per segment. B2's
    /// `setPauseSeconds(_:)` rebuilds it from the "Insert after a pause of" setting.
    public var endpointer = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8.0, maxUtterance: 60)

    private var endpointState = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8.0, maxUtterance: 60)
    private var segmentStart: TimeInterval = 0
    private var engine: SegmentSessionEngine?
    private var events: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private var generation = 0
    private var queued = 0
    private var completed = 0

    // B1 — the live feed, and where each segment's speech began.
    private var feed: LatchAudioFeed?
    private var positions: Task<Void, Never>?
    private var feedToken = 0
    private var openSegment: SegmentID?
    private var beganFocus: [SegmentID: FocusSnapshot] = [:]
    /// Focus at latch entry for the segment open then; used only if no speech start is heard.
    private var provisionalFocus: [SegmentID: FocusSnapshot] = [:]
    private var lastEnqueued: SegmentID?
    // B4
    private var elapsedAnchor: TimeInterval?
    private var publishedSecond = 0

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
    /// B4 — audio seconds since latch entry. Reset on every new latch.
    public private(set) var elapsed: TimeInterval = 0
    /// The last stream position the feed (or a caller) ticked with.
    public private(set) var lastPosition: TimeInterval = 0
    /// True while a live capture feed is connected.
    public var isConnected: Bool { lock.withLock { feed != nil } }
    /// The segment the engine has open, as its last `.opened` said.
    public var currentSegment: SegmentID? { lock.withLock { openSegment } }
    /// Where the open segment's speech began, once a speech start has been heard in it (B1).
    public var openSegmentSpeechFocus: FocusSnapshot? {
        lock.withLock { openSegment.flatMap { beganFocus[$0] } }
    }

    public init(delivery: any LatchDelivering) {
        self.delivery = delivery
    }

    deinit {
        events?.cancel()
        positions?.cancel()
    }

    // MARK: Attaching to a session

    /// Subscribes to R2.2's segment stream. Safe to call again; the previous subscription ends.
    public func attach(_ engine: any EngineProtocol) {
        attach(segments: engine.segmentSession)
    }

    /// Attaching the engine that is already attached keeps the live subscription. `SessionCoordinator`
    /// attaches on every start *and* again on latch entry; re-subscribing there could drop the
    /// session's `.opened` if the engine emitted it in between, and with it the open segment the
    /// focus-at-speech-start bookkeeping (B1) keys on. The segment broadcaster never finishes a
    /// stream between sessions, so one subscription per engine is all it takes.
    public func attach(segments: SegmentSessionEngine?) {
        let same = lock.withLock { () -> Bool in
            guard let current = engine, let segments else { return false }
            return current === segments
        }
        if same, let events, !events.isCancelled { return }
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

    // MARK: Entering and leaving latch (B1, B4)

    /// Latch began. Connects the live capture feed (when there is one), starts the timer at zero,
    /// and notes where focus is for the segment already open. That note is provisional: the feed
    /// only reports speech from now on, so it stands in for "where the speech began" only if no
    /// speech start is heard before the segment closes (the words were already under way).
    public func enterLatch(feed newFeed: LatchAudioFeed?) {
        let segment = lock.withLock { () -> SegmentID? in
            elapsed = 0
            elapsedAnchor = nil
            publishedSecond = 0
            guard let open = openSegment, beganFocus[open] == nil, provisionalFocus[open] == nil else { return nil }
            return open
        }
        if let segment, source == .dictation, let focus = delivery.currentFocus() {
            lock.withLock { if provisionalFocus[segment] == nil { provisionalFocus[segment] = focus } }
        }
        connect(newFeed)
        onElapsed?(0)
    }

    /// Latch ended (a stop tap, Escape, mute, lock, a failed start). Capture stops endpointing,
    /// the feed is released, and the endpointer starts clean next time.
    public func leaveLatch() {
        disconnect()
        lock.withLock {
            endpointState = endpointer
            endpointState.reset()
            elapsedAnchor = nil
        }
    }

    /// Swaps the feed under a running latch (the engine, and the pipeline behind it, was replaced)
    /// without restarting the timer.
    public func replaceFeed(_ newFeed: LatchAudioFeed?) {
        guard isLatched() else { return }
        connect(newFeed)
    }

    private func connect(_ newFeed: LatchAudioFeed?) {
        disconnect()
        guard let newFeed else { return }
        let (token, bounds) = lock.withLock { () -> (Int, Endpointer) in
            feedToken += 1
            feed = newFeed
            elapsedAnchor = nil
            return (feedToken, endpointer)
        }
        newFeed.setLatchEndpointer(bounds)
        newFeed.setLatched(true)
        let hop = feedQueue
        newFeed.onVAD = { [weak self] event in
            hop { guard let self, self.isCurrent(token) else { return }; self.noteVAD(event) }
        }
        newFeed.onEndpoint = { [weak self] decision in
            hop { guard let self, self.isCurrent(token) else { return }; self.noteEndpoint(decision) }
        }
        let stream = newFeed.latchPositions()
        let task = Task { [weak self] in
            for await position in stream {
                guard !Task.isCancelled else { return }
                hop { guard let self, self.isCurrent(token) else { return }; self.tick(at: position) }
            }
        }
        lock.withLock { positions = task }
    }

    private func disconnect() {
        let (old, task) = lock.withLock { () -> (LatchAudioFeed?, Task<Void, Never>?) in
            let was = (feed, positions)
            feed = nil
            positions = nil
            feedToken += 1
            return was
        }
        task?.cancel()
        guard let old else { return }
        old.onVAD = nil
        old.onEndpoint = nil
        old.setLatched(false)
    }

    private func isCurrent(_ token: Int) -> Bool { lock.withLock { feedToken == token } }

    // MARK: The pause setting (B2)

    /// Rebuilds the endpointer for a new pause — here, on the live segment (its speech so far is
    /// kept) and on the connected pipeline.
    public func setPauseSeconds(_ seconds: TimeInterval) {
        let bounds = LatchSettings.endpointer(pauseSeconds: seconds)
        let target = lock.withLock { () -> LatchAudioFeed? in
            endpointer = bounds
            endpointState.trailingSilence = bounds.trailingSilence
            endpointState.noSpeechTimeout = bounds.noSpeechTimeout
            endpointState.maxUtterance = bounds.maxUtterance
            return feed
        }
        target?.setLatchEndpointer(bounds)
    }

    // MARK: Endpoints

    /// One VAD event from the capture pipeline. Positions are stream-relative seconds.
    public func noteVAD(_ event: VADEvent) {
        guard isLatched() else { return }
        let firstSpeech = lock.withLock { () -> SegmentID? in
            switch event {
            case .speechStart(let t): endpointState.speechStarted(at: t - segmentStart)
            case .speechEnd(let t): endpointState.speechEnded(at: t - segmentStart)
            }
            guard case .speechStart = event, let open = openSegment, beganFocus[open] == nil else { return nil }
            return open
        }
        // B1 — where this segment's words were going when they began.
        if let firstSpeech, source == .dictation, let focus = delivery.currentFocus() {
            lock.withLock { if beganFocus[firstSpeech] == nil { beganFocus[firstSpeech] = focus } }
        }
    }

    /// Call on every audio tick with the current stream position. Advances the latch timer (B4)
    /// and, when no feed is connected, closes a segment when the endpointer says speech ended or
    /// the segment hit its hard bound. With a feed connected the pipeline decides (`noteEndpoint`).
    ///
    /// `.noSpeech` deliberately does **not** close anything: latch is an explicit session, and a
    /// user who is thinking has not stopped dictating. Only the user's single tap ends the session.
    public func tick(at position: TimeInterval) {
        guard isLatched() else { return }
        let (decision, publish) = lock.withLock { () -> (Endpointer.Decision?, TimeInterval?) in
            lastPosition = position
            if let anchor = elapsedAnchor { elapsed += max(0, position - anchor) }
            elapsedAnchor = position
            var publish: TimeInterval?
            if Int(elapsed) != publishedSecond {
                publishedSecond = Int(elapsed)
                publish = elapsed
            }
            guard feed == nil else { return (nil, publish) }
            return (endpointState.tick(now: position - segmentStart), publish)
        }
        if let publish { onElapsed?(publish) }
        switch decision {
        case .endpoint, .maxDuration:
            closeSegmentAtEndpoint(at: position)
        case .noSpeech:
            lock.withLock { endpointState.reset(); segmentStart = position }
        case nil:
            break
        }
    }

    /// The capture pipeline decided (it is latched). This is what closes segments while a feed is
    /// connected. A decision about speech this runtime has already closed (a repeat, or one that
    /// raced a closure driven by hand) is stale and ignored:
    /// * `.endpoint(at:)` for speech that ended before the current segment began;
    /// * `.maxDuration` for a segment younger than half the bound (this side cut it already);
    /// * `.noSpeech` once this side has heard speech in the segment.
    public func noteEndpoint(_ decision: Endpointer.Decision, at position: TimeInterval? = nil) {
        guard isLatched() else { return }
        let (now, start, heard, bound) = lock.withLock {
            (position ?? lastPosition, segmentStart, endpointState.speechHeard, endpointer.maxUtterance)
        }
        switch decision {
        case .endpoint(let speechEnd):
            guard speechEnd > start else { return }
            closeSegmentAtEndpoint(at: max(now, speechEnd))
        case .maxDuration:
            guard now - start >= bound / 2 else { return }
            closeSegmentAtEndpoint(at: now)
        case .noSpeech:
            guard !heard else { return }
            lock.withLock { endpointState.reset(); segmentStart = now }
        }
    }

    /// Asks R2.2 to close the open segment while capture keeps running. A speaker still talking
    /// when the segment is cut (the hard bound) is still talking in the next one.
    public func closeSegmentAtEndpoint(at position: TimeInterval? = nil) {
        let engine = lock.withLock { () -> SegmentSessionEngine? in
            let continuing = endpointState.inSpeech
            endpointState = endpointer
            endpointState.reset()
            if continuing { endpointState.speechStarted(at: 0) }
            segmentStart = position ?? lastPosition
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
            lastPosition = position
            elapsedAnchor = nil
            openSegment = nil
            beganFocus.removeAll()
            provisionalFocus.removeAll()
            generation += 1
        }
    }

    // MARK: Segment events

    public func handle(_ event: SegmentEvent) {
        switch event {
        case .opened(let segment):
            let continuing = lock.withLock { () -> Bool in
                openSegment = segment
                return endpointState.inSpeech && beganFocus[segment] == nil
            }
            // Cut at the hard bound mid-sentence: the next segment's speech began now. (`inSpeech`
            // is only ever set by `noteVAD`, which runs only while latched.)
            if continuing, source == .dictation, let focus = delivery.currentFocus() {
                lock.withLock { if beganFocus[segment] == nil { beganFocus[segment] = focus } }
            }
        case .preview, .rejected:
            break
        case .closed(let segment, let spans, _, let reason):
            switch reason {
            case .endpoint, .backlogBound:
                // A segment that closed while capture continued. This is the latch path, and the
                // only path this runtime delivers on.
                let fresh = lock.withLock { () -> Bool in
                    // Serialized by SegmentID: a closure at or before the last one is a repeat.
                    if let last = lastEnqueued, segment == last || segment.precedes(last) == true { return false }
                    lastEnqueued = segment
                    closedSegments.append(segment)
                    return true
                }
                guard fresh else {
                    Log.app.notice("latch: ignored a repeated closure of \(segment.description)")
                    return
                }
                // B1 — the focus snapshot is taken now, when the segment closed. Ambient speech never
                // consults the delivery at all.
                let began = lock.withLock { () -> FocusSnapshot? in
                    let provisional = provisionalFocus.removeValue(forKey: segment)
                    return beganFocus.removeValue(forKey: segment) ?? provisional
                }
                let closedFocus = source == .dictation ? delivery.currentFocus() : nil
                enqueue(Job(segment: segment, spans: spans, began: began, closed: closedFocus))
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

    private struct Job {
        var segment: SegmentID
        var spans: [TranscriptSpan]
        /// Focus when the segment's speech began, when it is known.
        var began: FocusSnapshot?
        /// Focus when the segment closed.
        var closed: FocusSnapshot?
    }

    private func enqueue(_ job: Job) {
        lock.lock()
        let generation = self.generation
        let previous = chain
        queued += 1
        chain = Task { [weak self] in
            await previous?.value
            await self?.run(job, generation: generation)
        }
        lock.unlock()
    }

    private func run(_ job: Job, generation: Int) async {
        let segment = job.segment
        let spans = job.spans
        defer { lock.withLock { completed += 1 } }
        // Cancelled behind our back (Escape, mute, lock, sleep). The text is dropped, never held:
        // the user asked for it to go away.
        guard lock.withLock({ self.generation == generation }) else {
            record(.cancelled, for: segment)
            return
        }
        let text = spans.renderedText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            let result = await delivery.hold(spans, segment: segment, reason: reason, destination: job.closed)
            if case .held(let named, _) = result {
                record(.held(destination: named.isEmpty ? (paused.1 ?? "") : named, reason: reason), for: segment)
            } else {
                record(outcome(for: result, text: text), for: segment)
            }
            return
        }
        // B1 — focus moved while this segment was being spoken: the words were meant for where
        // they began, so they are held for that destination (D01) and never typed into the new one.
        if let began = job.began, !LatchFocus.sameDestination(began, job.closed) {
            let reason = DeliveryReason.destinationChanged
            Log.app.notice("latch: focus changed during \(segment.description); holding it for \(LatchFocus.name(began))")
            let result = await delivery.hold(spans, segment: segment, reason: reason, destination: began)
            record(outcome(for: result, text: text, fallbackDestination: LatchFocus.name(began)), for: segment)
            return
        }
        let result = await delivery.deliver(spans, segment: segment, focus: job.closed)
        if case .notDelivered = result {
            let reason = DeliveryReason.destinationChanged
            let kept = await delivery.hold(spans, segment: segment, reason: reason, destination: job.closed)
            record(outcome(for: kept, text: text), for: segment)
            return
        }
        record(outcome(for: result, text: text), for: segment)
    }

    private func outcome(for result: LatchDeliveryResult, text: String,
                         fallbackDestination: String = "") -> LatchSegmentOutcome {
        switch result {
        case .delivered:
            lock.withLock { deliveredText.append(text) }
            return .delivered(text)
        case .held(let destination, let reason):
            return .held(destination: destination.isEmpty ? fallbackDestination : destination, reason: reason)
        case .consumed:
            return .consumed
        case .refused(let reason):
            return .refused(reason)
        case .notDelivered:
            return .empty
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

/// Production delivery: committed spans → `UtteranceLander` (pipeline → injector → history), held
/// text → R2.3's `FocusGuard` queue. There is no second holding mechanism here on purpose; the
/// pill's held row, the Recover-text menu and Insert here / Copy / Discard all already read that one.
///
/// B3 (V4.37) — held text goes through the lander too. It used to be `spans.joinedText`, raw: no
/// field rules, no continuation, no rendering. Now a hold runs the same `UtteranceLander.land` a
/// delivery does, and only its last step differs — the text is added to the held list instead of
/// being posted.
public final class LanderLatchDelivery: LatchDelivering, @unchecked Sendable {
    private let lander: UtteranceLander
    private let focusGuard: FocusGuard
    /// Where focus is right now. Taken when a segment's speech begins and when it closes.
    public var focusSnapshot: () -> FocusSnapshot?
    public var clock: () -> Date = Date.init
    /// Every landing, so the pill's delivery row works in latch exactly as it does in hold.
    public var onLanded: ((LandingResult) -> Void)?

    public init(lander: UtteranceLander, focusGuard: FocusGuard, focusSnapshot: @escaping () -> FocusSnapshot?) {
        self.lander = lander
        self.focusGuard = focusGuard
        self.focusSnapshot = focusSnapshot
    }

    public func currentFocus() -> FocusSnapshot? { focusSnapshot() }

    public func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool {
        await deliver(spans, segment: segment, focus: focusSnapshot()) == .delivered
    }

    /// Lands through the lander with the snapshot taken at segment close as the expected focus, so
    /// the injector still refuses (and holds, formatted) if focus moves before anything is posted.
    public func deliver(_ spans: [TranscriptSpan], segment: SegmentID, focus: FocusSnapshot?) async -> LatchDeliveryResult {
        let result = await lander.land(spans, startedAt: clock(), focus: focus)
        onLanded?(result)
        // Nothing was offered to the injector: a repair, a transform, an act claim, or no words.
        guard let injection = result.injection else { return .consumed }
        switch injection {
        case .injected:
            return .delivered
        case .abortedFocusChanged:
            // `TextInjector` already put the formatted text on the held list.
            return .held(destination: result.destinationName, reason: DeliveryReason.destinationChanged)
        case .refused(let refusal):
            return refusal.holdsText
                ? .held(destination: result.destinationName, reason: refusal.rawValue)
                : .refused(refusal.rawValue)
        case .failed(let attempts):
            // Nothing posted and nothing kept yet: keep the text the lander formatted.
            let reason = attempts.isEmpty ? DeliveryReason.noDestination : DeliveryReason.everyMethodThrew
            let request = InjectionRequest(text: result.text, utteranceID: result.utteranceID.uuidString,
                                           expectedFocus: focus)
            let item = focusGuard.hold(request, reason: reason, segmentID: segment, destination: focus)
            return .held(destination: item.destinationName, reason: reason)
        }
    }

    /// Kept for callers of the synchronous surface: the formatted hold completes asynchronously,
    /// the destination name is known now.
    public func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String {
        let destination = focusSnapshot()
        Task { _ = await self.hold(spans, segment: segment, reason: reason, destination: destination) }
        return LatchFocus.name(destination)
    }

    public func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String,
                     destination: FocusSnapshot?) async -> LatchDeliveryResult {
        let keeper = HoldingInjector(focusGuard: focusGuard, reason: reason, segment: segment, destination: destination)
        let result = await lander.holdingSibling(injector: keeper).land(spans, startedAt: clock(), focus: destination)
        // A destination change is D01 on the pill, like a hold-mode abort; the paused case has its
        // own surface (`onDeliveryPaused`).
        if reason == DeliveryReason.destinationChanged { onLanded?(result) }
        if let item = keeper.held { return .held(destination: item.destinationName, reason: reason) }
        if case .refused(let refusal)? = result.injection { return .refused(refusal.rawValue) }
        return .consumed
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

/// B3 — the injector at the end of a *hold*: the lander's formatted request goes on
/// `FocusGuard`'s held list for `destination`, and nothing is posted anywhere.
final class HoldingInjector: Injector, @unchecked Sendable {
    private let focusGuard: FocusGuard
    private let reason: String
    private let segment: SegmentID
    private let destination: FocusSnapshot?
    private(set) var held: HeldText?

    init(focusGuard: FocusGuard, reason: String, segment: SegmentID, destination: FocusSnapshot?) {
        self.focusGuard = focusGuard
        self.reason = reason
        self.segment = segment
        self.destination = destination
    }

    func inject(_ request: InjectionRequest) -> InjectionOutcome {
        var kept = request
        kept.expectedFocus = destination
        held = focusGuard.hold(kept, reason: reason, segmentID: segment, destination: destination)
        return .abortedFocusChanged(expected: destination, actual: nil)
    }
}

extension UtteranceLander {
    /// B3 — this lander, ending in `injector` instead of the real one: the same pipeline, persona,
    /// context, finalizer and field rules, so held text is formatted exactly as it would have landed.
    ///
    /// Left out on purpose, because held text has not been typed anywhere: the transform (it acts on
    /// the *current* selection), repair (it edits the last landed utterance in the focused field),
    /// silent correction, zero-edit and the recent-words ring. Field context is read only while the
    /// destination app is the one focused — otherwise it would describe some other app's field, so
    /// the caret is `unknown` and the text takes the unknown-caret style (D1: nothing invented).
    func holdingSibling(injector: any Injector) -> UtteranceLander {
        let sibling = UtteranceLander(pipeline: pipeline, injector: injector, system: system, repair: nil,
                                      flags: flags, database: database)
        sibling.stylePersonaProvider = stylePersonaProvider
        sibling.clock = clock
        sibling.personaManager = personaManager
        sibling.contextAugmenter = contextAugmenter
        sibling.actClaimConsumer = actClaimConsumer
        sibling.textFinalizer = textFinalizer
        sibling.formattingPreferences = formattingPreferences
        sibling.logsText = logsText
        if let fieldContext = fieldContextProvider {
            let system = self.system
            sibling.fieldContextProvider = { bundleID in
                guard let bundleID, system.frontmostApp()?.bundleID == bundleID else { return nil }
                return fieldContext(bundleID)
            }
        }
        return sibling
    }
}
