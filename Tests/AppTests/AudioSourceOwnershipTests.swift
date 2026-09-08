import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// 1.7.4 regression cover for the shared capture graph.
///
/// `PipelineAudioSource.start()` used to return success while doing nothing whenever the source was
/// already running. Two owners — the onboarding mic meter and the ASR engine — could therefore each
/// believe they had configured capture while only the first one had, and whichever stopped first
/// closed the microphone under the other. A start that does nothing must not report success.
@Suite("Audio source ownership")
struct AudioSourceOwnershipTests {
    private func bridge() -> (PipelineAudioSource, FixtureCaptureSource) {
        let source = FixtureCaptureSource(wav: WAVFile(sampleRate: 16_000, samples: []))
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 0            // no HAL here; the watchdog has nothing to police
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD(), options: options))
        audio.requireMicrophonePermission = false
        return (audio, source)
    }

    private func tone(_ n: Int = 8_000) -> [Float] {
        (0..<n).map { 0.1 * sin(Float($0) * 2 * .pi * 440 / 16_000) }
    }

    /// The engine outranks the meter: it takes the graph, and it takes it *restarted* — not the
    /// meter's running one, whose ring, VAD and utterance tap belong to somebody else's session.
    @Test func engineTakesTheGraphFromTheMeterAndRestartsIt() async throws {
        let (audio, source) = bridge()
        let tap = UtteranceAudioTap()
        audio.utteranceTap = tap

        try audio.start(for: .meter)
        #expect(audio.currentOwner == .meter)
        source.push(tone())
        await audio.pipeline.drain()
        #expect(!tap.samples.isEmpty, "the meter's audio should be in the tap before the handover")

        let displaced = OwnerLog()
        audio.onPreempted = { displaced.append($0) }
        let received = Counter()
        audio.sink = { received.add($0.count) }

        try audio.start(for: .engine)
        #expect(audio.currentOwner == .engine)
        #expect(displaced.owners == [.meter], "the displaced owner must be told, not silently starved")
        #expect(tap.samples.isEmpty, "a new owner must not inherit the previous owner's utterance tap")

        source.push(tone())
        await audio.pipeline.drain()
        #expect(received.count > 0, "the engine's sink saw no audio after taking the graph")
        audio.stop()
        #expect(audio.currentOwner == nil)
    }

    /// The other half: a meter that asks for a microphone dictation is holding is refused out loud.
    @Test func meterIsRefusedWhileTheEngineHoldsCapture() throws {
        let (audio, _) = bridge()
        try audio.start(for: .engine)
        #expect(throws: AudioCaptureError.busy(owner: "engine")) { try audio.start(for: .meter) }
        #expect(audio.currentOwner == .engine, "a refused start must not disturb the real owner")
        audio.stop()
    }

    /// A preempted meter calling `stopMonitoring()` a moment later must not close the microphone
    /// out from under the utterance that took it.
    @Test func aDisplacedOwnersStopDoesNotCloseTheNewOwnersCapture() async throws {
        let (audio, source) = bridge()
        try audio.start(for: .meter)
        try audio.start(for: .engine)

        audio.stop(for: .meter)               // the late stopMonitoring()
        #expect(audio.currentOwner == .engine)

        let received = Counter()
        audio.sink = { received.add($0.count) }
        source.push(tone())
        await audio.pipeline.drain()
        #expect(received.count > 0, "a displaced meter's stop closed the engine's microphone")
        audio.stop()
    }

    /// Ownership is released on a failed start too, so one bad start cannot wedge the graph.
    @Test func aFailedStartLeavesNoOwner() throws {
        let audio = PipelineAudioSource(pipeline: AudioPipeline(source: ThrowingCaptureSource(), vad: EnergyVAD()))
        audio.requireMicrophonePermission = false
        #expect(throws: AudioCaptureError.noInputDevice) { try audio.start(for: .engine) }
        #expect(audio.currentOwner == nil, "a failed start must not leave the graph owned")
        // Which means the next owner can still have it.
        let (working, _) = bridge()
        try working.start(for: .meter)
        #expect(working.currentOwner == .meter)
        working.stop(for: .meter)
    }
}

/// Thread-safe counters for the callbacks above.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var count: Int { lock.withLock { stored } }
    func add(_ n: Int) { lock.withLock { stored += n } }
}

final class OwnerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PipelineAudioSource.Owner] = []
    var owners: [PipelineAudioSource.Owner] { lock.withLock { stored } }
    func append(_ o: PipelineAudioSource.Owner) { lock.withLock { stored.append(o) } }
}

/// A capture source whose `start()` always fails, the way a denied microphone does.
final class ThrowingCaptureSource: AudioCaptureSource, @unchecked Sendable {
    var device: AudioDeviceInfo? { nil }
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    func prewarm() throws {}
    func start() throws { throw AudioCaptureError.noInputDevice }
    func stop() {}
    func switchDevice(to device: AudioDeviceInfo?) throws {}
}
