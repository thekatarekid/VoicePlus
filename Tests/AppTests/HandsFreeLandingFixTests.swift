import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Hands-free fixes (2026-10-04 investigation):
/// * RC3 — the speaker check hears each segment's own voice: audio is cut at the segment boundary
///   (empty segments included) and trimmed to its voiced part, so a long pause or Option-chord typing
///   no longer turns the owner's voice into "another voice" (→ Notes).
/// * RC5 — a sentence end (the EOU head) lands the piece without waiting out the whole pause.
/// * RC2 — a hands-free piece is drawn as `.inserting` (the ribbon's locate step) on its way in.
@Suite("Hands-free landing fixes (RC2, RC3, RC5)")
struct HandsFreeLandingFixTests {
    static let session = UUID()
    static func seg(_ i: Int) -> SegmentID { SegmentID(sessionID: session, index: i) }
    static func spans(_ text: String) -> [TranscriptSpan] {
        text.isEmpty ? [] : [TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr], stability: .committed)]
    }
    static func closed(_ i: Int, _ text: String) -> SegmentEvent {
        .closed(segment: seg(i), spans: spans(text), stability: .committed, reason: .endpoint)
    }

    final class Spy: LatchDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _inserted: [String] = []
        var inserted: [String] { lock.withLock { _inserted } }
        func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool {
            lock.withLock { _inserted.append(spans.renderedText) }
            return true
        }
        func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String { "" }
        func insertHeld(into target: String) -> Int { 0 }
    }

    // MARK: RC3 — voiced audio

    static func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }
    static func silence(seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16_000)) }
    /// A key click: 20 ms of loud noise.
    static func click() -> [Float] { (0..<320).map { $0 % 2 == 0 ? 0.6 : -0.6 } }

    @Test("the voiced part keeps the voice and drops silence and key clicks around it")
    func voicedTrimsSilenceAndClicks() {
        var audio = Self.silence(seconds: 8)
        for _ in 0..<6 { audio += Self.click() + Self.silence(seconds: 0.4) }
        audio += Self.tone(seconds: 2) + Self.silence(seconds: 2)
        let voiced = SpeakerSegmentAudio.voiced(audio)
        let seconds = Double(voiced.count) / 16_000
        #expect(seconds >= 1.9 && seconds <= 2.2, "\(seconds) s kept of \(Double(audio.count) / 16_000) s")
    }

    @Test("too little voice (or none) leaves the audio as it was")
    func voicedFallsBack() {
        let quiet = Self.silence(seconds: 3)
        #expect(SpeakerSegmentAudio.voiced(quiet) == quiet)
        let sliver = Self.silence(seconds: 1) + Self.tone(seconds: 0.2) + Self.silence(seconds: 1)
        #expect(SpeakerSegmentAudio.voiced(sliver).count == sliver.count)
        #expect(SpeakerSegmentAudio.voiced([0.1, 0.2]) == [0.1, 0.2])
    }

    @Test("each segment's speaker check gets only its own audio — an empty segment's audio is cut too")
    func speakerCheckHearsItsOwnSegment() async {
        let runtime = LatchRuntime(delivery: Spy())
        runtime.isLatched = { true }
        let audio = LatchSegmentAudio()
        runtime.cutSegmentAudio = { audio.take() }
        let heard = TurnControllerTests.Box<[[Float]?]>([])
        runtime.speakerCheck = { samples in heard.value.append(samples); return .allow(similarity: 0.9) }

        runtime.handle(.opened(Self.seg(0)))
        audio.append([Float](repeating: 0.1, count: 16_000))          // segment 0: a long, empty pause
        runtime.handle(.opened(Self.seg(1)))                           // the engine cut segment 0
        runtime.handle(Self.closed(0, ""))
        audio.append([Float](repeating: 0.2, count: 8_000))           // segment 1: the words
        runtime.handle(.opened(Self.seg(2)))
        audio.append([Float](repeating: 0.3, count: 100))             // next segment's first moments
        runtime.handle(Self.closed(1, "hello there"))
        await runtime.settle()

        #expect(heard.value.count == 1, "only a segment with words is checked")
        let samples = heard.value.first.flatMap { $0 } ?? []
        #expect(samples.count == 8_000, "segment 1's own audio, not the pause before it")
        #expect(samples.allSatisfy { $0 == 0.2 })
    }

    @Test("a speaker check on its own audio wins over the legacy guard; another voice still suppresses")
    func speakerCheckSuppresses() async {
        let spy = Spy()
        let runtime = LatchRuntime(delivery: spy)
        runtime.isLatched = { true }
        runtime.cutSegmentAudio = { [0.1] }
        runtime.speakerGuard = { .allow(similarity: nil) }
        runtime.speakerCheck = { _ in .suppress(.mismatch) }
        runtime.handle(.opened(Self.seg(0)))
        runtime.handle(Self.closed(0, "not me"))
        await runtime.settle()
        #expect(spy.inserted.isEmpty)
        #expect(runtime.outcomes.first?.outcome == .suppressed(.mismatch))
    }

    @Test("the controller hands the runtime its audio cut and arms the check only while filtering")
    func controllerWiresTheCheck() throws {
        let controller = PassiveEnrollmentLatchTests.controller()
        let runtime = LatchRuntime(delivery: Spy())
        controller.attach(runtime: runtime, segmentAudio: { [1, 2, 3] })
        #expect(runtime.cutSegmentAudio?() == [1, 2, 3])
        #expect(runtime.speakerCheck == nil, "no voice enrolled: no filter configured")
        let centroid = SpeakerEmbedding(vector: [1, 0], embedder: "test-wespeaker", metric: .cosine)
        #expect(controller.install(profile: SpeakerProfile(centroid: centroid, utteranceCount: 3, enrolledAt: Date())) == .filtering)
        let check = try #require(runtime.speakerCheck)
        #expect(check(PassiveEnrollmentLatchTests.clip(0.2)).allowsInsertion)
        #expect(check(PassiveEnrollmentLatchTests.clip(1.2)) == .suppress(.mismatch))
        #expect(check(nil) == .suppress(.uncertain), "no audio: uncertain is not yes")
        controller.speakerFilteringEnabled = false
        #expect(runtime.speakerCheck == nil)
    }

    // MARK: RC5 — sentence end

    static func latchedRuntime() -> LatchRuntime {
        let runtime = LatchRuntime(delivery: Spy())
        runtime.isLatched = { true }
        runtime.feedQueue = { $0() }
        runtime.handle(.opened(Self.seg(0)))
        return runtime
    }

    @Test("a sentence end after speech closes the segment now")
    func sentenceEndCloses() {
        let runtime = Self.latchedRuntime()
        runtime.noteVAD(.speechStart(at: 0.2))
        runtime.noteVAD(.speechEnd(at: 2.0))
        runtime.handle(.endOfUtterance(segment: Self.seg(0)))
        #expect(runtime.sentenceEndClosures == 1)
        #expect(runtime.endpointClosures == 1)
    }

    @Test("no closure while still speaking, before any speech, for an old segment, or when not latched")
    func sentenceEndIgnored() {
        let speaking = Self.latchedRuntime()
        speaking.noteVAD(.speechStart(at: 0.2))
        speaking.handle(.endOfUtterance(segment: Self.seg(0)))
        #expect(speaking.endpointClosures == 0, "the voice detector still hears speech")

        let silent = Self.latchedRuntime()
        silent.handle(.endOfUtterance(segment: Self.seg(0)))
        #expect(silent.endpointClosures == 0, "nothing was said in the segment")

        let old = Self.latchedRuntime()
        old.noteVAD(.speechStart(at: 0.2))
        old.noteVAD(.speechEnd(at: 1.0))
        old.handle(.endOfUtterance(segment: Self.seg(7)))
        #expect(old.endpointClosures == 0, "a hint about a segment that is not open")

        let off = Self.latchedRuntime()
        off.noteVAD(.speechStart(at: 0.2))
        off.noteVAD(.speechEnd(at: 1.0))
        off.isLatched = { false }
        off.handle(.endOfUtterance(segment: Self.seg(0)))
        #expect(off.endpointClosures == 0, "hold-to-talk never closes on a sentence end")

        let disabled = Self.latchedRuntime()
        disabled.closesAtSentenceEnd = false
        disabled.noteVAD(.speechStart(at: 0.2))
        disabled.noteVAD(.speechEnd(at: 1.0))
        disabled.handle(.endOfUtterance(segment: Self.seg(0)))
        #expect(disabled.endpointClosures == 0)
    }

    // MARK: RC2 — the hands-free piece's write is drawn

    @Test("a hands-free piece under the open latched capture is previewed, then drawn as inserting")
    func handsFreePieceShowsInserting() async throws {
        let h = TurnControllerTests.Harness(dwell: .immediate)
        guard case .began(let id) = h.controller.keyDown(latched: true) else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.noteLatched(true)
        let before = h.events.states.count
        _ = await h.lander.land(TurnControllerTests.words("first piece"), startedAt: Date(), focus: TurnControllerTests.textEdit)
        #expect(await h.wait { h.events.landed.count == 1 || h.system.postCount == 1 })
        let names = Array(h.events.stateNames[before...])
        let preview = try #require(names.firstIndex(of: "finalPreview"), "\(names)")
        #expect(names[preview...].contains("inserting"), "the ribbon's locate step: \(names)")
        #expect(h.controller.stage(of: id)?.isCapturing == true, "the hands-free capture is untouched")
    }
}
