import Engine
import Foundation
import Shared
import Testing

/// B1/B2 — the `AudioPipeline.Options` API a latched session runs on.
///
/// * `options` answers with the live values (`setLatched`, `setEndpointer`), not the initial ones.
/// * While latched, every decision re-arms the endpointer: one capture gives one decision per
///   segment, where it used to give one per `start()`.
/// * `setEndpointer` re-times a live segment without dropping its speech; leaving latch re-arms.
///
/// Scripted-VAD cases are exact; the `Fixtures/audio/vad` case runs the real `EnergyVAD` over a
/// recorded five-sentence file and checks the endpoint count against the labelled pauses.
@Suite("Audio pipeline — latched endpointing options")
struct AudioPipelineLatchOptionsTests {
    private static let block = 800

    private static func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.2 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
    }
    private static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    private func pipeline(latched: Bool, endpointer: Endpointer, vad: any VADProtocol = ExactVAD())
        -> (AudioPipeline, FixtureCaptureSource) {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.latched = latched
        options.endpointer = endpointer
        return (AudioPipeline(source: source, vad: vad, options: options), source)
    }

    /// Pushes `samples` in 50 ms blocks, each processed before the next — the pace of a live tap.
    /// (Pushed all at once, the pump would hand the pipeline one coalesced block, and the endpointer,
    /// which ticks once per processed block, would see a single instant.)
    private func push(_ samples: [Float], into source: FixtureCaptureSource, _ pipeline: AudioPipeline) async {
        var i = 0
        while i < samples.count {
            let end = min(i + Self.block, samples.count)
            source.push(Array(samples[i..<end]))
            i = end
            await pipeline.drain()
        }
    }

    /// Starts, runs `body`, stops, and returns every endpoint decision in order.
    private func endpoints(_ pipeline: AudioPipeline, _ body: () async throws -> Void) async throws -> [Endpointer.Decision] {
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
        try await body()
        await pipeline.stop()
        return await collector.value
    }

    // MARK: options are live

    @Test("options reports the live latch flag and endpointer, not the initial ones")
    func optionsAreLive() {
        let (pipeline, _) = pipeline(latched: false, endpointer: Endpointer(trailingSilence: 1.2))
        #expect(!pipeline.options.latched)
        pipeline.setLatched(true)
        #expect(pipeline.options.latched, "options.latched still answered with the initial value")
        #expect(pipeline.isLatched == pipeline.options.latched)
        pipeline.setEndpointer(Endpointer(trailingSilence: 3, noSpeechTimeout: 8, maxUtterance: 30))
        #expect(pipeline.options.endpointer.trailingSilence == 3)
        #expect(pipeline.options.endpointer.maxUtterance == 30)
        // Untouched options keep their initial values.
        #expect(pipeline.options.noAudioTimeout == 0)
        pipeline.setLatched(false)
        #expect(!pipeline.options.latched)
    }

    // MARK: one decision per segment

    @Test("a latched capture endpoints once per pause, not once per start")
    func threePausesThreeEndpoints() async throws {
        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: 0.5, noSpeechTimeout: 8, maxUtterance: 30))
        let got = try await endpoints(pipeline) {
            for _ in 0..<3 { await push(Self.tone(0.6) + Self.silence(0.8), into: source, pipeline) }
            await pipeline.drain()
        }
        // Speech 0–0.6, 1.4–2.0, 2.8–3.4: each followed by 0.8 s ≥ 0.5 s of silence.
        #expect(got == [.endpoint(at: 0.6), .endpoint(at: 2.0), .endpoint(at: 3.4)], "\(got)")
    }

    @Test("a pause shorter than the setting does not split the segment")
    func shortPausesStayInOneSegment() async throws {
        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: 1.0, noSpeechTimeout: 8, maxUtterance: 30))
        let got = try await endpoints(pipeline) {
            await push(Self.tone(0.5) + Self.silence(0.6) + Self.tone(0.5) + Self.silence(1.2), into: source, pipeline)
            await pipeline.drain()
        }
        #expect(got == [.endpoint(at: 1.6)], "\(got)")
    }

    @Test("the segment bound re-arms in speech, so a monologue lands in pieces")
    func maxDurationRearmsWhileSpeaking() async throws {
        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: 0.5, noSpeechTimeout: 8, maxUtterance: 1.2))
        let got = try await endpoints(pipeline) {
            await push(Self.tone(2.5) + Self.silence(0.7), into: source, pipeline)
            await pipeline.drain()
        }
        // Cut at 1.2 and 2.4 while still speaking; the words after the cut still count as speech,
        // so the tail closes on the pause at 3.0, not on a third bound at 3.6.
        #expect(got == [.maxDuration, .maxDuration, .endpoint(at: 2.5)], "\(got)")
    }

    @Test("no-speech is reported once, and the next speech re-arms the endpointer")
    func noSpeechOnceThenSpeechEndpoints() async throws {
        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: 0.5, noSpeechTimeout: 0.5, maxUtterance: 30))
        let got = try await endpoints(pipeline) {
            await push(Self.silence(2.0) + Self.tone(0.5) + Self.silence(0.7), into: source, pipeline)
            await pipeline.drain()
        }
        #expect(got == [.noSpeech, .endpoint(at: 2.5)], "\(got)")
    }

    // MARK: live changes

    @Test("setEndpointer re-times the live segment and keeps its speech")
    func setEndpointerRetimesTheLiveSegment() async throws {
        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: 0.5, noSpeechTimeout: 8, maxUtterance: 30))
        let got = try await endpoints(pipeline) {
            await push(Self.tone(0.5) + Self.silence(0.3), into: source, pipeline)       // 0.3 s into the pause
            await pipeline.drain()
            pipeline.setEndpointer(Endpointer(trailingSilence: 1.5, noSpeechTimeout: 8, maxUtterance: 30))
            await push(Self.silence(0.5), into: source, pipeline)                          // 0.8 s: past 0.5, not 1.5
            await pipeline.drain()
            #expect(pipeline.options.endpointer.trailingSilence == 1.5)
            await push(Self.silence(0.8), into: source, pipeline)                          // 1.6 s ≥ 1.5
            await pipeline.drain()
        }
        #expect(got == [.endpoint(at: 0.5)], "the new pause did not apply, or the speech was dropped: \(got)")
    }

    @Test("leaving latch re-arms: a later latch starts from a clean segment")
    func leavingLatchRearms() async throws {
        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: 0.5, noSpeechTimeout: 8, maxUtterance: 30))
        let got = try await endpoints(pipeline) {
            await push(Self.tone(0.5), into: source, pipeline)          // speech, then latch is left mid-word
            await pipeline.drain()
            pipeline.setLatched(false)
            await push(Self.silence(1.0), into: source, pipeline)       // unlatched: nothing may be emitted
            await pipeline.drain()
            pipeline.setLatched(true)
            await push(Self.silence(1.0), into: source, pipeline)       // the old speech must not endpoint now
            await pipeline.drain()
            await push(Self.tone(0.4) + Self.silence(0.7), into: source, pipeline)
            await pipeline.drain()
        }
        #expect(got == [.endpoint(at: 2.9)], "\(got)")
    }

    // MARK: fixture — real recorded pauses, real EnergyVAD

    /// `vad_03_5segs.wav`: five sentences, labelled pauses of 1.63, 1.93, 2.93 and 2.88 s, then a
    /// ~3 s tail. The expected count is derived from the labels, not typed in: every pause at least
    /// as long as the setting closes a segment.
    @Test("vad_03: the pause setting decides how many segments the pipeline closes", arguments: [1.0, 2.0])
    func recordedPausesMatchTheLabels(pause: Double) async throws {
        let url = try #require(AudioFixtures.url("vad", "vad_03_5segs.wav"))
        let wav = try WAVFile.read(url: url)
        let labels = try #require(try Self.labels()["vad_03_5segs.wav"])
        let duration = Double(wav.samples.count) / Double(wav.sampleRate)
        var pauses = zip(labels, labels.dropFirst()).map { $1[0] - $0[1] }
        pauses.append(duration - (labels.last?[1] ?? duration))
        // VAD padding (50 ms each side) only ever shortens a measured pause, so a pause below the
        // setting stays below it; one above needs that much room to stay above.
        #expect(pauses.allSatisfy { $0 < pause || $0 - 0.2 >= pause }, "a labelled pause sits on the setting: \(pauses)")
        let expected = pauses.filter { $0 >= pause }.count

        let (pipeline, source) = pipeline(latched: true,
                                          endpointer: Endpointer(trailingSilence: pause, noSpeechTimeout: 8, maxUtterance: 30),
                                          vad: EnergyVAD())
        let samples = FixtureCaptureSource(wav: wav).samples16k
        let got = try await endpoints(pipeline) {
            await push(samples, into: source, pipeline)
            await pipeline.drain()
        }
        let closes = got.filter { if case .endpoint = $0 { return true }; return false }
        #expect(closes.count == expected, "pause \(pause) s: \(got)")
        #expect(got.count == closes.count, "no-speech or bound decisions in continuous dictation: \(got)")
    }

    static func labels() throws -> [String: [[Double]]] {
        let url = try #require(AudioFixtures.url("vad", "labels.json"))
        struct Labels: Decodable { let spans: [String: [[Double]]] }
        return try JSONDecoder().decode(Labels.self, from: Data(contentsOf: url)).spans
    }
}

/// A VAD with no smoothing: a 10 ms frame is speech iff its peak exceeds 0.01. Edges are reported
/// at the first frame boundary of the new state, so every time in these tests is exact.
private final class ExactVAD: VADProtocol, @unchecked Sendable {
    let name = "exact"
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
