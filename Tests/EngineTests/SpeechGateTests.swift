import Foundation
import Testing
import Shared
@testable import Engine

// MARK: - Doubles

/// An `AudioSource` the test pushes into by hand; positions on the stream clock are exact.
final class GateAudioSource: AudioSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    func prewarm() throws {}
    func start() throws {}
    func stop() {}
    func push(seconds: Double, level: Float = 0.001) {
        let samples = [Float](repeating: level, count: Int(seconds * 16_000))
        samples.withUnsafeBufferPointer { sink?($0) }
    }
}

/// A final recognizer that counts its calls: the no-speech gate is about *not calling it*.
final class SpyFinal: FinalRecognizer, @unchecked Sendable {
    let name = "spy"
    private let lock = NSLock()
    private var lengths: [Int] = []
    private let spans: [TranscriptSpan]
    init(_ spans: [TranscriptSpan]) { self.spans = spans }
    var calls: Int { lock.withLock { lengths.count } }
    var receivedLengths: [Int] { lock.withLock { lengths } }
    func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        lock.withLock { lengths.append(samples.count) }
        return spans
    }
}

/// Counts refinement calls; a dropped segment must not reach it.
final class CountingRefiner: RefinementSession, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.withLock { n } }
    func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        lock.withLock { n += 1 }
        return []
    }
}

/// The production bridge in miniature: an `AudioPipeline` exposed as the `AudioSource` the engine
/// consumes (`PipelineAudioSource` does this in the app). Audio only — the VAD reaches the engine
/// through `RealEngine.VADFeed.pipeline`, which is exactly what is under test.
final class GatePipelineFeed: AudioSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    let pipeline: AudioPipeline
    private var forwarder: Task<Void, Never>?
    init(_ pipeline: AudioPipeline) { self.pipeline = pipeline }
    func prewarm() throws {}

    final class ErrorBox: @unchecked Sendable { var error: Error? }

    func start() throws {
        let events = pipeline.events()
        forwarder = Task.detached { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .audio(let samples, _) = event { samples.withUnsafeBufferPointer { self.sink?($0) } }
                if case .stopped = event { return }
            }
        }
        let box = ErrorBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached { [pipeline] in
            do { try await pipeline.start() } catch { box.error = error }
            done.signal()
        }
        done.wait()
        if let error = box.error { throw error }
    }

    func stop() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { [pipeline] in
            await pipeline.stop()
            done.signal()
        }
        done.wait()
    }
}

/// Collects the utterance stream so a test can see the `.final` a skip still emits.
final class FinalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var finals: [[TranscriptSpan]] = []
    private var task: Task<Void, Never>?
    init(_ engine: RealEngine) {
        let events = engine.events()
        task = Task { [weak self] in
            for await e in events { if case .final(let f) = e { self?.lock.withLock { self?.finals.append(f) } } }
        }
    }
    var all: [[TranscriptSpan]] { lock.withLock { finals } }
    func stop() { task?.cancel() }
    func wait(for count: Int) async {
        for _ in 0..<200 where all.count < count { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
}

private func words(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
    text.split(separator: " ").map {
        TranscriptSpan(text: String($0), confidence: confidence, audioRange: 0...1, provenance: [.asr])
    }
}

private func waitForSamples(_ engine: RealEngine, _ count: Int) async {
    for _ in 0..<400 where await engine.bufferedSampleCount() < count {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

private func makeEngine(_ final: FinalRecognizer, feed: RealEngine.VADFeed = .forwarded) -> (RealEngine, GateAudioSource) {
    let audio = GateAudioSource()
    let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: final, preview: nil))
    engine.vadFeed = feed
    return (engine, audio)
}

private func pipelineOf(_ feed: RealEngine.VADFeed) -> AudioPipeline? {
    if case .pipeline(let pipeline) = feed { return pipeline }
    return nil
}

// MARK: - Feed discovery

/// A bridge that is subclassed, so the pipeline sits in the superclass's stored properties.
class GateBaseBridge: AudioSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    let pipeline: AudioPipeline
    init(_ pipeline: AudioPipeline) { self.pipeline = pipeline }
    func prewarm() throws {}
    func start() throws {}
    func stop() {}
}
final class GateDerivedBridge: GateBaseBridge, @unchecked Sendable {
    var extra = 0
}

@Suite("C1 VAD feed discovery")
struct VADFeedDiscoveryTests {
    private func idlePipeline() -> AudioPipeline {
        AudioPipeline(source: FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: [])), vad: EnergyVAD())
    }

    /// The app's shape: an `AudioSource` holding its `AudioPipeline`. The gate is armed with no
    /// wiring line anywhere.
    @Test func pipelineBackedSourceIsFoundWithoutWiring() {
        let pipeline = idlePipeline()
        let engine = RealEngine(audio: GatePipelineFeed(pipeline), provider: StaticRecognizerProvider(final: SpyFinal([])))
        #expect(pipelineOf(engine.vadFeed) === pipeline)
    }

    @Test func pipelineInASuperclassIsFound() {
        let pipeline = idlePipeline()
        let engine = RealEngine(audio: GateDerivedBridge(pipeline), provider: StaticRecognizerProvider(final: SpyFinal([])))
        #expect(pipelineOf(engine.vadFeed) === pipeline)
    }

    /// Lab replays and bare sources have no VAD: they keep decoding by duration.
    @Test func sourcesWithoutAPipelineGetNoFeed() {
        for audio: AudioSource in [GateAudioSource(), SampleAudioSource(samples: [])] {
            let engine = RealEngine(audio: audio, provider: StaticRecognizerProvider(final: SpyFinal([])))
            if case .none = engine.vadFeed {} else { Issue.record("expected no VAD feed for \(type(of: audio))") }
        }
    }

    @Test func anExplicitFeedOverridesDiscovery() {
        let engine = RealEngine(audio: GatePipelineFeed(idlePipeline()), provider: StaticRecognizerProvider(final: SpyFinal([])))
        engine.vadFeed = .forwarded
        if case .forwarded = engine.vadFeed {} else { Issue.record("override ignored") }
        engine.vadFeed = .none
        if case .none = engine.vadFeed {} else { Issue.record("override ignored") }
    }
}

// MARK: - Ledger

@Suite("C1 speech ledger")
struct SpeechLedgerTests {
    @Test func countsClosedAndOpenRunsInsideAWindow() {
        var ledger = SpeechLedger()
        ledger.note(.speechStart(at: 0.2))
        ledger.note(.speechEnd(at: 0.6))
        ledger.note(.speechStart(at: 1.5))
        #expect(abs(ledger.speechSeconds(from: 0, to: 1.0) - 0.4) < 1e-9)
        // The open run counts to the window's end.
        #expect(abs(ledger.speechSeconds(from: 0, to: 2.0) - 0.9) < 1e-9)
        // Clipped to the window on both sides.
        #expect(abs(ledger.speechSeconds(from: 0.5, to: 1.7) - 0.3) < 1e-9)
        #expect(ledger.speechSeconds(from: 0.7, to: 1.4) == 0)
        #expect(ledger.speechSeconds(from: 1.0, to: 1.0) == 0)
    }

    @Test func paddedOverlapIsMergedNotDoubleCounted() {
        var ledger = SpeechLedger()
        ledger.note(.speechStart(at: 1.0))
        ledger.note(.speechEnd(at: 2.0))
        ledger.note(.speechStart(at: 1.8))   // padding overlap: same speech continuing
        ledger.note(.speechEnd(at: 2.5))
        #expect(ledger.intervals == [1.0...2.5])
        #expect(abs(ledger.speechSeconds(from: 0, to: 3) - 1.5) < 1e-9)
    }

    @Test func aSecondFeedOfTheSameVADCountsOnce() {
        let edges: [VADEvent] = [.speechStart(at: 1.0), .speechEnd(at: 2.0), .speechStart(at: 3.0), .speechEnd(at: 4.0)]
        var single = SpeechLedger()
        edges.forEach { single.note($0) }
        // Two feeds, the second lagging, interleaved.
        var double = SpeechLedger()
        for (i, e) in edges.enumerated() {
            double.note(e)
            if i >= 2 { double.note(edges[i - 2]) }
        }
        double.note(edges[2]); double.note(edges[3])
        #expect(double.intervals == single.intervals)
        #expect(double.speechSeconds(from: 0, to: 5) == 2)
    }

    @Test func strayEdgesAndResetAreHarmless() {
        var ledger = SpeechLedger()
        let strayEnd = ledger.note(.speechEnd(at: 0.5))      // end while silent
        let start = ledger.note(.speechStart(at: 0.6))
        let strayStart = ledger.note(.speechStart(at: 0.9))  // start while in speech
        #expect(!strayEnd)
        #expect(start)
        #expect(!strayStart)
        #expect(ledger.heardSpeech)
        ledger.reset()
        #expect(!ledger.heardSpeech)
        #expect(ledger.speechSeconds(from: 0, to: 10) == 0)
    }
}

// MARK: - Gate on the hold path

@Suite("C1 no-speech gate")
struct NoSpeechGateTests {
    /// Silence hold: the decoder is never called, nothing is returned, and the reason says why.
    @Test func silentHoldNeverReachesTheDecoder() async throws {
        let spy = SpyFinal(words("thank you"))
        let (engine, audio) = makeEngine(spy)
        let log = FinalLog(engine)
        defer { log.stop() }
        let segments = SegmentLog(engine)
        defer { segments.stop() }

        try await engine.start(prewarm: true)
        #expect(engine.isSpeechGateArmed)
        audio.push(seconds: 1.5)
        await waitForSamples(engine, 24_000)
        let spans = try await engine.stop()

        #expect(spans.isEmpty)
        #expect(spy.calls == 0)
        #expect(engine.lastStopReason == .noSpeech)
        #expect(engine.lastStopReason?.recoveryID == "A06")
        #expect(engine.diagnostics.noSpeechSkips == 1)
        let drop = try #require(engine.diagnostics.recentDrops.last)
        #expect(drop.kind == .noSpeech)
        #expect(drop.speechSeconds == 0)
        #expect(abs(drop.audioSeconds - 1.5) < 1e-9)
        #expect(drop.stamp.range(of: #"^\d{4}-\d{2}-\d{2}-\d{6}-\d{3}$"#, options: .regularExpression) != nil)
        // The session still ends the normal way: an empty `.final`, an empty `.closed` commit.
        await log.wait(for: 1)
        #expect(log.all == [[]])
        await segments.waitForClosed(1)
        #expect(segments.closed.first?.spans.isEmpty == true)
        #expect(segments.closed.first?.reason == .keyRelease)
        #expect(engine.state == .idle)
    }

    /// 0.4 s of speech is enough.
    @Test func fourHundredMillisecondsOfSpeechIsDecoded() async throws {
        let expected = words("send it")
        let spy = SpyFinal(expected)
        let (engine, audio) = makeEngine(spy)

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        engine.noteVAD(.speechStart(at: 0.3))
        engine.noteVAD(.speechEnd(at: 0.7))
        await waitForSamples(engine, 16_000)
        let spans = try await engine.stop()

        #expect(spy.calls == 1)
        #expect(spy.receivedLengths == [16_000])
        #expect(spans.map(\.text) == ["send", "it"])
        #expect(engine.lastStopReason == .decoded)
        #expect(engine.diagnostics.noSpeechSkips == 0)
    }

    @Test func justUnderTheMinimumIsNotDecoded() async throws {
        let spy = SpyFinal(words("hi"))
        let (engine, audio) = makeEngine(spy)
        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        engine.noteVAD(.speechStart(at: 0.3))
        engine.noteVAD(.speechEnd(at: 0.55))
        await waitForSamples(engine, 16_000)
        _ = try await engine.stop()
        #expect(spy.calls == 0)
        #expect(engine.lastStopReason == .noSpeech)
    }

    /// Key released mid-word: the VAD has not emitted `speechEnd` yet, and that speech counts.
    @Test func speechStillInProgressAtReleaseCounts() async throws {
        let spy = SpyFinal(words("hello there"))
        let (engine, audio) = makeEngine(spy)
        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        engine.noteVAD(.speechStart(at: 0.55))
        await waitForSamples(engine, 16_000)
        _ = try await engine.stop()
        #expect(spy.calls == 1)
    }

    /// Edges from an earlier session never count toward the next one.
    @Test func eachSessionStartsWithAnEmptyLedger() async throws {
        let spy = SpyFinal(words("first words"))
        let (engine, audio) = makeEngine(spy)
        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        engine.noteVAD(.speechStart(at: 0.1))
        engine.noteVAD(.speechEnd(at: 0.9))
        await waitForSamples(engine, 16_000)
        _ = try await engine.stop()
        #expect(spy.calls == 1)
        engine.noteVAD(.speechStart(at: 0.2))          // arrives between sessions: ignored

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        await waitForSamples(engine, 16_000)
        _ = try await engine.stop()
        #expect(spy.calls == 1)
        #expect(engine.lastStopReason == .noSpeech)
    }

    /// No VAD attached: the engine cannot know, so it decodes as it always did (fail open).
    @Test func withoutAVADFeedSilenceIsDecodedAsBefore() async throws {
        let spy = SpyFinal(words("hello"))
        let (engine, audio) = makeEngine(spy, feed: .none)
        try await engine.start(prewarm: true)
        #expect(!engine.isSpeechGateArmed)
        audio.push(seconds: 1.0)
        await waitForSamples(engine, 16_000)
        let spans = try await engine.stop()
        #expect(spy.calls == 1)
        #expect(spans.map(\.text) == ["hello"])
        #expect(engine.lastStopReason == .decoded)
    }

    /// Below the recognizer's audio floor the reason stays `tooShort` when no VAD is attached.
    @Test func subFloorAudioWithoutVADIsTooShort() async throws {
        let spy = SpyFinal(words("x"))
        let (engine, audio) = makeEngine(spy, feed: .none)
        try await engine.start(prewarm: true)
        audio.push(seconds: 0.2)
        await waitForSamples(engine, 3_200)
        _ = try await engine.stop()
        #expect(spy.calls == 0)
        #expect(engine.lastStopReason == .tooShort)
    }
}

// MARK: - Gate on the endpoint path (latch)

@Suite("C1 no-speech gate, endpoint close")
struct NoSpeechGateEndpointTests {
    /// Speech is measured per segment on the stream clock: a silent first segment closes empty
    /// without a pass; the second, with speech at 1.2–1.8 s, is decoded with exactly its own audio.
    @Test func eachSegmentIsGatedOnItsOwnSpeech() async throws {
        let spy = SpyFinal(words("second segment"))
        let (engine, audio) = makeEngine(spy)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        await waitForSamples(engine, 16_000)
        await engine.closeSegmentAtEndpoint()
        #expect(spy.calls == 0)

        audio.push(seconds: 1.0)
        engine.noteVAD(.speechStart(at: 1.2))
        engine.noteVAD(.speechEnd(at: 1.8))
        await waitForSamples(engine, 32_000)
        await engine.closeSegmentAtEndpoint()
        #expect(spy.receivedLengths == [16_000])

        // A third, silent segment closed by the key release.
        audio.push(seconds: 0.5)
        await waitForSamples(engine, 40_000)
        let last = try await engine.stop()
        #expect(last.isEmpty)
        #expect(spy.calls == 1)
        #expect(engine.lastStopReason == .noSpeech)
        #expect(engine.diagnostics.noSpeechSkips == 2)

        await log.waitForClosed(3)
        #expect(log.closed.map(\.segment.index) == [0, 1, 2])
        #expect(log.closed.map { $0.spans.map(\.text) } == [[], ["second", "segment"], []])
        #expect(log.closed.map(\.reason) == [.endpoint, .endpoint, .keyRelease])
    }
}

// MARK: - Guard wired into the engine

@Suite("C2 hallucination guard in RealEngine")
struct HallucinationGuardEngineTests {
    /// "Thank you." over 0.35 s of speech in 2 s of audio (17.5 %): decoded, then dropped.
    @Test func fillerOverLittleSpeechIsDropped() async throws {
        let spy = SpyFinal(words("Thank you."))
        let (engine, audio) = makeEngine(spy)
        let log = FinalLog(engine)
        defer { log.stop() }
        try await engine.start(prewarm: true)
        audio.push(seconds: 2.0)
        engine.noteVAD(.speechStart(at: 0.5))
        engine.noteVAD(.speechEnd(at: 0.85))
        await waitForSamples(engine, 32_000)
        let spans = try await engine.stop()

        #expect(spy.calls == 1)
        #expect(spans.isEmpty)
        #expect(engine.lastStopReason == .hallucination(.fillerWithoutSpeech))
        #expect(engine.lastStopReason?.recoveryID == "A06")
        #expect(engine.diagnostics.hallucinationDrops(.fillerWithoutSpeech) == 1)
        let drop = try #require(engine.diagnostics.recentDrops.last)
        #expect(drop.tokenCount == 2)
        #expect(abs((drop.speechSeconds ?? 0) - 0.35) < 1e-9)
        await log.wait(for: 1)
        #expect(log.all == [[]])
    }

    /// The same words with 60 % speech are the user's, and stand.
    @Test func realThankYouIsKept() async throws {
        let spy = SpyFinal(words("Thank you."))
        let (engine, audio) = makeEngine(spy)
        try await engine.start(prewarm: true)
        audio.push(seconds: 2.0)
        engine.noteVAD(.speechStart(at: 0.4))
        engine.noteVAD(.speechEnd(at: 1.6))
        await waitForSamples(engine, 32_000)
        let spans = try await engine.stop()
        #expect(spans.map(\.text) == ["Thank", "you."])
        #expect(engine.lastStopReason == .decoded)
        #expect(engine.diagnostics.hallucinationDrops == 0)
    }

    /// The repetition rule needs no VAD at all.
    @Test func decoderLoopIsDroppedEvenWithoutVAD() async throws {
        let spy = SpyFinal(words("the the the the the"))
        let (engine, audio) = makeEngine(spy, feed: .none)
        try await engine.start(prewarm: true)
        audio.push(seconds: 1.5)
        await waitForSamples(engine, 24_000)
        let spans = try await engine.stop()
        #expect(spans.isEmpty)
        #expect(engine.lastStopReason == .hallucination(.repeatedToken))
    }

    /// Endpoint path: a dropped segment commits empty and is never handed to the refiner.
    @Test func droppedSegmentSkipsRefinement() async throws {
        let spy = SpyFinal(words("you"))
        let (engine, audio) = makeEngine(spy)
        let refiner = CountingRefiner()
        engine.refiner = refiner
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 2.0)
        engine.noteVAD(.speechStart(at: 0.2))
        engine.noteVAD(.speechEnd(at: 0.55))      // 0.35 s of 2 s = 17.5 %
        await waitForSamples(engine, 32_000)
        await engine.closeSegmentAtEndpoint()
        await engine.cancel()

        #expect(spy.calls == 1)
        #expect(refiner.calls == 0)
        #expect(engine.diagnostics.hallucinationDrops(.fillerWithoutSpeech) == 1)
        await log.waitForClosed(1)
        #expect(log.closed.first?.spans.isEmpty == true)
        #expect(log.closed.first?.reason == .endpoint)
    }
}

// MARK: - Fixture replay through the real pipeline and VAD

@Suite("C1 fixture replay", .serialized)
struct NoSpeechFixtureReplayTests {
    private func replay(_ url: URL, spy: SpyFinal,
                        feedPipeline other: AudioPipeline? = nil) async throws -> (RealEngine, [TranscriptSpan], Int) {
        let wav = try WAVFile.read(url: url)
        let source = FixtureCaptureSource(wav: wav)
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        let feed = GatePipelineFeed(pipeline)
        let engine = RealEngine(audio: feed, provider: StaticRecognizerProvider(final: spy, preview: nil))
        // Wired the way the app is: nobody sets `vadFeed`, the engine finds the pipeline itself.
        #expect(pipelineOf(engine.vadFeed) === pipeline)
        if let other { engine.vadFeed = .pipeline(other) }

        try await engine.start(prewarm: true)
        await pipeline.drain()
        let total = source.samples16k.count
        await waitForSamples(engine, total)
        #expect(await engine.bufferedSampleCount() == total)
        let spans = try await engine.stop()
        return (engine, spans, total)
    }

    /// `Fixtures/audio/silence` through capture → pipeline → energy VAD → engine: nothing lands,
    /// and the decoder is never asked.
    @Test func silenceFixturesLandNothing() async throws {
        let files = AudioFixtures.list("silence")
        #expect(files.count == 2)
        for url in files {
            let spy = SpyFinal(words("Thank you."))
            let (engine, spans, _) = try await replay(url, spy: spy)
            #expect(spans.isEmpty, Comment(rawValue: url.lastPathComponent))
            #expect(spy.calls == 0, Comment(rawValue: url.lastPathComponent))
            #expect(engine.lastStopReason == .noSpeech, Comment(rawValue: url.lastPathComponent))
        }
    }

    /// The control: real speech through the same path is decoded, whole. Also proves the VAD's
    /// clock and the engine's sample clock line up (the gate would drop it otherwise).
    @Test func speechFixtureIsDecoded() async throws {
        let url = try #require(AudioFixtures.url("clean", "clean_03_rishi.wav"))
        let spy = SpyFinal(words("meet me at noon"))
        let (engine, spans, total) = try await replay(url, spy: spy)
        #expect(spy.receivedLengths == [total])
        #expect(spans.map(\.text) == ["meet", "me", "at", "noon"])
        #expect(engine.lastStopReason == .decoded)
    }

    /// A feed that never reports this session's start (wired to the wrong pipeline, or broken)
    /// leaves the gate open rather than discarding every dictation as silence.
    @Test func brokenFeedFailsOpen() async throws {
        let url = try #require(AudioFixtures.url("silence", "silence_lownoise_5s.wav"))
        let idle = AudioPipeline(source: FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: [])), vad: EnergyVAD())
        let spy = SpyFinal(words("hello"))
        let (engine, _, _) = try await replay(url, spy: spy, feedPipeline: idle)
        #expect(spy.calls == 1)
        #expect(engine.lastStopReason == .decoded)
    }
}
