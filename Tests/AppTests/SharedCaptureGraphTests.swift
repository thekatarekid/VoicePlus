import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 O1 — one capture graph, many subscribers.
///
/// Before O1 a meeting opened its own `CoreAudioCaptureSource()` beside dictation's graph: two HAL
/// clients on one microphone, uncoordinated. Now `AudioPipeline.Broadcaster` is the only source of
/// microphone audio; dictation is the graph's owner, the meeting mic leg and ambient are recorders
/// that subscribe to the same capture.
@Suite("V5 O1 shared capture graph")
struct SharedCaptureGraphTests {
    /// A push-fed capture source that counts how often the "HAL" was opened and closed.
    final class CountingSource: AudioCaptureSource, @unchecked Sendable {
        var device: AudioDeviceInfo? { .fixture }
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        private let lock = NSLock()
        private var _starts = 0
        private var _stops = 0
        var starts: Int { lock.withLock { _starts } }
        var stops: Int { lock.withLock { _stops } }
        func prewarm() throws {}
        func start() throws { lock.withLock { _starts += 1 } }
        func stop() { lock.withLock { _stops += 1 } }
        func switchDevice(to device: AudioDeviceInfo?) throws {}
        func push(_ samples: [Float]) { samples.withUnsafeBufferPointer { sink?($0) } }
    }

    final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float] = []
        var all: [Float] { lock.withLock { stored } }
        var count: Int { lock.withLock { stored.count } }
        func append(_ s: UnsafeBufferPointer<Float>) { lock.withLock { stored.append(contentsOf: s) } }
        func append(_ s: [Float]) { lock.withLock { stored.append(contentsOf: s) } }
    }

    private func rig() -> (PipelineAudioSource, CountingSource) {
        let source = CountingSource()
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.digitalSilenceTimeout = 0
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD(), options: options))
        audio.requireMicrophonePermission = false
        return (audio, source)
    }

    private func tone(_ n: Int = 1_600, phase: Int = 0) -> [Float] {
        (0..<n).map { 0.1 * sin(Float($0 + phase) * 2 * .pi * 440 / 16_000) }
    }

    /// Waits (bounded) until `cond` holds; subscribers are fed on their own tasks.
    private func eventually(_ cond: () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test("two subscribers receive identical frames")
    func twoSubscribersSeeIdenticalFrames() async throws {
        let source = CountingSource()
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.digitalSilenceTimeout = 0
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        let a = pipeline.subscribe()
        let b = pipeline.subscribe()
        #expect(pipeline.subscriberCount == 2)
        func collect(_ s: AudioPipeline.Subscription) -> Task<[[Float]], Never> {
            Task {
                var frames: [[Float]] = []
                for await e in s.events {
                    if case .audio(let samples, _) = e { frames.append(samples) }
                    if case .stopped = e { break }
                }
                return frames
            }
        }
        let ta = collect(a), tb = collect(b)
        try await pipeline.start()
        for i in 0..<5 { source.push(tone(800, phase: i * 800)); await pipeline.drain() }
        await pipeline.stop()
        let fa = await ta.value, fb = await tb.value
        #expect(!fa.isEmpty)
        #expect(fa == fb, "subscribers saw different audio")
        #expect(fa.flatMap { $0 }.count == 4_000)
    }

    @Test("a cancelled subscription ends alone; the capture and other subscribers carry on")
    func cancellingOneSubscriptionLeavesTheOthers() async throws {
        let source = CountingSource()
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0
        options.digitalSilenceTimeout = 0
        let pipeline = AudioPipeline(source: source, vad: EnergyVAD(), options: options)
        let leaving = pipeline.subscribe()
        let staying = pipeline.subscribe()
        let got = Samples()
        let t = Task {
            for await e in staying.events {
                if case .audio(let s, _) = e { got.append(s) }
                if case .stopped = e { break }
            }
        }
        try await pipeline.start()
        leaving.cancel()
        // The cancelled stream delivers what it already had (`.started`) and then finishes.
        var leftovers = 0
        for await _ in leaving.events { leftovers += 1 }
        #expect(leftovers <= 1)
        #expect(pipeline.subscriberCount == 1)
        source.push(tone()); await pipeline.drain()
        #expect(pipeline.isRunning)
        await pipeline.stop()
        await t.value
        #expect(got.count == 1_600)
    }

    @Test("meeting + hold key simultaneously: both get audio from one HAL client")
    func meetingAndDictationShareOneCapture() async throws {
        let (audio, source) = rig()
        let meetingAudio = Samples()
        let mic = SharedMicrophoneSource(audio, recorder: .meeting)
        mic.sink = { meetingAudio.append($0) }

        try mic.start()                                   // the meeting starts first
        #expect(source.starts == 1)
        #expect(audio.activeRecorders == [.meeting])

        let dictated = Samples()
        audio.sink = { dictated.append($0) }
        try audio.start(for: .engine)                     // the hold key, mid-meeting
        #expect(audio.currentOwner == .engine)
        #expect(source.starts == 1, "dictation opened a second HAL client / restarted the graph")

        source.push(tone())
        await audio.pipeline.drain()
        await eventually { dictated.count >= 1_600 && meetingAudio.count >= 1_600 }
        #expect(dictated.count == 1_600)
        #expect(meetingAudio.count == 1_600)
        #expect(dictated.all == Array(meetingAudio.all.suffix(1_600)))

        audio.stop(for: .engine)                          // key released: the meeting keeps recording
        #expect(audio.pipeline.isRunning)
        #expect(source.stops == 0)
        source.push(tone())
        await audio.pipeline.drain()
        await eventually { meetingAudio.count >= 3_200 }
        #expect(meetingAudio.count == 3_200)
        #expect(dictated.count == 1_600, "dictation kept receiving after its key was released")

        mic.stop()                                        // last claim: graph stops
        #expect(!audio.pipeline.isRunning)
        #expect(source.starts == 1 && source.stops == 1)
        #expect(!audio.isCapturing)
    }

    @Test("a meeting that starts during dictation joins without pre-empting it")
    func recorderJoinsARunningDictation() async throws {
        let (audio, source) = rig()
        let dictated = Samples()
        audio.sink = { dictated.append($0) }
        var preempted: [PipelineAudioSource.Owner] = []
        audio.onPreempted = { preempted.append($0) }
        try audio.start(for: .engine)

        let meetingAudio = Samples()
        let mic = SharedMicrophoneSource(audio, recorder: .meeting)
        mic.sink = { meetingAudio.append($0) }
        try mic.start()
        #expect(audio.currentOwner == .engine)
        #expect(preempted.isEmpty)
        #expect(source.starts == 1)

        source.push(tone())
        await audio.pipeline.drain()
        await eventually { dictated.count >= 1_600 && meetingAudio.count >= 1_600 }
        #expect(dictated.count == 1_600 && meetingAudio.count == 1_600)

        mic.stop()                                        // meeting ends; dictation carries on
        #expect(audio.pipeline.isRunning)
        source.push(tone())
        await audio.pipeline.drain()
        await eventually { dictated.count >= 3_200 }
        #expect(dictated.count == 3_200)
        audio.stop(for: .engine)
        #expect(!audio.pipeline.isRunning)
        #expect(source.starts == 1)
    }

    @Test("an owner joining a recorder's graph starts with an empty utterance tap")
    func joiningOwnerGetsAFreshTap() async throws {
        let (audio, source) = rig()
        let tap = UtteranceAudioTap()
        audio.utteranceTap = tap
        let mic = SharedMicrophoneSource(audio, recorder: .ambient)
        try mic.start()
        source.push(tone())
        await audio.pipeline.drain()
        #expect(tap.samples.isEmpty, "the tap is the owner's; a recorder must not fill it")
        try audio.start(for: .engine)
        source.push(tone(800))
        await audio.pipeline.drain()
        await eventually { tap.samples.count >= 800 }
        #expect(tap.samples.count == 800)
        audio.stop(for: .engine)
        mic.stop()
    }

    @Test("the meter is still pre-empted by dictation while a recorder keeps the graph")
    func preemptionBetweenOwnersSurvivesWithRecorders() async throws {
        let (audio, source) = rig()
        let mic = SharedMicrophoneSource(audio, recorder: .meeting)
        try mic.start()
        try audio.start(for: .meter)
        let displaced = OwnerLog()
        audio.onPreempted = { displaced.append($0) }
        try audio.start(for: .engine)
        #expect(displaced.owners == [.meter])
        #expect(audio.currentOwner == .engine)
        #expect(source.starts == 1, "pre-empting the meter restarted the graph under the meeting")
        #expect(throws: AudioCaptureError.busy(owner: "engine")) { try audio.start(for: .meter) }
        audio.stop(for: .engine)
        mic.stop()
        #expect(!audio.isCapturing)
    }

    @Test("SharedMicrophoneSource feeds DualCapture's mic leg unchanged")
    func dualCaptureOverTheSharedGraph() async throws {
        let (audio, source) = rig()
        let system = CountingSource()
        let capture = DualCapture(mic: SharedMicrophoneSource(audio, recorder: .meeting), system: system,
                                  micVAD: EnergyVAD(), systemVAD: EnergyVAD())
        try await capture.start()
        #expect(audio.activeRecorders == [.meeting])
        source.push(tone(16_000))
        await audio.pipeline.drain()
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = try await capture.stop()
        #expect(capture.delivered[.mic] == 16_000)
        #expect(!audio.isCapturing)
    }

    // MARK: SessionCoordinator — arbiter of intent

    @MainActor
    private func session() -> (SessionCoordinator, MuteController) {
        let engine = LatchLoopEngine()
        let dictation = DictationCoordinator(engine: engine, database: nil, pill: PillPanelController())
        let mute = MuteController(store: InMemoryMuteStore(muted: false))
        return (SessionCoordinator(dictation: dictation, mute: mute, latch: nil), mute)
    }

    @Test("recorders are never pre-empted and never pre-empt the utterance claim")
    @MainActor func recordersBesideClaims() {
        let (session, _) = session()
        var stoodDown: [SessionCoordinator.Requester] = []
        session.onStandDown = { stoodDown.append($0) }
        #expect(session.start(.meeting) == .granted)
        #expect(session.activeRequester == nil, "a recorder took the utterance claim")
        #expect(session.start(.hotkey) == .granted, "the hotkey was told it displaced the meeting")
        #expect(session.start(.ambient) == .granted)
        #expect(session.activeRecorders == [.meeting, .ambient])
        session.stop(.hotkey)
        #expect(session.activeRecorders == [.meeting, .ambient], "ending dictation stopped a recorder")
        #expect(stoodDown.isEmpty)
        session.stop(.meeting)
        #expect(session.activeRecorders == [.ambient])
        #expect(SessionCoordinator.Requester.meeting.audioOwner == nil)
        #expect(SessionCoordinator.Requester.meeting.recorder == .meeting)
        #expect(SessionCoordinator.Requester.ambient.isRecorder)
    }

    @Test("hard mute stands recorders down too")
    @MainActor func muteStandsDownRecorders() {
        let (session, _) = session()
        var stoodDown: [SessionCoordinator.Requester] = []
        session.onStandDown = { stoodDown.append($0) }
        session.start(.meeting)
        session.muteEngaged()
        #expect(stoodDown == [.meeting])
        #expect(session.activeRecorders.isEmpty)
    }
}
