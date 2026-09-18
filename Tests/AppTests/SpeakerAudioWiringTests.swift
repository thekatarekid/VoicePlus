import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H2 app wiring (W1 gate): the capture events that reach passive enrollment and the latch
/// speaker guard. Driven through `handle(_:)` with scripted pipeline events; no microphone.
@Suite("H2 — speaker audio wiring (holds → enrollment, latch → segment audio)")
struct SpeakerAudioWiringTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var latched = false
        var wantsHolds = true
        var observed: [(samples: Int, speech: TimeInterval)] = []
    }

    static func wiring(_ box: Box, dictation: Bool = true) -> SpeakerAudioWiring {
        let w = SpeakerAudioWiring(isLatched: { box.lock.withLock { box.latched } },
                                   wantsHolds: { box.lock.withLock { box.wantsHolds } },
                                   observe: { samples, speech in box.lock.withLock { box.observed.append((samples.count, speech)) } })
        let (stream, _) = AsyncStream<AudioPipelineEvent>.makeStream()
        w.bind(events: stream, isDictationCapture: { dictation })
        return w
    }

    /// `seconds` of audio in 50 ms blocks starting at `from`.
    static func audio(_ w: SpeakerAudioWiring, from: TimeInterval, seconds: TimeInterval) {
        var t = from
        while t < from + seconds - 1e-9 {
            w.handle(.audio(samples: [Float](repeating: 0.1, count: 800), position: t))
            t += 0.05
        }
    }

    @Test func aHoldHandsItsSamplesAndVADSpeechToEnrollment() {
        let box = Box()
        let w = Self.wiring(box)
        w.handle(.started(device: nil))
        w.handle(.vad(.speechStart(at: 0.2)))
        Self.audio(w, from: 0, seconds: 2.5)
        w.handle(.vad(.speechEnd(at: 2.0)))
        w.handle(.stopped(totalSamples: 40_000))
        #expect(box.observed.count == 1)
        #expect(box.observed.first?.samples == 40_000)
        #expect(abs((box.observed.first?.speech ?? 0) - 1.8) < 1e-6, "VAD speech, not capture length")
    }

    @Test func anOpenSpeechRunCountsToTheEndOfCapture() {
        let box = Box()
        let w = Self.wiring(box)
        w.handle(.started(device: nil))
        w.handle(.vad(.speechStart(at: 0.5)))
        Self.audio(w, from: 0, seconds: 2)
        w.handle(.stopped(totalSamples: 32_000))
        #expect(abs((box.observed.first?.speech ?? 0) - 1.5) < 1e-6)
    }

    @Test func aLatchedSessionNeverTeachesTheVoice() {
        let box = Box()
        let w = Self.wiring(box)
        w.handle(.started(device: nil))
        w.handle(.vad(.speechStart(at: 0)))
        Self.audio(w, from: 0, seconds: 1)
        box.lock.withLock { box.latched = true }           // double tap: the hold became a latch
        Self.audio(w, from: 1, seconds: 2)
        box.lock.withLock { box.latched = false }
        w.handle(.stopped(totalSamples: 48_000))
        #expect(box.observed.isEmpty, "latch audio may be anyone's voice")
    }

    @Test func nothingIsBufferedOnceAVoiceIsEnrolledOrForTheMeter() {
        let box = Box()
        box.wantsHolds = false
        let w = Self.wiring(box)
        w.handle(.started(device: nil))
        Self.audio(w, from: 0, seconds: 2)
        w.handle(.stopped(totalSamples: 32_000))
        #expect(box.observed.isEmpty)

        let meterBox = Box()
        let meter = Self.wiring(meterBox, dictation: false)
        meter.handle(.started(device: nil))
        Self.audio(meter, from: 0, seconds: 2)
        meter.handle(.stopped(totalSamples: 32_000))
        #expect(meterBox.observed.isEmpty, "the onboarding meter is not a hold")
    }

    @Test func aHoldIsCappedInMemory() {
        let box = Box()
        let w = Self.wiring(box)
        w.handle(.started(device: nil))
        Self.audio(w, from: 0, seconds: SpeakerAudioWiring.maxHoldSeconds + 5)
        w.handle(.stopped(totalSamples: 0))
        #expect(box.observed.first?.samples == Int(SpeakerAudioWiring.maxHoldSeconds * 16_000))
    }

    @Test func latchAudioFeedsTheSegmentGuardFreshOnEveryEntry() {
        let box = Box()
        let w = Self.wiring(box)
        w.handle(.started(device: nil))
        Self.audio(w, from: 0, seconds: 1)                  // the hold before the double tap
        #expect(w.segmentAudio.take() == nil, "hold audio is not segment audio")
        box.lock.withLock { box.latched = true }
        Self.audio(w, from: 1, seconds: 1)
        #expect(w.segmentAudio.take()?.count == 16_000)
        Self.audio(w, from: 2, seconds: 0.5)
        #expect(w.segmentAudio.take()?.count == 8_000, "each take is the audio since the previous one")
        box.lock.withLock { box.latched = false }
        Self.audio(w, from: 2.5, seconds: 0.5)
        w.handle(.stopped(totalSamples: 0))
        #expect(w.segmentAudio.take() == nil)

        // A stale remainder from a previous latch is dropped on the next entry.
        w.handle(.started(device: nil))
        box.lock.withLock { box.latched = true }
        Self.audio(w, from: 0, seconds: 0.25)
        #expect(w.segmentAudio.take()?.count == 4_000)
    }

    @Test func theControllerLearnsFromWiredHolds() {
        let embedder = PassiveEnrollmentLatchTests.ScriptedEmbedder()
        let controller = PassiveEnrollmentLatchTests.controller(embedder)
        let w = SpeakerAudioWiring(isLatched: { false },
                                   wantsHolds: { !controller.hasEnrolledVoice },
                                   observe: { samples, speech in _ = controller.observeHoldUtterance(samples: samples, speechSeconds: speech) })
        let (stream, _) = AsyncStream<AudioPipelineEvent>.makeStream()
        w.bind(events: stream, isDictationCapture: { true })
        for _ in 0..<SpeakerEnrollment.passiveUtterances {
            w.handle(.started(device: nil))
            w.handle(.vad(.speechStart(at: 0)))
            w.handle(.audio(samples: PassiveEnrollmentLatchTests.clip(0), position: 0))
            w.handle(.stopped(totalSamples: 32_000))
        }
        #expect(controller.hasEnrolledVoice && controller.speakerFilteringEnabled)
    }
}
