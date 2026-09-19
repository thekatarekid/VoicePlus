import Combine
import Engine
import Foundation
import Lab
import Shared

// R7.2 / S7e — Voice (design §8.4, §9): the microphone and its test, recognition (language and
// the enrolled voice), and the measurements behind a disclosure. This is where the standalone
// enrollment window and the whole Lab UI ended up, and the only place model names, latency and
// thermal state may appear (V3 §9.1, `DESIGN.md` §12.6 — never the pill, never the menu).
//
// The page has one base rendering (`page`): loading while the microphones are first enumerated
// ("Looking for microphones…", never an empty claim), content otherwise, with a scoped banner when
// the microphone permission is off (P01) or the chosen microphone vanished (A02). Inside it each
// group keeps its own state, so nothing here can blank the others: no microphone ("No microphones
// found") is not the same thing as no voice ("No voice enrolled"), and neither hides the language
// picker or the benchmarks.

/// Voice. Four groups, four independent states.
@MainActor
public final class VoiceSectionViewModel: ObservableObject {
    // MARK: Page

    /// The page's one base rendering.
    @Published public private(set) var page: SectionState = .loading(.voice, headline: SectionCopy.lookingForMicrophones)
    /// The page's scoped banner over content: P01 (permission) outranks A02 (vanished microphone).
    @Published public private(set) var pageBanner: SectionBanner?

    // MARK: Microphone

    /// The microphone group's rendering. Its words are R7's (callers and tests hold them); the pane
    /// draws the catalogue's through `pageBanner` and `VoiceCopy`.
    @Published public private(set) var microphone: SectionState = .content
    /// The chosen microphone vanished (A02), over live content.
    @Published public private(set) var microphoneBanner: SectionBanner?
    /// False until the device list has been enumerated once, which is the only honest basis for
    /// "Looking for microphones…".
    @Published public private(set) var devicesEnumerated = false

    // MARK: Enrollment

    /// The group's rendering: empty while no voice is enrolled or learning, content otherwise, error
    /// when enrollment cannot start. The pane draws `enrollmentStatus`'s words.
    @Published public private(set) var enrollment: SectionState = .content
    /// Enrolled / learning N of 10 / off.
    @Published public private(set) var enrollmentStatus: VoiceEnrollmentStatus = .off
    /// Non-nil while enrollment is running **inline in this pane** — never in its own window.
    @Published public private(set) var enrolling: SpeakerEnrollmentViewModel?

    // MARK: Language

    @Published public private(set) var languageCapability = VoiceLanguageCapability(.none)
    /// The saved choice (`VoiceLanguageSettings`); always one the capability supports.
    @Published public private(set) var languageSelection = VoiceLanguageSettings.automatic

    // MARK: Benchmark

    @Published public private(set) var benchmark: SectionState = .content

    public let audio: AudioInputSettingsViewModel
    public let lab: LabPanelViewModel
    public let counters: BenchmarkViewModel
    /// The microphone test (idle / capturing / analyzing / result / no samples / too short / device removed).
    public let test: VoiceMicrophoneTest
    let permissions: OnboardingPermissionChecking
    private let speaker: () -> VoiceSpeakerReading
    private let profileStore: () -> SpeakerProfileStore
    private let makeEnrollment: (() -> SpeakerEnrollmentViewModel?)?
    private let settings: () -> SettingsStore?
    private let readiness: () -> RecognizerReadiness?
    private var runTask: Task<Void, Never>?
    /// Keeps the benchmarks group's state in step with the Lab, whoever started the run (this pane's
    /// Run benchmark or the Lab panel's own controls).
    private var labChanges: AnyCancellable?

    /// - Parameters:
    ///   - profiles: the speaker profile store. When nil, every read opens the file afresh, because
    ///     the latch controller writes it through a store of its own.
    ///   - speaker: overrides the profile read (tests).
    ///   - settings / readiness: where the language choice is saved and what recognizer would run;
    ///     default to the window's dependencies.
    ///   - testCapture: the microphone the test opens; defaults to its own live capture graph.
    public init(audio: AudioInputSettingsViewModel? = nil,
                permissions: OnboardingPermissionChecking,
                lab: LabPanelViewModel,
                counters: BenchmarkViewModel? = nil,
                profiles: SpeakerProfileStore? = nil,
                makeEnrollment: (() -> SpeakerEnrollmentViewModel?)? = nil,
                speaker: (() -> VoiceSpeakerReading)? = nil,
                settings: (() -> SettingsStore?)? = nil,
                readiness: (() -> RecognizerReadiness?)? = nil,
                testCapture: VoiceTestCapturing? = nil) {
        self.audio = audio ?? AudioInputSettingsViewModel()
        self.permissions = permissions
        self.lab = lab
        self.counters = counters ?? BenchmarkViewModel(report: BenchmarkViewModel.lastMeasured)
        let store: () -> SpeakerProfileStore = profiles.map { given in { given } } ?? { SpeakerProfileStore() }
        self.profileStore = store
        self.speaker = speaker ?? { VoiceSpeakerReading.read(store()) }
        self.makeEnrollment = makeEnrollment
        self.settings = settings ?? { MainWindowController.dependencies?.settingsStore }
        self.readiness = readiness ?? { MainWindowController.dependencies?.models.stackReadiness }
        self.test = VoiceMicrophoneTest(capture: testCapture ?? LiveVoiceTestCapture())
        refresh()
        // `objectWillChange` fires before the change lands; re-read once it has.
        labChanges = lab.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshBenchmark() } }
    }

    public func refresh() {
        refreshMicrophone()
        refreshEnrollment()
        refreshLanguage()
        refreshBenchmark()
    }

    // MARK: Microphone (§8.4, §9)

    /// The first enumeration answered (the pane calls it on appear).
    public func markDevicesEnumerated() {
        devicesEnumerated = true
        refreshMicrophone()
    }

    /// Re-enumerates the inputs. A chosen microphone that is gone is reported (A02) rather than
    /// silently replaced — the picker itself falls back to Automatic.
    public func refreshDevices() {
        let chosen = audio.selection
        let chosenName = audio.devices.first { $0.uid == chosen }?.name
        audio.refresh()
        devicesEnumerated = true
        if chosen != AudioInputSettingsViewModel.automatic, audio.selection == AudioInputSettingsViewModel.automatic {
            microphoneBanner = VoiceCopy.vanishedBanner(name: chosenName)
        }
        refreshMicrophone()
    }

    public func refreshMicrophone() {
        let status = permissions.status(of: .microphone)
        let denied = status == .denied || status == .awaitingUserAction
        microphone = Self.microphoneState(denied: denied, enumerated: devicesEnumerated, deviceCount: audio.devices.count)
        if microphone.rendering == .empty { microphoneBanner = nil }
        // A chosen device that vanished while this model was not looking.
        if microphone.isContent, audio.selection != AudioInputSettingsViewModel.automatic,
           !audio.devices.contains(where: { $0.uid == audio.selection }) {
            microphoneBanner = VoiceCopy.vanishedBanner(name: nil)
        }
        refreshPage(denied: denied)
    }

    /// The microphone group's rendering, from the three facts it depends on. A denial wins (nothing
    /// else about the inputs matters until it is granted); then "Looking for microphones…" until the
    /// first enumeration; then "No microphones found" — distinct from "No voice enrolled".
    static func microphoneState(denied: Bool, enumerated: Bool, deviceCount: Int) -> SectionState {
        if denied {
            // S11: P01 — "Microphone access is off", its consequence, "Open Microphone settings".
            return .error(.P01)
        }
        guard enumerated else { return .loading(SectionCopy.lookingForMicrophones) }
        guard deviceCount > 0 else {
            return .empty(VoiceCopy.noMicrophones, detail: VoiceCopy.noMicrophonesDetail, action: VoiceCopy.checkAgain)
        }
        return .content
    }

    /// The page's base rendering: loading only until the inputs are known (or the grant is known to
    /// be off), content afterwards — never an empty page, because language and benchmarks never
    /// depend on a microphone.
    static func pageState(denied: Bool, enumerated: Bool) -> SectionState {
        (enumerated || denied) ? .content : .loading(.voice, headline: SectionCopy.lookingForMicrophones)
    }

    private func refreshPage(denied: Bool) {
        page = Self.pageState(denied: denied, enumerated: devicesEnumerated)
        pageBanner = denied ? SectionBanner.partial(RecoveryCatalog.entry(.P01)) : microphoneBanner
    }

    /// The page banner's action: P01 opens the microphone pane of System Settings; A02 re-reads the
    /// inputs and puts the banner away (the picker is right there).
    public func performBannerAction() {
        switch pageBanner?.recoveryID {
        case .P01?: openMicrophoneSettings()
        default: dismissVanishedMicrophone()
        }
    }

    /// The picker's choice. Choosing puts the vanished-microphone banner away: the user acted.
    public func selectMicrophone(_ uid: String) {
        audio.selection = uid
        microphoneBanner = nil
        refreshMicrophone()
    }

    public func dismissVanishedMicrophone() {
        microphoneBanner = nil
        audio.refresh()
        devicesEnumerated = true
        refreshMicrophone()
    }

    /// The picker is disabled until the enumeration answers — `DESIGN.md` §9.4's loading state — and
    /// while a test has the microphone open.
    public var isMicrophonePickerEnabled: Bool {
        (microphone.rendering == .content || microphone.rendering == .empty) && !test.phase.isCapturing
    }

    public var isMicrophoneDenied: Bool { microphone.rendering == .error }

    // MARK: The test (§8.4)

    /// Whether Test microphone can run: a granted microphone, at least one input, and no enrollment
    /// open in the pane — its next take would want the same microphone (one microphone, one purpose).
    public var canTest: Bool {
        microphone.rendering == .content && enrolling == nil
    }

    public var testPresentation: VoiceTestPresentation {
        VoiceTestPresentation(phase: test.phase, device: test.deviceName, canStart: canTest,
                              hasOtherMicrophones: !audio.devices.isEmpty)
    }

    public func perform(_ action: VoiceTestAction) {
        switch action {
        case .start:
            guard canTest else { return }
            test.start()
        case .stop:
            test.stop()
            refreshDevices()
        case .chooseMicrophone:
            test.cancel()
            refreshDevices()
        case .openMicrophoneSettings:
            openMicrophoneSettings()
        }
        objectWillChange.send()
    }

    /// The device the test was using is gone: re-read the inputs so the picker and banner catch up.
    public func testDidEnd() {
        if case .deviceRemoved = test.phase { refreshDevices() }
    }

    /// Leaving Voice (another section, the window closing): the microphone closes, nothing is graded.
    public func leave() { test.cancel() }

    // MARK: Enrollment (§8.4) — inline, never a window

    public var enrolledProfile: SpeakerProfile? { speaker().profile }
    public var isEnrolled: Bool { enrolledProfile != nil }

    public func refreshEnrollment() {
        enrollmentStatus = VoiceEnrollmentStatus(speaker())
        if enrolling != nil { enrollment = .content; return }
        enrollment = enrollmentStatus == .off
            ? .empty(SectionCopy.noEnrollment, detail: SectionCopy.noEnrollmentDetail, action: DesignScreen.voice.empty.action)
            : .content
    }

    /// Starts (or restarts) enrollment in this pane. Returns false when no recorder is wired, which
    /// is stated (X03) rather than pretended. A running microphone test is stopped first: one
    /// microphone, one purpose.
    @discardableResult
    public func beginEnrollment() -> Bool {
        test.cancel()
        guard let model = makeEnrollment?() else {
            let entry = RecoveryCatalog.entry(.X03)
            enrollment = SectionState(rendering: .error, headline: entry.headline,
                                      detail: "The microphone isn't available to this window right now. \(entry.consequence)",
                                      actionTitle: entry.action, recoveryID: .X03)
            return false
        }
        install(enrollment: model)
        return true
    }

    /// Adopts an enrollment view model built elsewhere (the composition root owns the recorder).
    public func install(enrollment model: SpeakerEnrollmentViewModel) {
        test.cancel()
        let existing = model.onComplete
        model.onComplete = { [weak self] profile in
            existing?(profile)
            MainActor.assumeIsolated {
                self?.enrolling = nil
                self?.refreshEnrollment()
            }
        }
        enrolling = model
        enrollment = .content
    }

    public func cancelEnrollment() {
        enrolling = nil
        refreshEnrollment()
    }

    public func deleteEnrollment() {
        profileStore().delete()
        enrolling = nil
        refreshEnrollment()
    }

    // MARK: Language (§8.4)

    public func refreshLanguage() {
        languageCapability = VoiceLanguageCapability.resolve(readiness())
        let saved = VoiceLanguageSettings.code(settings())
        // Never show a language the installed model cannot recognize, even one saved under another model.
        languageSelection = languageCapability.supports(saved) ? saved : VoiceLanguageSettings.automatic
    }

    public func selectLanguage(_ code: String) {
        guard languageCapability.supports(code) else { return }
        VoiceLanguageSettings.setCode(code, store: settings())
        languageSelection = code
    }

    public var languageNote: String {
        [languageCapability.note, languageCapability.choiceNote(for: languageSelection)]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// The chosen language (or, for Automatic, a supported second script) mixed with English.
    public var scriptPreview: VoiceScriptPreview {
        VoiceScriptPreview.make(capability: languageCapability, selection: languageSelection)
    }

    /// Hindi + English, shown beside it whenever the model cannot write Devanagari.
    public var unsupportedScriptPreview: VoiceScriptPreview? {
        guard !languageCapability.scripts.contains(.devanagari), languageCapability.recognizerName != nil else { return nil }
        let preview = VoiceScriptPreview.devanagari(capability: languageCapability)
        return preview == scriptPreview ? nil : preview
    }

    // MARK: Benchmark (§8.4) — the whole Lab, in a disclosure with stage, result and diagnostics

    public func refreshBenchmark() {
        switch lab.phase {
        case .running(let done, let total):
            benchmark = .loading("Running \(done) of \(total)…")
        case .failed(let message):
            // The stage is named in the sentence; the raw detail goes behind Copy diagnostics.
            benchmark = .error(SectionCopy.benchmarkFailed(stage: Self.stage(of: message)),
                               action: SectionCopy.copyDiagnostics)
        case .idle, .finished:
            benchmark = (lab.reports.isEmpty && !counters.hasData)
                ? .empty(SectionCopy.noMeasurements, detail: "Run it to see latency, word error and thermal state for this Mac.",
                         action: SectionCopy.runBenchmark)
                : .content
        }
    }

    /// `LabPanelViewModel` reports failures as "<config>: <error>"; the config name is the stage a
    /// person can act on, and the rest is diagnostics.
    static func stage(of message: String) -> String {
        message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? message
    }

    /// The disclosure's one-line summary: the stage while running, the stage that failed, or what
    /// the results are.
    public var benchmarkSummary: String {
        switch lab.phase {
        case .running(let done, let total):
            let configs = lab.selectedConfigs
            let stage = configs.indices.contains(done) ? configs[done].name : nil
            return "Stage \(min(done + 1, total)) of \(total)" + (stage.map { " · \($0)" } ?? "")
        case .failed(let message):
            return "Stopped during \(Self.stage(of: message)) · diagnostics available"
        case .idle, .finished:
            if !lab.reports.isEmpty { return lab.reports.count == 1 ? "1 result on this Mac" : "\(lab.reports.count) results on this Mac" }
            return counters.hasData ? "Recorded measurements" : SectionCopy.noMeasurements
        }
    }

    /// Percentage as text, never as a bare bar (`DESIGN.md` §9.4 wants the number readable).
    public var benchmarkProgressText: String? {
        guard case .running(let done, let total) = lab.phase, total > 0 else { return nil }
        return "\(Int((Double(done) / Double(total)) * 100))%"
    }

    public var diagnostics: String? {
        if case .failed(let message) = lab.phase { return message }
        return nil
    }

    public func run() async {
        refreshBenchmark()
        await lab.run()
        refreshBenchmark()
    }

    /// The run, as the pane drives it, plus the Cancel `DESIGN.md` §9.4 asks for. Cancelling stops
    /// waiting on the run and puts the group back to idle; it never claims the numbers it did not get.
    public func startRun() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            await self?.run()
            self?.runTask = nil
        }
    }

    public func cancelRun() {
        runTask?.cancel()
        runTask = nil
        lab.phase = .idle
        refreshBenchmark()
    }

    public var isRunning: Bool { lab.isRunning }

    /// Opens the microphone pane of System Settings — the only honest action for a denied grant.
    public func openMicrophoneSettings() { permissions.openSystemSettings(for: .microphone) }
}

// MARK: - The test, as the pane shows it

public enum VoiceTestAction: Equatable, Sendable {
    case start, stop, chooseMicrophone, openMicrophoneSettings
}

/// One phase of the microphone test in words and buttons. Pure, so every state's copy is a test.
public struct VoiceTestPresentation: Equatable, Sendable {
    public struct Button: Equatable, Sendable {
        public var title: String
        public var action: VoiceTestAction
        public var isEnabled: Bool
    }

    public var status: String
    public var detail: String?
    /// "Hold dictation remains if possible" (design §9) — only where it is true.
    public var holdNote: String?
    public var recoveryID: RecoveryID?
    public var tag: (text: String, good: Bool)?
    public var primary: Button
    public var secondary: Button?
    public var meterLabel: String

    public static func == (lhs: VoiceTestPresentation, rhs: VoiceTestPresentation) -> Bool {
        lhs.status == rhs.status && lhs.detail == rhs.detail && lhs.holdNote == rhs.holdNote
            && lhs.recoveryID == rhs.recoveryID && lhs.tag?.text == rhs.tag?.text && lhs.tag?.good == rhs.tag?.good
            && lhs.primary == rhs.primary && lhs.secondary == rhs.secondary && lhs.meterLabel == rhs.meterLabel
    }

    public init(phase: VoiceMicrophoneTest.Phase, device: String?, canStart: Bool, hasOtherMicrophones: Bool) {
        let testAgain = Button(title: VoiceTestCopy.testAgain, action: .start, isEnabled: canStart)
        holdNote = nil
        recoveryID = phase.recoveryID
        tag = nil
        secondary = nil
        meterLabel = VoiceTestCopy.idleMeter
        switch phase {
        case .idle:
            status = VoiceTestCopy.idle
            detail = nil
            primary = Button(title: VoiceTestCopy.test, action: .start, isEnabled: canStart)
        case .capturing:
            status = VoiceTestCopy.capturing(device: device)
            detail = nil
            primary = Button(title: VoiceTestCopy.stop, action: .stop, isEnabled: true)
            meterLabel = "Live input level" + (device.map { " · \($0)" } ?? "")
        case .analyzing:
            status = VoiceTestCopy.analyzing
            detail = nil
            primary = Button(title: VoiceTestCopy.test, action: .start, isEnabled: false)
        case .result(let result):
            status = result.headline
            detail = result.guidance
            tag = (result.cause == .clear ? "Clear" : "Needs attention", result.cause == .clear)
            holdNote = result.cause == .clear ? nil : VoiceTestCopy.holdUnaffected
            primary = testAgain
            meterLabel = result.measurement
        case .noSamples:
            let entry = RecoveryCatalog.entry(.A05)
            status = entry.headline
            detail = VoiceTestCopy.noSamplesDetail
            primary = Button(title: entry.action, action: .start, isEnabled: canStart)
        case .tooShort(let seconds):
            let entry = RecoveryCatalog.entry(.A07)
            status = entry.headline
            detail = VoiceTestCopy.tooShortDetail(speechSeconds: seconds)
            holdNote = VoiceTestCopy.holdUnaffected
            primary = Button(title: entry.action, action: .start, isEnabled: canStart)
        case .deviceRemoved(let name):
            let entry = RecoveryCatalog.entry(.A02)
            status = entry.headline
            detail = VoiceTestCopy.deviceRemovedDetail(name: name)
            holdNote = hasOtherMicrophones ? VoiceTestCopy.holdSwitches : nil
            primary = testAgain
            secondary = Button(title: entry.action, action: .chooseMicrophone, isEnabled: true)
        case .failed(let id):
            let entry = RecoveryCatalog.entry(id)
            status = entry.headline
            detail = entry.consequence
            primary = testAgain
            secondary = Button(title: entry.action, action: id == .P01 ? .openMicrophoneSettings : .chooseMicrophone,
                               isEnabled: true)
        }
    }
}

// MARK: - Copy

public enum VoiceCopy {
    public static let microphoneTitle = "Microphone"
    public static let microphoneDetail = "Select the input VoicePlus will use."
    public static let automatic = "Automatic"
    /// Design §9: distinct from "No voice enrolled".
    public static let noMicrophones = "No microphones found"
    public static let noMicrophonesDetail = "Connect a microphone, or check that the Mac's built-in one is turned on. Dictation needs one; nothing else on this page does."
    public static let checkAgain = "Check again"
    public static let recognition = "Recognition"
    public static let secondPass = "Second pass"

    /// A02 over the page when the chosen microphone went away.
    public static func vanishedBanner(name: String?) -> SectionBanner {
        let entry = RecoveryCatalog.entry(.A02)
        return SectionBanner(headline: entry.headline, actionTitle: entry.action,
                             body: "\(name ?? "The microphone you chose") is no longer connected. VoicePlus switched to Automatic; choose it again when it is back.",
                             recoveryID: .A02)
    }
}
