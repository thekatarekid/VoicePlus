import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Keeps the original practice continuation so a test can replay events that were queued by the
/// button's engine run, after its result has already reached the main actor.
private final class GuidedPracticeProbe: EngineProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [AsyncStream<EngineEvent>.Continuation] = []
    private let subject = CurrentValueSubject<EngineState, Never>(.idle)
    let spans = [TranscriptSpan(text: "The quick brown fox", confidence: 1, audioRange: 0...1)]
    var state: EngineState { subject.value }
    var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
    func events() -> AsyncStream<EngineEvent> {
        AsyncStream { continuation in lock.withLock { streams.append(continuation) } }
    }
    func prewarm() async throws {}
    func start(prewarm: Bool) async throws { subject.send(.listening(level: 0)) }
    func stop() async throws -> [TranscriptSpan] { subject.send(.idle); return spans }
    func cancel() async { subject.send(.idle) }
    func replayOldPracticeEvent() -> Bool {
        let stream = lock.withLock { streams.first }
        guard let stream else { return false }
        if case .terminated = stream.yield(.partial(spans)) { return true }
        return false
    }
    func emit(_ event: EngineEvent) {
        for stream in lock.withLock({ streams }) { stream.yield(event) }
    }
}

@Suite("Guided dictation owns its engine events")
@MainActor
struct GuidedPracticeOwnershipTests {
    @Test func completedButtonResultRejectsItsOldPracticeEventsAndAcceptsTheNextRealTurn() async throws {
        let engine = GuidedPracticeProbe()
        var dependencies = OnboardingDependencies.mock()
        dependencies.engine = engine
        dependencies.models = OnboardingMockModelManager.installed()
        let model = OnboardingViewModel(dependencies: dependencies)
        defer { model.teardown() }
        model.send(.skip); model.send(.skip); model.send(.skip)
        try await waitUntil { model.step == .firstDictation && model.dictationGate.canRun }
        model.startGuidedDictation()
        model.finishGuidedDictation()
        try await waitUntil { !model.isDictating && model.machine.dictation != nil }
        #expect(model.machine.heardText == "The quick brown fox")
        // The old subscription must be terminated, so a delayed guided partial cannot masquerade
        // as the next real hotkey press and send retryDictation over the successful verdict.
        #expect(engine.replayOldPracticeEvent())
        #expect(model.practice.phase == .waiting)
        engine.emit(.state(.listening(level: 0.5)))
        engine.emit(.partial(engine.spans))
        engine.emit(.final(engine.spans))
        try await waitUntil { model.practice.phase == .preview }
        model.practiceInsertionTimedOut()
        #expect(model.machine.heardText == "The quick brown fox")
        #expect(model.practice.phase == .notInserted)
    }
}
