import Foundation
import Shared
import Testing
@testable import Engine

@Suite("Speaker embedding + enrollment + gate (P5.3)")
struct SpeakerEmbeddingTests {
    /// Synthetic "voice": harmonic series with a vibrato'd F0, a fixed per-voice spectral envelope
    /// (formant-ish `tilt`), and noise. Same (f, tilt) = same voice; `seed` = a different utterance.
    static func voice(_ f: Float, tilt: Float = 1, seconds: Float = 1.5, seed: UInt64 = 1) -> [Float] {
        var rng = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func rand() -> Float { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Float(rng % 10_000) / 5_000 - 1 }
        let n = Int(16_000 * seconds)
        let vib = 3 + abs(rand()) * 3, phase = rand() * .pi
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / 16_000
            let f0 = f * (1 + 0.015 * sin(2 * .pi * vib * t + phase) + 0.03 * sin(2 * .pi * 0.7 * t + phase))
            var s: Float = 0
            for h in 1...12 { s += sin(2 * .pi * f0 * Float(h) * t) * pow(Float(h), -tilt) * (h % 3 == 0 ? 1.8 : 1) }
            out[i] = s * 0.15 * (0.85 + 0.15 * sin(2 * .pi * 2.5 * t + phase)) + rand() * 0.003
        }
        return out
    }
    static func tone(_ f: Float, seconds: Float = 1.5, harmonics: Int = 5, seed: Float = 0) -> [Float] {
        voice(f, tilt: Float(harmonics) / 4, seconds: seconds, seed: UInt64(seed * 100) + 7)
    }

    @Test func embeddingIsUnitNormAndDeterministic() throws {
        let e = MFCCEmbedder()
        let a = try e.embed(Self.tone(140))
        let b = try e.embed(Self.tone(140))
        #expect(a.vector.count == e.dimension * 2 && a.dimension == e.dimension && a.metric == .gaussian)
        #expect(a.similarity(b) > 0.999)
        #expect(a.similarity(try e.embed(Self.tone(480, harmonics: 2))) < 0.5)
        // Gain-invariant: same voice at half level is still the same voice.
        #expect(a.similarity(try e.embed(Self.tone(140).map { $0 * 0.5 })) > 0.9)
        // Cosine metric normalises; metrics never compare across kinds.
        let u = SpeakerEmbedding(vector: [3, 4], embedder: "c")
        #expect(u.vector == [0.6, 0.8] && u.similarity(a) == 0)
    }

    @Test func tooShortThrows() {
        #expect(throws: SpeakerError.tooShort(samples: 100)) { try MFCCEmbedder().embed([Float](repeating: 0.1, count: 100)) }
    }

    @Test func centroidAndMelBank() {
        let a = SpeakerEmbedding(vector: [1, 0], embedder: "t"), b = SpeakerEmbedding(vector: [0, 1], embedder: "t")
        let c = try! #require(SpeakerEmbedding.centroid([a, b]))
        #expect(abs(c.cosine(a) - 0.7071) < 1e-3)
        let g1 = SpeakerEmbedding(vector: [0, 1], embedder: "g", metric: .gaussian)
        let g2 = SpeakerEmbedding(vector: [2, 1], embedder: "g", metric: .gaussian)
        let gc = try! #require(SpeakerEmbedding.centroid([g1, g2]))
        #expect(gc.vector == [1, 1] && g1.similarity(g1) == 1 && g1.similarity(g2) < 0.1)
        #expect(g1.blended(with: g2, weight: 0.5).vector == [1, 1])
        #expect(SpeakerEmbedding.centroid([a, SpeakerEmbedding(vector: [1, 2, 3], embedder: "t")]) == nil)
        let fb = MFCCEmbedder.melFilterBank(filters: 26, fftSize: 512, sampleRate: 16_000)
        #expect(fb.count == 26 && fb.allSatisfy { $0.max() == 1 })
    }

    @Test func enrollmentThreeUtterancesToCentroid() throws {
        let emb = MFCCEmbedder()
        var enr = SpeakerEnrollment()
        #expect(enr.currentPrompt == SpeakerEnrollment.prompts[0])
        let u = [Self.tone(130), Self.tone(132, seed: 0.3), Self.tone(128, seed: 1.1)].map { try! emb.embed($0) }
        #expect(enr.record(u[0]) == .accepted(1))
        // A very different voice mid-enrollment is rejected, not averaged in.
        let other = try emb.embed(Self.voice(620, tilt: 0.2, seed: 99))
        let o = enr.record(other)
        if case .inconsistent = o {} else { Issue.record("expected inconsistent, got \(o) sim=\(u[0].similarity(other))") }
        #expect(enr.record(u[1]) == .accepted(2))
        #expect(enr.record(u[2]) == .complete)
        #expect(enr.step == .done && enr.record(u[2]) == .complete)
        let p = try #require(enr.profile)
        #expect(p.utteranceCount == 3 && p.centroid.dimension == emb.dimension)

        // Persistence round-trip (JSON, no audio).
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID()).json")
        try p.save(to: url)
        #expect(try SpeakerProfile.load(from: url) == p)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func gateVerdictsAndHandsFreePolicy() throws {
        let emb = MFCCEmbedder()
        var enr = SpeakerEnrollment()
        for s in [Float](arrayLiteral: 0, 0.4, 0.9) { enr.record(try emb.embed(Self.tone(130, seed: s))) }
        var profile = try #require(enr.profile)
        var gate = SpeakerGate(profile: profile, threshold: 0.5)
        let me = try emb.embed(Self.tone(131, seed: 2))
        let tv = try emb.embed(Self.tone(700, harmonics: 1))
        #expect(gate.verdict(for: me).isUser)
        #expect(!gate.verdict(for: tv).isUser)
        #expect(gate.shouldAccept(.other(similarity: 0), handsFree: false))
        #expect(!gate.shouldAccept(.other(similarity: 0), handsFree: true))
        #expect(gate.shouldAccept(.unknown, handsFree: true))
        #expect(SpeakerGate(profile: nil).verdict(for: me) == .unknown)
        #expect(gate.verdict(for: [Float](repeating: 0, count: 10), embedder: emb) == .unknown)

        // "Not you" negative vetoes a near-duplicate of itself even above threshold.
        let impostor = try emb.embed(Self.tone(134, seed: 0.2))
        #expect(gate.verdict(for: impostor).isUser)
        profile.addNegative(impostor)
        gate.profile = profile
        #expect(!gate.verdict(for: impostor).isUser)
        profile.reinforce(me)
        #expect(profile.utteranceCount == 4)
        #expect(SpeakerGate.defaultThreshold(for: emb) == 0.5)
    }

    @Test func fluidEmbedderOnlyWhenModelsPresent() throws {
        guard FluidSpeakerEmbedder.isAvailable, let f = FluidSpeakerEmbedder.loadIfAvailable() else {
            #expect(SpeakerEmbedderFactory.make() is MFCCEmbedder)
            return
        }
        let dir = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/clean")
        let a = try f.embed(WAVFile.read(url: dir.appendingPathComponent("clean_01_samantha.wav")).mono)
        let b = try f.embed(WAVFile.read(url: dir.appendingPathComponent("clean_04_samantha.wav")).mono)
        let c = try f.embed(WAVFile.read(url: dir.appendingPathComponent("clean_02_daniel.wav")).mono)
        #expect(a.vector.count == f.dimension && a.cosine(b) > a.cosine(c))
    }
}
