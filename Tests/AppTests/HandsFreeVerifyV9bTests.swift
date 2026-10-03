import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Verification of the hands-free fixes against the owner's own recordings (2026-10-04):
/// * the speaker check's voiced part must drop a real room, not just digital silence — the MacBook
///   mic's quiet room sits at −49…−45 dBFS, which "24 dB under the peak" kept in full;
/// * a sentence end confirmed during the voice detector's hangover still lands the piece.
@Suite("Hands-free verification (voiced room, sentence end in hangover)")
struct HandsFreeVerifyV9bTests {
    static func seg(_ i: Int) -> SegmentID { SegmentID(sessionID: session, index: i) }
    static let session = UUID()

    /// Deterministic room noise at about `dBFS`.
    static func room(seconds: Double, dBFS: Float = -47) -> [Float] {
        var g = SystemRandomNumberGenerator()
        let a = powf(10, dBFS / 20) * 1.732   // uniform noise: rms = a / √3
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -a...a, using: &g) }
    }
    static func voice(seconds: Double, dBFS: Float = -30) -> [Float] {
        let a = powf(10, dBFS / 20) * 1.414
        return (0..<Int(seconds * 16_000)).map { a * sin(Float($0) * 2 * .pi * 180 / 16_000) }
    }

    @Test("a long segment of room tone around a little speech keeps only the speech")
    func voicedDropsARealRoom() {
        let audio = Self.room(seconds: 30) + Self.voice(seconds: 3) + Self.room(seconds: 10)
        let kept = Double(SpeakerSegmentAudio.voiced(audio).count) / 16_000
        #expect(kept >= 2.9 && kept <= 3.3, "\(kept) s kept of 43 s")
    }

    @Test("a segment that is nearly all speech keeps its speech")
    func voicedKeepsSpeech() {
        let audio = Self.room(seconds: 0.5) + Self.voice(seconds: 6) + Self.room(seconds: 0.5)
        let kept = Double(SpeakerSegmentAudio.voiced(audio).count) / 16_000
        #expect(kept >= 5.9, "\(kept) s kept")
    }

    static func latched() -> LatchRuntime {
        let runtime = LatchRuntime(delivery: HandsFreeLandingFixTests.Spy())
        runtime.isLatched = { true }
        runtime.feedQueue = { $0() }
        runtime.handle(.opened(Self.seg(0)))
        return runtime
    }

    @Test("a sentence end heard during the hangover lands on that speech end, once")
    func sentenceEndInHangover() {
        let runtime = Self.latched()
        runtime.noteVAD(.speechStart(at: 0.2))
        runtime.tick(at: 1.5)
        runtime.handle(.endOfUtterance(segment: Self.seg(0)))
        #expect(runtime.endpointClosures == 0, "still in speech")
        runtime.noteVAD(.speechEnd(at: 1.2))
        #expect(runtime.sentenceEndClosures == 1)
        #expect(runtime.endpointClosures == 1)
        runtime.noteVAD(.speechStart(at: 2.0))
        runtime.noteVAD(.speechEnd(at: 2.5))
        #expect(runtime.endpointClosures == 1, "the held sentence end is spent")
    }

    @Test("speech that ends after the sentence end arrived is new speech: it waits for its pause")
    func sentenceEndThenMoreSpeech() {
        let runtime = Self.latched()
        runtime.noteVAD(.speechStart(at: 0.2))
        runtime.tick(at: 1.5)
        runtime.handle(.endOfUtterance(segment: Self.seg(0)))
        runtime.noteVAD(.speechEnd(at: 4.0))
        #expect(runtime.endpointClosures == 0)
        #expect(runtime.sentenceEndClosures == 0)
    }
}
