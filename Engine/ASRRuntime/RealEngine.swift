import Combine
import Foundation
import Shared

/// Resolves which recognizers an utterance uses. Decoupled so tests inject mocks and so the
/// choice can change between utterances as background downloads land.
public protocol RecognizerProvider: Sendable {
    func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?)
    /// Changes whenever a *different* set of models is on disk, so a cached resolve can be spotted
    /// as stale. Providers with a fixed answer keep the default and are never re-resolved.
    func revision() async -> Int
}

public extension RecognizerProvider {
    func revision() async -> Int { 0 }
}

public struct StaticRecognizerProvider: RecognizerProvider {
    public let final: FinalRecognizer
    public let preview: PreviewRecognizer?
    public init(final: FinalRecognizer, preview: PreviewRecognizer? = nil) { self.final = final; self.preview = preview }
    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) { (final, preview) }
}

public struct ModelManagerRecognizerProvider: RecognizerProvider {
    public let manager: ModelManager
    /// Which preview candidate to build (R1.5). Resolved from the `previewBackend` flag when a flag
    /// service is passed; otherwise the measured default.
    public let previewBackend: PreviewBackend

    public init(manager: ModelManager, previewBackend: PreviewBackend = .measuredDefault) {
        self.manager = manager
        self.previewBackend = previewBackend
    }

    public init(manager: ModelManager, flags: FeatureFlagService) {
        self.init(manager: manager, previewBackend: PreviewBackend.resolve(flags))
    }

    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        return (final, await RecognizerFactory.makePreview(manager: manager, final: final, backend: previewBackend))
    }

    /// A bitmask of which models are on disk. A download that lands mid-session flips a bit, which
    /// is what tells `RealEngine` to throw away a recognizer it resolved before the download —
    /// otherwise the Apple Speech fallback that was chosen at first launch stays in place until the
    /// app is relaunched, and the 1.2 GB the user just waited for does nothing.
    public func revision() async -> Int {
        var mask = 0
        for (bit, id) in ModelID.allCases.enumerated() where await manager.isPresent(id) {
            mask |= 1 << bit
        }
        return mask
    }
}

/// Per-utterance sample store + serialised preview feeding.
actor UtteranceBuffer {
    private(set) var samples: [Float] = []
    private var previewTask: Task<Void, Never>?
    private var lastText = ""
    /// R2.2 — first sample of the segment currently taking audio. Everything before it belongs to
    /// a segment that has already been closed and handed to the final pass.
    private var segmentStart = 0
    /// R2.2 ring bound, in samples. The oldest audio is dropped past this so a wedged session
    /// cannot grow without limit. Set from `SegmentTracker.Bounds.maxBufferedSeconds`, which is
    /// generous on purpose (`Endpointer.maxUtterance` is 120 s) — it is a backstop, not a trimmer.
    private(set) var capacity = 180 * 16_000
    /// How much the bound has thrown away this session. Diagnostics and tests only.
    private(set) var droppedSamples = 0

    func setCapacity(samples count: Int) { capacity = max(1, count); trim() }

    func append(_ block: [Float]) { samples.append(contentsOf: block); trim() }
    func reset() {
        samples.removeAll(); lastText = ""; previewTask?.cancel(); previewTask = nil
        segmentStart = 0; droppedSamples = 0
    }

    private func trim() {
        let over = samples.count - capacity
        guard over > 0 else { return }
        samples.removeFirst(over)
        segmentStart = max(0, segmentStart - over)
        droppedSamples += over
    }

    /// Closes the tracker's open segment and hands back that segment's audio.
    ///
    /// The two happen together, inside this actor, on purpose: the segment identity and the
    /// samples it names must be taken atomically. Two endpoint closures racing (a plausible latch
    /// session) would otherwise be able to give segment *n*'s ID segment *n+1*'s audio.
    func closeSegment(tracker: SegmentTracker, openNext: Bool) -> ClosedSegmentAudio? {
        guard let closure = tracker.closeOpenSegment(openNext: openNext) else { return nil }
        let start = min(max(segmentStart, 0), samples.count)
        let slice = Array(samples[start...])
        // V4.21 — where this audio sits on the capture stream's clock, which is the clock the VAD
        // reports in. Absolute, so a ring-bound trim cannot shift one onto the other.
        let window = (droppedSamples + start)..<(droppedSamples + samples.count)
        segmentStart = samples.count
        return ClosedSegmentAudio(closed: closure.closed, opened: closure.opened, samples: slice, window: window)
    }

    /// Every sample of the session on the stream's clock (see `closeSegment`).
    var wholeWindow: Range<Int> { droppedSamples..<(droppedSamples + samples.count) }

    /// Samples accumulated for the segment now taking audio.
    var openSegmentSampleCount: Int { max(0, samples.count - segmentStart) }

    /// Runs preview on `block` after any in-flight preview finishes; calls `onText` only on change.
    func schedulePreview(_ block: [Float], using preview: PreviewRecognizer,
                         onEndOfUtterance: (@Sendable () -> Void)? = nil,
                         onText: @escaping @Sendable (String) -> Void) {
        let previous = previewTask
        previewTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            guard let text = try? await preview.feed(block) else { return }
            if await self.updateText(text) { onText(text) }
            // RC5 — a sentence end the recognizer confirmed on this block.
            if let onEndOfUtterance, let eou = preview as? EndOfUtteranceReporting, await eou.takeEndOfUtterance() {
                onEndOfUtterance()
            }
        }
    }

    private func updateText(_ text: String) -> Bool {
        guard text != lastText else { return false }
        lastText = text
        return true
    }

    func drain() async { await previewTask?.value }
}

/// One closed segment's audio, its identity, and where it sits on the capture stream's clock.
struct ClosedSegmentAudio: Sendable {
    let closed: SegmentID
    let opened: SegmentID?
    let samples: [Float]
    /// Absolute sample positions since capture opened (16 kHz): the VAD's time base × 16 000.
    let window: Range<Int>
}

/// Why the last `stop()` returned what it did (V4.21, V4.22).
///
/// `stop()` returning `[]` used to mean one thing to the caller — "nothing to land" — whether the
/// user tapped the key, stayed silent, or the decoder invented "Thank you." into room tone. The
/// coordinator needs to tell those apart to say the right thing: a silent hold is recovery **A06**,
/// "No speech detected — Try again", shown as a quiet return that fades after 1200 ms.
public enum EngineStopReason: Equatable, Sendable {
    /// The final pass ran and its text stands.
    case decoded
    /// Less audio than the recognizer's floor (`minimumUtteranceSeconds`); nothing was decoded.
    case tooShort
    /// The VAD heard less than `minimumSpeechSeconds` of speech; nothing was decoded (V4.21).
    case noSpeech
    /// The final pass ran and the hallucination guard dropped its text (V4.22).
    case hallucination(HallucinationGuard.Reason)

    /// The recovery-catalogue row the coordinator shows for this outcome, or nil when there is
    /// nothing to say. A dropped hallucination reads to the user exactly like silence: the text
    /// was not theirs, so "No speech detected" is the true sentence.
    public var recoveryID: String? {
        switch self {
        case .noSpeech, .hallucination: return "A06"
        case .decoded, .tooShort: return nil
        }
    }

    /// A06 is a quiet return: no action required, the notice fades by itself.
    public var isQuietReturn: Bool { recoveryID != nil }

    /// How long a quiet return stays before it fades (design A06).
    public static let quietReturnFade: TimeInterval = 1.2
}

/// Engines that can say why their last `stop()` came back empty. Asked through the protocol, not by
/// class: the coordinator holds a `SwappableEngine`, so it asks `current`.
public protocol EngineStopReporting: AnyObject {
    /// Reason for the most recent `stop()`; nil before the first one of a session completes.
    var lastStopReason: EngineStopReason? { get }
}

/// Engines that publish captured input level continuously, not just while the state machine happens
/// to sit in `.listening`. Consumers (the pill waveform) bind this instead of reading levels out of
/// `EngineState`, which stops carrying them the moment a preview arrives.
public protocol AudioLevelPublishing: AnyObject {
    /// Normalised 0…1 input level, ≈10 per second while capturing.
    var audioLevels: AnyPublisher<Float, Never> { get }
}

/// The real `EngineProtocol` implementation (P1.3 T4): audio → streaming preview (EOU) into the
/// pill, and on release a final TDT pass whose spans replace the preview (no dual-path yet — Bet 4
/// is Phase 1.5).
public final class RealEngine: EngineProtocol, @unchecked Sendable {
    private let audio: AudioSource
    private let provider: RecognizerProvider
    private let broadcaster = EngineEventBroadcaster()
    private let stateSubject = CurrentValueSubject<EngineState, Never>(.idle)
    private let buffer = UtteranceBuffer()
    private let lock = NSLock()
    private var recognizers: (final: FinalRecognizer, preview: PreviewRecognizer?)?
    /// `provider.revision()` at the time `recognizers` was resolved; a change means a better model
    /// landed on disk since and the cache has to go.
    private var recognizerRevision = 0
    private var listening = false
    private var lastLevelEmit = Date.distantPast
    private let levelSubject = PassthroughSubject<Float, Never>()
    /// Seconds per preview block handed to the preview recognizer.
    public var previewBlock: TimeInterval = 0.16
    /// Shortest utterance the final pass is given. Matches FluidAudio's own floor
    /// (`ASRConstants.minimumRequiredSamples` = 4800 samples = 300 ms of 16 kHz audio); below it the
    /// decoder can only throw, so `stop()` returns no spans instead of surfacing that throw.
    public var minimumUtteranceSeconds: TimeInterval = 0.3
    private var previewPending: [Float] = []
    static let sampleRate: Double = 16_000

    // MARK: R2.2 — segments

    /// Segment identity, ordering and bounds for this engine (V3 §4.5).
    public let segments: SegmentTracker
    private let segmentBroadcaster = SegmentEventBroadcaster()
    /// Per-segment work still running, so `stop()` can wait for earlier segments to land instead
    /// of ending the session out from under them.
    private var closeTasks: [SegmentID: Task<Void, Never>] = [:]
    /// Closes that have been admitted but have not yet registered in `closeTasks`. Counted so
    /// `stop()` cannot slip into that window and end the session out from under one.
    private var closesStarting = 0
    /// How each closed segment was closed, so a segment released *behind* a slow predecessor is
    /// still reported with its own reason and stability rather than its successor's.
    private var closureFacts: [SegmentID: (stability: Stability, reason: SegmentCloseReason)] = [:]
    /// Optional second pass. `nil` today — R5.2 wires `Qwen3RefinementSession` in behind its flag.
    /// When set, a segment closed mid-session is refined off the critical path, bounded by
    /// `SegmentTracker.Bounds.maxPendingSegments`; past that bound the pass-1 text commits instead
    /// of queueing more work behind it (V3 §5.3).
    public var refiner: RefinementSession?
    /// Hard deadline for one segment's refinement. On timeout pass-1 is kept.
    public var refinementDeadline: Duration = .milliseconds(1_200)
    /// Context text handed to the refiner. Never logged and never persisted here.
    public var refinementContext = ""

    // MARK: V4.21 / V4.22 — speech guards

    /// Where the engine learns what the capture VAD heard. Chosen at construction by
    /// `discoverVADFeed(in:)`; set `vadFeed` to override.
    public enum VADFeed: Sendable {
        /// No VAD. The engine cannot tell silence from speech and decodes by duration alone, as
        /// it did before V4.21. Lab replays and bare test sources run like this.
        case none
        /// The caller forwards the capture pipeline's VAD events to `noteVAD(_:)` (for example from
        /// `PipelineAudioSource.onVAD`). The no-speech gate is armed for every session.
        case forwarded
        /// The engine subscribes to this pipeline's own event stream for each session. It does not
        /// take the `onVAD` slot, so the latch runtime can keep that. The gate arms when the
        /// session's `.started` arrives; if it never does (a broken feed), the gate stays open
        /// rather than discarding every dictation as silence.
        case pipeline(AudioPipeline)
    }

    /// Discovered at construction (the pipeline behind `audio`, when there is one); set it to wire
    /// the engine differently. Read at each `start()`, so change it between sessions, not during one.
    public var vadFeed: VADFeed {
        get { lock.withLock { feed } }
        set { lock.withLock { feed = newValue } }
    }

    /// V4.21 — the VAD must have heard at least this much speech in a segment before the final
    /// pass is run on it. The same number as the recognizer's audio floor, on purpose: 300 ms of
    /// room tone is not an utterance, and neither is 300 ms of audio.
    public var minimumSpeechSeconds: TimeInterval = 0.3

    /// Counters and recent records of what the speech guards dropped.
    public let diagnostics = EngineDiagnostics()

    private var feed: VADFeed = .none
    private var ledger = SpeechLedger()
    /// Serializes `release(_:…)`: commit + `.closed` broadcast as one step, so events keep spoken order.
    private let releaseLock = NSLock()
    /// Events are accepted from `start()` until the session's last segment is decided.
    private var ledgerOpen = false
    /// `.pipeline` feed only: the subscription has seen this session's `.started`.
    private var feedLive = false
    private var feedTask: Task<Void, Never>?
    private var stopReason: EngineStopReason?
    private var finalPassTiming: FinalPassTiming?
    /// Longest `stop()` waits for the VAD subscription to deliver the capture's last events.
    static let vadSettleTimeout: UInt64 = 300_000_000

    public init(audio: AudioSource, provider: RecognizerProvider, segmentBounds: SegmentTracker.Bounds = .init()) {
        self.audio = audio
        self.provider = provider
        self.segments = SegmentTracker(bounds: segmentBounds)
        self.feed = Self.discoverVADFeed(in: audio)
    }

    /// The VAD feed an engine starts with: the capture pipeline behind `audio`, if it has one.
    ///
    /// The app's bridge (`PipelineAudioSource`, App module) keeps its `AudioPipeline` in a stored
    /// property. This module cannot name that type, so the pipeline is found by reflecting over the
    /// source's stored properties — once, here, before any capture thread exists. That is what arms
    /// the no-speech gate for live dictation without the app having to remember a wiring line.
    /// A source with no pipeline (Lab replays, `SampleAudioSource`, test doubles) gets `.none` and
    /// is decoded by duration alone, exactly as before V4.21.
    static func discoverVADFeed(in audio: AudioSource) -> VADFeed {
        var mirror: Mirror? = Mirror(reflecting: audio)
        while let current = mirror {
            for child in current.children {
                if let pipeline = child.value as? AudioPipeline { return .pipeline(pipeline) }
            }
            mirror = current.superclassMirror
        }
        return .none
    }

    public convenience init(audio: AudioSource, manager: ModelManager) {
        self.init(audio: audio, provider: ModelManagerRecognizerProvider(manager: manager))
    }

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }
    /// Input level for the whole utterance — `.listening` *and* `.previewing`.
    public var audioLevels: AnyPublisher<Float, Never> { levelSubject.eraseToAnyPublisher() }
    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    /// R2.2 — the segment stream, alongside `events()`, which is unchanged.
    ///
    /// `EngineEvent` lives in `Shared/` and is the frozen *utterance* contract: one `.final` per
    /// `stop()`, with no room for a `SegmentID`, and `Shared/` is not this item's to change. A
    /// dictation can close several segments (key release in hold, endpoints in latch), so
    /// segment-aware consumers — the ordered commit queue, the pill — subscribe here instead.
    ///
    /// Each subscriber gets every event emitted after subscribing. Both streams are driven from
    /// the same code path, so a consumer may use either or both.
    public func segmentEvents() -> AsyncStream<SegmentEvent> { segmentBroadcaster.subscribe() }

    private func setState(_ s: EngineState) {
        stateSubject.send(s)
        broadcaster.send(.state(s))
    }

    public func prewarm() async throws {
        // Re-resolving on a revision change is what makes "pick a model, wait, dictate" work without
        // a relaunch. Before this the pair resolved on the very first utterance was kept for the
        // whole process, so a model that finished downloading afterwards was never used — flatly
        // contradicting this file's own header, which promises the choice can change per utterance.
        let revision = await provider.revision()
        let have = lock.withLock { recognizers != nil && recognizerRevision == revision }
        if !have {
            setState(.prewarming)
            do {
                let r = try await provider.resolve()
                lock.withLock { recognizers = r; recognizerRevision = revision }
            } catch {
                setState(.error(EngineMessage.describe(error))); throw error
            }
        }
        try audio.prewarm()
        if case .prewarming = state { setState(.idle) }
    }

    /// Loads the model into memory *without* touching `EngineState`.
    ///
    /// `prewarm()` publishes `.prewarming`, which the pill draws as "Warming up…" — fine on a hotkey
    /// press, wrong at launch. This is the eager load the app runs as soon as a model is on disk, so
    /// the user's first press finds the recognizers already resolved instead of paying a cold CoreML
    /// compile in the middle of their sentence. Failures are logged, never surfaced: nobody asked.
    @discardableResult
    public func preloadModel() async -> Bool {
        let revision = await provider.revision()
        if lock.withLock({ recognizers != nil && recognizerRevision == revision }) { return true }
        do {
            let t0 = Date()
            let r = try await provider.resolve()
            lock.withLock { recognizers = r; recognizerRevision = revision }
            Log.engine.info("model preloaded in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms — first dictation will not wait")
            return true
        } catch {
            Log.engine.warning("model preload failed (will retry on first use): \(error)")
            return false
        }
    }

    /// Are the recognizers already in memory? `false` means the next `start()` is a cold one.
    public var isModelLoaded: Bool { lock.withLock { recognizers != nil } }

    public func start(prewarm: Bool) async throws {
        let already = lock.withLock { listening }
        if already { throw EngineError.alreadyListening }
        // Is the model already in memory? If not, the load below can take tens of seconds on a cold
        // CoreML compile — and until 1.7.4 that whole wait happened *before* `audio.start()`, so the
        // pill sat on "Warming up…" with the microphone shut and the opening words of the utterance
        // were simply gone. Capture opens first now and the samples accumulate in `buffer` while the
        // recognizers resolve; preview text starts flowing the moment they land.
        let revision = prewarm ? await provider.revision() : 0
        let ready = lock.withLock { recognizers != nil && (!prewarm || recognizerRevision == revision) }
        guard prewarm || ready else { throw EngineError.modelUnavailable("prewarm() not called") }
        await buffer.reset()
        await buffer.setCapacity(samples: Int(segments.bounds.maxBufferedSeconds * Self.sampleRate))
        if ready { await lock.withLock { recognizers }?.preview?.reset() }
        lock.withLock {
            listening = true
            previewPending.removeAll()
            closureFacts.removeAll()
            closesStarting = 0
            ledger.reset()
            ledgerOpen = true
            feedLive = false
            stopReason = nil
            finalPassTiming = nil   // N6: never attribute the previous turn's final pass to this one
        }
        // V4.21 — subscribe before capture opens, so the session's first VAD edge is not missed.
        startVADFeed()
        // R2.2 — a dictation session is a fresh UUID; segment 0 starts taking audio now.
        segmentBroadcaster.send(.opened(segments.beginSession()))
        // "Warming up…" is only honest while it is *bounded and recording*. The state stays
        // `.prewarming` until the model is in memory, but capture is already open underneath it.
        setState(ready ? .listening(level: 0) : .prewarming)
        audio.sink = { [weak self] ptr in self?.ingest(Array(ptr)) }
        // `listening` is set *before* capture opens, because the sink can fire from inside
        // `audio.start()`. That makes the throw below the one place where the flag can outlive the
        // session it describes: until 1.7.3 a failed `audio.start()` (denied microphone, HAL start
        // timeout, format mismatch) left `listening == true` with no capture behind it, so every
        // later `start()` threw `alreadyListening` — "VoicePlus is already recording." — for the
        // rest of the process. Roll the whole session back here rather than relying on some caller
        // to notice and call `cancel()`; not one of the five callers did.
        do {
            try audio.start()
        } catch {
            audio.sink = nil
            lock.withLock { listening = false; previewPending.removeAll() }
            stopVADFeed()
            await buffer.reset()
            abandonSegmentSession()
            setState(.error(EngineMessage.describe(error)))
            throw error
        }
        if !ready {
            // Cold start: the model loads *while* the user is already being recorded.
            do {
                let t0 = Date()
                let pair = try await provider.resolve()
                await pair.preview?.reset()
                lock.withLock { recognizers = pair; recognizerRevision = revision }
                Log.engine.info("recognizers resolved in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms (capture was already open)")
                flushPendingPreview()
            } catch {
                await rollbackSession()
                setState(.error(EngineMessage.describe(error)))
                throw error
            }
        }
        setState(.listening(level: 0))
    }

    /// Capture is open but the session cannot continue: close it and forget the audio.
    private func rollbackSession() async {
        audio.stop()
        audio.sink = nil
        lock.withLock { listening = false; previewPending.removeAll() }
        stopVADFeed()
        await buffer.reset()
        abandonSegmentSession()
    }

    // MARK: V4.21 — VAD feed and the no-speech gate

    /// A speech edge from the capture VAD, in stream seconds since capture opened. Thread-safe;
    /// events outside a session are ignored. Feeding the same VAD twice counts it once.
    public func noteVAD(_ event: VADEvent) {
        lock.withLock {
            guard ledgerOpen else { return }
            ledger.note(event)
        }
    }

    /// Whether the no-speech gate applies to the session in progress (see `VADFeed`).
    public var isSpeechGateArmed: Bool { lock.withLock { gateArmedLocked } }

    /// Caller holds `lock`.
    private var gateArmedLocked: Bool {
        switch feed {
        case .none: return false
        case .forwarded: return true
        case .pipeline: return feedLive
        }
    }

    /// VAD speech inside `window` (absolute samples), or nil when the gate is not armed — "nil"
    /// meaning *unknown*, which the gate and the guard both treat as "do not drop on speech".
    private func speechSeconds(in window: Range<Int>) -> Double? {
        lock.withLock {
            guard gateArmedLocked else { return nil }
            return ledger.speechSeconds(from: Double(window.lowerBound) / Self.sampleRate,
                                        to: Double(window.upperBound) / Self.sampleRate)
        }
    }

    private func startVADFeed() {
        let pipeline: AudioPipeline? = lock.withLock {
            if case .pipeline(let p) = feed { return p }
            return nil
        }
        guard let pipeline else { return }
        // Subscribed here, synchronously, so everything the pipeline broadcasts from now on is
        // buffered for us. A `.stopped` from a previous owner being torn down (the onboarding
        // meter) arrives *before* this session's `.started` and is ignored, as are its VAD edges.
        let events = pipeline.events()
        let task = Task.detached(priority: .high) { [weak self] in
            var live = false
            for await event in events {
                guard let self else { return }
                switch event {
                case .started:
                    live = true
                    self.lock.withLock { self.feedLive = true }
                case .vad(let edge) where live:
                    self.noteVAD(edge)
                case .stopped where live:
                    return
                default:
                    break
                }
            }
        }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            let old = feedTask
            feedTask = task
            return old
        }
        previous?.cancel()
    }

    private func stopVADFeed() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = feedTask
            feedTask = nil
            ledgerOpen = false
            return t
        }
        task?.cancel()
    }

    /// Waits (bounded) until the VAD subscription has seen capture stop, so the edges of the last
    /// few hundred milliseconds — the VAD's tail flush runs inside the pipeline's `stop()` — are
    /// counted before the gate decides. The `onVAD` forward has no such guarantee; there an open
    /// run simply counts to the end of the audio.
    private func settleVADFeed() async {
        guard let task = lock.withLock({ feedTask }) else { return }
        let timeout = Self.vadSettleTimeout
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await task.value; return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeout)
                // Cancelling the feed is what lets the first child return if it has not already.
                task.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished { Log.engine.notice("VAD feed did not report capture stop in time; gating on the edges already seen") }
        lock.withLock { if feedTask == task { feedTask = nil } }
    }

    /// Records a guard drop and logs it with the utterance stamp. Never logs the text.
    private func recordDrop(_ kind: EngineDiagnostics.DropKind, segment: SegmentID?, speech: Double?,
                            audioSeconds: Double, tokens: Int) {
        let stamp = EngineDiagnostics.stamp(Date())
        diagnostics.record(.init(stamp: stamp, segment: segment, kind: kind, speechSeconds: speech,
                                 audioSeconds: audioSeconds, tokenCount: tokens))
        let heard = speech.map { String(format: "%.2f", $0) } ?? "unknown"
        let what: String
        switch kind {
        case .noSpeech: what = "no-speech gate skipped the final pass"
        case .hallucination(let reason): what = "hallucination guard dropped \(tokens) token(s) (\(reason.rawValue))"
        }
        Log.engine.notice("\(what): utterance \(stamp), segment \(segment?.description ?? "-"), speech \(heard) s of \(String(format: "%.2f", audioSeconds)) s audio")
    }

    /// R2.2 — tears the segment session down without committing anything. The open segment is
    /// announced as `.cancelled` (empty spans) so a consumer holding provisional text for it
    /// knows to drop it rather than wait forever for a commit that is not coming.
    private func abandonSegmentSession() {
        if let open = segments.openSegment {
            segmentBroadcaster.send(.closed(segment: open, spans: [], stability: .final, reason: .cancelled))
        }
        segments.endSession()
        lock.withLock { closureFacts.removeAll() }
    }

    /// Hands the preview recognizer everything captured during a cold start, so the words spoken
    /// while the model was loading appear in the pill instead of being dropped.
    private func flushPendingPreview() {
        lock.lock()
        let preview = recognizers?.preview
        let pending = previewPending
        if preview != nil, !pending.isEmpty { previewPending.removeAll() }
        lock.unlock()
        guard let preview, !pending.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.buffer.schedulePreview(pending, using: preview) { [weak self] text in self?.emitPartial(text) }
        }
    }

    private func ingest(_ block: [Float]) {
        lock.lock()
        guard listening else { lock.unlock(); return }
        let preview = recognizers?.preview
        previewPending.append(contentsOf: block)
        // R2.2 ring bound. Nothing drains this while the model is still loading, so a cold start
        // that never finishes (or a preview recognizer that never arrives) would otherwise grow it
        // for the whole session. Drop the oldest audio past the bound rather than the newest: the
        // words the user is speaking *now* are the ones the pill has to show.
        let previewCapacity = Int(segments.bounds.maxBufferedSeconds * Self.sampleRate)
        if previewPending.count > previewCapacity {
            previewPending.removeFirst(previewPending.count - previewCapacity)
        }
        var toPreview: [Float]?
        // Only drain the pending buffer when there is something to drain it *into*. During a cold
        // start the preview recognizer is still loading; those samples are kept and flushed by
        // `flushPendingPreview()` rather than thrown away.
        if preview != nil, Double(previewPending.count) / 16_000 >= previewBlock {
            toPreview = previewPending; previewPending.removeAll()
        }
        let emitLevel = Date().timeIntervalSince(lastLevelEmit) > 0.1
        if emitLevel { lastLevelEmit = Date() }
        lock.unlock()

        Task { await buffer.append(block) }
        if emitLevel {
            let rms = sqrt(block.reduce(0) { $0 + $1 * $1 } / Float(max(block.count, 1)))
            let level = min(1, rms * 4)
            // Levels flow for the whole utterance. `EngineState` can only carry a level in
            // `.listening`, and the first preview moves the state to `.previewing` — publishing the
            // level separately is what keeps the pill's waveform alive past that point (a state
            // update here would instead throw the preview text away every 100 ms).
            levelSubject.send(level)
            if case .listening = state { setState(.listening(level: level)) }
        }
        if let toPreview, let preview {
            Task { [weak self] in
                guard let self else { return }
                await self.buffer.schedulePreview(toPreview, using: preview,
                                                  onEndOfUtterance: { [weak self] in self?.emitEndOfUtterance() }) { [weak self] text in
                    self?.emitPartial(text)
                }
            }
        }
    }

    /// RC5 — the preview recognizer confirmed an end of utterance in the open segment.
    private func emitEndOfUtterance() {
        lock.lock(); let live = listening; lock.unlock()
        guard live, let open = segments.openSegment else { return }
        segmentBroadcaster.send(.endOfUtterance(segment: open))
    }

    private func emitPartial(_ text: String) {
        lock.lock(); let live = listening; lock.unlock()
        guard live, !text.isEmpty else { return }
        // Preview has no per-word confidence upstream; mark it neutral (0.5) and time-bound it to
        // the audio captured so far. Final spans replace these at landing.
        //
        // R2.1/R2.2: preview text is `.provisional`. The pill owns it and may rewrite it freely;
        // nothing downstream may treat it as deliverable. Only a `SegmentEvent.closed` commits.
        let span = TranscriptSpan(text: text, confidence: 0.5, audioRange: 0...0, provenance: [.asr], stability: .provisional)
        broadcaster.send(.partial([span]))
        if let open = segments.openSegment {
            segmentBroadcaster.send(.preview(segment: open, spans: [span]))
        }
        setState(.previewing(text: text))
    }

    public func stop() async throws -> [TranscriptSpan] {
        let recs: (final: FinalRecognizer, preview: PreviewRecognizer?)? = try lock.withLock {
            guard listening else { throw EngineError.notListening }
            listening = false
            return recognizers
        }
        audio.stop()
        audio.sink = nil
        setState(.finalizing)
        await buffer.drain()
        // V4.21 — the VAD's tail flush runs inside the pipeline's stop; let its edges land before
        // the gate below reads them.
        await settleVADFeed()
        // R2.2 — earlier segments closed by an endpoint may still be in the final or refinement
        // pass. Wait for them before ending the session: `SegmentTracker` refuses results for a
        // session that is over, so tearing it down here would throw their text away. No new close
        // can start behind this, because `listening` is already false.
        await drainClosedSegments()
        // Key release closes the session's last segment, and is its endpoint (V3 §4.2). The split
        // is taken together with the tracker so the ID always names the audio it was given.
        let closure = await buffer.closeSegment(tracker: segments, openNext: false)
        // Without a mid-session closure `segmentStart` is still 0, so this is the whole utterance —
        // byte for byte what the final pass saw before R2.2.
        let samples: [Float]
        let window: Range<Int>
        if let closure {
            samples = closure.samples; window = closure.window
        } else {
            samples = await buffer.samples; window = await buffer.wholeWindow
        }
        // nil = no VAD feed for this session: nothing is known about speech, so nothing is gated.
        let speech = speechSeconds(in: window)
        stopVADFeed()
        guard let final = recs?.final else {
            segments.endSession()
            setState(.error(EngineError.modelUnavailable("final").readable))
            throw EngineError.modelUnavailable("final")
        }
        let seconds = Double(samples.count) / Self.sampleRate
        // V4.21 — a hold the VAD heard no speech in is never decoded. Room tone handed to Parakeet
        // comes back as "you" or "Thank you.", and the only precondition used to be duration.
        if let speech, speech < minimumSpeechSeconds {
            recordDrop(.noSpeech, segment: closure?.closed, speech: speech, audioSeconds: seconds, tokens: 0)
            return endSessionWithoutText(closure?.closed, reason: .noSpeech)
        }
        // Too little audio to transcribe is a normal human thing to do (a stray tap of the key, a
        // start/stop that raced the HAL) — not an error worth a red pill. FluidAudio throws
        // `ASRError.invalidAudioData` below 300 ms, and until 1.6.6 that reached the user as the raw
        // token "invalidAudioData". Never call the recognizer where the answer is already known.
        if seconds < minimumUtteranceSeconds {
            Log.engine.notice("final pass skipped: \(String(format: "%.2f", seconds)) s captured, minimum is \(String(format: "%.2f", self.minimumUtteranceSeconds)) s")
            return endSessionWithoutText(closure?.closed, reason: .tooShort)
        }
        do {
            let t0 = Date()
            let spans = try await final.recognize(samples)
            let timing = (final as? FinalPassTimingReporting)?.lastFinalPassTiming
            lock.withLock { finalPassTiming = timing }
            Log.engine.info("final pass \(final.name): \(spans.count) spans, \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms for \(String(format: "%.1f", seconds)) s audio")
            // `.final` at the span level too: this segment ended the session, so nothing further
            // will arrive for it. The recognizers already hand back spans at that default, so this
            // is a no-op on the hold path and exists for symmetry with the endpoint path.
            let mine = stamped(spans, .final)
            // V4.22 — the final pass's text must have been said. A drop lands nothing.
            if case .drop(let why) = HallucinationGuard.verdict(for: mine, speechSeconds: speech, audioSeconds: seconds) {
                recordDrop(.hallucination(why), segment: closure?.closed, speech: speech, audioSeconds: seconds,
                           tokens: HallucinationGuard.tokens(of: mine.renderedText).count)
                return endSessionWithoutText(closure?.closed, reason: .hallucination(why))
            }
            lock.withLock { stopReason = .decoded }
            // The legacy utterance stream is unchanged: `.final` carries *this* segment's spans,
            // exactly as it did before R2.2, regardless of where the ordered segment queue is.
            broadcaster.send(.final(mine))
            release(closure?.closed, spans: mine, stability: .final, reason: .keyRelease)
            setState(.landed)
            setState(.idle)
            segments.endSession()
            return mine
        } catch {
            segments.endSession()
            setState(.error(EngineMessage.describe(error)))
            throw error
        }
    }

    /// Ends a session whose last segment produces no text: an empty commit (so the ordered queue
    /// moves), an empty `.final`, and the reason for whoever asks `lastStopReason`.
    private func endSessionWithoutText(_ id: SegmentID?, reason: EngineStopReason) -> [TranscriptSpan] {
        lock.withLock { stopReason = reason }
        release(id, spans: [], stability: .final, reason: .keyRelease)
        broadcaster.send(.final([]))
        setState(.landed)
        setState(.idle)
        segments.endSession()
        return []
    }

    // MARK: R2.2 — endpoint closure (latch)

    /// An endpoint closed a segment while capture continues (V3 §4.3, latch).
    ///
    /// Closes the open segment, opens the next one immediately, and takes the closed segment's
    /// audio through the final pass — and the refiner, when one is set and the backlog has room.
    /// The microphone is never touched: whatever the user says during this call belongs to the
    /// newly opened segment, so a latched session does not lose the first words after an endpoint.
    ///
    /// Committed text is released in `SegmentID` order. A segment whose passes finish before its
    /// predecessor's waits rather than jumping the queue, so `.closed` events always arrive in
    /// spoken order — which is what the ordered commit queue downstream relies on.
    ///
    /// Returns the segment that was closed, or `nil` when nothing was open (not listening).
    @discardableResult
    public func closeSegmentAtEndpoint() async -> SegmentID? {
        // Admitted under the lock, before the first `await`: a close that has claimed a segment but
        // not yet registered its task is still a close `stop()` has to wait for, or the segment's
        // text is committed into a session that has already been torn down and is simply lost.
        let admitted = lock.withLock { () -> Bool in
            guard listening else { return false }
            closesStarting += 1
            return true
        }
        guard admitted else { return nil }
        await buffer.drain()
        guard let closure = await buffer.closeSegment(tracker: segments, openNext: true) else {
            lock.withLock { closesStarting -= 1 }
            return nil
        }
        // V4.21 — this segment's speech, measured now: the endpoint fired after trailing silence,
        // so every VAD edge of the segment has already arrived.
        let speech = speechSeconds(in: closure.window)
        // Say the next segment is live *before* the slow part: capture is already filling it.
        if let opened = closure.opened { segmentBroadcaster.send(.opened(opened)) }
        // Preview state restarts per segment. A streaming recognizer that carried its state across
        // a closed segment would keep re-emitting words that have already been committed.
        if let preview = lock.withLock({ recognizers?.preview }) { await preview.reset() }

        let task = Task<Void, Never> { [weak self] in
            await self?.finishSegment(closure, speech: speech, reason: .endpoint, stability: .committed)
        }
        lock.withLock { closeTasks[closure.closed] = task; closesStarting -= 1 }
        await task.value
        return closure.closed
    }

    /// Runs the passes for one closed segment and commits it.
    private func finishSegment(
        _ closure: ClosedSegmentAudio,
        speech: Double?,
        reason: SegmentCloseReason,
        stability: Stability
    ) async {
        let id = closure.closed
        defer { lock.withLock { closeTasks[id] = nil } }

        // Identity gate before any work: a segment from another session, or one already committed,
        // must not spend a pass, let alone reach a destination (V3 §4.5).
        if let rejection = segments.rejection(for: id) {
            segmentBroadcaster.send(.rejected(segment: id, reason: rejection))
            return
        }
        let seconds = Double(closure.samples.count) / Self.sampleRate
        // V4.21 — a segment the VAD heard no speech in closes empty without a pass, like a sliver.
        if let speech, speech < minimumSpeechSeconds {
            recordDrop(.noSpeech, segment: id, speech: speech, audioSeconds: seconds, tokens: 0)
            release(id, spans: [], stability: stability, reason: reason)
            return
        }
        guard seconds >= minimumUtteranceSeconds, let final = lock.withLock({ recognizers?.final }) else {
            // An endpoint on a sub-300 ms sliver of audio: nothing to say, but the segment still
            // closes so the queue behind it can move.
            release(id, spans: [], stability: stability, reason: reason)
            return
        }
        var spans: [TranscriptSpan]
        do {
            spans = try await final.recognize(closure.samples)
            let timing = (final as? FinalPassTimingReporting)?.lastFinalPassTiming
            lock.withLock { finalPassTiming = timing }
        } catch {
            Log.engine.warning("final pass failed for segment \(id.description): \(error)")
            release(id, spans: [], stability: stability, reason: reason)
            return
        }
        // V4.22 — judged on pass 1, whose confidences are real; refinement reports none. A
        // dropped segment is not worth a second pass either.
        if case .drop(let why) = HallucinationGuard.verdict(for: spans, speechSeconds: speech, audioSeconds: seconds) {
            recordDrop(.hallucination(why), segment: id, speech: speech, audioSeconds: seconds,
                       tokens: HallucinationGuard.tokens(of: spans.renderedText).count)
            release(id, spans: [], stability: stability, reason: reason)
            return
        }

        var closeReason = reason
        if let refiner {
            if segments.enqueuePending(id) {
                defer { segments.dropPending(id) }
                do {
                    let refined = try await refiner.refine(
                        samples: closure.samples, context: refinementContext, deadline: refinementDeadline)
                    // Empty is not an improvement. A refiner that returns nothing (or throws, or
                    // runs out its deadline) leaves pass-1 standing — it is never a regression.
                    if !refined.isEmpty { spans = refined }
                } catch {
                    Log.engine.notice("refinement declined for segment \(id.description), keeping pass-1: \(error)")
                }
            } else {
                // The bound (V3 §5.3): two segments may be in flight. Past that, this segment
                // commits its pass-1 text now instead of adding to a backlog that is already the
                // reason text is late.
                closeReason = .backlogBound
                Log.engine.notice("refinement backlog full (\(self.segments.pendingCount)) — committing pass-1 for segment \(id.description)")
            }
        }
        release(id, spans: spans, stability: stability, reason: closeReason)
    }

    /// Commits one segment and emits `.closed` for everything the commit put in order.
    ///
    /// The commit and its sends are one step under `releaseLock`: two segments whose passes finish
    /// together would otherwise commit in order and then broadcast out of order (segment 1's
    /// `.closed` before segment 0's), breaking the spoken-order promise above.
    private func release(_ id: SegmentID?, spans: [TranscriptSpan], stability: Stability, reason: SegmentCloseReason) {
        guard let id else { return }
        releaseLock.lock()
        defer { releaseLock.unlock() }
        lock.withLock { closureFacts[id] = (stability, reason) }
        switch segments.commit(id, spans: stamped(spans, stability)) {
        case .rejected(let why):
            lock.withLock { closureFacts[id] = nil }
            segmentBroadcaster.send(.rejected(segment: id, reason: why))
        case .released(let ready):
            for item in ready {
                let facts = lock.withLock { closureFacts.removeValue(forKey: item.segment) }
                segmentBroadcaster.send(.closed(
                    segment: item.segment,
                    spans: item.spans,
                    stability: facts?.stability ?? stability,
                    reason: facts?.reason ?? reason))
            }
        }
    }

    /// Waits for every segment still in a pass, including one admitted a moment ago that has not
    /// registered its task yet. Bounded: `listening` is already false by the time this is called,
    /// so no further close can be admitted and the count only falls.
    private func drainClosedSegments() async {
        for _ in 0..<1_000 {
            let (starting, tasks) = lock.withLock { (closesStarting, Array(closeTasks.values)) }
            if starting == 0, tasks.isEmpty { return }
            for task in tasks { await task.value }
            if starting > 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        Log.engine.warning("segment drain gave up with work still in flight")
    }

    /// Stamps a segment's stability onto its spans.
    ///
    /// Direct assignment rather than `stabilized(_:)`, deliberately: the recognizers hand back
    /// spans at `Stability`'s *default* of `.final`, which is a type default (chosen in R2.1 so
    /// pre-R2.1 call sites kept working), not a claim that the session is over. A segment closed
    /// mid-session is `.committed` — delivered once, never retracted, but the session continues —
    /// and `stabilized(_:)` is forward-only, so it cannot express that.
    private func stamped(_ spans: [TranscriptSpan], _ stability: Stability) -> [TranscriptSpan] {
        spans.map { span in
            guard span.stability != stability else { return span }
            var copy = span
            copy.stability = stability
            return copy
        }
    }

    public func cancel() async {
        let was = lock.withLock { let w = listening; listening = false; return w }
        if was { audio.stop(); audio.sink = nil }
        stopVADFeed()
        await drainClosedSegments()
        await buffer.reset()
        abandonSegmentSession()
        setState(.idle)
    }
}

extension RealEngine: AudioLevelPublishing {}

extension RealEngine: EngineStopReporting, FinalPassTimingReporting {
    public var lastStopReason: EngineStopReason? { lock.withLock { stopReason } }

    /// N6 — per-stage ms and pre-boost raw text of the most recent final pass (key-release or
    /// endpoint segment). Nil until one ran, or for recognisers that do not report stages.
    public var lastFinalPassTiming: FinalPassTiming? { lock.withLock { finalPassTiming } }
}

/// Engines that can say how much audio the current utterance holds.
///
/// A caller that is about to finalise (the onboarding dictation test, a hands-free endpointer) can
/// then refuse a doomed final pass and say "I didn't hear anything" in its own words, instead of
/// letting a decoder-specific error escape into the UI.
public protocol CapturedAudioReporting: AnyObject {
    /// Seconds of audio captured so far in the current utterance.
    var capturedSeconds: Double { get async }
    /// Below this, `stop()` will not run the final pass at all.
    var minimumUtteranceSeconds: TimeInterval { get }
}

extension RealEngine: CapturedAudioReporting {
    public var capturedSeconds: Double {
        get async { Double(await buffer.samples.count) / Self.sampleRate }
    }
}

extension RealEngine {
    /// Test/diagnostic hook: samples captured so far in the current utterance.
    public func bufferedSampleCount() async -> Int { await buffer.samples.count }
}
