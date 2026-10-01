import Foundation
import Testing
@testable import Lab

/// V5 V3 — noise mixing: exact SNR, determinism, tags, the noisy-set builder and `lab mix`.
@Suite("V3 noise mixing")
struct NoiseMixerTests {
    static func tone(_ n: Int, freq: Double = 220, amp: Float = 0.3) -> [Float] {
        (0..<n).map { amp * Float(sin(2 * .pi * freq * Double($0) / 16_000)) }
    }

    func measuredSNR(speech: [Float], mix: NoiseMixer.Mix) -> Double {
        // noise = mixed/outputGain − speech
        let noise = zip(mix.samples, speech).map { $0 / Float(mix.outputGain) - $1 }
        return 20 * log10(NoiseMixer.rms(speech) / NoiseMixer.rms(noise))
    }

    @Test(arguments: [20.0, 10, 5, 0])
    func achievesTargetSNR(_ snr: Double) {
        let speech = Self.tone(16_000)
        var rng = SeededRandom(seed: 1)
        let noise = NoiseMixer.pink(count: speech.count, rng: &rng)
        let m = NoiseMixer.mix(speech: speech, noise: noise, snrDB: snr)
        #expect(abs(m.achievedSNR - snr) < 1e-9)
        #expect(abs(measuredSNR(speech: speech, mix: m) - snr) < 0.05)
        #expect(m.samples.allSatisfy { abs($0) <= 0.99 + 1e-6 })
    }

    @Test func antiClipKeepsSNR() {
        let speech = Self.tone(8_000, amp: 0.95)
        var rng = SeededRandom(seed: 2)
        let m = NoiseMixer.mix(speech: speech, noise: NoiseMixer.white(count: speech.count, rng: &rng), snrDB: 0)
        #expect(m.outputGain < 1)
        #expect(abs(measuredSNR(speech: speech, mix: m) - 0) < 0.05)
    }

    @Test func deterministicPerItemNotPerOrder() {
        var a = NoiseMixer.rng(seed: 7, item: "x", source: .pink, snr: 10)
        var b = NoiseMixer.rng(seed: 7, item: "x", source: .pink, snr: 10)
        var c = NoiseMixer.rng(seed: 7, item: "y", source: .pink, snr: 10)
        #expect(NoiseMixer.pink(count: 64, rng: &a) == NoiseMixer.pink(count: 64, rng: &b))
        var a2 = NoiseMixer.rng(seed: 7, item: "x", source: .pink, snr: 10)
        #expect(NoiseMixer.pink(count: 64, rng: &a2) != NoiseMixer.pink(count: 64, rng: &c))
    }

    @Test func fitTilesShortAndOffsetsLong() {
        var rng = SeededRandom(seed: 3)
        #expect(NoiseMixer.fit([1, 2, 3], count: 7, rng: &rng) == [1, 2, 3, 1, 2, 3, 1])
        let long = (0..<100).map(Float.init)
        let part = NoiseMixer.fit(long, count: 10, rng: &rng)
        #expect(part.count == 10)
        #expect(zip(part.dropFirst(), part).allSatisfy { $0 - $1 == 1 })
    }

    @Test func pinkHasMoreLowThanHighEnergy() {
        var rng = SeededRandom(seed: 4)
        let p = NoiseMixer.pink(count: 32_000, rng: &rng)
        // crude: energy of first difference (high-pass) vs the signal; pink is low-heavy
        let diff = zip(p.dropFirst(), p).map { $0 - $1 }
        var w = SeededRandom(seed: 4)
        let white = NoiseMixer.white(count: 32_000, rng: &w)
        let wdiff = zip(white.dropFirst(), white).map { $0 - $1 }
        #expect(NoiseMixer.rms(diff) / NoiseMixer.rms(p) < NoiseMixer.rms(wdiff) / NoiseMixer.rms(white))
    }

    @Test func tags() {
        #expect(NoiseMixer.snrTag(10) == "snr-10")
        #expect(NoiseMixer.snrTag(-5) == "snr--5")
        #expect(NoiseSource.babble(talkers: 3).tag == "noise-babble")
        #expect(NoiseSource.recordings(name: "musan", files: []).tag == "noise-musan")
    }

    /// Three synthetic "speakers" on disk → builder writes clean + 2 noises × 2 SNRs, tagged.
    @Test func builderWritesTaggedNoisySet() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("v3-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("toy/audio", isDirectory: true)
        let items = (0..<3).map { i in EvalItem(id: "\(100 + i)-1-000\(i)", audio: "a\(i).wav", reference: "word \(i)", tags: ["clean-read"]) }
        for (i, item) in items.enumerated() { try EvalAudio.writeWAV(Self.tone(8_000, freq: 200 + Double(i) * 50), to: src.appendingPathComponent(item.audio!)) }
        let manifest = EvalManifest(set: "toy", audioRoot: "toy/audio", items: items)
        let paths = EvalPaths(cacheDirectory: tmp, fixturesDirectory: nil, resultsDirectory: tmp.appendingPathComponent("results"))
        let builder = NoisySetBuilder(paths: paths, snrs: [10, 0], sources: [.babble(talkers: 2), .pink], seed: 9, limit: 1)
        let noisy = try builder.build(from: manifest)
        #expect(noisy.set == "toy-noisy")
        #expect(noisy.items.count == 1 + 2 * 2)
        #expect(noisy.items.first?.tags == ["clean-read", "snr-clean"])
        let mixed = try #require(noisy.items.first { $0.id == "100-1-0000@babble-snr-0" })
        #expect(mixed.tags == ["clean-read", "snr-0", "noise-babble"])
        #expect(mixed.reference == "word 0")
        let url = try #require(paths.audioURL(mixed, manifest: noisy))
        let audio = try EvalAudio.load16k(url)
        #expect(audio.count == 8_000)
        // reloaded manifest equals the returned one, and a rebuild is byte-identical (deterministic)
        let onDisk = try paths.loadManifest(set: "toy-noisy")
        #expect(onDisk == noisy)
        let before = try Data(contentsOf: url)
        try builder.build(from: manifest)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func cliMix() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("v3cli-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let items = (0..<2).map { i in EvalItem(id: "\(i)-0-0", audio: "a\(i).wav", reference: "x") }
        for item in items { try EvalAudio.writeWAV(Self.tone(4_000), to: tmp.appendingPathComponent("toy/\(item.audio!)")) }
        let m = EvalManifest(set: "toy", audioRoot: "toy", items: items)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("toy"), withIntermediateDirectories: true)
        try JSONEncoder().encode(m).write(to: tmp.appendingPathComponent("toy/manifest.json"))
        let ev = PublicEval(paths: EvalPaths(cacheDirectory: tmp, fixturesDirectory: nil, resultsDirectory: tmp))
        let out = await LabCLI.main(["mix", "--set", "toy", "--snr", "5", "--noise", "white,pink"], eval: ev)
        #expect(out.exitCode == 0, "\(out.text)")
        #expect(try ev.paths.loadManifest(set: "toy-noisy").items.count == 2 * (1 + 2))
        let bad = await LabCLI.main(["mix", "--set", "toy", "--noise", "jazz"], eval: ev)
        #expect(bad.exitCode == 2)
    }
}

/// Opt-in: `VOICEPLUS_EVAL_MIX=librispeech-test-clean [VOICEPLUS_EVAL_LIMIT=50]` builds the noisy copy
/// in the eval cache (babble + pink × 20/10/5/0 dB + clean) for the real-model run.
@Suite("V3 noisy set (opt-in)", .serialized)
struct NoiseMixAcceptanceTests {
    @Test(.timeLimit(.minutes(30))) func mixIfRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let set = env["VOICEPLUS_EVAL_MIX"], !set.isEmpty else { return }
        var args = ["mix", "--set", set]
        if let n = env["VOICEPLUS_EVAL_LIMIT"] { args += ["--limit", n] }
        let out = await LabCLI.main(args)
        print(out.text)
        #expect(out.exitCode == 0)
    }
}

