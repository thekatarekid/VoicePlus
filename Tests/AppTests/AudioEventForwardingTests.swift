import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// G0.2 — `PipelineAudioSource` forwards the pipeline's `.vad`, `.endpoint` and `.chunk` events,
/// and `setLatched` flips latching on the live pipeline.
///
/// Before G0.2 the events loop ended in `default: break`, so VAD and endpoint decisions never left
/// the pipeline and the latch runtime's `noteVAD` / `noteEndpoint` could not be called. The
/// pipeline here is real; its boundaries are mocked: a push-driven `FixtureCaptureSource` and a
/// scripted VAD whose speech start / end times are exact, so every expectation is deterministic.
@Suite("Audio event forwarding")
struct AudioEventForwardingTests {
    // 0.2 s silence, 1.0 s tone, 1.0 s silence: speech 0.2…1.2 s, then a trailing pause.
    private static let lead = 3_200, speech = 16_000, tail = 16_000
    private static let block = 800   // 50 ms, the pipeline's native block

    private func bridge(latched: Bool, chunkMin: TimeInterval = 3, chunkMax: TimeInterval = 5,
                        endpointer: Endpointer = Endpointer(trailingSilence: 0.3, noSpeechTimeout: 8, maxUtterance: 60))
        -> (PipelineAudioSource, FixtureCaptureSource) {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))  // manual pushes
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.latched = latched
        options.chunkMin = chunkMin
        options.chunkMax = chunkMax
        options.endpointer = endpointer
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: ScriptedVAD(), options: options))
        audio.requireMicrophonePermission = false
        return (audio, source)
    }

    private static func utterance() -> [Float] {
        let tone = (0..<speech).map { 0.2 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
        return [Float](repeating: 0, count: lead) + tone + [Float](repeating: 0, count: tail)
    }

    private func push(_ samples: [Float], into source: FixtureCaptureSource) {
        var i = 0
        while i < samples.count {
            let end = min(i + Self.block, samples.count)
            source.push(Array(samples[i..<end]))
            i = end
        }
    }

    @Test("A latched pipeline's .vad, .endpoint and .chunk events reach the callbacks, in order")
    func vadEndpointAndChunkReachTheCallbacks() async throws {
        let (audio, source) = bridge(latched: true, chunkMin: 0.5, chunkMax: 1.0)
        let log = ForwardLog()
        audio.onVAD = { log.vad($0) }
        audio.onEndpoint = { log.endpoint($0) }
        audio.onChunk = { log.chunk($0) }
        audio.sink = { log.samples($0.count) }

        try audio.start(for: .engine)
        let pushed = Self.utterance()
        push(pushed, into: source)
        await audio.pipeline.drain()
        try await poll { log.endpoints.count == 1 && log.vadEvents.count == 2 && log.chunks.count >= 2 }

        #expect(log.vadEvents == [.speechStart(at: 0.2), .speechEnd(at: 1.2)])
        #expect(log.endpoints == [.endpoint(at: 1.2)], "the endpoint lands on the real speech end")
        // Across the three callbacks, delivery keeps pipeline order: start, end, then the endpoint.
        #expect(log.order.filter { $0 != "chunk" } == ["vad.start", "vad.end", "endpoint"])
        // Chunks arrive whole, in order, tiling the stream from 0 s.
        let chunks = log.chunks
        #expect(chunks.first?.range.lowerBound == 0)
        for (a, b) in zip(chunks, chunks.dropFirst()) { #expect(abs(a.range.upperBound - b.range.lowerBound) < 1e-9) }
        let tiled = chunks.flatMap(\.samples)
        #expect(tiled == Array(pushed.prefix(tiled.count)))
        audio.stop()
    }

    /// Unlatched: the silence after speech is long enough to endpoint, yet nothing is emitted.
    /// `setLatched(true)` on the *running* pipeline makes the very next block endpoint — from the
    /// speech history recorded while unlatched. `setLatched(false)` overrides `Options.latched`.
    @Test("setLatched flips latching on the live pipeline", arguments: [false, true])
    func setLatchedIsObservedByTheLivePipeline(initiallyLatched: Bool) async throws {
        let (audio, source) = bridge(latched: initiallyLatched)
        #expect(audio.isLatched == initiallyLatched)
        audio.setLatched(false)
        #expect(!audio.pipeline.isLatched, "setLatched(false) must reach the pipeline")

        let log = ForwardLog()
        audio.onVAD = { log.vad($0) }
        audio.onEndpoint = { log.endpoint($0) }
        audio.sink = { log.samples($0.count) }

        try audio.start(for: .engine)
        let unlatched = Self.utterance()
        push(unlatched, into: source)
        await audio.pipeline.drain()
        try await poll { log.sampleCount == unlatched.count && log.vadEvents.count == 2 }
        #expect(log.vadEvents == [.speechStart(at: 0.2), .speechEnd(at: 1.2)], "VAD is forwarded whether or not latched")

        audio.setLatched(true)
        #expect(audio.pipeline.isLatched, "setLatched(true) must reach the live pipeline")
        push([Float](repeating: 0, count: Self.block), into: source)
        await audio.pipeline.drain()
        try await poll { log.endpoints.count == 1 }

        #expect(log.endpoints == [.endpoint(at: 1.2)])
        // Forwarding is ordered, so the sample count seen when the endpoint arrived says which block
        // produced it: the one pushed after `setLatched(true)`, not the 1 s of silence before it.
        #expect(log.samplesAtFirstEndpoint == unlatched.count + Self.block,
                "an endpoint was emitted while the pipeline was unlatched")

        audio.stop()
        #expect(audio.isLatched, "the live flag survives stop() until flipped back")
        audio.setLatched(false)
        #expect(!audio.isLatched && !audio.pipeline.isLatched)
    }

    /// `onEndpoint` forwards every `Endpointer.Decision`, not just `.endpoint(at:)`: the latch
    /// runtime needs `.noSpeech` and `.maxDuration` to close a segment too.
    @Test("onEndpoint forwards .noSpeech and .maxDuration decisions")
    func noSpeechAndMaxDurationReachOnEndpoint() async throws {
        // Silence past `noSpeechTimeout` → .noSpeech, and no VAD event.
        do {
            let (audio, source) = bridge(latched: true,
                                         endpointer: Endpointer(trailingSilence: 0.3, noSpeechTimeout: 0.5, maxUtterance: 60))
            let log = ForwardLog()
            audio.onVAD = { log.vad($0) }
            audio.onEndpoint = { log.endpoint($0) }
            try audio.start(for: .engine)
            push([Float](repeating: 0, count: 16_000), into: source)
            await audio.pipeline.drain()
            try await poll { log.endpoints.count == 1 }
            #expect(log.endpoints == [.noSpeech])
            #expect(log.vadEvents.isEmpty)
            audio.stop()
        }
        // Speech that never pauses, past `maxUtterance` → .maxDuration.
        do {
            let (audio, source) = bridge(latched: true,
                                         endpointer: Endpointer(trailingSilence: 0.3, noSpeechTimeout: 8, maxUtterance: 1.0))
            let log = ForwardLog()
            audio.onVAD = { log.vad($0) }
            audio.onEndpoint = { log.endpoint($0) }
            try audio.start(for: .engine)
            let tone = (0..<24_000).map { 0.2 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
            push(tone, into: source)
            await audio.pipeline.drain()
            try await poll { log.endpoints.count == 1 }
            #expect(log.endpoints == [.maxDuration])
            #expect(log.order.filter { $0 != "chunk" } == ["vad.start", "endpoint"])
            audio.stop()
        }
    }

    /// Chunks and VAD do not depend on the latch: a plain hold still gets both, and no endpoint.
    @Test("An unlatched pipeline forwards .vad and .chunk but never .endpoint")
    func unlatchedForwardsVADAndChunksOnly() async throws {
        let (audio, source) = bridge(latched: false, chunkMin: 0.5, chunkMax: 1.0)
        let log = ForwardLog()
        audio.onVAD = { log.vad($0) }
        audio.onEndpoint = { log.endpoint($0) }
        audio.onChunk = { log.chunk($0) }
        audio.sink = { log.samples($0.count) }

        try audio.start(for: .engine)
        let pushed = Self.utterance()
        push(pushed, into: source)
        await audio.pipeline.drain()
        try await poll { log.sampleCount == pushed.count && log.vadEvents.count == 2 && log.chunks.count >= 2 }

        #expect(log.vadEvents == [.speechStart(at: 0.2), .speechEnd(at: 1.2)])
        #expect(log.chunks.first?.range.lowerBound == 0)
        #expect(log.endpoints.isEmpty, "2.2 s with 1 s of trailing silence must not endpoint while unlatched")
        audio.stop()
    }

    /// The latch flag outlives a stop/start cycle, and each start gets a fresh endpointer, so a
    /// second latched turn endpoints again without another `setLatched(true)`.
    @Test("setLatched set before start survives stop/start; each start endpoints afresh")
    func latchSurvivesRestartWithAFreshEndpointer() async throws {
        let (audio, source) = bridge(latched: false)
        audio.setLatched(true)                      // before the first start
        let log = ForwardLog()
        audio.onVAD = { log.vad($0) }
        audio.onEndpoint = { log.endpoint($0) }

        for turn in 1...2 {
            try audio.start(for: .engine)
            #expect(audio.isLatched)
            push(Self.utterance(), into: source)
            await audio.pipeline.drain()
            try await poll { log.endpoints.count == turn && log.vadEvents.count == 2 * turn }
            audio.stop()
        }
        #expect(log.endpoints == [.endpoint(at: 1.2), .endpoint(at: 1.2)], "stream time restarts at 0 on each start")
        #expect(log.vadEvents == [.speechStart(at: 0.2), .speechEnd(at: 1.2), .speechStart(at: 0.2), .speechEnd(at: 1.2)])
    }

    private func poll(timeoutMs: Int = 5_000, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1_000)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within \(timeoutMs) ms")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Everything the forwarder delivered, in delivery order. All callbacks run on the forwarder task.
private final class ForwardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _vad: [VADEvent] = []
    private var _endpoints: [Endpointer.Decision] = []
    private var _chunks: [AudioChunk] = []
    private var _samples = 0
    private var _samplesAtFirstEndpoint: Int?
    private var _order: [String] = []

    var vadEvents: [VADEvent] { lock.withLock { _vad } }
    var endpoints: [Endpointer.Decision] { lock.withLock { _endpoints } }
    var chunks: [AudioChunk] { lock.withLock { _chunks } }
    var sampleCount: Int { lock.withLock { _samples } }
    var samplesAtFirstEndpoint: Int? { lock.withLock { _samplesAtFirstEndpoint } }
    /// One tag per callback invocation, across all three callbacks, in delivery order.
    var order: [String] { lock.withLock { _order } }

    func vad(_ e: VADEvent) {
        lock.withLock {
            _vad.append(e)
            if case .speechStart = e { _order.append("vad.start") } else { _order.append("vad.end") }
        }
    }
    func chunk(_ c: AudioChunk) { lock.withLock { _chunks.append(c); _order.append("chunk") } }
    func samples(_ n: Int) { lock.withLock { _samples += n } }
    func endpoint(_ d: Endpointer.Decision) {
        lock.withLock {
            if _samplesAtFirstEndpoint == nil { _samplesAtFirstEndpoint = _samples }
            _endpoints.append(d)
            _order.append("endpoint")
        }
    }
}

/// A VAD with no smoothing: a 10 ms frame is speech iff its peak exceeds 0.01. Start / end are
/// reported at the first frame boundary of the new state, so the times are exact.
private final class ScriptedVAD: VADProtocol, @unchecked Sendable {
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
