import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// MARK: - Engines the onboarding dictation test can be driven against

/// An engine whose `stop()` fails the way FluidAudio's does — with a `LocalizedError` whose *case
/// name* is `invalidAudioData` and whose sentence is readable. Both matter: the 1.6.6 pill showed
/// the case name because `RealEngine` interpolated the error instead of describing it.
private struct FluidAudioLikeError: LocalizedError {
    var errorDescription: String? { "Invalid audio data provided. Must be at least 300ms of 16kHz audio." }
}

/// Minimal `EngineProtocol` under the view model's control: it can report how much audio it holds
/// (like `RealEngine`), fail on stop, or return scripted spans.
private final class StubEngine: EngineProtocol, CapturedAudioReporting, @unchecked Sendable {
    enum Behaviour { case spans([TranscriptSpan]), failStop(Error), failStart(Error) }

    private let subject = CurrentValueSubject<EngineState, Never>(.idle)
    private let broadcaster = EngineEventBroadcaster()
    var behaviour: Behaviour
    /// What `capturedSeconds` reports — the hook the view model uses to refuse a doomed final pass.
    var seconds: Double
    let minimumUtteranceSeconds: TimeInterval = 0.3
    private(set) var stopCalls = 0
    private(set) var cancelCalls = 0

    init(behaviour: Behaviour = .spans([]), seconds: Double = 2) {
        self.behaviour = behaviour
        self.seconds = seconds
    }

    var state: EngineState { subject.value }
    var statePublisher: AnyPublisher<EngineState, Never> { subject.eraseToAnyPublisher() }
    func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }
    var capturedSeconds: Double { get async { seconds } }

    func prewarm() async throws {}

    func start(prewarm: Bool) async throws {
        if case .failStart(let error) = behaviour { throw error }
        subject.send(.listening(level: 0))
    }

    func stop() async throws -> [TranscriptSpan] {
        stopCalls += 1
        switch behaviour {
        case .failStop(let error): subject.send(.error("boom")); throw error
        case .failStart: return []
        case .spans(let spans): subject.send(.idle); return spans
        }
    }

    func cancel() async { cancelCalls += 1; subject.send(.idle) }
}

/// Holds a mock download open until the test lets it finish.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.withLock { opened = true } }
    var isOpen: Bool { lock.withLock { opened } }
    func wait() async {
        while !isOpen { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private func fox(_ text: String = "The quick brown fox jumps over the lazy dog.") -> [TranscriptSpan] {
    [TranscriptSpan(text: text, confidence: 0.97, audioRange: 0...2.4, provenance: [.asr])]
}

@MainActor
private func onboardingAtDictationStep(engine: EngineProtocol,
                                       models: OnboardingMockModelManager = OnboardingMockModelManager(installed: [.balanced]),
                                       land: (@Sendable ([TranscriptSpan]) async -> GuidedLanding)? = nil)
    -> OnboardingViewModel {
    var deps = OnboardingDependencies.mock()
    deps.engine = engine
    deps.models = models
    deps.landUtterance = land
    let vm = OnboardingViewModel(dependencies: deps)
    // With no microphone grant the mic-check step is blocked rather than skipped silently, so it
    // takes two skips from the welcome screen to reach the model picker.
    vm.send(.skip)
    vm.send(.skip)
    vm.send(.choose(.balanced))
    // Continue only opens once the model is really there; a test with nothing installed skips.
    vm.send(vm.machine.canContinueFromModelChoice ? .next : .skip)
    return vm
}

// MARK: - P2

/// The 1.6.6 report: the overlay showed a red microphone and `⚠ invalidAudioData`, nothing was
/// typed, and the onboarding screen underneath showed a green check and "It landed. You're set."
/// Two claims about one attempt, and the more visible one was false.
@Suite("P2 — the dictation test reports what actually happened")
struct GuidedDictationOutcomeTests {
    typealias M = OnboardingStateMachine

    @Test func successMessageNeedsARealLanding() {
        var m = M()
        // welcome → mic check (blocked, no grant) → model choice → dictation. Continue needs an
        // installed model now, so the model step is reached with one already present.
        m.handle(.skip); m.handle(.skip)
        m.handle(.modelPresenceChanged([.fast])); m.handle(.choose(.fast)); m.handle(.next)
        #expect(m.step == .firstDictation)

        m.handle(.dictationFinished(.heard(text: "hello", recognizer: "Parakeet TDT 0.6B v3")))
        #expect(m.landedText == nil, "transcribed-but-not-typed must never read as “It landed”")
        #expect(m.heardText == "hello")
        #expect(m.dictationError == nil)

        m.handle(.dictationFinished(.landed(text: "hello", app: "Notes")))
        #expect(m.landedText == "hello")
    }

    /// The exact old shape: failure reported through the success event with an empty payload, which
    /// the view read as `landedText != nil` and drew a green check for. The event no longer exists,
    /// and every failure case carries its message.
    @Test func failureCanNotMasqueradeAsSuccess() {
        var m = M()
        // welcome → mic check (blocked, no grant) → model choice → dictation. Continue needs an
        // installed model now, so the model step is reached with one already present.
        m.handle(.skip); m.handle(.skip)
        m.handle(.modelPresenceChanged([.fast])); m.handle(.choose(.fast)); m.handle(.next)
        m.handle(.dictationFinished(.failed(reason: "Invalid audio data provided. Must be at least 300ms of 16kHz audio.")))
        #expect(m.landedText == nil)
        #expect(m.heardText == nil)
        #expect(m.dictationError == "Invalid audio data provided. Must be at least 300ms of 16kHz audio.")

        m.handle(.dictationFinished(.noSpeech(seconds: 0.1)))
        #expect(m.landedText == nil)
        #expect(m.dictationError?.contains("0.1 s") == true)
        #expect(m.dictationError?.contains("too short") == true)
    }

    @Test func retryClearsTheStaleVerdict() {
        var m = M()
        // welcome → mic check (blocked, no grant) → model choice → dictation. Continue needs an
        // installed model now, so the model step is reached with one already present.
        m.handle(.skip); m.handle(.skip)
        m.handle(.modelPresenceChanged([.fast])); m.handle(.choose(.fast)); m.handle(.next)
        m.handle(.dictationFinished(.failed(reason: "nope")))
        #expect(m.dictationError == "nope")
        #expect(m.handle(.retryDictation) == [.checkRecognizerReadiness])
        #expect(m.dictation == nil)
    }

    /// The root cause. `runGuidedDictation` used to call `engine.start` and `engine.stop` in
    /// consecutive statements, so the capture window was zero-length: the user spoke *after* the
    /// engine had stopped, the final pass got ~0 samples, and FluidAudio threw. There is now no way
    /// to finalise without a second, separate press.
    @MainActor
    @Test func startAndStopAreTwoSeparatePresses() async throws {
        let engine = StubEngine(behaviour: .spans(fox()))
        let vm = onboardingAtDictationStep(engine: engine)

        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        #expect(vm.machine.dictation == nil, "no verdict may exist while the capture window is open")
        #expect(engine.stopCalls == 0, "start must not finalise")

        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(engine.stopCalls == 1)
        #expect(vm.machine.heardText?.contains("quick brown fox") == true)
        #expect(!vm.isDictating)
        vm.teardown()
    }

    /// A second press of Stop must not run a second `engine.stop()`: that throws `notListening`, and
    /// reporting it would replace a perfectly good transcript with a failure the user did not cause.
    @MainActor
    @Test func aSecondPressOfStopCannotOverwriteAGoodResult() async throws {
        let engine = StubEngine(behaviour: .spans(fox()))
        let vm = onboardingAtDictationStep(engine: engine)
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }

        vm.finishGuidedDictation()
        #expect(vm.isFinalizing)
        vm.finishGuidedDictation()          // impatient second click
        vm.toggleGuidedDictation()          // and the button itself
        try await waitUntil { vm.machine.dictation != nil }

        #expect(engine.stopCalls == 1)
        #expect(vm.machine.heardText?.contains("quick brown fox") == true)
        #expect(vm.machine.dictationError == nil)
        #expect(!vm.isFinalizing)
        vm.teardown()
    }

    /// With no landing path wired, the honest answer is "heard", never "landed" — pressing a button
    /// inside the onboarding window makes VoicePlus frontmost, so there is no other field to type in.
    @MainActor
    @Test func withoutALandingPathTheScreenSaysHeardNotLanded() async throws {
        let vm = onboardingAtDictationStep(engine: StubEngine(behaviour: .spans(fox())))
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(vm.machine.landedText == nil)
        #expect(vm.machine.heardText != nil)
        vm.teardown()
    }

    /// And when a landing path *is* wired, "It landed" follows the injector's own verdict — the
    /// signal `LandingResult.landed` has always carried and nothing read.
    @MainActor
    @Test func aRealInjectionIsWhatEarnsTheSuccessMessage() async throws {
        for injected in [true, false] {
            let vm = onboardingAtDictationStep(engine: StubEngine(behaviour: .spans(fox()))) { spans in
                GuidedLanding(text: spans.joinedText, injected: injected, appName: "Notes")
            }
            vm.startGuidedDictation()
            try await waitUntil { vm.isDictating }
            vm.finishGuidedDictation()
            try await waitUntil { vm.machine.dictation != nil }
            #expect((vm.machine.landedText != nil) == injected)
            #expect(vm.machine.heardText != nil, "the text was transcribed either way")
            vm.teardown()
        }
    }

    /// A throw from the engine surfaces as the author's sentence, not as an enum case name.
    @MainActor
    @Test func aFailedAttemptShowsTheRealErrorInPlainLanguage() async throws {
        let vm = onboardingAtDictationStep(engine: StubEngine(behaviour: .failStop(FluidAudioLikeError())))
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(vm.machine.landedText == nil)
        #expect(vm.machine.dictationError == "Invalid audio data provided. Must be at least 300ms of 16kHz audio.")
        #expect(vm.machine.dictationError?.contains("invalidAudioData") == false,
                "the raw enum case name is what the user was shown in 1.6.6")
        vm.teardown()
    }

    @MainActor
    @Test func aStartThatFailsIsReportedAsAFailureNotASuccess() async throws {
        let vm = onboardingAtDictationStep(engine: StubEngine(behaviour: .failStart(EngineError.modelUnavailable("tdt-v3"))))
        vm.startGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(vm.machine.landedText == nil)
        #expect(vm.machine.dictationError == "No speech model is ready yet (tdt-v3).")
        #expect(!vm.isDictating)
        vm.teardown()
    }

    /// Under the recogniser's floor the screen says "too short" in its own words and the recogniser
    /// is never called, so `invalidAudioData` cannot be produced in the first place.
    @MainActor
    @Test func tooLittleAudioSaysSoAndNeverRunsTheFinalPass() async throws {
        let engine = StubEngine(behaviour: .spans(fox()), seconds: 0.12)
        let vm = onboardingAtDictationStep(engine: engine)
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(engine.stopCalls == 0, "a doomed final pass must not be attempted")
        #expect(engine.cancelCalls == 1, "the utterance is dropped, not left half-open")
        #expect(vm.machine.dictation == .noSpeech(seconds: 0.12))
        #expect(vm.machine.landedText == nil)
        vm.teardown()
    }

    /// Spans that come back empty are not a success either.
    @MainActor
    @Test func anEmptyTranscriptIsNotASuccess() async throws {
        let vm = onboardingAtDictationStep(engine: StubEngine(behaviour: .spans([]), seconds: 3))
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(vm.machine.landedText == nil)
        #expect(vm.machine.heardText == nil)
        #expect(vm.machine.dictationError != nil)
        vm.teardown()
    }

    /// Closing the window mid-utterance must release the microphone rather than leave the engine
    /// listening behind a screen that no longer exists.
    @MainActor
    @Test func teardownMidUtteranceReleasesTheMicrophone() async throws {
        let engine = StubEngine(behaviour: .spans(fox()))
        let vm = onboardingAtDictationStep(engine: engine)
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.teardown()
        #expect(!vm.isDictating)
        try await waitUntil { engine.cancelCalls == 1 }
    }
}

// MARK: - P3

@Suite("P3 — the dictation test never pretends a missing model is working")
struct RecognizerReadinessTests {
    typealias M = OnboardingStateMachine

    @Test func gateNamesTheModelThatWillActuallyRun() {
        let ready = GuidedDictationGate.decide(readiness: .ready(name: "Parakeet TDT 0.6B v3"), download: .installed)
        #expect(ready.canRun)
        #expect(ready.banner == "Using Parakeet TDT 0.6B v3.")
        #expect(!ready.isWarning)
    }

    /// "explicitly fall back … and SAY so": the banner names both what is running now and what is
    /// still on its way, with how far along it is.
    @Test func gateNamesTheFallbackAndWhatIsStillDownloading() {
        let progress = ModelDownloadProgress(fraction: 0.42, bytesReceived: 378_000_000,
                                             bytesExpected: 900_000_000, modelName: "Parakeet TDT 0.6B v3")
        let d = GuidedDictationGate.decide(
            readiness: .fallback(name: "Apple Speech (on-device)", awaiting: "Parakeet TDT 0.6B v3"),
            download: .downloading(progress))
        #expect(d.canRun, "a 900 MB download must not block the last onboarding step")
        #expect(d.banner == "Using Apple Speech (on-device) for now — Parakeet TDT 0.6B v3 is still downloading — 42%.")
    }

    @Test func gateSaysWhenTheDownloadFailedAndWhatIsRunningInstead() {
        let d = GuidedDictationGate.decide(readiness: .fallback(name: "Parakeet TDT-CTC 110M (tiny)", awaiting: nil),
                                           download: .failed("the network connection was lost"))
        #expect(d.canRun)
        #expect(d.isWarning)
        #expect(d.banner.contains("Parakeet TDT-CTC 110M (tiny)"))
        #expect(d.banner.contains("the network connection was lost"))
    }

    /// The one case where the test is genuinely refused: nothing on the machine can transcribe, so
    /// offering the button would be offering a failure.
    @Test func gateRefusesWhenNothingCanTranscribe() {
        let d = GuidedDictationGate.decide(readiness: .unavailable(reason: "No speech model has finished downloading yet."),
                                           download: .downloading(ModelDownloadProgress(fraction: 0.1, bytesReceived: 1, bytesExpected: 10, modelName: "x")))
        #expect(!d.canRun)
        #expect(d.isWarning)
        #expect(d.banner == "No speech model has finished downloading yet.")
    }

    @MainActor
    @Test func theButtonDoesNothingWhileNothingCanTranscribe() async throws {
        let models = OnboardingMockModelManager(installed: [])
        models.fallbackName = nil                       // no Parakeet, no Apple Speech
        let gate = TestGate()
        models.hold = { await gate.wait() }             // the download never lands during the test
        defer { gate.open() }
        let engine = StubEngine(behaviour: .spans(fox()))
        let vm = onboardingAtDictationStep(engine: engine, models: models)
        try await waitUntil { !vm.dictationGate.canRun }

        vm.startGuidedDictation()
        #expect(!vm.isDictating, "the test must not start against a recogniser that does not exist")
        #expect(engine.stopCalls == 0)
        #expect(vm.machine.dictation == nil)
        vm.teardown()
    }

    /// Entering the step asks which recogniser is available, so the banner is right before the
    /// button is drawn rather than after the first failure.
    @MainActor
    @Test func enteringTheStepAsksWhichRecognizerIsReady() async throws {
        let vm = onboardingAtDictationStep(engine: StubEngine(), models: OnboardingMockModelManager(installed: [.balanced]))
        #expect(vm.machine.readiness == .ready(name: "Parakeet TDT 0.6B v3"))
        #expect(vm.dictationGate.banner == "Using Parakeet TDT 0.6B v3.")
        vm.teardown()
    }

    @Test func enteringTheDictationStepChecksReadinessBeforeAnythingElse() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        m.handle(.modelPresenceChanged([.fast])); m.handle(.choose(.fast))
        #expect(m.handle(.next) == [.checkRecognizerReadiness, .beginGuidedDictation])
    }

    /// The second half of P3, restated for the explicit buttons: each option's Download press fetches
    /// that option, whatever any other option has already done — and a failure is retryable.
    @Test func eachOptionsDownloadButtonFetchesThatOption() {
        var m = M()
        m.handle(.skip); m.handle(.skip)
        #expect(m.handle(.download(.fast)) == [.selectModel(.fast), .startDownload(.fast)])
        m.handle(.downloadFinished(.fast))
        #expect(m.handle(.download(.best)) == [.selectModel(.best), .startDownload(.best)],
                "a tier downloaded after another one finished must still be fetched")
        m.handle(.downloadFailed(.best, "no network"))
        #expect(m.downloadState(for: .fast) == .installed, "one option's failure is not another's")
        #expect(m.handle(.download(.best)) == [.selectModel(.best), .startDownload(.best)],
                "Retry after a failure fetches it again")
    }

    /// `ModelManagerTiers.readiness` mirrors `RecognizerFactory.chooseFinal`, so the screen names the
    /// recogniser the engine will really pick. Driven over a real `ModelManager` on a scratch root.
    @Test func readinessFollowsWhatIsOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-readiness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(root: root, externalCaches: [:])
        let tiers = ModelManagerTiers(manager: manager, settings: InMemorySettingsStore())
        tiers.appleSpeechAvailable = { false }
        await tiers.refresh()

        // Empty disk, no Apple Speech: nothing can transcribe, and the screen must say so.
        var readiness = tiers.readiness(for: .best)
        #expect(readiness == .unavailable(reason: "No speech model has finished downloading yet, and macOS' own on-device recogniser isn't available on this Mac. There is nothing to transcribe with until the download lands."))

        // The tiny model lands: it stands in for "Best", and the screen names both.
        try stubModel(.parakeetTDTCTC110m, under: root)
        await tiers.refresh()
        readiness = tiers.readiness(for: .best)
        #expect(readiness == .fallback(name: "Parakeet TDT-CTC 110M (tiny)", awaiting: "Parakeet TDT 0.6B v3"))

        // Both of "Best"'s models land: it is now genuinely ready and named as itself.
        try stubModel(.parakeetTDTv3, under: root)
        try stubModel(.parakeetEOU160, under: root)
        await tiers.refresh()
        readiness = tiers.readiness(for: .best)
        #expect(readiness == .ready(name: "Parakeet TDT 0.6B v3"))
    }

    private func stubModel(_ id: ModelID, under root: URL) throws {
        // Not `id.rawValue`: since 1.7.13 the folder is `ModelDescriptor.folderName`, which is
        // FluidAudio's own `Repo.folderName` — the name its loaders resolve to. See `ModelCatalog`.
        let folder = ModelCatalog.folder(for: id, in: root)
        for path in ModelCatalog.descriptor(id).requiredPaths {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("stub".utf8).write(to: file)
        }
    }
}

/// "The user must never be left guessing whether a 1.2 GB download has started."
@Suite("P3 — download progress says bytes, percent and how long")
struct DownloadProgressTextTests {
    private func progress(_ fraction: Double) -> ModelDownloadProgress {
        ModelDownloadProgress(fraction: fraction, bytesReceived: Int64(900_000_000 * fraction),
                              bytesExpected: 900_000_000, modelName: "Parakeet TDT 0.6B v3",
                              index: 1, count: 2)
    }

    @Test func bytesAreDecimalAndLocaleIndependent() {
        #expect(ByteText.short(110_000_000) == "110 MB")
        #expect(ByteText.short(500_000_000) == "500 MB")
        #expect(ByteText.short(900_000_000) == "900 MB")
        #expect(ByteText.short(1_200_000_000) == "1.2 GB")
        #expect(ByteText.short(0) == "0 MB")
    }

    @Test func theLineNamesTheModelTheBytesAndThePosition() {
        let line = DownloadProgressText.line(progress(0.42), elapsed: 60)
        #expect(line.hasPrefix("Downloading Parakeet TDT 0.6B v3 (1 of 2) — 378 MB of 900 MB (42%)"))
    }

    @Test func anEstimateAppearsOnlyOnceItMeansSomething() {
        // Too early in the download, and too early in wall-clock time: no number at all beats a
        // number that triples on the next tick.
        #expect(DownloadProgressText.remaining(progress(0.01), elapsed: 30) == nil)
        #expect(DownloadProgressText.remaining(progress(0.5), elapsed: 1) == nil)
        #expect(DownloadProgressText.remaining(progress(1), elapsed: 300) == nil)
        // Half of a download that has taken 60 s has about 60 s to go.
        #expect(DownloadProgressText.remaining(progress(0.5), elapsed: 60) == "about 60 seconds")
        #expect(DownloadProgressText.remaining(progress(0.25), elapsed: 120) == "about 6 min")
    }

    @Test func durationsAreRoundedToSomethingAPersonWouldSay() {
        #expect(DownloadProgressText.duration(4) == "a few seconds")
        #expect(DownloadProgressText.duration(47) == "about 45 seconds")
        #expect(DownloadProgressText.duration(200) == "about 3 min")
        #expect(DownloadProgressText.duration(7200) == "about 2.0 hours")
    }

    @MainActor
    @Test func theViewModelPublishesTheLineWhileADownloadIsInFlight() async throws {
        var deps = OnboardingDependencies.mock()
        let models = OnboardingMockModelManager(installed: [])
        // Held open by the test rather than by a sleep, so a loaded machine cannot let the whole
        // download finish between two polls and leave the assertion looking at `.installed`.
        let gate = TestGate()
        models.hold = { await gate.wait() }
        deps.models = models
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip); vm.send(.skip)   // welcome → blocked mic check → model choice
        vm.send(.download(.best))
        try await waitUntil { vm.machine.download.isInFlight }
        let line = try #require(vm.downloadLine)
        #expect(line.contains("Parakeet TDT 0.6B v3"))
        #expect(line.contains("900 MB"), "the denominator is the tier's real total, not a bare percentage")
        #expect(vm.downloadStartedAt[.best] != nil)
        gate.open()
        vm.teardown()
    }
}

// MARK: - P4

/// "Show the real model name next to each friendly tier, with its size."
@Suite("P4 — the picker names the real models")
struct ModelTierNamingTests {
    @Test func namesAndSizesComeFromTheCatalog() {
        #expect(ModelTier.fast.modelNames == ["Parakeet TDT-CTC 110M (tiny)"])
        #expect(ModelTier.balanced.modelNames == ["Parakeet TDT 0.6B v3"])
        #expect(ModelTier.best.modelNames == ["Parakeet TDT 0.6B v3", "Parakeet Realtime EOU 120M (160 ms)"])
        #expect(ModelTier.best.modelNameLine == "Parakeet TDT 0.6B v3 + Parakeet Realtime EOU 120M (160 ms)")

        #expect(ModelTier.fast.approximateBytes == 110_000_000)
        #expect(ModelTier.balanced.approximateBytes == 500_000_000)
        #expect(ModelTier.best.approximateBytes == 900_000_000)
        #expect(ModelTier.fast.sizeLabel == "110 MB")
        #expect(ModelTier.best.sizeLabel == "900 MB")
    }

    /// The three sizes the 1.6.6 picker printed were hardcoded and all three had drifted. Every one
    /// of them is now a sum over `ModelCatalog`, so drift is a build-time impossibility.
    @Test func theHardcodedSizesAreGone() {
        let hardcoded: [ModelTier: Int64] = [.fast: 120_000_000, .balanced: 450_000_000, .best: 1_200_000_000]
        for (tier, wrong) in hardcoded {
            #expect(tier.approximateBytes != wrong, "\(tier.rawValue) is still using the old hardcoded size")
        }
        for tier in ModelTier.allCases {
            #expect(tier.approximateBytes == tier.descriptors.reduce(0) { $0 + $1.approxBytes })
            #expect(!tier.modelNames.isEmpty, "every tier must name what it downloads")
        }
    }
}
