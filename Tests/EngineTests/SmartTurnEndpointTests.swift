import Engine
import Foundation
import Shared
import Testing

/// V5 C4 — Smart Turn endpointing.
///
/// The model itself (CoreML export of pipecat-ai/smart-turn-v3) is not installed in the test
/// process, so these cases drive the endpointing contract through `TurnCompletionPredicting` with a
/// stand-in that hears "finished" as a fading ending and "continuing" as an abrupt cut. Covered:
/// asked only after ≥ 400 ms of trailing silence, once per pause, "complete" ends early, "not
/// complete"/"can't tell" waits out the pause setting, no model → silence only; the feature
/// extractor's shape and mel layout; missing model → nil.
@Suite("Smart Turn endpointing (C4)")
struct SmartTurnEndpointTests {
    // MARK: Endpointer contract

    @Test("not asked before 400 ms of silence; asked once per pause; true ends at the speech end")
    func endpointerAsksOncePerPause() {
        var e = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8, maxUtterance: 60)
        var asks = 0
        e.speechStarted(at: 0.2); e.speechEnded(at: 1.0)
        #expect(e.tick(now: 1.3, turnComplete: { asks += 1; return false }) == nil)
        #expect(asks == 0, "asked before 400 ms of trailing silence")
        #expect(e.tick(now: 1.45, turnComplete: { asks += 1; return false }) == nil)
        #expect(e.tick(now: 1.6, turnComplete: { asks += 1; return false }) == nil)
        #expect(asks == 1, "asked more than once in one pause")
        // Not complete → the plain timeout still ends it.
        #expect(e.tick(now: 2.2, turnComplete: { asks += 1; return false }) == .endpoint(at: 1.0))
        #expect(!e.endedByTurnModel)

        var f = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8, maxUtterance: 60)
        f.speechStarted(at: 0.2); f.speechEnded(at: 1.0)
        #expect(f.tick(now: 1.41, turnComplete: { true }) == .endpoint(at: 1.0))
        #expect(f.endedByTurnModel)
        f.reset()
        #expect(!f.endedByTurnModel)
    }

    @Test("a new pause is asked again; nil is 'not complete'; never asked when the pause setting ≤ 400 ms")
    func endpointerNewPauseAndShortSetting() {
        var e = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8, maxUtterance: 60)
        var asks = 0
        e.speechStarted(at: 0); e.speechEnded(at: 1.0)
        #expect(e.tick(now: 1.5, turnComplete: { asks += 1; return nil }) == nil)
        e.speechStarted(at: 1.6); e.speechEnded(at: 2.0)
        #expect(e.tick(now: 2.5, turnComplete: { asks += 1; return true }) == .endpoint(at: 2.0))
        #expect(asks == 2)

        var short = Endpointer(trailingSilence: 0.4, noSpeechTimeout: 8, maxUtterance: 60)
        var asked = false
        short.speechStarted(at: 0); short.speechEnded(at: 1.0)
        #expect(short.tick(now: 1.41, turnComplete: { asked = true; return true }) == .endpoint(at: 1.0))
        #expect(!asked && !short.endedByTurnModel)
    }

    // MARK: pipeline on synthetic pause / continuation audio

    @Test("finished sentence (fading ending) closes after ~0.5 s of silence instead of 1.2 s")
    func pipelineEndsFinishedSentenceEarly() async throws {
        let audio = Self.tone(1.0) + Self.fade(0.3) + Self.silence(0.5)
        let withModel = try await endpoints(audio, predictor: FadeTurnPredictor())
        #expect(withModel.count == 1)
        if case .endpoint(let at)? = withModel.first { #expect(abs(at - 1.3) < 0.05) }
        let without = try await endpoints(audio, predictor: nil)
        #expect(without.isEmpty, "without the model a 0.5 s pause must not endpoint at a 1.2 s setting")
    }

    @Test("mid-sentence pause (abrupt cut) waits out the pause setting; the sentence continues")
    func pipelineKeepsContinuationOpen() async throws {
        let audio = Self.tone(1.0) + Self.silence(0.6) + Self.tone(1.0) + Self.fade(0.3) + Self.silence(0.5)
        let predictor = FadeTurnPredictor()
        let got = try await endpoints(audio, predictor: predictor)
        #expect(got.count == 1, "the mid-sentence pause was cut: \(got)")
        if case .endpoint(let at)? = got.first { #expect(abs(at - 2.9) < 0.05) }
        #expect(predictor.asks == 2, "one ask per pause")
    }

    // MARK: features and loading

    @Test("features: [80 × 800], finite, a 1 kHz tone peaks in the right mel band")
    func featureShapeAndBand() {
        let fx = SmartTurnFeatures()
        let tone = (0..<32_000).map { (i: Int) -> Float in 0.3 * sin(Float(i) * 2 * Float.pi * 1000 / 16_000) }
        let feats = fx.features(tone)
        #expect(feats.count == SmartTurnFeatures.melBins * SmartTurnFeatures.frames)
        #expect(feats.allSatisfy { $0.isFinite })
        // Last frame (inside the tone): the loudest mel band holds 1 kHz. Slaney mel: 1 kHz = 15 mel,
        // 80 bands over 0…~45.2 mel → band ≈ 15 / 45.25 × 81 − 1 ≈ 25.
        let last = SmartTurnFeatures.frames - 2
        let column = (0..<SmartTurnFeatures.melBins).map { feats[$0 * SmartTurnFeatures.frames + last] }
        let peak = column.indices.max { column[$0] < column[$1] }!
        #expect((24...27).contains(peak), "1 kHz landed in band \(peak)")
        // Left padding: the first frame (6 s before the 2 s of audio) is at the floor.
        let first = (0..<SmartTurnFeatures.melBins).map { feats[$0 * SmartTurnFeatures.frames] }
        #expect(first.max()! <= column.max()! - 1.9)
    }

    @Test("prepare keeps the last 8 s and left-pads shorter audio")
    func prepareWindow() {
        let long = (0..<(9 * 16_000)).map { Float($0 % 7) }
        #expect(SmartTurnFeatures.prepare(long).count == 128_000)
        let short = SmartTurnFeatures.prepare([1, -1, 1, -1])
        #expect(short.count == 128_000)
        #expect(short[0] == 0 && short[127_995] == 0 && short[127_996] != 0)
    }

    @Test("no model installed → nil (endpointing falls back to silence)")
    func missingModel() async {
        let locator = SmartTurnModelLocator(candidates: [URL(fileURLWithPath: "/nonexistent/smart-turn-v3.mlmodelc")])
        #expect(await SmartTurnModel.loadIfAvailable(locator: locator, residency: nil) == nil)
    }

    // MARK: helpers

    static func tone(_ s: Double) -> [Float] {
        (0..<Int(s * 16_000)).map { (i: Int) -> Float in 0.2 * sin(Float(i) * 2 * Float.pi * 220 / 16_000) }
    }
    static func fade(_ s: Double) -> [Float] {
        let n = Int(s * 16_000)
        return (0..<n).map { (i: Int) -> Float in
            let gain: Float = 0.2 * (1 - Float(i) / Float(n))
            let phase: Float = Float(i) * 2 * Float.pi * 220 / 16_000
            return gain * sin(phase)
        }
    }
    static func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16_000)) }

    private func endpoints(_ audio: [Float], predictor: (any TurnCompletionPredicting)?) async throws -> [Endpointer.Decision] {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.latched = true
        options.endpointer = Endpointer(trailingSilence: 1.2, noSpeechTimeout: 8, maxUtterance: 60)
        options.turnPredictor = predictor
        let pipeline = AudioPipeline(source: source, vad: PeakVAD(), options: options)
        let stream = pipeline.events()
        let collector = Task { () -> [Endpointer.Decision] in
            var out: [Endpointer.Decision] = []
            for await e in stream {
                if case .endpoint(let d) = e { out.append(d) }
                if case .stopped = e { break }
            }
            return out
        }
        try await pipeline.start()
        var i = 0
        while i < audio.count {
            let end = min(i + 800, audio.count)
            source.push(Array(audio[i..<end])); i = end
            await pipeline.drain()
        }
        await pipeline.stop()
        return await collector.value.filter { if case .endpoint = $0 { return true }; return false }
    }
}

/// Stand-in for Smart Turn: "finished" when the last 150 ms of sound is much quieter than the
/// 150 ms before it (a falling ending), "continuing" when the sound stops at full level.
final class FadeTurnPredictor: TurnCompletionPredicting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var asks: Int { lock.withLock { count } }

    func probabilityComplete(_ audio: [Float]) -> Float? {
        lock.withLock { count += 1 }
        guard let lastLoud = audio.lastIndex(where: { abs($0) > 0.01 }) else { return nil }
        let w = 2_400
        guard lastLoud >= 2 * w else { return nil }
        func rms(_ r: Range<Int>) -> Float { (audio[r].reduce(0) { $0 + $1 * $1 } / Float(r.count)).squareRoot() }
        let tail = rms((lastLoud - w)..<lastLoud), before = rms((lastLoud - 2 * w)..<(lastLoud - w))
        return tail < 0.6 * before ? 0.9 : 0.1
    }
}

/// 10 ms frames, speech iff the peak exceeds 0.01; exact edge times.
private final class PeakVAD: VADProtocol, @unchecked Sendable {
    let name = "peak"
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
