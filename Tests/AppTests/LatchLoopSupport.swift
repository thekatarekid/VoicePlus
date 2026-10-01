import Combine
import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

// Shared by the B1–B4 latch suites: a scripted segmented engine, a delivery spy that knows where
// focus is, a hand-driven capture feed, and a rig wired exactly as `AppDelegate.wire` wires the
// production objects (dictation → session coordinator → latch runtime).

/// `EngineProtocol` + R2.2's segment surface. Each endpoint closure commits the next scripted text
/// ("segment N" once the script runs out); `stop()` ends the session with `.keyRelease`.
final class LatchLoopEngine: EngineProtocol, SegmentSessionEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let subject = CurrentValueSubject<EngineState, Never>(.idle)
    private let broadcaster = EngineEventBroadcaster()
    private let segments = SegmentEventBroadcaster()
    let sessionID = UUID()
    private var index = 0
    private var _listening = false
    private var _closures = 0
    private var _stops = 0
    private var script: [String]
    var finalText = "the last one"

    init(script: [String] = []) { self.script = script }

    var listening: Bool { lock.withLock { _listening } }
    /// Endpoint closures the engine actually performed.
    var closures: Int { lock.withLock { _closures } }
    var stops: Int { lock.withLock { _stops } }

    var state: EngineState { subject.value }
    var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
    func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }
    func segmentEvents() -> AsyncStream<SegmentEvent> { segments.subscribe() }
    func prewarm() async throws {}

    func start(prewarm: Bool) async throws {
        if lock.withLock({ _listening }) { throw EngineError.alreadyListening }
        lock.withLock { _listening = true; index = 0 }
        segments.send(.opened(SegmentID(sessionID: sessionID, index: 0)))
        subject.send(.listening(level: 0))
    }

    func stop() async throws -> [TranscriptSpan] {
        guard lock.withLock({ let was = _listening; _listening = false; _stops += 1; return was }) else {
            throw EngineError.notListening
        }
        let id = lock.withLock { SegmentID(sessionID: sessionID, index: index) }
        let spans = [Self.span(finalText, stability: .final)]
        segments.send(.closed(segment: id, spans: spans, stability: .final, reason: .keyRelease))
        subject.send(.idle)
        return spans
    }

    func cancel() async {
        lock.withLock { _listening = false }
        subject.send(.idle)
    }

    @discardableResult
    func closeSegmentAtEndpoint() async -> SegmentID? {
        let step = lock.withLock { () -> (SegmentID, SegmentID, String)? in
            guard _listening else { return nil }
            let closed = SegmentID(sessionID: sessionID, index: index)
            let text = script.isEmpty ? "segment \(index)" : script.removeFirst()
            index += 1
            _closures += 1
            return (closed, SegmentID(sessionID: sessionID, index: index), text)
        }
        guard let (closed, opened, text) = step else { return nil }
        segments.send(.closed(segment: closed, spans: [Self.span(text, stability: .committed)],
                              stability: .committed, reason: .endpoint))
        segments.send(.opened(opened))
        return closed
    }

    static func span(_ text: String, stability: Stability) -> TranscriptSpan {
        TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr], stability: stability)
    }
}

/// A latch delivery that knows where focus is (`focus`), and records what it was asked to do.
final class LatchFocusSpy: LatchDelivering, @unchecked Sendable {
    private let lock = NSLock()
    private var _focus: FocusSnapshot?
    private var _delivered: [(text: String, focus: FocusSnapshot?)] = []
    private var _held: [(text: String, reason: String, destination: FocusSnapshot?)] = []

    var focus: FocusSnapshot? {
        get { lock.withLock { _focus } }
        set { lock.withLock { _focus = newValue } }
    }
    var delivered: [(text: String, focus: FocusSnapshot?)] { lock.withLock { _delivered } }
    var held: [(text: String, reason: String, destination: FocusSnapshot?)] { lock.withLock { _held } }

    func currentFocus() -> FocusSnapshot? { focus }

    func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool {
        await deliver(spans, segment: segment, focus: focus) == .delivered
    }

    func deliver(_ spans: [TranscriptSpan], segment: SegmentID, focus: FocusSnapshot?) async -> LatchDeliveryResult {
        lock.withLock { _delivered.append((spans.renderedText, focus)) }
        return .delivered
    }

    func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String {
        lock.withLock { _held.append((spans.renderedText, reason, _focus)) }
        return LatchFocus.name(focus)
    }

    func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String,
              destination: FocusSnapshot?) async -> LatchDeliveryResult {
        lock.withLock { _held.append((spans.renderedText, reason, destination)) }
        return .held(destination: LatchFocus.name(destination), reason: reason)
    }

    func insertHeld(into target: String) -> Int { 0 }
}

/// A capture feed driven by hand: VAD edges, pipeline endpoint decisions and positions are
/// emitted by the test; the switches the runtime flips are recorded.
final class FakeLatchFeed: LatchAudioFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var _onVAD: (@Sendable (VADEvent) -> Void)?
    private var _onEndpoint: (@Sendable (Endpointer.Decision) -> Void)?
    private var _latched: [Bool] = []
    private var _endpointers: [Endpointer] = []
    private var continuation: AsyncStream<TimeInterval>.Continuation?

    var onVAD: (@Sendable (VADEvent) -> Void)? {
        get { lock.withLock { _onVAD } }
        set { lock.withLock { _onVAD = newValue } }
    }
    var onEndpoint: (@Sendable (Endpointer.Decision) -> Void)? {
        get { lock.withLock { _onEndpoint } }
        set { lock.withLock { _onEndpoint = newValue } }
    }
    /// Every `setLatched` the runtime made, in order.
    var latchedCalls: [Bool] { lock.withLock { _latched } }
    /// Every endpointer the runtime handed the pipeline, in order.
    var endpointers: [Endpointer] { lock.withLock { _endpointers } }

    func setLatched(_ on: Bool) { lock.withLock { _latched.append(on) } }
    func setLatchEndpointer(_ endpointer: Endpointer) { lock.withLock { _endpointers.append(endpointer) } }
    func latchPositions() -> AsyncStream<TimeInterval> {
        AsyncStream { c in lock.withLock { continuation = c } }
    }

    func vad(_ event: VADEvent) { onVAD?(event) }
    func endpoint(_ decision: Endpointer.Decision) { onEndpoint?(decision) }
    func position(_ p: TimeInterval) { _ = lock.withLock { continuation }?.yield(p) }
}

/// Records every request; always "posts".
final class LatchSpyInjector: Injector, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [InjectionRequest] = []
    var requests: [InjectionRequest] { lock.withLock { _requests } }
    func inject(_ request: InjectionRequest) -> InjectionOutcome {
        lock.withLock { _requests.append(request) }
        return .injected(method: .ax, verified: true)
    }
}

/// Bounded wait on the main actor, so a failure is a failed expectation and not a hung suite.
/// Yielding lets main-queue hops (the runtime's `feedQueue`) run; the short sleeps give the
/// cooperative pool (segment events, the capture forwarder) room when the whole suite runs in
/// parallel. The bound is wall-clock, not a spin count: a loaded machine is slow, not wrong.
@MainActor
func latchWait(_ what: String = "condition", timeout: TimeInterval = 30, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    var n = 0
    while !condition() {
        if Date() >= deadline { Issue.record("timed out waiting for \(what)"); return }
        n += 1
        if n % 32 == 0 { try? await Task.sleep(nanoseconds: 1_000_000) } else { await Task.yield() }
    }
}

/// A VAD with no smoothing: a 10 ms frame is speech iff its peak exceeds 0.01, and each edge is
/// reported at the first frame of the new state. Scripted speech (tone) and silence (zeros) then
/// produce VAD edges at exact, known stream times.
final class ScriptedLatchVAD: VADProtocol, @unchecked Sendable {
    let name = "scripted"
    let frameSize = 160
    private let lock = NSLock()
    private var frames = 0
    private var speaking = false

    func reset() async { lock.withLock { frames = 0; speaking = false } }

    func process(frame: [Float]) async throws -> VADStep {
        lock.withLock {
            let at = Double(frames * frameSize) / 16_000
            frames += 1
            let speech = frame.contains { abs($0) > 0.01 }
            defer { speaking = speech }
            switch (speaking, speech) {
            case (false, true): return VADStep(probability: 1, isSpeech: true, event: .speechStart(at: at))
            case (true, false): return VADStep(probability: 0, isSpeech: false, event: .speechEnd(at: at))
            default: return VADStep(probability: speech ? 1 : 0, isSpeech: speech)
            }
        }
    }
}

/// The production capture feed — a real `PipelineAudioSource` over a real `AudioPipeline` — fed by
/// hand: `speech(_:)` is a tone, `silence(_:)` is zeros. Blocks go in at a live tap's pace (each is
/// processed before the next), so the pipeline's endpointer ticks every 50 ms as it does live.
@MainActor
final class ScriptedLatchCapture {
    static let block = 800
    let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
    let audio: PipelineAudioSource
    /// Samples pushed so far; `seconds` is the stream position after the last one.
    private(set) var pushed = 0
    var seconds: TimeInterval { Double(pushed) / 16_000 }

    init(vad: any VADProtocol = ScriptedLatchVAD()) {
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: vad, options: options))
        audio.requireMicrophonePermission = false
    }

    static func speech(_ seconds: Double) -> [Float] {
        (0..<Int((seconds * 16_000).rounded())).map { 0.2 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
    }
    /// Bit-exact zero. This is what a *silenced* stream delivers (TCC, a mute switch, a detached
    /// tap), not what a live microphone delivers — `CaptureSilenceWatchdog` fires on it by design.
    /// Use it only for a pause that follows real audio in the same capture (one non-zero sample
    /// disarms the watchdog for the rest of the capture); for "the user is simply not speaking yet",
    /// use `roomTone(_:)`.
    static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int((seconds * 16_000).rounded())) }

    /// A live-but-silent microphone: the ±1 LSB dither of a real 16-bit analogue input in a quiet
    /// room. Non-zero in every sample, so the capture reads as healthy, and three orders of
    /// magnitude under `ScriptedLatchVAD`'s 0.01 speech threshold, so it is still "not speaking".
    /// This — not `silence(_:)` — is what the user who latches and then pauses is producing.
    static func roomTone(_ seconds: Double) -> [Float] {
        let lsb: Float = 1.0 / 32_768
        var state: UInt64 = 0x9E3779B97F4A7C15
        return (0..<Int((seconds * 16_000).rounded())).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (state >> 63) == 0 ? lsb : -lsb          // never zero
        }
    }

    func start() throws { try audio.start(for: .engine) }
    func stop() { audio.stop() }

    /// Pushes `samples` block by block and, after each, waits until the pipeline has processed it
    /// and `latch` has ticked with its end. VAD edges and endpoint decisions travel on a different
    /// hop (the source's forwarder) and may land a little later; wait on their effects explicitly.
    func play(_ samples: [Float], into latch: LatchRuntime) async {
        var i = 0
        while i < samples.count {
            let end = min(i + Self.block, samples.count)
            source.push(Array(samples[i..<end]))
            pushed += end - i
            i = end
            await audio.pipeline.drain()
            let t = seconds
            await latchWait("position \(t)") { latch.lastPosition >= t - 1e-9 }
        }
    }
}

/// `AppDelegate.wire`, minus the window server: dictation → session coordinator → latch runtime,
/// with the final (key-release) segment landing through a real `UtteranceLander` into a spy.
@MainActor
struct LatchLoopRig {
    let engine: LatchLoopEngine
    let dictation: DictationCoordinator
    let spy: LatchFocusSpy
    let latch: LatchRuntime
    let session: SessionCoordinator
    let finalInjector = LatchSpyInjector()
    var machine = HotkeyStateMachine()

    init(script: [String] = [], settings: SettingsStore? = InMemorySettingsStore(),
         center: NotificationCenter = NotificationCenter()) {
        engine = LatchLoopEngine(script: script)
        dictation = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
        dictation.lander = UtteranceLander(pipeline: PipelineRunner(stages: []), injector: finalInjector,
                                           system: MockSystemAccess(), repair: nil, flags: .inMemory(), database: nil)
        spy = LatchFocusSpy()
        latch = LatchRuntime(delivery: spy)
        session = SessionCoordinator(dictation: dictation, mute: MuteController(store: InMemoryMuteStore()), latch: latch)
        if let settings { session.bindLatchSettings(settings, center: center) }
        latch.attach(segments: engine)
    }

    /// The double tap, through the real gesture recogniser; the capture it opens is latched.
    mutating func doubleTap(at t: TimeInterval = 0) async {
        for action in machine.keyDown(at: t) { session.handle(action) }
        for action in machine.keyUp(at: t + 0.05) { session.handle(action) }
        for action in machine.keyDown(at: t + 0.2) { session.handle(action) }
        for action in machine.keyUp(at: t + 0.25) { session.handle(action) }
        await settle()
        await latchWait("the open segment") { latch.currentSegment != nil }
    }

    /// Binds `capture` as `AppDelegate` binds the container's pipeline (`bindWaveform`), opens it
    /// the way the engine does on key-down, and latches with a real double tap.
    mutating func latch(on capture: ScriptedLatchCapture) async throws {
        dictation.bindWaveform(to: capture.audio)
        try capture.start()
        await doubleTap()
    }

    /// The single tap that stops a latched session.
    mutating func stopTap(at t: TimeInterval) async {
        for action in machine.keyDown(at: t) { session.handle(action) }
        for action in machine.keyUp(at: t + 0.05) { session.handle(action) }
        await settle()
    }

    func settle() async {
        await dictation.settle()
        await latch.settle()
    }

    func wait(outcomes count: Int) async {
        await latchWait("\(count) latch outcome(s)") { latch.outcomes.count >= count }
        await settle()
    }

    /// Emits a stream position and waits until the runtime has ticked with it.
    func position(_ feed: FakeLatchFeed, _ p: TimeInterval) async {
        feed.position(p)
        await latchWait("position \(p)") { latch.lastPosition == p }
    }

    /// VAD edges hop to the main queue; this lets them land before the next step.
    func vad(_ feed: FakeLatchFeed, _ event: VADEvent) async {
        feed.vad(event)
        await flush()
    }

    /// Lets main-queue hops (and anything they started) run.
    func flush() async {
        for _ in 0..<50 { await Task.yield() }
        await settle()
    }
}
