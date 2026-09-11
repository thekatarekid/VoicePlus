import Combine
import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// BUG 2 regression cover for the *wiring*, not just the state machine: the mic-check meter must be
/// driven by real `AudioPipelineEvent.level(rms:)` traffic through `PipelineAudioSource` and
/// `PipelineMicLevelPublisher`, with no ASR engine anywhere in the chain.
///
/// Everything here is the production code path except the HAL, which `FixtureCaptureSource` stands in
/// for (a real microphone and its TCC grant cannot be exercised from a test process — see the report).
@Suite("Mic check — real pipeline wiring")
struct MicCheckPipelineTests {
    /// 1 s of a −20 dBFS tone at 16 kHz: loud enough to clear the 0.08 "good" threshold.
    private func tone(seconds: Double = 1.0, amplitude: Float = 0.1) -> WAVFile {
        let n = Int(seconds * 16_000)
        let samples = (0..<n).map { amplitude * sin(Float($0) * 2 * .pi * 440 / 16_000) }
        return WAVFile(sampleRate: 16_000, samples: samples)
    }

    private func bridge(_ wav: WAVFile, noAudioTimeout: TimeInterval = 2) -> (PipelineAudioSource, FixtureCaptureSource) {
        let source = FixtureCaptureSource(wav: wav)
        var options = AudioPipeline.Options()
        options.noAudioTimeout = noAudioTimeout
        let bridge = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD(), options: options))
        bridge.requireMicrophonePermission = false   // no HAL, no TCC in this process
        return (bridge, source)
    }

    /// `PipelineMicLevelPublisher` opens the HAL off the main actor now, so a test that pushes
    /// fixture blocks has to wait for the pipeline to have installed its sink first.
    private func waitForCapture(_ audio: PipelineAudioSource) async throws {
        try await waitUntil(timeoutMs: 4000) { audio.pipeline.source.sink != nil }
    }

    /// The `.level(rms:)` channel the pipeline has always emitted now reaches a consumer.
    @Test func pipelineLevelEventsReachTheAudioSourceCallback() async throws {
        let (audio, source) = bridge(WAVFile(sampleRate: 16_000, samples: []))
        let levels = Box<[Float]>([])
        audio.onLevel = { levels.append($0) }
        try audio.start()
        source.push(tone().samples)
        await audio.pipeline.drain()
        audio.stop()
        #expect(!levels.value.isEmpty, "PipelineAudioSource dropped .level events again")
        #expect(levels.value.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(levels.value.contains { $0 > 0.08 }, "a −20 dBFS tone must clear the 'good' threshold")
    }

    /// End to end: pipeline → publisher → view model → meter, and the resulting verdict.
    @Test @MainActor func meterAndVerdictAreDrivenByRealAudio() async throws {
        let (audio, source) = bridge(WAVFile(sampleRate: 16_000, samples: []))
        let publisher = PipelineMicLevelPublisher(audio: audio)
        var deps = OnboardingDependencies.mock(permissionResults: [:])
        deps.micLevel = publisher
        (deps.permissions as? OnboardingMockPermissionChecker)?.statuses = [
            .microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted,
        ]
        let vm = OnboardingViewModel(dependencies: deps)
        #expect(publisher.isRealCapture)

        vm.send(.next)                       // all granted → straight to the meter
        #expect(vm.step == .microphone)
        #expect(vm.machine.micVerdict == .waiting)

        try await waitForCapture(audio)
        source.push(tone().samples)
        await audio.pipeline.drain()
        try await waitUntil(timeoutMs: 4000) { vm.machine.micVerdict == .good }
        #expect(vm.machine.micLevelEvents > 0, "the verdict must come from audio that actually arrived")
        #expect(vm.micLevel > 0)
        vm.teardown()
    }

    /// Silence that really is silence still reads as quiet — but only after enough blocks arrive.
    @Test @MainActor func genuineSilenceReadsAsQuietNotAsNoAudio() async throws {
        // Blocks of digital silence are audio: the watchdog is about blocks that never arrive.
        let (audio, source) = bridge(WAVFile(sampleRate: 16_000, samples: []))
        var deps = OnboardingDependencies.mock()
        deps.micLevel = PipelineMicLevelPublisher(audio: audio)
        (deps.permissions as? OnboardingMockPermissionChecker)?.statuses = [
            .microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted,
        ]
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        try await waitForCapture(audio)
        source.push([Float](repeating: 0, count: 16_000 * 2))
        await audio.pipeline.drain()
        try await waitUntil(timeoutMs: 6000) { vm.machine.micVerdict == .tooQuiet }
        #expect(vm.machine.micLevelEvents > 0, "quiet must be a statement about audio that arrived")
        #expect(vm.machine.micSettled)
        vm.teardown()
    }

    /// A start failure is reported as itself. Previously this was logged and swallowed, leaving the
    /// screen on "Very quiet" forever.
    @Test @MainActor func captureStartFailureBecomesAVisibleVerdict() async throws {
        let (audio, _) = bridge(WAVFile(sampleRate: 16_000, samples: []))
        audio.requireMicrophonePermission = true    // no HAL grant in this process → start throws
        guard !PipelineAudioSource.microphoneAuthorized else { return }
        var deps = OnboardingDependencies.mock()
        deps.micLevel = PipelineMicLevelPublisher(audio: audio)
        (deps.permissions as? OnboardingMockPermissionChecker)?.statuses = [
            .microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted,
        ]
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        try await waitUntil(timeoutMs: 4000) {
            if case .unavailable = vm.machine.micVerdict { return true }
            return false
        }
        vm.teardown()
    }

    /// The fixture-driven guarantee the mic check rests on: a started pipeline pushes real blocks
    /// all the way to the meter's own publisher, not just to `PipelineAudioSource`.
    @Test func startedPipelineDeliversBlocksToTheLevelPublisher() async throws {
        // The watchdog window has to outlast this test's own setup wait, or the two race: opening
        // capture is allowed 4 s below, so a 2 s default lets `.failed` fire before the tone is
        // pushed and the "no failure while audio was arriving" assertion fails for the wrong reason.
        // This test is about blocks reaching the publisher; the watchdog has its own test.
        let (audio, source) = bridge(WAVFile(sampleRate: 16_000, samples: []), noAudioTimeout: 30)
        let publisher = PipelineMicLevelPublisher(audio: audio)
        let signals = Box<[MicCheckSignal]>([])
        let cancellable = publisher.signalPublisher.sink { s in signals.mutate { $0.append(s) } }
        defer { cancellable.cancel() }

        publisher.startMonitoring()
        try await waitForCapture(audio)
        source.push(tone().samples)
        await audio.pipeline.drain()
        try await waitUntil(timeoutMs: 4000) { signals.value.contains { if case .level = $0 { return true }; return false } }
        publisher.stopMonitoring()

        let levels = signals.value.compactMap { s -> Float? in if case .level(let l) = s { return l }; return nil }
        #expect(!levels.isEmpty, "no audio block reached the mic-check meter")
        #expect(levels.contains { $0 > 0.08 }, "a −20 dBFS tone must move the meter")
        #expect(!signals.value.contains { if case .failed = $0 { return true }; return false },
                "the watchdog reported a failure while audio was arriving")
    }

    /// BUG (1.6.3) regression: capture started, no block ever arrived, and the screen said nothing.
    /// The no-audio watchdog must turn that into a visible failure on the mic-check signal.
    @Test func noAudioWatchdogSurfacesAsAMicCheckFailure() async throws {
        // Starts cleanly, delivers nothing — the shape of a tap that can never fire.
        let (audio, _) = bridge(WAVFile(sampleRate: 16_000, samples: []), noAudioTimeout: 0.2)
        let publisher = PipelineMicLevelPublisher(audio: audio)
        let signals = Box<[MicCheckSignal]>([])
        let cancellable = publisher.signalPublisher.sink { s in signals.mutate { $0.append(s) } }
        defer { cancellable.cancel() }

        publisher.startMonitoring()
        // `startMonitoring` opens capture from a detached task that then blocks on a semaphore
        // waiting for a second detached task (`PipelineAudioSource.start`). Both need a thread from
        // the same cooperative pool, so under a saturated whole-suite run the watchdog can take far
        // longer than the 0.2 s window to arm. The assertion is that it fires, not how fast.
        try await waitUntil(timeoutMs: 20_000) {
            signals.value.contains { if case .failed = $0 { return true }; return false }
        }
        publisher.stopMonitoring()

        let reason = signals.value.compactMap { s -> String? in if case .failed(let r) = s { return r }; return nil }.first
        let text = try #require(reason)
        #expect(text.contains("No sound is reaching VoicePlus"))
        #expect(text.contains("not one audio block arrived"))
    }

    @Test func startTimeoutIsAFailureNotASilentSuccess() {
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.noInputDevice).contains("older copy"))
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.engineStartFailed("boom")).contains("boom"))
        // A graph whose tap could never fire must read as a format problem, not as a quiet room.
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.formatMismatch(hardware: 48_000, client: 44_100)).contains("48000 Hz"))
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.formatMismatch(hardware: 0, client: 0)).contains("could not be opened"))
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.noAudio(seconds: 2)).contains("No sound is reaching"))
    }
}

/// Minimal thread-safe accumulator for callbacks fired off the test's actor.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.withLock { storage } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&storage) } }
}

extension Box where T == [Float] {
    func append(_ element: Float) { mutate { $0.append(element) } }
}
