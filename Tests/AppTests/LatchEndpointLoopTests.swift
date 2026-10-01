import Engine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// B1 (V4.32) — the latch endpoint loop, and B4 — the latch timer feed.
///
/// Before B1, `LatchRuntime.tick / noteVAD / noteEndpoint` had no callers and nothing set the
/// pipeline latched, so a latched session kept one open segment until the stopping tap. These
/// suites drive the production wiring (`SessionCoordinator` → `LatchRuntime` → capture feed) with a
/// scripted engine (`LatchLoopEngine`) and scripted VAD: most cases run a real `AudioPipeline`
/// behind a real `PipelineAudioSource` (`ScriptedLatchCapture`), the fixture case replays
/// `Fixtures/audio/vad` through the real `EnergyVAD`, and a hand-driven feed (`FakeLatchFeed`)
/// covers what needs exact control of the hops.
@Suite("Latch endpoint loop (B1) and timer (B4)")
@MainActor
struct LatchEndpointLoopTests {
    typealias S = ScriptedLatchCapture
    static let notes = FocusSnapshot(pid: 11, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "n1")
    static let mail = FocusSnapshot(pid: 22, bundleID: "com.apple.mail", appName: "Mail", elementToken: "m1")

    // MARK: B1 — entering latch connects the feed; leaving lets go

    @Test("entering latch sets the pipeline latched at the user's pause; the stop tap undoes it")
    func feedLifecycle() async {
        var rig = LatchLoopRig()
        let feed = FakeLatchFeed()
        await rig.doubleTap()
        #expect(rig.dictation.latched)
        rig.latch.replaceFeed(feed)
        #expect(rig.latch.isConnected)
        #expect(feed.latchedCalls == [true])
        #expect(feed.endpointers.last?.trailingSilence == LatchSettings.defaultPauseSeconds)
        #expect(feed.endpointers.last?.noSpeechTimeout == LatchSettings.noSpeechTimeout)
        #expect(feed.endpointers.last?.maxUtterance == LatchSettings.maxSegmentSeconds)
        #expect(feed.onVAD != nil && feed.onEndpoint != nil)

        await rig.stopTap(at: 5)
        #expect(!rig.dictation.latched)
        #expect(feed.latchedCalls == [true, false], "leaving latch must unlatch the pipeline")
        #expect(feed.onVAD == nil && feed.onEndpoint == nil, "the feed kept calling a latch that ended")
        #expect(!rig.latch.isConnected)
    }

    @Test("the double tap connects to the bound pipeline itself; Escape lets go of it")
    func realPipelineConnectsAndEscapeReleases() async throws {
        var rig = LatchLoopRig()
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)
        #expect(rig.latch.isConnected, "latch entry did not connect to the pipeline bound by bindWaveform")
        #expect(capture.audio.isLatched)
        #expect(capture.audio.pipeline.options.latched)
        #expect(capture.audio.pipeline.options.endpointer.trailingSilence == LatchSettings.defaultPauseSeconds)
        #expect(capture.audio.onVAD != nil && capture.audio.onEndpoint != nil)

        rig.session.escape()
        await rig.settle()
        #expect(!capture.audio.isLatched, "Escape left the pipeline endpointing")
        #expect(capture.audio.onVAD == nil && capture.audio.onEndpoint == nil)
        #expect(!rig.latch.isConnected)
        capture.stop()
    }

    // MARK: B1 — three pauses, three landings

    @Test("three pauses → three landings, in order, while listening continues")
    func threePausesThreeLandings() async throws {
        var rig = LatchLoopRig(script: ["first sentence", "second sentence", "third sentence"])
        rig.spy.focus = Self.notes
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)

        for i in 0..<3 {
            // A one-second breath inside the sentence is not the 2 s pause: nothing closes.
            await capture.play(S.speech(0.6) + S.silence(1.0) + S.speech(0.6), into: rig.latch)
            await rig.flush()
            #expect(rig.latch.endpointClosures == i, "segment \(i) closed on a breath")
            await capture.play(S.silence(2.2), into: rig.latch)
            await rig.wait(outcomes: i + 1)
        }
        await rig.flush()
        #expect(rig.spy.delivered.map(\.text) == ["first sentence", "second sentence", "third sentence"])
        #expect(rig.spy.delivered.allSatisfy { $0.focus == Self.notes })
        #expect(rig.latch.endpointClosures == 3)
        #expect(rig.engine.closures == 3, "a segment was closed twice")
        #expect(rig.engine.listening, "an endpoint ended capture")
        #expect(rig.dictation.latched)
        #expect(rig.latch.outcomes.map(\.outcome) == [.delivered("first sentence"), .delivered("second sentence"),
                                                       .delivered("third sentence")])
        let order = rig.latch.outcomes.map(\.segment.index)
        #expect(order == [0, 1, 2], "segments were not serialized by SegmentID")
        #expect(rig.finalInjector.requests.isEmpty, "a latch segment went down the key-release path")

        await rig.stopTap(at: 60)
        await latchWait("the final landing") { !rig.finalInjector.requests.isEmpty }
        #expect(rig.finalInjector.requests.map(\.text) == ["the last one"])
        #expect(rig.latch.outcomes.count == 3)
        capture.stop()
    }

    @Test("with a feed connected the pipeline decides; a repeated decision is stale")
    func connectedFeedThePipelineDecides() async {
        var rig = LatchLoopRig(script: ["from the pipeline"])
        let feed = FakeLatchFeed()
        await rig.doubleTap()
        rig.latch.replaceFeed(feed)
        // Speech, then a pause longer than the setting, told to the runtime directly. The runtime's
        // own endpointer would close here; with the pipeline connected it must wait for its verdict
        // (the VAD edges it has not been handed yet could still be on their way).
        await rig.vad(feed, .speechStart(at: 0.2))
        await rig.position(feed, 1.2)
        await rig.vad(feed, .speechEnd(at: 1.2))
        await rig.position(feed, 3.5)
        await rig.flush()
        #expect(rig.latch.endpointClosures == 0, "the runtime second-guessed the pipeline")

        feed.endpoint(.endpoint(at: 1.2))
        await rig.wait(outcomes: 1)
        #expect(rig.spy.delivered.map(\.text) == ["from the pipeline"])
        feed.endpoint(.endpoint(at: 1.2))                          // the same decision again: stale
        await rig.flush()
        #expect(rig.latch.endpointClosures == 1)
        #expect(rig.engine.closures == 1)
    }

    // MARK: B1 — focus

    @Test("focus that moves mid-segment holds that segment for where it began; the next one lands")
    func focusChangeMidSegmentHoldsThatSegment() async throws {
        var rig = LatchLoopRig(script: ["meant for notes", "meant for mail"])
        rig.spy.focus = Self.notes
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)

        await capture.play(S.speech(0.4), into: rig.latch)          // begins in Notes
        await latchWait("the speech start") { rig.latch.openSegmentSpeechFocus != nil }
        #expect(rig.latch.openSegmentSpeechFocus == Self.notes)
        rig.spy.focus = Self.mail                                   // ⌘-Tab while still talking
        await capture.play(S.speech(0.4) + S.silence(2.2), into: rig.latch)
        await rig.wait(outcomes: 1)
        #expect(rig.spy.delivered.isEmpty, "text was typed into the app the user switched to")
        #expect(rig.spy.held.map(\.text) == ["meant for notes"])
        #expect(rig.spy.held.first?.reason == DeliveryReason.destinationChanged)
        #expect(rig.spy.held.first?.destination == Self.notes)
        #expect(rig.latch.outcomes.first?.outcome == .held(destination: "Notes", reason: DeliveryReason.destinationChanged))

        // Speech that begins in Mail lands in Mail: the snapshot is the one taken at segment close.
        await latchWait("the next segment") { rig.latch.currentSegment?.index == 1 }
        await capture.play(S.speech(0.6) + S.silence(2.2), into: rig.latch)
        await rig.wait(outcomes: 2)
        #expect(rig.spy.delivered.map(\.text) == ["meant for mail"])
        #expect(rig.spy.delivered.first?.focus == Self.mail)
        #expect(rig.latch.outcomes.last?.outcome == .delivered("meant for mail"))
        #expect(rig.engine.listening)
        capture.stop()
    }

    @Test("delivery uses the focus at segment close, never the one from the key release")
    func closeSnapshotNotKeyRelease() async {
        var rig = LatchLoopRig(script: ["after the move"])
        let feed = FakeLatchFeed()
        rig.spy.focus = Self.notes                                  // focused at the double tap
        await rig.doubleTap()
        rig.latch.replaceFeed(feed)
        rig.spy.focus = Self.mail                                   // moved during the silence
        await rig.vad(feed, .speechStart(at: 1.0))
        await rig.position(feed, 2.0)
        await rig.vad(feed, .speechEnd(at: 2.0))
        await rig.position(feed, 4.1)
        feed.endpoint(.endpoint(at: 2.0))
        await rig.wait(outcomes: 1)
        #expect(rig.spy.delivered.first?.focus == Self.mail)
        #expect(rig.spy.held.isEmpty)
    }

    // MARK: B1 — no endpoint, nothing lands

    @Test("with no endpoint nothing lands until the stop tap, which lands once")
    func noEndpointNothingLandsUntilStop() async throws {
        var rig = LatchLoopRig()
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)
        // Twelve seconds of talking whose pauses never reach the 2 s setting.
        for _ in 0..<6 { await capture.play(S.speech(0.8) + S.silence(1.2), into: rig.latch) }
        await rig.flush()
        #expect(rig.latch.endpointClosures == 0)
        #expect(rig.engine.closures == 0)
        #expect(rig.latch.outcomes.isEmpty)
        #expect(rig.spy.delivered.isEmpty && rig.spy.held.isEmpty)
        #expect(rig.finalInjector.requests.isEmpty, "something landed before the stop tap")

        await rig.stopTap(at: 30)
        await latchWait("the final landing") { !rig.finalInjector.requests.isEmpty }
        #expect(rig.finalInjector.requests.map(\.text) == ["the last one"], "the stop tap lands exactly once")
        #expect(rig.latch.outcomes.isEmpty, "the key-release segment was delivered by the latch too")
        #expect(rig.engine.stops == 1)
        #expect(!capture.audio.isLatched)
        capture.stop()
    }

    @Test("silence while latched is reported by the pipeline but never closes a segment")
    func silenceNeverCloses() async throws {
        var rig = LatchLoopRig()
        let capture = ScriptedLatchCapture()
        let decisions = DecisionLog(capture.audio.pipeline)
        try await rig.latch(on: capture)
        // Room tone, not bit-exact zeros: a live microphone in a quiet room. Zeros here would be a
        // *silenced* stream, which `CaptureSilenceWatchdog` ends with A05 — a different claim than
        // this test's, and one that would make the expectations below pass for the wrong reason
        // (no segment closes because the whole turn was torn down).
        await capture.play(S.roomTone(9.0), into: rig.latch)        // past the 8 s no-speech bound
        await latchWait("the no-speech report") { decisions.all == [.noSpeech] }
        await rig.flush()
        #expect(rig.latch.endpointClosures == 0)
        #expect(rig.engine.closures == 0)
        #expect(rig.latch.outcomes.isEmpty)
        capture.stop()
    }

    // MARK: B1 — the production feed, fixture-verified

    /// `vad_03_5segs.wav` through a real `PipelineAudioSource` (`AudioPipeline` + `EnergyVAD`),
    /// bound the way `AppDelegate` binds it (`bindWaveform`), latched by a real double tap, at the
    /// default 2 s pause. The labelled pauses are 1.63, 1.93, 2.93, 2.88 s and a ~3 s tail, so the
    /// session must land exactly three segments, in order, and never cut on the 1.93 s pause.
    @Test("vad_03 fixture: three pauses of ≥ 2 s → three landings, in order")
    func fixtureThreeLandings() async throws {
        let url = try #require(AudioFixtures.url("vad", "vad_03_5segs.wav"))
        let samples = try FixtureCaptureSource(url: url).samples16k
        let capture = ScriptedLatchCapture(vad: EnergyVAD())

        var rig = LatchLoopRig()
        rig.spy.focus = Self.notes
        try await rig.latch(on: capture)
        #expect(capture.audio.pipeline.options.endpointer.trailingSilence == 2.0)

        await capture.play(samples, into: rig.latch)
        await rig.wait(outcomes: 3)
        await rig.flush()                                           // anything late would show now

        #expect(rig.engine.closures == 3, "closures: \(rig.engine.closures)")
        #expect(rig.spy.delivered.map(\.text) == ["segment 0", "segment 1", "segment 2"])
        #expect(rig.spy.delivered.allSatisfy { $0.focus == Self.notes })

        await rig.stopTap(at: 40)
        #expect(!capture.audio.isLatched, "the pipeline stayed latched after the stop tap")
        #expect(capture.audio.onVAD == nil && capture.audio.onEndpoint == nil)
        capture.stop()
    }

    // MARK: B4 — the timer

    @Test("elapsed advances with the audio and reaches the pill as the latched timer")
    func elapsedAdvancesAndReachesThePill() async {
        var rig = LatchLoopRig()
        var published: [TimeInterval] = []
        let forward = rig.latch.onElapsed
        rig.latch.onElapsed = { published.append($0); forward?($0) }
        let feed = FakeLatchFeed()
        await rig.doubleTap()
        rig.latch.replaceFeed(feed)
        #expect(published == [0])
        #expect(rig.dictation.latchElapsed == 0)

        await rig.position(feed, 0.5)                               // the anchor
        await rig.position(feed, 1.2)
        #expect(abs(rig.latch.elapsed - 0.7) < 1e-9)
        #expect(published == [0], "published more often than once a second")
        await rig.position(feed, 2.6)
        #expect(abs(rig.latch.elapsed - 2.1) < 1e-9)
        #expect(published.count == 2 && abs(published[1] - 2.1) < 1e-9)
        await latchWait("the pill timer") { rig.dictation.latchElapsed > 2 }
        #expect(rig.dictation.pill.model.state == .latched(elapsed: published[1]))
        await rig.position(feed, 4.0)
        #expect(abs(rig.latch.elapsed - 3.5) < 1e-9)
    }

    @Test("elapsed counts the real pipeline's audio")
    func elapsedFollowsThePipeline() async throws {
        var rig = LatchLoopRig()
        let capture = ScriptedLatchCapture()
        try await rig.latch(on: capture)
        // Room tone: the user has latched and is not speaking yet, with a live microphone. The
        // clock must count that audio. (Bit-exact zeros would be a silenced input, which the
        // capture-silence watchdog ends with A05 — correctly, and this test is not about that.)
        await capture.play(S.roomTone(3.1), into: rig.latch)
        // The first block anchors the clock; every block after it counts.
        #expect(abs(rig.latch.elapsed - (3.1 - 0.05)) < 1e-6)
        await latchWait("the pill timer") { rig.dictation.latchElapsed >= 3 }
        #expect(rig.dictation.pill.model.state == .latched(elapsed: rig.dictation.latchElapsed))
        capture.stop()
    }

    @Test("elapsed resets on a new latch")
    func elapsedResetsOnANewLatch() async {
        var rig = LatchLoopRig()
        var published: [TimeInterval] = []
        let forward = rig.latch.onElapsed
        rig.latch.onElapsed = { published.append($0); forward?($0) }
        let feed = FakeLatchFeed()
        await rig.doubleTap()
        rig.latch.replaceFeed(feed)
        await rig.position(feed, 0.1)
        await rig.position(feed, 3.1)
        #expect(abs(rig.latch.elapsed - 3.0) < 1e-9)

        await rig.stopTap(at: 10)
        let second = FakeLatchFeed()
        await rig.doubleTap(at: 20)
        rig.latch.replaceFeed(second)
        #expect(rig.latch.elapsed == 0)
        #expect(published.last == 0)
        #expect(rig.dictation.latchElapsed == 0)
        await rig.position(second, 0.2)                              // a new capture clock
        await rig.position(second, 1.4)
        #expect(abs(rig.latch.elapsed - 1.2) < 1e-9, "the new latch counted from the old one")
    }

    @Test("outside latch there is no timer")
    func noTimerOutsideLatch() async {
        let rig = LatchLoopRig()
        rig.dictation.noteLatchElapsed(5)
        #expect(rig.dictation.latchElapsed == 0)
        rig.latch.tick(at: 3)
        #expect(rig.latch.elapsed == 0)
    }
}

/// Every endpoint decision a pipeline broadcasts, in order.
final class DecisionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var decisions: [Endpointer.Decision] = []
    private var task: Task<Void, Never>?

    init(_ pipeline: AudioPipeline) {
        let events = pipeline.events()
        task = Task { [weak self] in
            for await event in events {
                guard case .endpoint(let decision) = event, let self else { continue }
                self.lock.withLock { self.decisions.append(decision) }
            }
        }
    }

    deinit { task?.cancel() }

    var all: [Endpointer.Decision] { lock.withLock { decisions } }
}
