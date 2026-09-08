import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Regression cover for the 1.7.0 "downloaded a model, dictation is still dead" bug.
///
/// The engine was resolved once, at launch. A fresh install necessarily launches with no ASR model
/// on disk, so every collaborator got `UnavailableEngine` and kept it — for the whole life of the
/// process, however many models the user then downloaded. Before 1.7.0 the same staleness existed
/// but was masked: the composition root substituted `MockEngine`, so instead of a dead app you got
/// fabricated transcripts. Fixing the fabrication exposed the staleness.
///
/// The rule locked in here: the engine is a *box*, and installing a model swaps its contents
/// without recreating anything and without landing a half-finished utterance.
@Suite("The engine becomes live when a model lands, with no relaunch")
struct EngineSwapTests {
    static func fixture(_ text: String) -> TranscriptFixture {
        TranscriptFixture(name: "swap", spans: [.init(text: text, confidence: 0.9, audioStart: 0, audioEnd: 1, delayMs: 5)])
    }

    // MARK: The box itself

    @Test("an engine that starts unavailable transcribes after a model-available swap")
    func unavailableBecomesUsable() async throws {
        let engine = SwappableEngine(UnavailableEngine(lingerMs: 0))
        #expect(engine.isUnavailable)
        try await engine.start(prewarm: true)
        #expect(try await engine.stop().isEmpty, "nothing can be recognised yet")

        // The download lands.
        await engine.swap(to: MockEngine(fixture: Self.fixture("Hello there."), prewarmMs: 0))
        #expect(!engine.isUnavailable)

        try await engine.start(prewarm: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        let spans = try await engine.stop()
        #expect(spans.joinedText == "Hello there.", "the same box now produces real transcript")
    }

    @Test("subscribers bound before the swap see the transition")
    func subscribersSurviveTheSwap() async throws {
        let engine = SwappableEngine(UnavailableEngine(lingerMs: 0))
        var states: [String] = []
        let sink = engine.statePublisher.sink { states.append($0.caseName) }
        defer { sink.cancel() }
        let events = engine.events()

        try await engine.start(prewarm: true)
        _ = try await engine.stop()
        #expect(states.contains("unavailable"))

        await engine.swap(to: MockEngine(fixture: Self.fixture("After the swap."), prewarmMs: 0))

        let finals = FinalBox()
        let drain = Task {
            for await event in events {
                if case .final(let spans) = event { finals.append(spans.joinedText) }
            }
        }
        try await engine.start(prewarm: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        _ = try await engine.stop()
        // The forwarder hop is asynchronous; poll rather than guess how long a loaded machine takes.
        for _ in 0..<200 where finals.values.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        drain.cancel()

        #expect(finals.values == ["After the swap."], "the pre-swap event subscription still delivers")
        // States from the *new* engine, on a subscription taken before it existed. ("previewing"
        // would be nicer but depends on the mock's span timer winning a race under load; these two
        // are emitted synchronously by start/stop.)
        #expect(states.contains("listening"), "the pre-swap state subscription still delivers")
        #expect(states.contains("landed"))
    }

    @Test("the happy path — a model present at launch — is untouched")
    func modelPresentAtLaunchStillWorks() async throws {
        let engine = SwappableEngine(MockEngine(fixture: Self.fixture("Already installed."), prewarmMs: 0))
        #expect(!engine.isUnavailable)
        try await engine.start(prewarm: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(try await engine.stop().joinedText == "Already installed.")
    }

    @Test("a model deleted at runtime makes the box honestly unavailable again")
    func deletionSwapsBack() async throws {
        let engine = SwappableEngine(MockEngine(fixture: Self.fixture("gone"), prewarmMs: 0))
        await engine.swap(to: UnavailableEngine(lingerMs: 0))
        #expect(engine.isUnavailable)
        try await engine.start(prewarm: true)
        #expect(try await engine.stop().isEmpty)
    }

    @Test("a swap mid-utterance lands nothing — not half of it, not twice")
    func swapDuringUtteranceLandsNothing() async throws {
        let outgoing = MockEngine(fixture: Self.fixture("half an utterance"), prewarmMs: 0)
        let engine = SwappableEngine(outgoing)
        try await engine.start(prewarm: true)

        await engine.swap(to: MockEngine(fixture: Self.fixture("the new engine"), prewarmMs: 0))
        #expect(outgoing.state == .idle, "the outgoing engine is cancelled, not left listening")

        let spans = try await engine.stop()
        #expect(spans.isEmpty, "an utterance that started on the replaced engine must not land")

        // And the box is immediately usable for the *next* utterance.
        try await engine.start(prewarm: true)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(try await engine.stop().joinedText == "the new engine")
    }

    // MARK: The rule that decides when to swap

    @Test("only an availability flip swaps the engine")
    func refreshDecisionTable() {
        typealias D = AppContainer.RefreshDecision
        let unavailable = EngineFactory.Kind.unavailable(reason: EngineFactory.noRecognizerReason)
        let real = EngineFactory.Kind.real(recognizer: "Parakeet TDT 0.6B v3")
        #expect(AppContainer.refreshDecision(kind: unavailable, canRecognize: true) == D.activate)
        // A download that failed or was cancelled leaves nothing on disk: stay honestly unavailable.
        #expect(AppContainer.refreshDecision(kind: unavailable, canRecognize: false) == D.none)
        #expect(AppContainer.refreshDecision(kind: real, canRecognize: true) == D.none)
        #expect(AppContainer.refreshDecision(kind: real, canRecognize: false) == D.deactivate)
        // The mock engine is an explicit developer opt-in; a refresh must never take it away.
        #expect(AppContainer.refreshDecision(kind: .mock(fixture: "email_reply"), canRecognize: true) == D.none)
    }

    // MARK: Onboarding's "Dictate now"

    @Test("the onboarding dictation test re-resolves the engine before opening the microphone")
    @MainActor
    func guidedDictationPreparesTheEngine() async throws {
        let box = SwappableEngine(UnavailableEngine(lingerMs: 0))
        var deps = OnboardingDependencies.mock()
        deps.engine = box
        // Exactly what `AppContainer` installs: the model landed while the screen was open.
        let prepared = FinalBox()
        deps.prepareEngine = { @Sendable in
            prepared.append("prepared")
            await box.swap(to: MockEngine(fixture: Self.fixture("It landed."), prewarmMs: 0))
        }
        deps.models = OnboardingMockModelManager(installed: [.balanced])
        let model = OnboardingViewModel(dependencies: deps)
        model.send(.skip)               // welcome
        model.send(.skip)               // mic check (blocked without a grant)
        model.send(.choose(.balanced))
        model.send(.next)               // model choice → first dictation
        model.startGuidedDictation()
        for _ in 0..<200 where prepared.values.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }

        #expect(!prepared.values.isEmpty, "\"Dictate now\" must not inherit the launch-time engine")
        #expect(!box.isUnavailable)
        for _ in 0..<200 where box.state == .idle { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(box.state.isActive, "the microphone is open on the engine that can actually hear")
        model.teardown()
    }

    // MARK: The trigger

    /// Writes a model's required files on demand, so `ModelManager.isPresent` flips like a real
    /// download landing.
    final class StubFetcher: ModelFetcher, @unchecked Sendable {
        let shouldFail: Bool
        init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
        func fetch(_ descriptor: ModelDescriptor, into folder: URL, progress: ModelProgressHandler?) async throws {
            if shouldFail { throw URLError(.networkConnectionLost) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for p in descriptor.requiredPaths {
                let f = folder.appendingPathComponent(p)
                try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("stub".utf8).write(to: f)
            }
        }
    }

    static func manager(fetcher: StubFetcher) -> ModelManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-swap-\(UUID().uuidString)")
        return ModelManager(root: root, fetchers: [.finalTDT: fetcher, .streamingEOU: fetcher], externalCaches: [:])
    }

    @Test("a finished download tells the app the models changed; a failed one does not")
    func downloadNotifiesOnlyOnSuccess() async throws {
        let good = ModelManagerTiers(manager: Self.manager(fetcher: StubFetcher()), settings: InMemorySettingsStore())
        let counter = FinalBox()
        good.onModelsChanged = { counter.append("changed") }
        try await good.download(.fast) { _ in }
        #expect(!counter.values.isEmpty, "the engine must be re-resolved when a model lands")
        #expect(good.isInstalled(.fast))

        let bad = ModelManagerTiers(manager: Self.manager(fetcher: StubFetcher(shouldFail: true)), settings: InMemorySettingsStore())
        let noCounter = FinalBox()
        bad.onModelsChanged = { noCounter.append("changed") }
        await #expect(throws: (any Error).self) { try await bad.download(.fast) { _ in } }
        #expect(noCounter.values.isEmpty, "a failed download must leave the app honestly unavailable")
        #expect(!bad.isInstalled(.fast))
    }
}

/// Tiny thread-safe collector (the test bodies run across suspension points).
final class FinalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
}
