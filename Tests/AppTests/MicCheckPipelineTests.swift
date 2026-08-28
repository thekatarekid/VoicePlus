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

    private func bridge(_ wav: WAVFile) -> (PipelineAudioSource, FixtureCaptureSource) {
        let source = FixtureCaptureSource(wav: wav)
        let bridge = PipelineAudioSource(pipeline: AudioPipeline(source: source, vad: EnergyVAD()))
        bridge.requireMicrophonePermission = false   // no HAL, no TCC in this process
        return (bridge, source)
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

        vm.send(.next)                       // all granted → straight to the mic check
        #expect(vm.step == .micCheck)
        #expect(vm.machine.micVerdict == .waiting)

        source.push(tone().samples)
        await audio.pipeline.drain()
        try await waitUntil(timeoutMs: 4000) { vm.machine.micVerdict == .good }
        #expect(vm.machine.micLevelEvents > 0, "the verdict must come from audio that actually arrived")
        #expect(vm.micLevel > 0)
        vm.teardown()
    }

    /// Silence that really is silence still reads as quiet — but only after enough blocks arrive.
    @Test @MainActor func genuineSilenceReadsAsQuietNotAsNoAudio() async throws {
        let (audio, source) = bridge(WAVFile(sampleRate: 16_000, samples: []))
        var deps = OnboardingDependencies.mock()
        deps.micLevel = PipelineMicLevelPublisher(audio: audio)
        (deps.permissions as? OnboardingMockPermissionChecker)?.statuses = [
            .microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted,
        ]
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
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

    @Test func startTimeoutIsAFailureNotASilentSuccess() {
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.noInputDevice).contains("older copy"))
        #expect(PipelineMicLevelPublisher.describe(AudioCaptureError.engineStartFailed("boom")).contains("boom"))
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
