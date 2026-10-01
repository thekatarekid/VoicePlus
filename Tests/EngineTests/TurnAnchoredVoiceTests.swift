import Foundation
import Testing
@testable import Engine
@testable import Shared

// V5 K4 — turn-anchored voice: the first 500 ms of speech after key-down is the user for this turn;
// later segments below the anchor-length threshold (0.35 → 0.6 as the anchor grows to 4 s) are
// dropped (hold) or routed to Notes (latch); confirmed latch segments re-anchor.

/// Stand-in for WeSpeaker: a "voice" is the pitch of a tone. Low (< 300 Hz zero-crossing pitch) and
/// high voices embed to vectors with cosine ≈ 0.2; the same voice embeds identically.
private final class PitchEmbedder: SpeakerEmbedder, @unchecked Sendable {
    let name = "pitch-mock"
    let dimension = 2
    let identifiesSpeakers: Bool
    var calls = 0
    var failing = false
    init(identifies: Bool = true) { identifiesSpeakers = identifies }
    func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
        calls += 1
        if failing { throw SpeakerError.backendUnavailable }
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        let hz = Double(crossings) / 2 / (Double(samples.count) / 16_000)
        return SpeakerEmbedding(vector: hz < 300 ? [1, 0.1] : [0.1, 1], embedder: name)
    }
}

private func voice(_ hz: Double, _ seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { Float(0.3 * sin(2 * .pi * hz * Double($0) / 16_000)) }
}

@Suite struct TurnAnchoredVoiceTests {
    @Test func holdDropsASecondVoice() {
        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder(), mode: .hold)
        let verdicts = k4.filter([voice(150, 0.8), voice(150, 0.6), voice(450, 0.9), voice(150, 0.5)])
        #expect(verdicts.map(\.keeps) == [true, true, false, true])
        guard case .drop(let s) = verdicts[2] else { Issue.record("expected drop, got \(verdicts[2])"); return }
        #expect(s < 0.6)
        #expect(verdicts[2].diagnosticsReason == "k4.voice.other.drop")
    }

    @Test func latchRoutesASecondVoiceToNotes() {
        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder(), mode: .latch)
        k4.beginTurn()
        k4.noteSpeech(voice(150, 0.5))
        #expect(k4.anchor != nil, "500 ms of speech fixes the anchor")
        let v = k4.evaluate(voice(450, 1))
        guard case .routeToNotes = v else { Issue.record("expected Notes, got \(v)"); return }
        #expect(v.diagnosticsReason == "k4.voice.other.notes")
        #expect(k4.evaluate(voice(150, 1)).keeps)
    }

    @Test func anchorIsTheFirst300To500Milliseconds() {
        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder())
        k4.beginTurn()
        // 500 ms of the user, then another voice in the same buffer: only the first 500 ms anchor.
        k4.noteSpeech(voice(150, 0.5) + voice(450, 1))
        #expect(k4.evaluate(voice(150, 0.6)).keeps)
        #expect(!k4.evaluate(voice(450, 0.6)).keeps)

        // Under 500 ms of speech before release: no anchor (300 ms does not separate voices),
        // nothing judged, nothing lost.
        k4.beginTurn()
        k4.noteSpeech(voice(150, 0.3))
        #expect(k4.anchor == nil, "not fixed until 500 ms")
        k4.closeAnchor()
        #expect(k4.anchor == nil)
        #expect(k4.evaluate(voice(450, 1)) == .unjudged(.noAnchor))

        // Spread over several segments, 500 ms in total is an anchor.
        k4.beginTurn()
        k4.noteSpeech(voice(150, 0.3))
        k4.noteSpeech(voice(150, 0.3))
        #expect(k4.anchor != nil && abs(k4.anchorSeconds - 0.5) < 1e-9)
    }

    @Test func thresholdStepsWithAnchorLength() {
        let c = TurnAnchoredVoice.Config()
        #expect(c.threshold(forAnchorSeconds: 0.5) == 0.35)
        #expect(c.threshold(forAnchorSeconds: 1.5) == 0.4)
        #expect(c.threshold(forAnchorSeconds: 3) == 0.5)
        #expect(c.threshold(forAnchorSeconds: 4) == 0.6)
    }

    @Test func keptSegmentsGrowTheAnchorToFourSeconds() {
        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder())
        k4.beginTurn(); k4.noteSpeech(voice(150, 0.5))
        #expect(k4.currentThreshold == 0.35)
        #expect(!k4.evaluate(voice(450, 1)).keeps)
        #expect(abs(k4.anchorSeconds - 0.5) < 1e-9, "a rejected voice never feeds the anchor")
        #expect(k4.evaluate(voice(150, 1)).keeps)
        #expect(abs(k4.anchorSeconds - 1.5) < 1e-9)
        for _ in 0..<4 { _ = k4.evaluate(voice(150, 1)) }
        #expect(abs(k4.anchorSeconds - 4) < 1e-9, "capped at 4 s")
        #expect(k4.currentThreshold == 0.6)
        k4.beginTurn()
        #expect(k4.anchorSeconds == 0, "forgotten at the next key-down")
    }

    @Test func eachKeyDownReanchors() {
        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder())
        k4.beginTurn(); k4.noteSpeech(voice(150, 0.5))
        #expect(!k4.evaluate(voice(450, 0.5)).keeps)
        // Next turn, someone else holds the key: they are the user now.
        k4.beginTurn(); k4.noteSpeech(voice(450, 0.5))
        #expect(k4.evaluate(voice(450, 0.5)).keeps)
        #expect(!k4.evaluate(voice(150, 0.5)).keeps)
    }

    @Test func confirmedLatchSegmentReanchors() {
        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder(), mode: .latch)
        k4.beginTurn(); k4.noteSpeech(voice(150, 0.5))
        #expect(!k4.evaluate(voice(450, 0.5)).keeps)
        #expect(k4.reanchor(onConfirmed: voice(450, 0.6)))
        #expect(k4.reanchorCount == 1)
        #expect(k4.evaluate(voice(450, 0.5)).keeps)
        #expect(!k4.reanchor(onConfirmed: voice(450, 0.1)), "too short to anchor on")
        #expect(k4.reanchorCount == 1)
    }

    @Test func honestWhenItCannotTell() {
        // MFCC fallback: identifiesSpeakers == false → never judges, never embeds.
        let mfcc = PitchEmbedder(identifies: false)
        let off = TurnAnchoredVoice(embedder: mfcc)
        #expect(off.filter([voice(150, 0.6), voice(450, 0.6)]).allSatisfy { $0 == .unjudged(.embedderCannotIdentify) })
        #expect(mfcc.calls == 0)

        let k4 = TurnAnchoredVoice(embedder: PitchEmbedder())
        k4.beginTurn(); k4.noteSpeech(voice(150, 0.5))
        #expect(k4.evaluate(voice(450, 0.1)) == .unjudged(.segmentTooShort))

        let failing = PitchEmbedder()
        let f = TurnAnchoredVoice(embedder: failing)
        f.beginTurn(); f.noteSpeech(voice(150, 0.5))
        failing.failing = true
        let v = f.evaluate(voice(450, 1))
        #expect(v == .unjudged(.embeddingFailed) && v.keeps)
    }

    /// Two real voices through WeSpeaker, when its weights are on this Mac (FluidAudio cache or our
    /// install). The V5 doc names an AMI clip; the repo carries no AMI audio (no download > 500 MB, no
    /// corpus fetch in tests), so the two-speaker fixture is two `say` voices from `Fixtures/audio/clean`.
    @Test func realWeSpeakerRejectsTheSecondVoice() throws {
        guard let embedder = FluidSpeakerEmbedder.loadIfAvailable() else { return }   // → T1 without weights
        let dir = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/clean")
        let user = try WAVFile.read(url: dir.appendingPathComponent("clean_01_samantha.wav")).mono
        let userAgain = try WAVFile.read(url: dir.appendingPathComponent("clean_04_samantha.wav")).mono
        let other = try WAVFile.read(url: dir.appendingPathComponent("clean_02_daniel.wav")).mono
        let third = try WAVFile.read(url: dir.appendingPathComponent("clean_03_rishi.wav")).mono
        let k4 = TurnAnchoredVoice(embedder: embedder, mode: .hold)
        k4.beginTurn()
        k4.noteSpeech(user)                     // first 500 ms of the user's speech
        let second = k4.evaluate(other)
        #expect(!second.keeps, "second voice rejected on the 500 ms anchor: \(second)")
        let same = k4.evaluate(userAgain)
        #expect(same.keeps, "the user's own later speech is kept: \(same)")
        #expect(k4.anchorSeconds > 0.5, "and grows the anchor")
        #expect(!k4.evaluate(third).keeps, "a third voice against the grown anchor")
        #expect(!k4.evaluate(other).keeps)
    }
}
