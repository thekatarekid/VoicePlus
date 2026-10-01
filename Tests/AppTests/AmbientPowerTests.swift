import CoreML
import Engine
import Foundation
import Lab
import Shared
import Testing
@testable import VoicePlusApp

/// V5 L5 — battery: VAD always (on the ANE), ASR only on speech, decisions only at segment end,
/// camera only when a lip-reading mode is on; CPU per audio second measured into `Lab/results`.
@Suite("V5 L5 AmbientPower")
struct AmbientPowerTests {
    /// Speech-shaped VAD for the rig: frames with energy are speech (EnergyVAD's contract, no warm-up).
    final class LevelVAD: VADProtocol, @unchecked Sendable {
        let name = "level"
        let frameSize = 512
        private var inSpeech = false
        private var position = 0
        func reset() async { inSpeech = false; position = 0 }
        func process(frame: [Float]) async throws -> VADStep {
            let t = Double(position) / 16_000
            position += frameSize
            let speech = (frame.map(abs).max() ?? 0) > 0.05
            defer { inSpeech = speech }
            if speech, !inSpeech { return VADStep(probability: 1, isSpeech: true, event: .speechStart(at: t)) }
            if !speech, inSpeech { return VADStep(probability: 0, isSpeech: false, event: .speechEnd(at: t)) }
            return VADStep(probability: speech ? 1 : 0, isSpeech: speech)
        }
    }

    final class Runs: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }

    static func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { 0.3 * sinf(Float($0) * 2 * .pi * 220 / 16_000) }
    }
    static func quiet(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    @Test("ASR runs once per speech segment and never on silence")
    func asrOnlyOnSpeech() async throws {
        let runs = Runs()
        let bench = AmbientPowerBench(vad: LevelVAD(), transcribe: { _ in runs.add(); return [] })
        #expect(try await bench.listen(Self.quiet(30)) == .init(segments: 0, asrRuns: 0))
        #expect(runs.count == 0)
        let speech = Self.quiet(1) + Self.tone(2) + Self.quiet(2) + Self.tone(1.5) + Self.quiet(1) + Self.tone(1)
        #expect(try await bench.listen(speech) == .init(segments: 3, asrRuns: 3))
        // The counterfactual L5 avoids: 8.5 s in 4 s chunks = 3 runs even over pure silence.
        #expect(try await bench.transcribeEverything(Self.quiet(8.5)) == 3)
    }

    @Test("decisions happen only at segment end: one per kept segment, none while speech is open")
    func decisionsAtSegmentEnd() async {
        final class Capture: AmbientAudioAttaching, @unchecked Sendable {
            var cont: AsyncStream<AudioPipelineEvent>.Continuation?
            func attachAmbient() throws -> AmbientAudioAttachment {
                let (s, c) = AsyncStream<AudioPipelineEvent>.makeStream(bufferingPolicy: .unbounded)
                cont = c
                return AmbientAudioAttachment(events: s) { c.finish() }
            }
        }
        let capture = Capture(), heard = AmbientListenerTests.Calls()
        let l = AmbientListener(audio: capture, listens: { true },
                                transcribe: { { _ in [TranscriptSpan(text: "hi", confidence: 1, audioRange: 0...1, provenance: [.asr])] } },
                                verdict: { _ in .user(similarity: 1) }, deliver: { heard.noteHeard($0) })
        l.refresh()
        capture.cont?.yield(.vad(.speechStart(at: 0)))
        for i in 0..<40 { capture.cont?.yield(.audio(samples: [Float](repeating: 0.2, count: 800), position: Double(i) * 0.05)) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(heard.heard.isEmpty, "two seconds of open speech: nothing decided yet")
        capture.cont?.yield(.vad(.speechEnd(at: 2)))
        capture.cont?.finish()
        for _ in 0..<200 where l.isAttached { try? await Task.sleep(nanoseconds: 5_000_000) }
        await l.settle()
        #expect(heard.heard.count == 1)
    }

    @Test("camera only for a lip-reading mode, whatever the ambient mode")
    func cameraOnlyWithLipReading() {
        for ambient in AmbientMode.allCases {
            for lip in LipMode.allCases {
                #expect(AmbientPowerPolicy.cameraMayRun(lipMode: lip, ambient: ambient) == lip.needsCamera)
            }
            #expect(!AmbientPowerPolicy.cameraMayRun(lipMode: .off, ambient: ambient))
            #expect(CameraModeGate.decide(mode: .off, status: .granted) == .off)
        }
    }

    @Test("the always-on VAD loads on the Neural Engine (real Silero, through a recording loader)")
    func vadOnANE() async throws {
        final class Units: @unchecked Sendable { var seen: [MLComputeUnits] = [] }
        let units = Units()
        let vad = await SileroVAD.loadIfAvailable(loader: { url, u in units.seen.append(u); return try SileroVAD.coreMLLoader(url, u) },
                                                  residency: nil)
        try #require(vad != nil, "Silero is checked in under Packaging/vad (K17)")
        #expect(units.seen == [AmbientPowerPolicy.vadComputeUnits])
        #expect(AmbientPowerPolicy.vadComputeUnits == .cpuAndNeuralEngine)
    }

    @Test("the CPU report: phases, % of one core, and the results file")
    func report() async throws {
        var clock = 0.0
        let bench = AmbientPowerBench(vad: LevelVAD(), transcribe: { _ in [] }, recognizerName: "mock")
        let report = try await bench.measure(silence: Self.quiet(10), speech: Self.tone(2) + Self.quiet(2), date: "2026-10-02",
                                             hardware: "test", cpu: { clock += 0.05; return clock })
        #expect(report.phases.map(\.name) == ["off", "listening · silence", "listening · speech",
                                             "counterfactual · ASR every 4 s · silence", "counterfactual · ASR every 4 s · speech"])
        #expect(report.phases[0].percentOfOneCore == 0)
        #expect(abs(report.phases[1].percentOfOneCore - 0.5) < 1e-9, "0.05 CPU s over 10 audio s")
        #expect(report.table.contains("| listening · speech |"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l5-\(UUID().uuidString)")
        let url = try CPUProbe.write(report, paths: EvalPaths(cacheDirectory: dir, fixturesDirectory: nil, resultsDirectory: dir))
        #expect(url.lastPathComponent == "2026-10-02-ambient-cpu.json")
        #expect(try JSONDecoder().decode(CPUReport.self, from: Data(contentsOf: url)) == report)
    }

    /// Opt-in measurement on this Mac: `VOICEPLUS_L5_MEASURE=1 swift test --filter AmbientPower`.
    /// Real Silero (ANE) over the fixture silence and speech; ASR only when a final model is already on
    /// disk (never downloads). Writes `Lab/results/<date>-ambient-cpu.json`.
    @Test("measure on this Mac (opt-in)", .enabled(if: ProcessInfo.processInfo.environment["VOICEPLUS_L5_MEASURE"] == "1"))
    func measureHere() async throws {
        let vad = try #require(await SileroVAD.loadIfAvailable(residency: nil))
        let fixtures = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio")
        var silence: [Float] = []
        for _ in 0..<6 { silence += try SampleAudioSource.load16k(url: fixtures.appendingPathComponent("silence/silence_lownoise_5s.wav")) }
        var speech: [Float] = []
        for i in 1...6 {
            let name = String(format: "clean_%02d_%@.wav", i, ["samantha", "daniel", "rishi"][(i - 1) % 3])
            speech += try SampleAudioSource.load16k(url: fixtures.appendingPathComponent("clean/\(name)")) + Self.quiet(1)
        }
        let manager = ModelManager()
        var transcribe: AmbientListener.Transcribe?
        var name = "none"
        if let choice = await RecognizerFactory.chooseFinal(manager: manager, appleSpeechAvailable: false),
           let final = try? await RecognizerFactory.makeFinal(manager: manager) {
            transcribe = { try await final.recognize($0) }
            name = "\(choice)"
        }
        let bench = AmbientPowerBench(vad: vad, transcribe: transcribe, recognizerName: name)
        let report = try await bench.measure(silence: silence, speech: speech, date: String(ISO8601DateFormatter().string(from: Date()).prefix(10)))
        print(report.table)
        print("wrote \(try CPUProbe.write(report).path)")
    }
}
