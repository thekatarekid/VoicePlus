import Engine
import Foundation
import Lab
import Shared
import Testing
@testable import VoicePlusApp

// S7e — Voice (design §8.4, §9): the microphone test's seven states, Spool on the Voice surfaces,
// enrollment status and "Not you" history, language capability and the mixed-script preview, the
// benchmarks disclosure, and the page's renderings. Real capture (HAL, TCC, device removal) cannot be
// opened here: the test runs against `MockVoiceCapture`, and the live graph is named as unverified.

/// A microphone the test can open and close, driven by hand.
final class MockVoiceCapture: VoiceTestCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<VoiceTestCaptureEvent>.Continuation?
    private(set) var opens = 0
    private(set) var releases = 0

    var isOpen: Bool { lock.withLock { continuation != nil } }

    func open() -> AsyncStream<VoiceTestCaptureEvent> {
        let (stream, continuation) = AsyncStream<VoiceTestCaptureEvent>.makeStream()
        lock.withLock {
            self.continuation = continuation
            opens += 1
        }
        return stream
    }

    func release() {
        let open = lock.withLock { () -> AsyncStream<VoiceTestCaptureEvent>.Continuation? in
            defer { continuation = nil }
            if continuation != nil { releases += 1 }
            return continuation
        }
        open?.finish()
    }

    func send(_ event: VoiceTestCaptureEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }
}

@MainActor
@Suite("S7e — Voice: microphone test, Spool, enrollment, language, benchmarks")
struct VoiceSectionS7eTests {
    /// The hang guard gave up: the condition never held in `checks` looks at it.
    struct WaitGaveUp: Error, CustomStringConvertible {
        let checks: Int
        var description: String { "condition still false after \(checks) checks on the main actor" }
    }

    /// A hang guard, not a latency assertion. It counts its own checks, not wall time: a full parallel
    /// AppTests run (`-j 3`, or several verifier runs at once) can stall the main actor for minutes
    /// (see OnboardingS8Tests' waiter), and every hop the model under test needs to make the condition
    /// true is stalled with it. A wall-clock deadline then expired with the condition still false and
    /// threw `CancellationError` — the wave-3 flake. A stalled main actor runs no checks, so it spends
    /// none of this budget; `timeout` of an unstalled run is 20 ms × checks, as before.
    static func waitUntil(timeout: TimeInterval = 120, _ condition: @MainActor () -> Bool) async throws {
        let limit = max(1, Int((timeout / 0.02).rounded()))
        var checks = 0
        while !condition() {
            checks += 1
            if checks >= limit { throw WaitGaveUp(checks: checks) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The wave-3 flake, reproduced in miniature: the main actor stalls for longer than the whole
    /// budget and the condition needs one more main-actor hop after the stall. A wall-clock deadline
    /// expired here with the condition still false; a stalled main actor spends no checks.
    @Test("the hang guard counts its checks, not wall time: a stalled main actor does not spend it")
    func hangGuardSurvivesAStalledMainActor() async throws {
        final class Flag: @unchecked Sendable { var ready = false }
        let flag = Flag()
        Task { @MainActor in
            Thread.sleep(forTimeInterval: 0.3)            // a busy neighbour holding the main actor
            Task { @MainActor in flag.ready = true }      // the hop the condition waits for
        }
        try await Self.waitUntil(timeout: 0.1) { flag.ready }
        #expect(flag.ready)
        await #expect(throws: WaitGaveUp.self) { try await Self.waitUntil(timeout: 0.06) { false } }
    }

    /// Speech-like audio: a 220 Hz tone at `amplitude`, `seconds` long, 16 kHz.
    static func tone(seconds: Double, amplitude: Float = 0.3) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    /// A room with a little hiss.
    static func room(seconds: Double, amplitude: Float = 0.002) -> [Float] {
        let count = Int(seconds * 16_000)
        var seed: UInt32 = 7
        return (0..<count).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(seed % 2000) / 1000 - 1)
        }
    }

    /// Feeds `samples` in 0.5 s blocks starting at `start` seconds. Blocks are coarse on purpose:
    /// every event is a main-actor hop, and a full parallel AppTests run makes each hop slow.
    static func feed(_ capture: MockVoiceCapture, _ samples: [Float], from start: Double) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 8_000, samples.count)
            capture.send(.audio(samples: Array(samples[offset..<end]), position: start + Double(offset) / 16_000))
            offset = end
        }
    }

    // MARK: - The microphone test: seven states

    @Test("idle → capturing (microphone open, real levels) → Stop releases it → analyzing → result")
    func testHappyPath() async throws {
        let capture = MockVoiceCapture()
        let test = VoiceMicrophoneTest(capture: capture)
        #expect(test.phase == .idle)
        #expect(test.meter == Array(repeating: 0, count: 16), "no illustrated levels: the meter is flat until a test runs")
        #expect(!test.isMicrophoneOpen)

        test.start()
        #expect(test.phase == .capturing)
        #expect(capture.isOpen)
        capture.send(.started(device: "MacBook Pro Microphone"))
        capture.send(.level(0.42))
        Self.feed(capture, Self.room(seconds: 0.5), from: 0)
        capture.send(.vad(.speechStart(at: 0.5)))
        Self.feed(capture, Self.tone(seconds: 2.5), from: 0.5)
        capture.send(.vad(.speechEnd(at: 3.0)))
        Self.feed(capture, Self.room(seconds: 0.3), from: 3.0)
        try await Self.waitUntil { abs((test.meter.last ?? 0) - 0.42) < 1e-6 && test.deviceName == "MacBook Pro Microphone" }
        #expect(abs(test.level - 0.42) < 1e-6, "the meter shows the level the capture measured")
        try await Self.waitUntil { test.currentSpeechSeconds > 2.4 }

        test.stop()
        #expect(!capture.isOpen, "Stop releases the microphone before anything is analysed")
        #expect(test.phase == .analyzing)
        #expect(test.level == 0)
        try await Self.waitUntil { if case .result = test.phase { return true } else { return false } }
        guard case .result(let result) = test.phase else { Issue.record("no result"); return }
        #expect(result.quality.verdict == .good)
        #expect(result.cause == .clear)
        #expect(result.headline == "Clear input")
        #expect(abs(result.speechSeconds - 2.5) < 0.05)
        #expect(result.device == "MacBook Pro Microphone")
        #expect(result.measurement.contains("2.5 s of speech"))
        #expect(!result.measurement.contains("-"), "minus signs are typographic")
        #expect(capture.releases == 1)
    }

    @Test("no samples: capture opened but nothing arrived (A05), from Stop or from the watchdog")
    func noSamples() async throws {
        let capture = MockVoiceCapture()
        let test = VoiceMicrophoneTest(capture: capture)
        test.start()
        test.stop()
        try await Self.waitUntil { test.phase == .noSamples }
        #expect(test.phase.recoveryID == .A05)

        test.start()
        capture.send(.failed(.noAudio))
        try await Self.waitUntil { test.phase == .noSamples }
        #expect(!capture.isOpen)
    }

    @Test("too short: audio but under a second of speech (A07) — says how much it heard")
    func tooShort() async throws {
        let capture = MockVoiceCapture()
        let test = VoiceMicrophoneTest(capture: capture)
        test.start()
        Self.feed(capture, Self.room(seconds: 0.4), from: 0)
        capture.send(.vad(.speechStart(at: 0.4)))
        Self.feed(capture, Self.tone(seconds: 0.4), from: 0.4)
        try await Self.waitUntil { test.currentSpeechSeconds > 0.35 }
        test.stop()   // the speech segment is still open: it counts up to the last sample
        try await Self.waitUntil { if case .tooShort = test.phase { return true } else { return false } }
        guard case .tooShort(let seconds) = test.phase else { return }
        #expect(abs(seconds - 0.4) < 0.05)
        let shown = VoiceTestPresentation(phase: test.phase, device: nil, canStart: true, hasOtherMicrophones: true)
        #expect(shown.status == RecoveryCatalog.entry(.A07).headline)
        #expect(shown.detail == VoiceTestCopy.tooShortDetail(speechSeconds: seconds))
        #expect(shown.detail?.contains("0.4 s") == true)
        #expect(shown.primary.title == RecoveryCatalog.entry(.A07).action)
        #expect(shown.holdNote == VoiceTestCopy.holdUnaffected)
    }

    @Test("device removed: the test stops, the microphone is released, nothing is graded (A02)")
    func deviceRemoved() async throws {
        let capture = MockVoiceCapture()
        let test = VoiceMicrophoneTest(capture: capture)
        test.start()
        capture.send(.started(device: "USB Mic"))
        Self.feed(capture, Self.tone(seconds: 1.5), from: 0)
        capture.send(.deviceRemoved(name: nil))
        try await Self.waitUntil { if case .deviceRemoved = test.phase { return true } else { return false } }
        #expect(test.phase == .deviceRemoved(name: "USB Mic"), "the device the test opened is named")
        #expect(!capture.isOpen)
        let shown = VoiceTestPresentation(phase: test.phase, device: nil, canStart: true, hasOtherMicrophones: true)
        #expect(shown.status == "Microphone disconnected")
        #expect(shown.secondary?.title == "Choose microphone")
        #expect(shown.secondary?.action == .chooseMicrophone)
        #expect(shown.holdNote == VoiceTestCopy.holdSwitches)
        let alone = VoiceTestPresentation(phase: test.phase, device: nil, canStart: false, hasOtherMicrophones: false)
        #expect(alone.holdNote == nil, "hold dictation is only promised when another microphone exists")
    }

    @Test("start failures map to the catalogue: permission P01, no device A01, busy A09, anything else A03")
    func startFailures() async throws {
        let cases: [(VoiceTestCaptureFailure, RecoveryID)] = [
            (.permissionDenied, .P01), (.noInputDevice, .A01), (.busy, .A09), (.couldNotStart("HAL -10868"), .A03),
        ]
        for (failure, id) in cases {
            let capture = MockVoiceCapture()
            let test = VoiceMicrophoneTest(capture: capture)
            test.start()
            capture.send(.failed(failure))
            try await Self.waitUntil { test.phase == .failed(id) }
            #expect(!capture.isOpen)
            let shown = VoiceTestPresentation(phase: test.phase, device: nil, canStart: true, hasOtherMicrophones: true)
            #expect(shown.status == RecoveryCatalog.entry(id).headline)
            #expect(!shown.status.contains("-10868"), "raw detail never reaches the headline")
            #expect(shown.secondary?.title == RecoveryCatalog.entry(id).action)
            #expect(shown.secondary?.action == (id == .P01 ? .openMicrophoneSettings : .chooseMicrophone))
        }
    }

    @Test("a forgotten test stops itself; cancelling closes the microphone and drops late events")
    func autoStopAndCancel() async throws {
        let capture = MockVoiceCapture()
        let test = VoiceMicrophoneTest(capture: capture, maximumSeconds: 0.05)
        test.start()
        try await Self.waitUntil { test.phase == .noSamples }
        #expect(!capture.isOpen)

        let other = MockVoiceCapture()
        let cancelled = VoiceMicrophoneTest(capture: other)
        cancelled.start()
        cancelled.cancel()
        #expect(cancelled.phase == .idle)
        #expect(!other.isOpen)
        other.send(.level(0.9))
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(cancelled.meter.allSatisfy { $0 == 0 }, "a released test never moves the meter")
    }

    @Test("every phase's words and buttons")
    func presentation() {
        let idle = VoiceTestPresentation(phase: .idle, device: nil, canStart: true, hasOtherMicrophones: true)
        #expect(idle.primary == .init(title: "Test microphone", action: .start, isEnabled: true))
        #expect(idle.status == VoiceTestCopy.idle)
        #expect(idle.meterLabel == VoiceTestCopy.idleMeter)
        #expect(!VoiceTestPresentation(phase: .idle, device: nil, canStart: false, hasOtherMicrophones: false).primary.isEnabled)

        let capturing = VoiceTestPresentation(phase: .capturing, device: "Studio Mic", canStart: true, hasOtherMicrophones: true)
        #expect(capturing.primary == .init(title: "Stop", action: .stop, isEnabled: true))
        #expect(capturing.status.contains("Studio Mic"))

        let analyzing = VoiceTestPresentation(phase: .analyzing, device: nil, canStart: true, hasOtherMicrophones: true)
        #expect(!analyzing.primary.isEnabled)
        #expect(analyzing.status.contains("microphone is closed"))

        let noSamples = VoiceTestPresentation(phase: .noSamples, device: nil, canStart: true, hasOtherMicrophones: true)
        #expect(noSamples.status == "No audio is reaching VoicePlus")
        #expect(noSamples.detail == "Check the selected input and its mute switch.")
        #expect(noSamples.primary.title == "Test microphone")

        let noisy = VoiceTestResult(quality: MicQuality(snr: 6, clipping: 0, lowLevel: false, verdict: .poor), speechSeconds: 2)
        let poor = VoiceTestPresentation(phase: .result(noisy), device: nil, canStart: true, hasOtherMicrophones: true)
        #expect(poor.status == RecoveryCatalog.entry(.A08).headline)
        #expect(poor.detail == VoiceTestCopy.noiseGuidance)
        #expect(poor.recoveryID == .A08)
        #expect(poor.holdNote == VoiceTestCopy.holdUnaffected)
        #expect(poor.primary.title == "Test again")
        #expect(VoiceTestResult(quality: MicQuality(snr: 30, clipping: 0, lowLevel: true, verdict: .bad), speechSeconds: 2).cause == .quiet)
        #expect(VoiceTestResult(quality: MicQuality(snr: 30, clipping: 0.05, lowLevel: false, verdict: .bad), speechSeconds: 2).cause == .clipping)
    }

    // MARK: - Spool on the Voice surfaces (design §8.9)

    @Test("Spool moves only during a real test or enrollment capture, parks while analysing")
    func spool() {
        for surface in [SpoolSurfacePolicy.Surface.voiceTest, .voiceEnrollment] {
            let idle = VoiceSpoolStrip.appearance(surface: surface, activity: .idle, recovery: nil)
            #expect(idle.key == .ready && !idle.animates)
            let capturing = VoiceSpoolStrip.appearance(surface: surface, activity: .capturing, recovery: nil)
            #expect(capturing.key == .listening && capturing.animates)
            let analyzing = VoiceSpoolStrip.appearance(surface: surface, activity: .analyzing, recovery: nil)
            #expect(analyzing.key == .finishing && !analyzing.animates, "analysing parks the reels")
        }
        let failed = VoiceSpoolStrip.appearance(surface: .voiceTest, activity: .idle, recovery: .A05)
        #expect(!failed.animates)
        #expect(failed.key == SpoolSurfacePolicy.cameo(for: .A05))
        #expect(VoiceMicrophoneTest.Phase.capturing.activity == .capturing)
        #expect(VoiceMicrophoneTest.Phase.analyzing.activity == .analyzing)
        #expect(VoiceMicrophoneTest.Phase.noSamples.activity == .idle)
    }

    @Test("enrollment: capturing while the recorder has the microphone, analysing while embedding")
    func enrollmentPhases() async throws {
        final class Gate: @unchecked Sendable {
            var continuation: CheckedContinuation<[Float], Never>?
        }
        let gate = Gate()
        let model = SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true)) {
            await withCheckedContinuation { gate.continuation = $0 }
        }
        #expect(model.capture == .idle)
        #expect(model.stepLabel == "Phrase 1 of 3")
        model.recordUtterance()
        #expect(model.capture == .capturing)
        #expect(model.isRecording)
        try await Self.waitUntil { gate.continuation != nil }
        gate.continuation?.resume(returning: [Float](repeating: 0.1, count: 16_000))
        try await Self.waitUntil { !model.isRecording }
        #expect(model.capture == .idle)
        #expect(model.status == SpeakerEnrollmentCopy.accepted(1))
        #expect(model.stepLabel == "Phrase 2 of 3")

        let silent = SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true), record: { [] })
        silent.recordUtterance()
        try await Self.waitUntil { !silent.isRecording }
        #expect(silent.status == SpeakerEnrollmentCopy.noAudio)
        #expect(silent.enrollment.embeddings.isEmpty)
    }

    // MARK: - The page and the microphone group

    @Test("page: 'Looking for microphones…' until enumerated (never an empty claim), then content")
    func pageStates() {
        let loading = VoiceSectionViewModel.pageState(denied: false, enumerated: false)
        #expect(loading.rendering == .loading)
        #expect(loading.headline == "Looking for microphones…")
        #expect(loading.detail == SectionCopy.loadingNote)
        #expect(loading.headline != DesignScreen.voice.empty.headline)
        #expect(VoiceSectionViewModel.pageState(denied: false, enumerated: true) == .content)
        #expect(VoiceSectionViewModel.pageState(denied: true, enumerated: false) == .content,
                "a denied grant is a banner over content, not a page that never loads")
        let blocks = SectionPageAnatomy.blocks(copy: .section(.voice), state: loading, hotkey: "fn / 🌐")
        #expect(SectionPageAnatomy.snapshot(blocks) == """
        header Voice
        empty-state[ready] Looking for microphones… / No empty-state claim while the data is still loading.
        """)
        let content = SectionPageAnatomy.blocks(copy: .section(.voice), state: .content, hotkey: "fn / 🌐")
        #expect(SectionPageAnatomy.snapshot(content) == "header Voice / Make sure we hear you clearly.\ncontent")
    }

    @Test("'No microphones found' is its own state, distinct from 'No voice enrolled'")
    func microphoneStates() {
        let none = VoiceSectionViewModel.microphoneState(denied: false, enumerated: true, deviceCount: 0)
        #expect(none.rendering == .empty)
        #expect(none.headline == "No microphones found")
        #expect(none.headline != VoiceEnrollmentStatus.off.tag)
        #expect(VoiceEnrollmentStatus.off.tag == "No voice enrolled")
        #expect(none.actionTitle == VoiceCopy.checkAgain)
        #expect(none.isWellFormed)
        #expect(VoiceSectionViewModel.microphoneState(denied: false, enumerated: false, deviceCount: 3).headline
                == "Looking for microphones…")
        #expect(VoiceSectionViewModel.microphoneState(denied: false, enumerated: true, deviceCount: 1) == .content)
        #expect(VoiceSectionViewModel.microphoneState(denied: true, enumerated: true, deviceCount: 1).rendering == .error)
    }

    @Test("denied microphone: P01 banner over the page, no test, the rest of the page stays")
    func deniedMicrophone() {
        let model = Self.voice(permissions: [.microphone: .denied])
        model.refreshDevices()
        #expect(model.page == .content)
        #expect(model.pageBanner?.recoveryID == .P01)
        #expect(model.pageBanner?.headline == "Microphone access is off")
        #expect(model.pageBanner?.actionTitle == "Open Microphone settings")
        #expect(!model.canTest)
        #expect(!model.testPresentation.primary.isEnabled)
        model.performBannerAction()
        #expect((model.permissions as? OnboardingMockPermissionChecker)?.openedSettings == [.microphone])
    }

    @Test("a vanished microphone is A02 over the page, with the device named")
    func vanishedBanner() {
        let banner = VoiceCopy.vanishedBanner(name: "Studio Mic")
        #expect(banner.headline == RecoveryCatalog.entry(.A02).headline)
        #expect(banner.actionTitle == "Choose microphone")
        #expect(banner.body?.contains("Studio Mic") == true)
        #expect(banner.recoveryID == .A02)
        #expect(banner.body?.contains("switched to Automatic") == true,
                "the picker forgets a vanished choice, so the banner never promises to switch back by itself")
    }

    @Test("leaving Voice and starting enrollment both close the test's microphone")
    func oneMicrophoneOnePurpose() {
        let capture = MockVoiceCapture()
        let model = Self.voice(capture: capture)
        model.test.start()
        #expect(capture.isOpen)
        model.leave()
        #expect(!capture.isOpen)
        #expect(model.test.phase == .idle)

        model.test.start()
        #expect(capture.isOpen)
        model.install(enrollment: SpeakerEnrollmentViewModel(embedder: S8StubEmbedder(identifiesSpeakers: true), record: { [] }))
        #expect(!capture.isOpen, "enrollment takes the microphone: the test is stopped first")
        #expect(model.enrolling != nil)
        #expect(!model.canTest, "no test while an enrollment is open: its next take wants the same microphone")
        #expect(!model.testPresentation.primary.isEnabled)
    }

    // MARK: - Enrollment status and "Not you" (H2)

    static let wespeaker = VoiceSpeakerReading.identifyingEmbedderName

    static func profile(embedder: String = VoiceSpeakerReading.identifyingEmbedderName) -> SpeakerProfile {
        SpeakerProfile(centroid: SpeakerEmbedding(vector: [1, 0, 0], embedder: embedder), utteranceCount: 3,
                       enrolledAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test("off → learning N of 10 → enrolled (filtering on / unavailable), read fresh every time")
    func enrollmentStatus() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-s7e-\(UUID().uuidString).json")
        var identifies = true
        // A fresh store per read, as the live default does: the latch controller writes through its own.
        let model = Self.voice(profilesURL: url,
                               speaker: { VoiceSpeakerReading.read(SpeakerProfileStore(url: url), identifyingEmbedderAvailable: identifies) })
        #expect(model.enrollmentStatus == .off)
        #expect(model.enrollment.rendering == .empty)
        #expect(VoiceEnrollmentStatus.off.line(hotkey: "fn / 🌐") == "Enrollment is optional. Hold-to-talk works without it.")
        #expect(VoiceEnrollmentStatus.off.primaryAction == "Set up my voice")

        var passive = SpeakerEnrollment(mode: .passive)
        for i in 0..<4 {
            _ = passive.recordHold(SpeakerEmbedding(vector: [1, Float(i) * 0.01, 0], embedder: Self.wespeaker), speechSeconds: 2)
        }
        SpeakerProfileStore(url: url).savePassiveEnrollment(passive)
        model.refreshEnrollment()
        #expect(model.enrollmentStatus == .learning(learned: 4, of: 10))
        #expect(model.enrollmentStatus.tag == "Learning 4 of 10")
        #expect(model.enrollmentStatus.line(hotkey: "").contains("6 more"))
        #expect(model.enrollment.isContent)

        SpeakerProfileStore(url: url).save(Self.profile())
        model.refreshEnrollment()
        guard case .enrolled(_, let filtering, let notYou) = model.enrollmentStatus else { Issue.record("not enrolled"); return }
        #expect(filtering)
        #expect(notYou.corrections == 0)
        #expect(notYou.summary == VoiceEnrollmentCopy.notYouNone)
        #expect(model.enrollmentStatus.tagIsGood)
        #expect(model.enrollmentStatus.primaryAction == "Re-enroll")
        #expect(model.isEnrolled)

        identifies = false
        model.refreshEnrollment()
        #expect(model.enrollmentStatus.line(hotkey: "").contains(RecoveryCatalog.entry(.X03).consequence),
                "without WeSpeaker weights the voice is kept and filtering is honestly off (X03)")
        #expect(!model.enrollmentStatus.tagIsGood)

        identifies = true
        SpeakerProfileStore(url: url).save(Self.profile(embedder: "mfcc-mean"))
        model.refreshEnrollment()
        guard case .enrolled(_, let mfccFiltering, _) = model.enrollmentStatus else { return }
        #expect(!mfccFiltering, "an MFCC-built profile cannot drive the WeSpeaker filter")

        model.deleteEnrollment()
        #expect(model.enrollmentStatus == .off, "Delete reaches the file every later read opens")
    }

    @Test("\"Not you\" history: corrections counted, the lifted match shown")
    func notYouHistory() {
        var profile = Self.profile()
        profile.noteNotYou(SpeakerEmbedding(vector: [0.6, 0.8, 0], embedder: Self.wespeaker))
        profile.noteNotYou(SpeakerEmbedding(vector: [0.5, 0.5, 0.7], embedder: Self.wespeaker))
        let history = NotYouHistory(profile)
        #expect(history.corrections == 2)
        #expect(history.thresholdFloor.map { abs($0 - 0.62) < 0.001 } == true)
        #expect(history.summary.hasPrefix("2 voices marked “Not you”."))
        #expect(history.summary.contains("0.62"))
        #expect(NotYouHistory(corrections: 1, thresholdFloor: nil).summary.hasPrefix("1 voice marked"))
        #expect(history.title == "“Not you” corrections")
    }

    @Test("no recorder: enrollment says so with X03, and hold-to-talk is not blocked")
    func enrollmentUnavailable() {
        let model = Self.voice()
        #expect(model.beginEnrollment() == false)
        #expect(model.enrollment.rendering == .error)
        #expect(model.enrollment.recoveryID == .X03)
        #expect(model.enrollment.headline == "Couldn’t finish voice setup")
        #expect(model.enrollment.detail?.contains("Hold-to-talk still works") == true)
        #expect(model.enrollment.isWellFormed)
    }

    // MARK: - Language (§8.4)

    static func readiness(_ name: String?) -> RecognizerReadiness? {
        name.map { .ready(name: $0) } ?? .unavailable(reason: "nothing")
    }

    @Test("the picker lists only what the installed model recognizes, with a capability note")
    func languageCapability() {
        let v3Name = ModelCatalog.descriptor(.parakeetTDTv3).displayName
        let v3 = VoiceLanguageCapability.resolve(.ready(name: v3Name))
        #expect(v3.languages.count == 25)
        #expect(v3.options.first?.title == "Automatic")
        #expect(v3.options.count == 26)
        #expect(!v3.supports("hi") && !v3.supports("ja") && !v3.supports("zh"), "never promise unsupported languages")
        #expect(v3.supports("uk") && v3.supports("el") && v3.supports("auto"))
        #expect(v3.note.contains("25 European languages"))
        #expect(v3.note.contains(v3Name))
        #expect(v3.scripts == [.latin, .cyrillic, .greek])

        let tiny = VoiceLanguageCapability.resolve(.fallback(name: ModelCatalog.descriptor(.parakeetTDTCTC110m).displayName, awaiting: v3Name))
        #expect(tiny.languages.map(\.code) == ["en"])
        #expect(tiny.note.contains("English only"))

        let apple = VoiceLanguageCapability.resolve(.fallback(name: "Apple Speech (on-device)", awaiting: nil),
                                                    locale: Locale(identifier: "de_DE"))
        #expect(apple.languages.map(\.code) == ["de"])
        #expect(apple.languages.first?.name == "German")

        let none = VoiceLanguageCapability.resolve(.unavailable(reason: "no model"))
        #expect(none.languages.isEmpty)
        #expect(none.options.map { $0.code } == ["auto"])
        #expect(none.note == VoiceLanguageCopy.noModel)

        let unknown = VoiceLanguageCapability.resolve(.ready(name: "Some Future Model"))
        #expect(unknown.options.map { $0.code } == ["auto"])
        #expect(unknown.note.contains("can't tell"))
    }

    @Test("the choice is saved, a choice the model can't recognize is refused and never shown")
    func languageSelection() {
        let store = InMemorySettingsStore()
        let v3Name = ModelCatalog.descriptor(.parakeetTDTv3).displayName
        var readiness: RecognizerReadiness? = .ready(name: v3Name)
        let model = Self.voice(settings: store, readiness: { readiness })
        #expect(model.languageSelection == "auto")
        model.selectLanguage("de")
        #expect(model.languageSelection == "de")
        #expect(store.string(VoiceLanguageSettings.key) == "de")
        #expect(model.languageNote.contains("German is saved as your dictation language"))
        #expect(model.languageNote.contains("still identifies the spoken language itself"), "a choice is never sold as a switch")
        model.selectLanguage("hi")
        #expect(model.languageSelection == "de", "Hindi is not offered by this model")

        readiness = .fallback(name: ModelCatalog.descriptor(.parakeetTDTCTC110m).displayName, awaiting: nil)
        model.refreshLanguage()
        #expect(model.languageSelection == "auto", "German saved under v3 is not shown while only English can run")
        #expect(store.string(VoiceLanguageSettings.key) == "de", "…and it is not thrown away either")
    }

    @Test("mixed-script preview: per script, whether the installed model writes it")
    func scriptPreview() {
        let v3 = VoiceLanguageCapability.resolve(.ready(name: ModelCatalog.descriptor(.parakeetTDTv3).displayName))
        let russian = VoiceScriptPreview.make(capability: v3, selection: "ru")
        #expect(russian.scripts.map(\.script) == [.latin, .cyrillic])
        #expect(russian.scripts.allSatisfy { $0.supported })
        #expect(russian.runs.map(\.text).joined() == russian.sample, "the runs rebuild the sentence exactly")
        #expect(russian.runs.contains { $0.text == "Марии" && $0.script == .cyrillic && $0.supported })

        let automatic = VoiceScriptPreview.make(capability: v3, selection: "auto")
        #expect(automatic.scripts.count == 2, "Automatic previews a second script the model writes")
        #expect(automatic.scripts.allSatisfy { $0.supported })

        let hindi = VoiceScriptPreview.devanagari(capability: v3)
        #expect(hindi.scripts.map(\.script) == [.latin, .devanagari])
        #expect(hindi.scripts.map(\.supported) == [true, false])
        #expect(hindi.runs.contains { $0.text == "बजे" && !$0.supported })
        #expect(hindi.lines(recognizer: "Parakeet TDT 0.6B v3")
                == ["Latin — written as spoken", "Devanagari — not recognized by Parakeet TDT 0.6B v3"])

        let tiny = VoiceLanguageCapability.resolve(.ready(name: ModelCatalog.descriptor(.parakeetTDTCTC110m).displayName))
        let tinyPreview = VoiceScriptPreview.make(capability: tiny, selection: "auto")
        #expect(tinyPreview.scripts.map(\.supported) == [true, false], "English-only: the mixed sample shows what it can't write")

        let model = Self.voice(readiness: { .ready(name: ModelCatalog.descriptor(.parakeetTDTv3).displayName) })
        #expect(model.unsupportedScriptPreview == hindi, "v3 cannot write Devanagari, so the page says so beside the preview")
        let english = Self.voice(readiness: { .ready(name: ModelCatalog.descriptor(.parakeetTDTCTC110m).displayName) })
        #expect(english.unsupportedScriptPreview == nil, "the same Hindi sample is not shown twice")
    }

    // MARK: - Benchmarks disclosure

    @Test("the old Benchmark tab opens Voice with the disclosure open; its summary names stage and result")
    func benchmarksDisclosure() async throws {
        let window = MainWindowShellS7aTests.window(section: .today)
        window.apply(LegacySettingsTab.benchmark.route)
        #expect(window.selection == .voice)
        #expect(window.navigation(.voice).isExpanded(.benchmarks))

        let lab = LabPanelViewModel(choices: [], runner: LabRunner(clock: { 0 }, hardware: "test", thermal: { .nominal }))
        let model = Self.voice(lab: lab)
        #expect(model.benchmarkSummary == SectionCopy.noMeasurements)
        lab.phase = .running(done: 1, total: 4)
        #expect(model.benchmarkSummary == "Stage 2 of 4")
        lab.phase = .failed("biasing on: the fixture suite is missing")
        #expect(model.benchmarkSummary == "Stopped during biasing on · diagnostics available")
        #expect(!model.benchmarkSummary.contains("fixture suite"))

        // The group follows the Lab whoever runs it: loading with a stage while running, the named
        // failure after — never the stale empty state.
        lab.phase = .running(done: 1, total: 4)
        try await Self.waitUntil { model.benchmark.rendering == .loading }
        #expect(model.benchmark.headline == "Running 1 of 4…")
        #expect(model.benchmarkProgressText == "25%")
        lab.phase = .failed("biasing on: the fixture suite is missing")
        try await Self.waitUntil { model.benchmark.rendering == .error }
        #expect(model.benchmark.headline == SectionCopy.benchmarkFailed(stage: "biasing on"))
        lab.phase = .idle
        try await Self.waitUntil { model.benchmark.rendering == .empty }
    }

    // MARK: - Design copy and structure

    @Test("row copy is the prototype's Voice screen, verbatim")
    func prototypeCopy() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let html = try String(contentsOf: root.appendingPathComponent("design/design_v1.html"), encoding: .utf8)
        guard let start = html.range(of: "case'voice':out=title('Voice'"),
              let end = html.range(of: "case'privacy'", range: start.upperBound..<html.endIndex) else {
            Issue.record("prototype Voice screen not found"); return
        }
        let voice = String(html[start.lowerBound..<end.lowerBound])
        for copy in [VoiceCopy.microphoneTitle, VoiceCopy.microphoneDetail, VoiceTestCopy.rowTitle, VoiceTestCopy.rowDetail,
                     VoiceTestCopy.test, VoiceCopy.recognition, VoiceLanguageCopy.rowTitle, VoiceLanguageCopy.rowDetail,
                     VoiceLanguageCopy.automatic, VoiceEnrollmentCopy.rowTitle, VoiceEnrollmentCopy.rowDetail] {
            #expect(voice.contains(copy), "“\(copy)” is not the prototype's")
        }
        let copy = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/design/design_copy.json"))) as? [String: Any]
        let empty = (copy?["emptyCopy"] as? [String: [String]])?["voice"]
        #expect(empty == [VoiceEnrollmentStatus.off.tag, VoiceEnrollmentStatus.off.line(hotkey: "fn / 🌐"),
                          VoiceEnrollmentStatus.off.primaryAction])
    }

    @Test("Voice draws itself in SectionPage; the enrollment view stays standalone and window-free")
    func structure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let screen = try read("App/Settings/VoiceScreen.swift")
        #expect(screen.contains("SectionPage("))
        #expect(screen.contains("model.leave()"), "leaving Voice closes the test's microphone")
        let enrollment = try read("App/Onboarding/SpeakerEnrollmentWindow.swift")
        #expect(!enrollment.contains("NSWindow("))
        #expect(enrollment.contains("public struct SpeakerEnrollmentView: View"))
        #expect(try read("App/Onboarding/OnboardingView.swift").contains("SpeakerEnrollmentView(model:"),
                "onboarding's Voice step reuses this view (owner decision)")
        let capture = try read("App/Settings/VoiceTestCapture.swift")
        #expect(capture.contains("release(reason: .idle)"), "Stop is a full teardown, not a pause")
        // Second pass is drawn with the design's rows inside the page's group, not a system Form.
        let refinement = try read("App/Settings/VoiceSettings.swift")
        #expect(refinement.contains("RowView(") && !refinement.contains("Form {"))
        #expect(try read("App/Settings/VoiceSectionView.swift").contains("GroupBox(VoiceCopy.secondPass, layout: .rows)"))
    }

    // MARK: - Helpers

    static func voice(permissions: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                      capture: MockVoiceCapture = MockVoiceCapture(),
                      lab: LabPanelViewModel? = nil,
                      profilesURL: URL? = nil,
                      speaker: (() -> VoiceSpeakerReading)? = nil,
                      settings: InMemorySettingsStore = InMemorySettingsStore(),
                      readiness: (() -> RecognizerReadiness?)? = nil) -> VoiceSectionViewModel {
        let checker = OnboardingMockPermissionChecker(results: [:])
        checker.statuses = permissions
        let url = profilesURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("vp-s7e-\(UUID().uuidString).json")
        return VoiceSectionViewModel(
            audio: AudioInputSettingsViewModel(defaults: UserDefaults(suiteName: "vp.s7e.\(UUID().uuidString)")!),
            permissions: checker,
            lab: lab ?? LabPanelViewModel(choices: [], runner: LabRunner(clock: { 0 }, hardware: "test", thermal: { .nominal })),
            counters: BenchmarkViewModel(report: nil),
            profiles: SpeakerProfileStore(url: url),
            makeEnrollment: nil,
            speaker: speaker ?? { VoiceSpeakerReading(profile: nil, passive: nil, identifyingEmbedderAvailable: true) },
            settings: { settings },
            readiness: readiness ?? { .unavailable(reason: "none") },
            testCapture: capture)
    }
}

