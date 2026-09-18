import Foundation
import Testing
@testable import Engine
@testable import Shared

private func noisyFixtures() -> [URL] { AudioFixtures.list("noisy") }

@Suite struct RobustnessNoiseSuppressionTests {
    @Test func snrImprovesOnEveryNoisyFixture() throws {
        let files = noisyFixtures()
        try #require(!files.isEmpty, "Fixtures/audio/noisy missing")
        var improved = 0
        for url in files {
            let wav = try WAVFile.read(url: url)
            let raw = wav.mono
            let ns = SpectralGateNoiseSuppressor(strength: 0.6)
            var out = ns.process(raw)
            out.append(contentsOf: ns.flush())
            #expect(out.count >= raw.count - SpectralGateNoiseSuppressor.fftSize, "\(url.lastPathComponent) dropped samples")
            let before = SNREstimate.percentileSNR(raw)
            let after = SNREstimate.percentileSNR(Array(out.prefix(raw.count)))
            if after > before { improved += 1 }
            #expect(after > before, "\(url.lastPathComponent): \(before) dB -> \(after) dB")
        }
        #expect(improved == files.count)
    }

    @Test func referenceSNRImprovesAgainstCleanSource() throws {
        // Mixed file = clean + noise, aligned; true SNR vs the clean source must go up.
        let noisy = try #require(AudioFixtures.url("noisy", "clean_02_daniel_snr00db_white.wav"))
        let clean = try #require(AudioFixtures.url("clean", "clean_02_daniel.wav"))
        let x = try WAVFile.read(url: noisy).mono
        let ref = try WAVFile.read(url: clean).mono
        let ns = SpectralGateNoiseSuppressor(strength: 0.6)
        // Streaming in 100 ms blocks, as the capture thread would. Output is sample-aligned with input
        // (the overlap-add emits each hop in place; the one-hop algorithmic latency is internal buffering).
        var out: [Float] = []
        var i = 0
        while i < x.count { let e = min(i + 1600, x.count); out.append(contentsOf: ns.process(Array(x[i..<e]))); i = e }
        out.append(contentsOf: ns.flush())
        let aligned = Array(out.prefix(x.count))
        let before = SNREstimate.referenceSNR(x, reference: ref)
        let after = SNREstimate.referenceSNR(aligned, reference: ref)
        #expect(after > before + 4, "reference SNR \(before) -> \(after)")
    }

    @Test func streamingMatchesOneShot() {
        let x = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.3 + Float.random(in: -0.05...0.05) }
        let a = SpectralGateNoiseSuppressor(); let b = SpectralGateNoiseSuppressor()
        var one = a.process(x); one.append(contentsOf: a.flush())
        var stream: [Float] = []
        var i = 0
        while i < x.count { let e = min(i + 777, x.count); stream.append(contentsOf: b.process(Array(x[i..<e]))); i = e }
        stream.append(contentsOf: b.flush())
        #expect(one.count == stream.count)
        for (p, q) in zip(one, stream) { #expect(abs(p - q) < 1e-5) }
    }

    @Test func latencyUnder20msPer100msChunk() {
        let ns = SpectralGateNoiseSuppressor()
        let chunk = (0..<1600).map { _ in Float.random(in: -0.3...0.3) }
        _ = ns.process(chunk) // warm caches
        let iterations = 50
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { _ = ns.process(chunk) }
        let perChunkMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(iterations)
        #expect(perChunkMs < 20, "NS took \(perChunkMs) ms per 100 ms chunk")
    }

    @Test func profileTogglesStage() {
        let on = AcousticChain(profile: RobustnessProfile(noiseSuppression: true))
        let off = AcousticChain(profile: .raw)
        #expect(on.stages.contains { $0.name == "spectral-gate-ns" })
        #expect(off.stages.isEmpty)
        let x: [Float] = Array(repeating: 0.1, count: 4000)
        #expect(off.process(x) == x)
    }
}

@Suite struct RobustnessAECTests {
    final class FakeBackend: NeuralAECBackend {
        var calls = 0
        func process(_ samples: [Float]) -> [Float] { calls += 1; return samples.map { $0 * 0.5 } }
        func reset() {}
    }

    @Test func slotsPassThroughWithoutWeightsAndSelectorPrefersLocalVQE() {
        let vqe = LocalVQEAEC(weightsURL: URL(fileURLWithPath: "/nonexistent/localvqe.gguf"))
        let dtln = DTLNAEC()
        #expect(!vqe.isAvailable && !vqe.weightsPresent && !dtln.isAvailable)
        #expect(AECSelector.select(localVQE: vqe, dtln: dtln) == nil)
        let x: [Float] = [0.1, 0.2, 0.3]
        #expect(vqe.process(x) == x)
        dtln.backend = FakeBackend()
        #expect(AECSelector.select(localVQE: vqe, dtln: dtln)?.name == "dtln-aec")
        vqe.backend = FakeBackend()
        #expect(AECSelector.select(localVQE: vqe, dtln: dtln)?.name == "localvqe-aec")
        #expect(vqe.process(x) == [0.05, 0.1, 0.15])
    }

    @Test func chainSkipsUnavailableNeuralSlot() {
        let chain = AcousticChain(profile: RobustnessProfile(noiseSuppression: false, aec: .neural), aec: DTLNAEC())
        #expect(chain.stages.count == 1 && !chain.isAvailable)
        let x: [Float] = Array(repeating: 0.2, count: 1000)
        #expect(chain.process(x) == x)
    }

    @Test func appleVoiceProcessingIsSupportedOnTarget() {
        #expect(AppleVoiceProcessing.isSupported)
    }
}

@Suite struct RobustnessBluetoothTests {
    private func dev(_ name: String, _ t: AudioDeviceInfo.Transport, rate: Double, ch: Int = 1) -> AudioDeviceInfo {
        AudioDeviceInfo(id: 7, uid: "uid-\(name)", name: name, transport: t, sampleRate: rate, inputChannels: ch)
    }

    @Test func classifiesMockedDevices() {
        #expect(BluetoothInputDetector.mode(for: dev("AirPods Pro", .bluetooth, rate: 8_000)) == .scoNarrowband)
        #expect(BluetoothInputDetector.mode(for: dev("AirPods Pro", .bluetooth, rate: 16_000)) == .scoWideband)
        #expect(BluetoothInputDetector.mode(for: dev("AirPods Pro", .bluetooth, rate: 24_000)) == .highQuality)
        #expect(BluetoothInputDetector.mode(for: dev("AirPods Pro", .bluetooth, rate: 48_000)) == .highQuality)
        #expect(BluetoothInputDetector.mode(for: dev("WH-1000XM5", .bluetooth, rate: 44_100, ch: 0)) == .noInput)
        #expect(BluetoothInputDetector.mode(for: dev("MacBook Pro Microphone", .builtIn, rate: 48_000)) == .notBluetooth)
        #expect(BluetoothInputDetector.mode(for: dev("Scarlett", .usb, rate: 8_000)) == .notBluetooth)
    }

    @Test func lowQualityModePublishesWarningMicQuality() {
        let a = try! #require(BluetoothInputDetector.assess(dev("Aditya's AirPods", .bluetooth, rate: 8_000)))
        #expect(a.isLowQuality)
        #expect(a.micQuality?.verdict == .poor)
        #expect(a.warning?.contains("AirPods in low-quality mode") == true)
        let good = try! #require(BluetoothInputDetector.assess(dev("MacBook Pro Microphone", .builtIn, rate: 48_000)))
        #expect(!good.isLowQuality && good.micQuality == nil && good.warning == nil)
        #expect(BluetoothInputDetector.assess(nil) == nil)
    }

    @Test func prerollKeepsFirstWordAcrossPrewarmToStart() throws {
        // Inner "device" starts streaming at `beginPreroll()` (as SCO does, slowly); what arrives
        // before start() must still reach the sink, newest `prerollSeconds` first. (V4.7: plain
        // `prewarm()` no longer opens the microphone, so the pre-roll is asked for explicitly.)
        let speech = (0..<8000).map { Float($0) / 8000 }        // 0.5 s ramp, identifiable
        let inner = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []),
                                         device: dev("AirPods", .bluetooth, rate: 16_000))
        let src = AcousticCaptureSource(wrapping: inner, profile: RobustnessProfile(noiseSuppression: false, aec: .off, prerollSeconds: 0.3))
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }
        try src.beginPreroll()
        #expect(src.bluetooth?.mode == .scoWideband)
        inner.push(speech)                                      // arrives while pre-rolling
        #expect(received.isEmpty)
        try src.start()
        #expect(src.prerollFlushed == 4800)
        #expect(received.count == 4800)
        #expect(received.first == speech[8000 - 4800])
        inner.push([1, 2, 3])
        #expect(received.suffix(3) == [1, 2, 3])
        src.stop()
    }

    @Test func wrapperRunsNSAndFlushesOnStop() throws {
        let url = try #require(AudioFixtures.url("noisy", "clean_03_rishi_snr10db_pink.wav"))
        let wav = try WAVFile.read(url: url)
        let inner = FixtureCaptureSource(wav: wav)
        let src = AcousticCaptureSource(wrapping: inner, profile: RobustnessProfile(noiseSuppression: true, aec: .off, prerollSeconds: 0))
        var received: [Float] = []
        src.sink = { received.append(contentsOf: $0) }
        try src.start()
        src.stop()
        #expect(received.count >= wav.mono.count)
        #expect(SNREstimate.percentileSNR(Array(received.prefix(wav.mono.count))) > SNREstimate.percentileSNR(wav.mono))
    }
}
