import Engine
import Foundation
import Testing

/// V5 K2 — near-field level gate on synthetic two-level audio.
@Suite("Near-field level gate (K2)")
struct NearFieldGateTests {
    /// A voiced-ish signal: 180 Hz tone with a slow syllable envelope, peak `amp`.
    static func voice(_ seconds: Double, amp: Float, f0: Float = 180) -> [Float] {
        let n = Int(seconds * 16_000)
        return (0..<n).map { (i: Int) -> Float in
            let t = Float(i) / 16_000
            let env: Float = 0.75 + 0.25 * sin(2 * Float.pi * 4 * t)
            return amp * env * sin(2 * Float.pi * f0 * t)
        }
    }

    @Test("a far talker 16 dB under the anchor is dropped; the user's later segments are kept")
    func twoLevels() {
        let near = Self.voice(1.2, amp: 0.3)        // the user, first in the turn
        let far = Self.voice(0.8, amp: 0.05)        // ≈ 15.6 dB quieter
        let nearAgain = Self.voice(0.6, amp: 0.25)
        var gate = NearFieldGate()
        #expect(gate.filter([near, far, nearAgain]) == [0, 2])
        guard case .drop(let level, let anchor) = gate.evaluate(far) else { Issue.record("far talker kept"); return }
        #expect(anchor - level > 12 && anchor - level < 18)
    }

    @Test("a segment 6 dB down (user turned their head) is kept; the threshold is configurable")
    func thresholdAndConfig() {
        let near = Self.voice(1.0, amp: 0.3)
        let softer = Self.voice(0.5, amp: 0.15)     // −6 dB
        let far = Self.voice(0.5, amp: 0.05)
        var gate = NearFieldGate()
        #expect(gate.filter([near, softer, far]) == [0, 1])
        var lenient = NearFieldGate(config: .init(dropBelowDB: 20))
        #expect(lenient.filter([near, softer, far]) == [0, 1, 2])
        var strict = NearFieldGate(config: .init(dropBelowDB: 4))
        #expect(strict.filter([near, softer, far]) == [0])
    }

    @Test("a 20 ms click in the first second does not become the anchor (level must be held)")
    func clickIsNotAnchor() {
        var anchorAudio = Self.voice(1.0, amp: 0.1)
        for i in 8_000..<8_320 { anchorAudio[i] = 0.9 }          // one loud frame
        var gate = NearFieldGate()
        gate.noteSpeech(anchorAudio)
        let anchor = try! #require(gate.anchorDB)
        let voiceOnly = NearFieldGate.sustainedPeakDB(Self.voice(1.0, amp: 0.1))!
        #expect(abs(anchor - voiceOnly) < 1.5, "click lifted the anchor to \(anchor) dB")
        #expect(gate.evaluate(Self.voice(0.5, amp: 0.08)).keeps)
    }

    @Test("anchor is the first second of speech only; a later louder talker does not move it")
    func anchorFixedAfterWindow() {
        var gate = NearFieldGate()
        gate.beginTurn()
        gate.noteSpeech(Self.voice(0.5, amp: 0.2))
        #expect(gate.anchorDB == nil)
        gate.noteSpeech(Self.voice(0.7, amp: 0.2))
        let anchor = try! #require(gate.anchorDB)
        gate.noteSpeech(Self.voice(1.0, amp: 0.9))
        #expect(gate.anchorDB == anchor)
    }

    @Test("no anchor or too-short segment → unjudged and kept; short turns close the anchor early")
    func unjudged() {
        var gate = NearFieldGate()
        #expect(gate.evaluate(Self.voice(0.5, amp: 0.01)) == .unjudged)
        gate.noteSpeech(Self.voice(0.4, amp: 0.3))
        gate.closeAnchor()
        #expect(gate.anchorDB != nil)
        #expect(gate.evaluate([Float](repeating: 0.01, count: 400)) == .unjudged)
        #expect(!gate.evaluate(Self.voice(0.5, amp: 0.02)).keeps)
        gate.beginTurn()
        #expect(gate.anchorDB == nil)
    }
}
