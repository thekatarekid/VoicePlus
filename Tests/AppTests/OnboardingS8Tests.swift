import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// S8 · Onboarding (design_v1 §8.7, V4.48, I1) — the copy against the verified prototype, the practice
// turn, the uncertain-word demo, the resume point, Ready's routing, and the view model's wiring of
// the new steps. The pure state machine's own S8 suite lives in OnboardingStateMachineTests.swift.

private let packageRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url
}()

// MARK: - Copy

@Suite("S8 — onboarding copy equals the verified prototype")
struct OnboardingCopyTests {
    /// The prototype's `steps` table (`case'onboarding'` in design_v1.html), as [heading, body, action].
    static func prototypeTable() throws -> [[String]] {
        let html = try String(contentsOf: packageRoot.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
        let open = try #require(html.range(of: "case'onboarding':{const steps=["))
        let close = try #require(html.range(of: "]];", range: open.upperBound..<html.endIndex))
        let table = String(html[open.upperBound..<close.lowerBound])
        let regex = try NSRegularExpression(pattern: "'([^']*)'")
        let strings = regex.matches(in: table, range: NSRange(table.startIndex..., in: table)).compactMap {
            Range($0.range(at: 1), in: table).map { String(table[$0]) }
        }
        return stride(from: 0, to: strings.count, by: 3).map { Array(strings[$0..<min($0 + 3, strings.count)]) }
    }

    static func designCopy() throws -> [String: Any] {
        let dir = try #require(AppPaths.fixturesDirectory())
        let data = try Data(contentsOf: dir.appendingPathComponent("design/design_copy.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theSixPrototypeRowsAreVerbatim() throws {
        let table = try Self.prototypeTable()
        #expect(table.count == 6)
        let ours = OnboardingCopy.prototypeSteps.map { [$0.heading, $0.body, $0.action] }
        #expect(ours == table)
    }

    @Test func eachDesignStepRendersItsPrototypeRow() {
        let key = "Right Control"   // the prototype's own key: rendering is then the identity…
        let pairs: [(OnboardingStateMachine.Step, OnboardingCopy.StepCopy)] = [
            (.welcome, OnboardingCopy.prototypeWelcome), (.accessibility, OnboardingCopy.prototypeTypingAccess),
            (.model, OnboardingCopy.prototypeModel), (.firstDictation, OnboardingCopy.prototypeTry),
            (.done, OnboardingCopy.prototypeReady),
        ]
        for (step, row) in pairs { #expect(OnboardingCopy.copy(for: step, key: key) == row, "\(step)") }
        // …except Microphone, whose last sentence narrates the prototype itself (the real app does
        // exactly what it says, with the real prompt).
        let mic = OnboardingCopy.copy(for: .microphone, key: key)
        #expect(mic.heading == "Let VoicePlus hear you.")
        #expect(mic.body == "Microphone access is needed only to capture your voice.")
        #expect(OnboardingCopy.prototypeMicrophone.body == mic.body + " " + OnboardingCopy.prototypeNarration)
        #expect(mic.action == "Allow microphone")
    }

    /// Owner decision (build doc §0): "Right Control" becomes the configured key; nothing else moves.
    @Test func theConfiguredKeyReplacesRightControlAndNothingElse() {
        let fn = HotkeyBinding(kind: .fn).label
        let tryCopy = OnboardingCopy.copy(for: .firstDictation, key: fn)
        #expect(tryCopy.body == "Hold fn / 🌐. Watch Spool’s reels turn counterclockwise and words appear above the tape. Release, review, then watch a clockwise feed place your sentence.")
        #expect(tryCopy.heading == OnboardingCopy.prototypeTry.heading)
        #expect(tryCopy.action == OnboardingCopy.prototypeTry.action)
        for step in OnboardingStateMachine.Step.allCases {
            let c = OnboardingCopy.copy(for: step, key: fn)
            #expect(![c.heading, c.body, c.action].joined().contains("Right Control"), "\(step)")
            // Problem — Action copy: no raw enum tokens in anything a user reads.
            #expect(![c.heading, c.body, c.action].joined().contains("firstDictation"), "\(step)")
        }
    }

    /// The owner's Voice step speaks in the Voice section's own words (design_copy.json).
    @Test func theVoiceStepUsesTheVoiceSectionsCopy() throws {
        let root = try Self.designCopy()
        let screens = try #require(root["screens"] as? [String: [String: String]])
        let empty = try #require(root["emptyCopy"] as? [String: [String]])
        #expect(screens["voice"]?["subtitle"] == OnboardingCopy.voiceSubtitle)
        #expect(empty["voice"] == [OnboardingCopy.voiceEmptyTitle, OnboardingCopy.voiceEmptyBody, OnboardingCopy.voiceEmptyAction])
        let voice = OnboardingCopy.copy(for: .voice, key: "fn / 🌐")
        #expect(voice == .init(heading: "Make sure we hear you clearly.",
                               body: "Enrollment is optional. Hold-to-talk works without it.",
                               action: "Set up my voice"))
    }

    /// V4.48's instruction names the real number of prompted lines and ~30 s; H2's fallback names the
    /// real passive count and the pill's own words.
    @Test func voiceInstructionAndPassiveFallbackAreTheRealNumbers() {
        #expect(SpeakerEnrollment.prompts.count == SpeakerEnrollment.requiredUtterances)
        #expect(OnboardingCopy.voiceInstruction == "Read these three lines so VoicePlus knows your voice. It takes about 30 seconds.")
        #expect(OnboardingCopy.voicePassiveFallback.contains("first \(SpeakerEnrollment.passiveUtterances) holds"))
        #expect(OnboardingCopy.voicePassiveFallback.contains("“\(LatchController.voiceLearnedMessage)”"))
    }

    @Test func chromeAndEyebrowMatchThePrototype() throws {
        let html = try String(contentsOf: packageRoot.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
        #expect(html.contains("btn('\(OnboardingCopy.back)','setup-back')"))
        #expect(html.contains("btn('\(OnboardingCopy.setUpLater)','setup-later')"))
        #expect(html.contains("Setup · ${setupStep+1} of 6"))
        #expect(OnboardingCopy.eyebrow(step: 1, of: 6) == "Setup · 1 of 6")
        #expect(OnboardingCopy.eyebrow(step: 6, of: OnboardingStateMachine.stepCount) == "Setup · 6 of 9")   // + V5 LANG1, + X5
    }

    /// The Word review is the prototype's `#reviewDialog`, word for word.
    @Test func wordReviewCopyIsThePrototypeDialog() throws {
        let html = try String(contentsOf: packageRoot.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
        let example = UncertainWordReview.example
        for fragment in ["<div class=\"eyebrow\">\(UncertainWordReview.eyebrow)</div>",
                         "<h3>\(example.title)</h3>", "<p>\(example.body)</p>",
                         ">\(example.keepTitle)</button>", ">\(UncertainWordReview.customLabel)</label>",
                         "placeholder=\"\(UncertainWordReview.customPlaceholder)\"",
                         ">\(UncertainWordReview.applyTitle)</button>", ">\(UncertainWordReview.cancelTitle)</button>"] {
            #expect(html.contains(fragment), "\(fragment)")
        }
        #expect(html.contains(example.sentence), "the prototype's sample sentence")
    }
}

// MARK: - Ready routing and optional later steps

@Suite("S8 — Ready: one fix per blocker, optional later steps")
struct OnboardingReadyTests {
    @Test func everyBlockerReadyCanShowHasAFixThatMatchesItsAction() {
        #expect(OnboardingReady.fix(for: .P01) == .systemSettings(.microphone))
        #expect(OnboardingReady.fix(for: .P02) == .systemSettings(.accessibility))
        #expect(OnboardingReady.fix(for: .M01) == .models)
        #expect(OnboardingReady.fix(for: .M02) == .installModels)
        #expect(OnboardingReady.fix(for: .M07) == .retryModelLoad)
        for id in [RecoveryID.A03, .A05, .X03] {
            #expect(OnboardingReady.fix(for: id) == .section(.voice), "\(id)")
        }
        // The catalogue's own action titles name those places.
        #expect(RecoveryCatalog.entry(.M01).action == "Open Models")
        #expect(RecoveryCatalog.entry(.P01).action == "Open Microphone settings")
        #expect(RecoveryCatalog.entry(.M07).action == "Retry loading")
    }

    @Test func meetingsAndCalendarAreOfferedLaterNeverAsked() {
        #expect(OnboardingReady.laterItems.map(\.title) == ["Meeting notes and system audio", "Calendar"])
        #expect(OnboardingReady.laterItems.allSatisfy { $0.section == .meetings })
        // Neither is a step: the walk has no Meetings or Calendar screen and no such permission.
        #expect(OnboardingStateMachine.Step.allCases.count == 9)   // + V5 LANG1 Languages, + X5 Rewrite model
        #expect(!OnboardingStateMachine.Step.allCases.map(\.rawValue).contains { $0.contains("meeting") || $0.contains("calendar") })
        #expect(Set(OnboardingPermission.order(hotkeyRequires: nil)) == [.microphone, .accessibility])
    }
}

// MARK: - The practice turn

@Suite("S8 — practice turn: hold → live words → release → final preview → insertion")
struct PracticeSessionTests {
    static let t0 = Date(timeIntervalSince1970: 1_000)

    static func span(_ text: String, _ confidence: Float = 0.95, alternates: [String] = []) -> TranscriptSpan {
        TranscriptSpan(text: text, confidence: confidence, audioRange: 0...1,
                       alternates: alternates.map { Alternate(text: $0, score: 0.4, source: .beam) })
    }

    @Test func aHoldWalksEveryStageItReallySaw() {
        var p = PracticeSession(now: Self.t0)
        #expect(p.phase == .waiting)
        #expect(!p.phase.isLive, "Spool is still until the real test runs")
        #expect(p.apply(.state(.starting), now: Self.t0.addingTimeInterval(1)) == true)
        #expect(p.phase == .listening)
        #expect(p.phase.isLive)
        #expect(p.phaseStartedAt == Self.t0.addingTimeInterval(1))
        p.apply(.state(.listening(level: 0.4)))
        #expect(p.level == 0.4)
        p.apply(.partial([Self.span("Can we meet")]))
        #expect(p.liveText == "Can we meet", "live words above the tape")
        p.apply(.state(.previewing(text: "Can we meet with")))
        #expect(p.liveText == "Can we meet with")
        #expect(p.apply(.state(.finishing)) == true)
        #expect(p.phase == .finishing)
        #expect(p.level == 0)
        let final = [Self.span("Can we meet with"), Self.span("Mira", 0.3, alternates: ["Meera"]), Self.span("on Friday?")]
        #expect(p.apply(.final(final)) == true)
        #expect(p.phase == .preview, "the final preview before insertion")
        #expect(p.finalText == "Can we meet with Mira on Friday?")
        #expect(p.fieldChanged("Can we meet with Mira on Friday?") == true)
        #expect(p.phase == .inserted)
        #expect(p.insertedText == "Can we meet with Mira on Friday?")
        #expect(p.insertions == 1)
        #expect(!p.phase.isLive)
    }

    @Test func typingWhileNothingIsFinishingIsNotALanding() {
        var p = PracticeSession()
        #expect(p.fieldChanged("hello") == false)
        #expect(p.phase == .waiting)
        p.apply(.state(.starting))
        #expect(p.fieldChanged("hello there") == false, "a landing needs a release first")
        #expect(p.insertions == 0)
    }

    @Test func releaseWithNoWordsIsNoSpeech() {
        var p = PracticeSession()
        p.apply(.state(.starting)); p.apply(.state(.finishing))
        p.apply(.final([Self.span("  ")]))
        #expect(p.phase == .noSpeech)
        #expect(p.fieldChanged("x") == false)
    }

    @Test func escapeCancelsBeforeAnythingIsWritten() {
        var p = PracticeSession()
        p.apply(.state(.starting)); p.apply(.partial([Self.span("hello")]))
        p.apply(.state(.cancelled))
        #expect(p.phase == .cancelled)
        #expect(p.fieldChanged("hello") == false, "nothing lands after a cancel")
        #expect(p.insertedText == nil)
    }

    @Test func aFinalThatNeverLandsIsReportedThenALateLandingStillCounts() {
        var p = PracticeSession()
        p.apply(.state(.starting)); p.apply(.state(.finishing)); p.apply(.final([Self.span("Hello there.")]))
        #expect(p.insertionTimedOut() == true)
        #expect(p.phase == .notInserted)
        #expect(p.insertionTimedOut() == false, "reported once")
        #expect(p.fieldChanged("Hello there.") == true)
        #expect(p.phase == .inserted)
    }

    @Test func anEngineErrorFailsTheTurn() {
        var p = PracticeSession()
        p.apply(.state(.starting))
        p.apply(.state(.error("boom")))
        #expect(p.phase == .failed("boom"))
    }

    /// Spool on the Try step: the still cameo until the real test starts, then the pill's own poses —
    /// listening (counterclockwise reels), finishing, preview or uncertain, then the insertion feed.
    @Test func spoolFollowsTheRealTestOnly() {
        var p = PracticeSession()
        #expect(OnboardingView.spoolKey(for: p) == .ready)
        p.apply(.state(.starting))
        #expect(OnboardingView.spoolKey(for: p) == .listening)
        p.apply(.state(.finishing))
        #expect(OnboardingView.spoolKey(for: p) == .finishing)
        p.apply(.final([Self.span("Can we meet with"), Self.span("Mira", 0.3, alternates: ["Meera"])]))
        #expect(OnboardingView.spoolKey(for: p) == .uncertain, "an uncertain word shows the review pose")
        p.fieldChanged("Can we meet with Mira")
        #expect(OnboardingView.spoolKey(for: p) == .inserted)
        var sure = PracticeSession()
        sure.apply(.state(.starting)); sure.apply(.final([Self.span("Hello.")]))
        #expect(OnboardingView.spoolKey(for: sure) == .preview)
    }

    @Test func theNextHoldStartsAFreshTurn() {
        var p = PracticeSession()
        p.apply(.state(.starting)); p.apply(.state(.finishing)); p.apply(.final([Self.span("One.")]))
        p.fieldChanged("One.")
        p.apply(.state(.starting))
        #expect(p.phase == .listening)
        #expect(p.liveText.isEmpty && p.finalSpans.isEmpty && p.insertedText == nil)
        p.apply(.state(.finishing)); p.apply(.final([Self.span("Two.")]))
        #expect(p.fieldChanged("One. Two.") == true)
        #expect(p.insertedText == "Two.")
        #expect(p.insertions == 2)
    }
}

// MARK: - One uncertain word, demonstrated and corrected

@Suite("S8 — one uncertain word, demonstrated and corrected")
struct UncertainWordReviewTests {
    typealias S = PracticeSessionTests

    @Test func theUsersOwnUncertainWordIsReviewedWhenItHasAnAlternative() {
        let spans = [S.span("Can we meet with"), S.span("Mira", 0.3, alternates: ["Meera", "mira", "Myra", "Mirror", "Meira"]),
                     S.span("on Friday?")]
        let review = UncertainWordReview.make(spans: spans, landed: "Can we meet with Mira on Friday?")
        #expect(review.source == .dictation)
        #expect(review.word == "Mira")
        #expect(review.suggestions == ["Meera", "Myra", "Mirror"], "at most three, never the word itself")
        #expect(review.offset == 17)
        #expect(review.title == "Did you mean “Meera”?")
    }

    @Test func noUncertainWordMeansTheLabelledExampleNeverAFakeMark() {
        let confident = [S.span("Hello there.")]
        #expect(UncertainWordReview.make(spans: confident, landed: "Hello there.") == .example)
        let noAlternative = [S.span("Mira", 0.2)]
        #expect(UncertainWordReview.make(spans: noAlternative, landed: "Mira").source == .example)
        let notLanded = [S.span("Mira", 0.2, alternates: ["Meera"])]
        #expect(UncertainWordReview.make(spans: notLanded, landed: "Something else").source == .example)
        #expect(UncertainWordReview.make(spans: notLanded, landed: nil).source == .example)
    }

    @Test func choosingCorrectsTheFieldOnlyWhileTheSentenceIsStillThere() {
        let spans = [S.span("Can we meet with"), S.span("Mira", 0.3, alternates: ["Meera"]), S.span("on Friday?")]
        var review = UncertainWordReview.make(spans: spans, landed: "Can we meet with Mira on Friday?")
        let field = "Notes: Can we meet with Mira on Friday?"
        #expect(review.choose("Meera", field: field) == "Notes: Can we meet with Meera on Friday?")
        #expect(review.isResolved)
        #expect(review.sentence == "Can we meet with Meera on Friday?")
        #expect(review.choose("Myra", field: field) == nil, "a settled word is not reopened")

        var stale = UncertainWordReview.make(spans: spans, landed: "Can we meet with Mira on Friday?")
        #expect(stale.choose("Meera", field: "The user rewrote everything") == nil, "no verified range, no replace")
        #expect(!stale.isResolved)
    }

    @Test func keepAndTheExampleChangeNothingInTheField() {
        var example = UncertainWordReview.example
        #expect(example.choose("Meera", field: "untouched") == "untouched")
        #expect(example.sentence == "Can we meet with Meera on Friday?")
        var kept = UncertainWordReview.example
        kept.keep()
        #expect(kept.isResolved && kept.currentWord == "Mira")
    }
}

// MARK: - Resume point

@Suite("S8 — resume at the unfinished step")
struct OnboardingResumeTests {
    @Test func savesEachStepAndNeverWelcomeOrReady() {
        let store = InMemorySettingsStore()
        let resume = OnboardingResume(store: store)
        #expect(resume.step == nil)
        resume.save(.model)
        #expect(resume.step == .model)
        resume.save(.welcome)
        #expect(resume.step == nil, "Welcome is where a fresh start is anyway")
        resume.save(.voice)
        resume.save(.done)
        #expect(resume.step == nil, "reaching Ready clears it")
        #expect(store.string(SettingsKeys.onboardingResumeStep) == nil)
    }

    @Test func aFinishedOnboardingOrAnUnknownValueIsNotResumed() {
        let store = InMemorySettingsStore()
        store.set("voice", for: SettingsKeys.onboardingResumeStep)
        #expect(OnboardingResume(store: store).step == .voice)
        store.set(true, for: SettingsKeys.onboardingCompleted)
        #expect(OnboardingResume(store: store).step == nil)
        let other = InMemorySettingsStore()
        other.set("tryTheKey", for: SettingsKeys.onboardingResumeStep)
        #expect(OnboardingResume(store: other).step == nil)
    }

    @Test func resumingAtVoiceWithAVoiceEnrolledSinceLandsOnItInsteadOfFinishing() {
        var m = OnboardingStateMachine(voiceEnrolled: true)
        #expect(m.resume(at: .voice) == [])
        #expect(m.step == .voice, "the window must not open already finished")
        #expect(m.handle(.next) == [.finish(skipped: false)])
    }
}

// MARK: - View model wiring

final class S8StubEmbedder: SpeakerEmbedder, @unchecked Sendable {
    let name = "s8-stub"
    let dimension = 3
    let identifiesSpeakers: Bool
    init(identifiesSpeakers: Bool) { self.identifiesSpeakers = identifiesSpeakers }
    func embed(_ samples: [Float]) throws -> SpeakerEmbedding { SpeakerEmbedding(vector: [1, 0, 0], embedder: name) }
}

@MainActor
@Suite("S8 — onboarding view model: resume, Set up later, model load, key test, practice, voice")
struct OnboardingS8ViewModelTests {
    /// Mock dependencies with every permission already granted and the resume step preset.
    static func deps(resumeAt step: OnboardingStateMachine.Step? = nil) -> OnboardingDependencies {
        let deps = OnboardingDependencies.mock(pretendRealMicCapture: true)
        let checker = deps.permissions as? OnboardingMockPermissionChecker
        for p in OnboardingPermission.allCases { checker?.statuses[p] = .granted }
        if let step { deps.settingsStore.set(step.rawValue, for: SettingsKeys.onboardingResumeStep) }
        return deps
    }

    @Test func opensWhereSetupWasLeftAndPersistsEveryStepChange() {
        let fresh = OnboardingViewModel(dependencies: Self.deps())
        #expect(fresh.step == .welcome)
        fresh.send(.next)
        #expect(fresh.deps.settingsStore.string(SettingsKeys.onboardingResumeStep) == "microphone")
        fresh.teardown()

        let resumed = OnboardingViewModel(dependencies: Self.deps(resumeAt: .voice))
        #expect(resumed.step == .voice)
        resumed.teardown()

        let selfTest = OnboardingViewModel(dependencies: Self.deps(resumeAt: .voice), resume: false)
        #expect(selfTest.step == .welcome, "the headless self-test always walks from Welcome")
        selfTest.teardown()
    }

    @Test func setUpLaterClosesWithoutFinishingAndTheNextOpenResumes() {
        let deps = Self.deps(resumeAt: .firstDictation)
        let vm = OnboardingViewModel(dependencies: deps)
        var closed = false
        var finished = false
        vm.onClose = { closed = true }
        vm.onFinished = { _ in finished = true }
        vm.setUpLater()
        #expect(closed)
        #expect(!finished)
        #expect(deps.settingsStore.bool(SettingsKeys.onboardingCompleted) != true)
        vm.teardown()
        let again = OnboardingViewModel(dependencies: deps)
        #expect(again.step == .firstDictation)
        again.teardown()
    }

    @Test func reachingReadyMarksSetupCompleteAndClearsTheResumePoint() {
        let deps = Self.deps(resumeAt: .voice)
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip)
        #expect(vm.step == .done)
        #expect(deps.settingsStore.bool(SettingsKeys.onboardingCompleted) == true)
        #expect(deps.settingsStore.string(SettingsKeys.onboardingResumeStep) == nil)
        vm.teardown()
    }

    @Test func theModelSaysReadyOnlyAfterALoadAndALoadFailureCanBeRetried() async throws {
        var deps = Self.deps(resumeAt: .model)
        final class Attempts { var n = 0 }
        let attempts = Attempts()
        deps.loadModel = {
            attempts.n += 1
            return attempts.n == 1 ? .failed("The speech model isn’t ready") : .loaded(name: "Parakeet TDT 0.6B v3")
        }
        let vm = OnboardingViewModel(dependencies: deps)
        try await waitUntil { vm.machine.modelPhase == .loadFailed("The speech model isn’t ready") }
        #expect(attempts.n == 1)
        vm.send(.retryModelLoad)
        try await waitUntil { vm.machine.modelPhase == .ready(name: "Parakeet TDT 0.6B v3") }
        #expect(attempts.n == 2)
        vm.teardown()
    }

    @Test func withNothingToLoadTheModelTheStepSaysSoInsteadOfReady() async throws {
        var deps = Self.deps(resumeAt: .model)
        deps.loadModel = nil
        let vm = OnboardingViewModel(dependencies: deps)
        try await waitUntil { vm.machine.modelPhase == .loadFailed(RecoveryCatalog.entry(.M07).headline) }
        vm.teardown()
    }

    @Test func theFnPromptThenTheKeyTestThenRightOption() {
        var deps = Self.deps(resumeAt: .firstDictation)
        final class Box { var conflict: FnKeyConflict? = FnKeyConflict(.showEmojiAndSymbols); var opened = 0; var bound: [HotkeyBinding.Kind] = [] }
        let box = Box()
        deps.dictationKey = { .fn }
        deps.fnConflict = { _ in box.conflict }
        deps.openKeyboardSettings = { box.opened += 1 }
        deps.setDictationKey = { box.bound.append($0) }
        let vm = OnboardingViewModel(dependencies: deps)
        #expect(vm.machine.keyCheck == .conflict(FnKeyConflict(.showEmojiAndSymbols)!))
        vm.send(.fixFnConflict)
        #expect(box.opened == 1)
        box.conflict = nil
        vm.readKeyStatus()   // back from System Settings (app re-activation)
        #expect(vm.machine.keyCheck == .testing(attempts: 0, prompting: false))
        for _ in 1...FnKeyProbe.attemptsBeforeFallback {
            vm.send(.checkKey)
            vm.pressedKeyWithoutEvent()
        }
        #expect(vm.machine.keyCheck == .offerFallback(.rightOption))
        vm.send(.useFallbackKey)
        #expect(box.bound == [.rightOption])
        #expect(vm.keyLabel == "Right Option")
        vm.teardown()
    }

    @Test func oneFnEventFromTheHotkeyServiceConfirmsTheKey() {
        var deps = Self.deps(resumeAt: .firstDictation)
        deps.dictationKey = { .fn }
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.checkKey)
        deps.keyEvents.noteFnEvent()
        #expect(vm.machine.keyCheck == .ready(.fn))
        vm.teardown()
        #expect(deps.keyEvents.onFnEvent == nil, "a closed window stops listening")
    }

    @Test func aRealHoldIntoThePracticeFieldLandsAndItsUncertainWordIsCorrected() throws {
        let vm = OnboardingViewModel(dependencies: Self.deps(resumeAt: .firstDictation))
        let S = PracticeSessionTests.self
        vm.practiceEvent(.state(.starting))
        vm.practiceEvent(.partial([S.span("Can we meet")]))
        #expect(vm.practice.phase == .listening)
        vm.practiceEvent(.state(.finishing))
        vm.practiceEvent(.final([S.span("Can we meet with"), S.span("Mira", 0.3, alternates: ["Meera"]), S.span("on Friday?")]))
        #expect(vm.practice.phase == .preview)
        #expect(vm.machine.dictation == nil, "nothing is claimed before the text lands")
        vm.practiceText = "Can we meet with Mira on Friday?"   // the lander's insertion into the field
        #expect(vm.practice.phase == .inserted)
        #expect(vm.machine.dictation == .landed(text: "Can we meet with Mira on Friday?", app: OnboardingCopy.practiceFieldName))
        let review = try #require(vm.wordReview)
        #expect(review.source == .dictation)
        vm.correctUncertainWord("Meera")
        #expect(vm.practiceText == "Can we meet with Meera on Friday?")
        #expect(vm.wordReview?.isResolved == true)
        #expect(vm.practice.insertions == 1, "a correction is not a second landing")
        vm.teardown()
    }

    @Test func aPreviewThatNeverLandsIsHeardNotLanded() {
        let vm = OnboardingViewModel(dependencies: Self.deps(resumeAt: .firstDictation))
        let S = PracticeSessionTests.self
        vm.practiceEvent(.state(.starting)); vm.practiceEvent(.state(.finishing))
        vm.practiceEvent(.final([S.span("Hello there.")]))
        vm.practiceInsertionTimedOut()
        #expect(vm.practice.phase == .notInserted)
        if case .heard(let text, _)? = vm.machine.dictation { #expect(text == "Hello there.") } else {
            Issue.record("expected .heard, got \(String(describing: vm.machine.dictation))")
        }
        vm.teardown()
    }

    @Test func aHoldWithNoWordsSaysNoSpeechInCatalogueWords() {
        let vm = OnboardingViewModel(dependencies: Self.deps(resumeAt: .firstDictation))
        vm.practiceEvent(.state(.starting)); vm.practiceEvent(.state(.finishing)); vm.practiceEvent(.final([]))
        #expect(vm.machine.dictation == .failed(reason: RecoveryCatalog.entry(.A06).headline))
        vm.teardown()
    }

    @Test func practiceEventsOffTheTryStepAreIgnored() {
        let vm = OnboardingViewModel(dependencies: Self.deps(resumeAt: .voice))
        vm.practiceEvent(.state(.starting))
        #expect(vm.practice.phase == .waiting)
        vm.teardown()
    }

    @Test func voiceEnrollmentWithNoRecorderIsStated() {
        var deps = Self.deps(resumeAt: .voice)
        deps.makeEnrollment = { nil }
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.beginVoiceEnrollment)
        #expect(vm.machine.voice == .unavailable)
        #expect(vm.enrollment == nil)
        vm.teardown()
    }

    @Test func voiceEnrollmentRunsTheVoiceSectionsViewAndInstallsTheProfileOnce() async throws {
        final class Installed { var profiles: [SpeakerProfile] = [] }
        for identifies in [true, false] {
            var deps = Self.deps(resumeAt: .voice)
            let installed = Installed()
            deps.makeEnrollment = {
                SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: identifies),
                                           record: { [Float](repeating: 0.1, count: 16_000) })
            }
            deps.installVoiceProfile = { profile in installed.profiles.append(profile); return identifies }
            let vm = OnboardingViewModel(dependencies: deps)
            vm.send(.beginVoiceEnrollment)
            #expect(vm.machine.voice == .enrolling)
            let enrollment = try #require(vm.enrollment)
            for _ in 0..<SpeakerEnrollment.requiredUtterances {
                enrollment.recordUtterance()
                try await waitUntil { !enrollment.isRecording }
            }
            try await waitUntil { vm.machine.voice.isEnrolled }
            #expect(vm.machine.voice == .enrolled(filtering: identifies))
            #expect(installed.profiles.count == 1)
            #expect(vm.enrollment == nil)
            vm.send(.next)
            #expect(vm.step == .done)
            #expect(!vm.machine.skippedSteps.contains(.voice))
            vm.teardown()
        }
    }

    @Test func leavingTheVoiceStepMidEnrollmentDropsIt() {
        var deps = Self.deps(resumeAt: .voice)
        deps.makeEnrollment = { SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true), record: { [] }) }
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.beginVoiceEnrollment)
        #expect(vm.enrollment != nil)
        vm.send(.back)
        #expect(vm.enrollment == nil)
        #expect(vm.step == .languages)   // V5 LANG1 sits between Try dictation and Voice
        vm.teardown()
    }
}
