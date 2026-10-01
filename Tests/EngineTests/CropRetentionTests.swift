import Foundation
import Testing
@testable import Engine

/// V5 LR5 — mouth crops live ≤ 1 s outside an utterance; an utterance's crops are handed to its
/// recogniser once and then gone.
@Suite struct CropRetentionTests {
    final class Clock: @unchecked Sendable { var t: TimeInterval = 0 }

    func feed(_ buf: VisualFrameBuffer, _ clock: Clock, seconds: Double, fps: Double = 25) {
        let n = Int(seconds * fps)
        for _ in 0..<n {
            clock.t += 1 / fps
            buf.append(MouthCropFrame(time: clock.t, pixels: [1]))
        }
    }

    @Test func idleCameraHoldsAtMostOneSecond() {
        let clock = Clock()
        let buf = VisualFrameBuffer(now: { clock.t })
        feed(buf, clock, seconds: 30)
        #expect(buf.heldSpan <= CropRetention.standard.idleSeconds)
        #expect(buf.count <= 26)
    }

    @Test func utteranceKeepsItsCropsThenHandsThemOverOnce() throws {
        let clock = Clock()
        let buf = VisualFrameBuffer(now: { clock.t })
        feed(buf, clock, seconds: 5)
        buf.beginUtterance()
        feed(buf, clock, seconds: 4)
        #expect(buf.heldSpan > 4, "the open utterance (plus its 1 s pre-roll) is kept")
        buf.endUtterance()
        #expect(buf.hasSealedClip && !buf.isUtteranceOpen)
        feed(buf, clock, seconds: 0.4)    // finalisation latency: the camera keeps running
        let clip = try #require(buf.visualClip(duration: 4))
        #expect(clip.frames.count >= 98 && abs(clip.duration - 4) < 1e-6, "the recogniser gets the utterance, not the idle tail")
        #expect(!buf.hasSealedClip, "handed over once")
        #expect(buf.heldSpan <= 1)
    }

    @Test func unreadSealedClipExpires() {
        let clock = Clock()
        let buf = VisualFrameBuffer(now: { clock.t })
        buf.beginUtterance()
        feed(buf, clock, seconds: 3)
        buf.endUtterance()
        feed(buf, clock, seconds: CropRetention.standard.sealedLifetime + 0.5)
        #expect(!buf.hasSealedClip && buf.heldSpan <= 1)
    }

    @Test func openUtteranceIsCappedAndClearDropsEverything() {
        let clock = Clock()
        let buf = VisualFrameBuffer(retention: CropRetention(maxSeconds: 2), now: { clock.t })
        buf.beginUtterance()
        feed(buf, clock, seconds: 10)
        #expect(buf.heldSpan <= 2)
        buf.endUtterance()
        buf.clear()
        #expect(buf.count == 0 && !buf.hasSealedClip && !buf.isUtteranceOpen)
    }

    @Test func lipsOnlyEngineBracketsTheBuffer() async throws {
        let clock = Clock()
        clock.t = 100
        let buf = VisualFrameBuffer(now: { clock.t })
        let model = AVSRRecognizerTests.MockModel()
        let engine = LipsOnlyEngine(recognizer: AVSRRecognizer(videoOnly: true, model: model, visual: buf),
                                    isModelInstalled: { true }, clock: { clock.t },
                                    onUtteranceStart: { buf.beginUtterance() }, onUtteranceEnd: { buf.clear() })
        try await engine.start()
        #expect(buf.isUtteranceOpen)
        feed(buf, clock, seconds: 2)
        let spans = try await engine.stop()
        #expect(!spans.isEmpty, "the whole 2 s utterance reached the recogniser")
        #expect(buf.count == 0 && !buf.isUtteranceOpen)
    }
}
