import AVFoundation
import Foundation
import Testing
@testable import Engine
@testable import Shared

/// V5 C1 — Apple voice-processing I/O behind Settings › Voice: profile selection, the graph plan,
/// AGC adaptation, the 300 ms level warm-up, and format negotiation (44.1/48 k) through the VP source.
/// Untested here (needs a mic + TCC): VP-IO's actual AEC/NS/AGC and its V1-gate WER → T1.
@Suite("V5 C1 — Apple voice-processing capture")
struct CaptureEnhancementTests {
    final class FakeSource: AudioCaptureSource, CaptureGraphDescribing, @unchecked Sendable {
        let label: String
        let vp: Bool
        init(_ label: String, vp: Bool) { self.label = label; self.vp = vp }
        var device: AudioDeviceInfo? { nil }
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        func prewarm() throws {}
        func start() throws {}
        func stop() {}
        func switchDevice(to device: AudioDeviceInfo?) throws {}
        var diagnostics: AudioCaptureDiagnostics { var d = AudioCaptureDiagnostics(); d.voiceProcessing = vp; return d }
    }

    // MARK: profile selection

    @Test func offIsThePlainTapAndTheShippingDefault() {
        #expect(CaptureEnhancement.shippingDefault == .off, "default stays off until the V1 gate (T1)")
        let plan = CaptureGraphPlan.plan(for: .off)
        #expect(plan.profile == .default)
        #expect(!plan.usesVoiceProcessingSource && !plan.usesNeuralStage)
        #expect(plan.levelWarmup == 0 && !plan.tracksAGC)
    }

    @Test func appleVoiceProcessingMovesSourceAndProfileTogether() {
        let plan = CaptureGraphPlan.plan(for: .appleVoiceProcessing)
        #expect(plan.usesVoiceProcessingSource)
        #expect(plan.profile.aec == .appleVoiceProcessing)
        #expect(!plan.profile.noiseSuppression, "no spectral gate on top (R1.4)")
        #expect(plan.levelWarmup == 0.3 && plan.tracksAGC)
        var made: [String] = []
        let capture = plan.makeCaptureSource(plainTap: { made.append("tap"); return FakeSource("tap", vp: false) },
                                             voiceProcessing: { made.append("vp"); return FakeSource("vp", vp: true) })
        #expect(made == ["vp"], "only the chosen source is built")
        #expect((capture.inner as? FakeSource)?.label == "vp")
        #expect(capture.effectiveAEC == .appleVoiceProcessing)
        #expect(capture.chain.stages.isEmpty)
        let options = plan.apply(to: AudioPipeline.Options())
        #expect(options.levelWarmup == 0.3 && options.tracksAGC)
    }

    @Test func plainTapPlanNeverReportsVoiceProcessing() {
        let capture = CaptureGraphPlan.plan(for: .off).makeCaptureSource(
            plainTap: { FakeSource("tap", vp: false) }, voiceProcessing: { FakeSource("vp", vp: true) })
        #expect(capture.effectiveAEC == .off)
    }

    @Test func storedChoiceAndEnvironmentOverride() throws {
        let defaults = try #require(UserDefaults(suiteName: "c1-\(UUID().uuidString)"))
        #expect(CaptureEnhancement.current(defaults: defaults, environment: [:]) == .off)
        CaptureEnhancement.set(.appleVoiceProcessing, defaults: defaults)
        #expect(CaptureEnhancement.current(defaults: defaults, environment: [:]) == .appleVoiceProcessing)
        #expect(CaptureEnhancement.current(defaults: defaults, environment: [CaptureEnhancement.environmentKey: "localVQE"]) == .localVQE)
        #expect(CaptureEnhancement.current(defaults: defaults, environment: [CaptureEnhancement.environmentKey: "bogus"]) == .appleVoiceProcessing)
    }

    @Test func gateArithmetic() {
        typealias R = CaptureEnhancementGate.Result
        let ok = R(cleanBaseline: 0.050, cleanCandidate: 0.052, noisyBaseline: 0.20, noisyCandidate: 0.15)
        let hurtsClean = R(cleanBaseline: 0.050, cleanCandidate: 0.054, noisyBaseline: 0.20, noisyCandidate: 0.10)
        let noHelp = R(cleanBaseline: 0.050, cleanCandidate: 0.050, noisyBaseline: 0.20, noisyCandidate: 0.21)
        #expect(CaptureEnhancementGate.passes(ok))
        #expect(!CaptureEnhancementGate.passes(hurtsClean), "> 0.3 pt clean regression")
        #expect(!CaptureEnhancementGate.passes(noHelp))
        #expect(CaptureEnhancementGate.winner([.appleVoiceProcessing: ok, .localVQE: hurtsClean]) == .appleVoiceProcessing)
        #expect(CaptureEnhancementGate.winner([.appleVoiceProcessing: noHelp]) == nil)
    }

    // MARK: AGC adaptation + level warm-up

    @Test func agcTrackerReportsTheRampLength() {
        var t = AGCAdaptationTracker()
        var outcome: AGCAdaptationTracker.Outcome?
        // 50 ms blocks: a 250 ms ramp from -50 dBFS to -20 dBFS, then steady.
        let ramp: [Float] = [-50, -44, -38, -32, -26]
        for db in ramp + [Float](repeating: -20, count: 10) where outcome == nil {
            outcome = t.feed(rms: pow(10, db / 20), duration: 0.05)
        }
        #expect(outcome == .settled(after: 0.25))
        #expect(t.logLine == "audio: AGC settled after 250 ms")
    }

    @Test func agcTrackerGivesUpAndIgnoresDigitalSilence() {
        var t = AGCAdaptationTracker(horizon: 1)
        var outcome: AGCAdaptationTracker.Outcome?
        var i = 0
        while outcome == nil {
            outcome = t.feed(rms: i % 2 == 0 ? 0.001 : 0.1, duration: 0.05)   // ±40 dB flapping never settles
            i += 1
        }
        #expect(outcome == .notSettled(within: 1))
        var s = AGCAdaptationTracker()
        for _ in 0..<4 { #expect(s.feed(rms: 0, duration: 0.05) == nil) }
        #expect(s.feed(rms: 0.1, duration: 0.1) == nil)
        #expect(s.feed(rms: 0.1, duration: 0.1) == .settled(after: 0.2), "silence is skipped, not a level")
    }

    /// The first 300 ms (the AGC ramp) never feeds a floor estimate.
    @Test func levelWarmupKeepsTheAGCRampOutOfTheFloor() {
        func quality(warmup: TimeInterval) -> MicQualityAnalyzer.Measurement? {
            let a = MicQualityAnalyzer()
            a.warmup = warmup
            // 300 ms near-silent ramp (AGC still low), 300 ms room noise, then 1.2 s speech.
            let ramp = [Float](repeating: 0.00005, count: 4_800)
            let room = (0..<4_800).map { _ in Float.random(in: -0.003...0.003) }
            let speech: [Float] = (0..<19_200).map { (i: Int) -> Float in
                let phase = Float(i) * 2 * Float.pi * 220 / 16_000
                return 0.2 * sin(phase)
            }
            a.feed(ramp + room)
            a.note(.speechStart(at: 0.6))
            a.feed(speech)
            return a.measurement
        }
        let cold = quality(warmup: 0), warm = quality(warmup: 0.3)
        #expect(cold != nil && warm != nil)
        // Without the warm-up the ramp's p10 is the floor (too low → SNR overstated).
        #expect(warm!.floorRMS > cold!.floorRMS * 5, "warm \(warm!.floorRMS) cold \(cold!.floorRMS)")
    }

    @Test func pipelineCarriesTheWarmupAndTracksAGC() async throws {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = CaptureGraphPlan.plan(for: .appleVoiceProcessing).apply(to: AudioPipeline.Options())
        options.noAudioTimeout = 0
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        try await pipeline.start()
        for db in [Float](arrayLiteral: -50, -40, -30) + [Float](repeating: -20, count: 6) {
            source.push([Float](repeating: pow(10, db / 20), count: 800))
            await pipeline.drain()
        }
        await pipeline.stop()
        guard case .settled(let t)? = pipeline.lastAGCOutcome else { Issue.record("not settled"); return }
        #expect(abs(t - 0.15) < 1e-9)
    }

    // MARK: format negotiation through the VP source

    /// > 2 channels need an explicit layout: the VP tap's is discrete-in-order (tag 9633797 for 5 ch).
    private static func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        if channels > 2 {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    private func buffer(rate: Double, channels: AVAudioChannelCount, seconds: Double) -> AVAudioPCMBuffer {
        let format = Self.format(rate: rate, channels: channels)
        let frames = AVAudioFrameCount(rate * seconds)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                // Tone on channel 0 only, like the VP tap's discrete layout.
                b.floatChannelData![c][i] = c == 0 ? 0.3 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) : 0
            }
        }
        return b
    }

    @Test("VP tap formats convert to 16 kHz mono", arguments: [(48_000.0, 5), (44_100.0, 5), (48_000.0, 1), (44_100.0, 1)])
    func formatNegotiation(rate: Double, channels: Int) {
        let source = VoiceProcessingCaptureSource()
        let input = buffer(rate: rate, channels: AVAudioChannelCount(channels), seconds: 0.5)
        let converter = source.converter(matching: input.format)
        #expect(converter.inputFormat.sampleRate == rate)
        #expect(converter.extractsChannelZero == (channels > 2))
        var out = converter.convert(input)
        out += converter.convert(buffer(rate: rate, channels: AVAudioChannelCount(channels), seconds: 0.5))
        // ~1 s at 16 kHz, give or take the resampler's history.
        #expect(abs(out.count - 16_000) < 600, "\(rate) Hz × \(channels) ch → \(out.count) samples")
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Float(max(1, out.count))).squareRoot()
        #expect(rms > 0.1, "channel 0 survives (not downmixed to silence): rms \(rms)")
    }

    @Test func aRenegotiatedRateRebuildsTheConverter() {
        let source = VoiceProcessingCaptureSource()
        let a = source.converter(matching: buffer(rate: 48_000, channels: 5, seconds: 0.1).format)
        #expect(source.converter(matching: buffer(rate: 48_000, channels: 5, seconds: 0.1).format) === a)
        let b = source.converter(matching: buffer(rate: 44_100, channels: 5, seconds: 0.1).format)
        #expect(b !== a && b.inputFormat.sampleRate == 44_100)
    }

    @Test func tapFormatPrefersHardwareThenCached() {
        let hw = Self.format(rate: 48_000, channels: 5)
        let cached = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        #expect(VoiceProcessingCaptureSource.tapFormat(hardware: hw, cached: cached) === hw)
        let empty = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let zero = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false) ?? empty
        if zero.sampleRate == 0 {
            #expect(VoiceProcessingCaptureSource.tapFormat(hardware: zero, cached: cached) === cached)
        }
    }
}
