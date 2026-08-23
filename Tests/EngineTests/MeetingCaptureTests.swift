import Foundation
import Testing
@testable import Engine
@testable import Shared

/// Dual capture + AEC + chunking + diarization labels on fixture audio split across two legs.
@Suite struct MeetingCaptureTests {
    /// mic = clean_01 then silence; system = silence then clean_02 (two people taking turns).
    static func twoChannelFixture() throws -> (mic: WAVFile, system: WAVFile, split: TimeInterval) {
        let a = try WAVFile.read(url: try #require(AudioFixtures.url("clean", "clean_01_samantha.wav"))).mono
        let b = try WAVFile.read(url: try #require(AudioFixtures.url("clean", "clean_02_daniel.wav"))).mono
        let gap = [Float](repeating: 0, count: 16_000)   // 1 s between turns
        let mic = a + gap + [Float](repeating: 0, count: b.count)
        let sys = [Float](repeating: 0, count: a.count) + gap + b
        return (WAVFile(sampleRate: 16_000, samples: mic), WAVFile(sampleRate: 16_000, samples: sys), Double(a.count + gap.count) / 16_000)
    }

    @Test func chunksAreCutPerChannelAndLabeledByChannel() async throws {
        let fx = try Self.twoChannelFixture()
        let mic = FixtureCaptureSource(wav: fx.mic)
        let sys = FixtureCaptureSource(wav: fx.system)
        let capture = DualCapture(mic: mic, system: sys, micVAD: EnergyVAD(), systemVAD: EnergyVAD(), aec: PassthroughEchoCanceller())
        try await capture.start()          // fixture sources replay synchronously
        let chunks = try await capture.stop()
        #expect(!chunks.isEmpty)
        let micChunks = chunks.filter { $0.channel == .mic }
        let sysChunks = chunks.filter { $0.channel == .system }
        #expect(!micChunks.isEmpty && !sysChunks.isEmpty)
        for c in chunks {
            #expect(c.chunk.duration <= 5.0 + 0.05, "chunk too long: \(c.chunk.duration)")
            #expect(c.chunk.reason == .flush || c.chunk.duration >= 3.0 - 0.05, "short non-flush chunk \(c.chunk.duration)")
        }
        // Silent halves are dropped: mic speech lives before the split, system speech after.
        #expect(micChunks.allSatisfy { $0.range.lowerBound < fx.split })
        #expect(sysChunks.allSatisfy { $0.range.upperBound > fx.split - 1 })
        // Sorted on the shared meeting clock.
        #expect(chunks.map(\.range.lowerBound) == chunks.map(\.range.lowerBound).sorted())

        let labeled = try await ChannelLabeler().label(chunks)
        #expect(labeled.filter { $0.chunk.channel == .mic }.allSatisfy { $0.speaker == .you })
        #expect(labeled.filter { $0.chunk.channel == .system }.allSatisfy { $0.speaker == .others(1) })
        #expect(MeetingSpeaker.others(1).label == "Others" && MeetingSpeaker.others(2).label == "Others 2")
    }

    @Test func embeddingLabelerUsesEnrolledUserAndClustersOthers() async throws {
        final class FakeEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
            // Embedding = direction chosen by the chunk's mean level sign → deterministic fake voices.
            func embedding(for samples: [Float]) throws -> [Float] {
                let mean = samples.reduce(0, +) / Float(max(1, samples.count))
                return mean >= 0 ? [1, 0, 0] : [0, 1, 0]
            }
        }
        func chunk(_ ch: MeetingChannel, level: Float, at t: TimeInterval) -> MeetingChunk {
            MeetingChunk(channel: ch, chunk: AudioChunk(samples: [Float](repeating: level, count: 160), range: t...(t + 0.01), reason: .speechEnd))
        }
        let labeler = EmbeddingLabeler(backend: FakeEmbedding(), enrolled: [1, 0, 0])
        let out = try await labeler.label([
            chunk(.mic, level: 0.1, at: 0),      // matches enrolled → You
            chunk(.mic, level: -0.1, at: 1),     // someone else at the laptop → Others
            chunk(.system, level: 0.1, at: 2),   // remote speaker 1
            chunk(.system, level: -0.1, at: 3),  // remote speaker 2
            chunk(.system, level: 0.1, at: 4),   // remote speaker 1 again
        ])
        #expect(out.map(\.speaker) == [.you, .others(1), .others(1), .others(2), .others(1)])
        #expect(EmbeddingMatch.cosine([1, 0], [1, 0]) == 1)
        #expect(abs(EmbeddingMatch.cosine([1, 0], [0, 1])) < 1e-6)
    }

    @Test func nlmsCancelsLinearEcho() {
        var rng = SystemRandomNumberGenerator()
        let n = 32_000
        let reference = (0..<n).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        // Echo: attenuated reference through a 2-tap path with a 12-sample delay.
        var mic = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i >= 12 { mic[i] += 0.5 * reference[i - 12] }
            if i >= 13 { mic[i] += 0.2 * reference[i - 13] }
        }
        let aec = NLMSEchoCanceller(taps: 64, stepSize: 0.5)
        let out = aec.process(mic: mic, reference: reference)
        #expect(out.count == n)
        let tail = (n - 4000)..<n
        let before = tail.reduce(Float(0)) { $0 + mic[$1] * mic[$1] }
        let after = tail.reduce(Float(0)) { $0 + out[$1] * out[$1] }
        #expect(after < before * 0.05, "residual \(after / before)")
        // Passthrough when reference is shorter.
        #expect(PassthroughEchoCanceller().process(mic: [1, 2], reference: []) == [1, 2])
    }

    @Test func dualCaptureAppliesAECToMicLeg() async throws {
        let n = 16_000 * 2
        let ref = (0..<n).map { Float(sin(Double($0) * 0.05)) * 0.4 }
        let mic = ref.map { $0 * 0.6 }   // pure echo, nobody talking at the mic
        let micSrc = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: mic))
        let sysSrc = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: ref))
        var opts = DualCapture.Options(); opts.dropSilentChunks = false
        let capture = DualCapture(mic: micSrc, system: sysSrc, micVAD: EnergyVAD(), systemVAD: EnergyVAD(), aec: NLMSEchoCanceller(taps: 32), options: opts)
        try await capture.start()
        let chunks = try await capture.stop()
        let micTail = try #require(chunks.last { $0.channel == .mic })
        let sysTail = try #require(chunks.last { $0.channel == .system })
        func rms(_ s: [Float]) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(max(1, s.count))).squareRoot() }
        #expect(rms(micTail.chunk.samples) < rms(sysTail.chunk.samples) * 0.2, "echo not cancelled")
        #expect(capture.delivered[.mic] == n && capture.delivered[.system] == n)
    }
}
