import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// S7e (design §8.4) — "Stop releases the mic" for speaker enrollment. The recorder here has the
/// live recorder's shape (`AppDelegate.makeSpeakerEnrollment`): open the microphone, wait out the
/// take, and on cancellation close the microphone at once and return nothing. The real engine and
/// HAL are not opened; the microphone is `EnrollmentMic`.
@MainActor
@Suite("S7e — enrollment Stop cancels the take and releases the microphone")
struct EnrollmentStopTests {
    /// A microphone opened and closed by the recorder. `takes` counts recorder calls.
    final class EnrollmentMic: @unchecked Sendable {
        private let lock = NSLock()
        private var _open = false, _takes = 0, _closedByCancel = 0
        var isOpen: Bool { lock.withLock { _open } }
        var takes: Int { lock.withLock { _takes } }
        var closedByCancel: Int { lock.withLock { _closedByCancel } }
        func open() { lock.withLock { _open = true; _takes += 1 } }
        func close(cancelled: Bool) { lock.withLock { _open = false; if cancelled { _closedByCancel += 1 } } }
    }

    /// The first `quick` takes return speech at once; every later take blocks for a minute, the way the
    /// live recorder holds the microphone for its take, until the take is cancelled.
    static func recorder(_ mic: EnrollmentMic, quick: Int) -> () async -> [Float] {
        return {
            mic.open()
            if mic.takes <= quick {
                mic.close(cancelled: false)
                return [Float](repeating: 0.1, count: 16_000)
            }
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                mic.close(cancelled: true)
                return []
            }
            mic.close(cancelled: false)
            return [Float](repeating: 0.1, count: 16_000)
        }
    }

    static func waitUntil(timeout: TimeInterval = 120, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw CancellationError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("Voice › Stop on the last phrase: the recorder is cancelled, no profile, capture idle")
    func stopOnTheLastPhrase() async throws {
        let mic = EnrollmentMic()
        let model = SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true),
                                               record: Self.recorder(mic, quick: SpeakerEnrollment.requiredUtterances - 1))
        var installed: [SpeakerProfile] = []
        model.onComplete = { installed.append($0) }
        let voice = VoiceSectionS7eTests.voice()
        voice.install(enrollment: model)
        for _ in 0..<(SpeakerEnrollment.requiredUtterances - 1) {
            model.recordUtterance()
            try await Self.waitUntil { !model.isRecording }
        }
        #expect(model.enrollment.embeddings.count == SpeakerEnrollment.requiredUtterances - 1)

        model.recordUtterance()
        try await Self.waitUntil { mic.isOpen }
        #expect(model.capture == .capturing && model.isRecording)
        voice.cancelEnrollment()   // the pane's Stop
        #expect(model.capture == .idle && !model.isRecording, "Stop is immediate in the view")
        #expect(voice.enrolling == nil)
        try await Self.waitUntil { !mic.isOpen }
        #expect(mic.closedByCancel == 1, "the recorder saw the cancellation and closed the microphone")
        // Give a late take every chance to embed or complete: it must not.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(installed.isEmpty, "a stopped take never installs a profile")
        #expect(model.enrollment.embeddings.count == SpeakerEnrollment.requiredUtterances - 1)
        #expect(!model.isDone)
        #expect(model.capture == .idle && !model.isRecording)
        #expect(model.status == SpeakerEnrollmentCopy.instruction)
    }

    @Test("a take that ignores the cancellation and returns late is dropped, never the next take's")
    func lateTakeIsDropped() async throws {
        final class Gate: @unchecked Sendable { var continuations: [CheckedContinuation<[Float], Never>] = [] }
        let gate = Gate()
        let model = SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true)) {
            await withCheckedContinuation { gate.continuations.append($0) }
        }
        var installed = 0
        model.onComplete = { _ in installed += 1 }
        model.recordUtterance()
        try await Self.waitUntil { gate.continuations.count == 1 }
        model.cancel()
        #expect(!model.isRecording && model.capture == .idle)
        // The next take starts before the stopped one wakes up.
        model.recordUtterance()
        try await Self.waitUntil { gate.continuations.count == 2 }
        gate.continuations[0].resume(returning: [Float](repeating: 0.1, count: 16_000))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.enrollment.embeddings.isEmpty, "the stopped take is not embedded")
        #expect(model.isRecording && model.capture == .capturing, "and it does not end the running take")
        gate.continuations[1].resume(returning: [Float](repeating: 0.1, count: 16_000))
        try await Self.waitUntil { !model.isRecording }
        #expect(model.enrollment.embeddings.count == 1)
        #expect(model.status == SpeakerEnrollmentCopy.accepted(1))
        #expect(installed == 0)
    }

    @Test("onboarding: leaving the Voice step mid-take releases the microphone")
    func onboardingLeaveCancels() async throws {
        let mic = EnrollmentMic()
        var deps = OnboardingS8ViewModelTests.deps(resumeAt: .voice)
        deps.makeEnrollment = {
            SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true), record: Self.recorder(mic, quick: 0))
        }
        var installed = 0
        deps.installVoiceProfile = { _ in installed += 1; return true }
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.beginVoiceEnrollment)
        let enrollment = try #require(vm.enrollment)
        enrollment.recordUtterance()
        try await Self.waitUntil { mic.isOpen }
        vm.send(.back)
        #expect(vm.enrollment == nil)
        #expect(!enrollment.isRecording && enrollment.capture == .idle)
        try await Self.waitUntil { !mic.isOpen }
        #expect(mic.closedByCancel == 1)
        #expect(installed == 0)
        vm.teardown()
    }

    @Test("Stop with no take running changes nothing; Start over stops a take first")
    func cancelIsIdempotent() async throws {
        let mic = EnrollmentMic()
        let model = SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true),
                                               record: Self.recorder(mic, quick: 1))
        model.cancel()
        #expect(model.capture == .idle && model.status == SpeakerEnrollmentCopy.instruction)
        model.recordUtterance()
        try await Self.waitUntil { !model.isRecording }
        #expect(model.status == SpeakerEnrollmentCopy.accepted(1))
        model.cancel()
        #expect(model.status == SpeakerEnrollmentCopy.accepted(1), "nothing running: the last line stays")
        model.recordUtterance()
        try await Self.waitUntil { mic.isOpen }
        model.reset()
        try await Self.waitUntil { !mic.isOpen }
        #expect(model.enrollment.embeddings.isEmpty && !model.isRecording)
    }

    @Test("the live recorder closes the engine when its take is cancelled")
    func liveRecorderHandlesCancellation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
        let recorder = try #require(source.range(of: "private func makeSpeakerEnrollment").map { String(source[$0.lowerBound...].prefix(1200)) })
        #expect(!recorder.contains("try? await Task.sleep"), "a swallowed cancellation keeps the microphone open")
        #expect(recorder.contains("} catch {") && recorder.contains("return []"))
    }
}
