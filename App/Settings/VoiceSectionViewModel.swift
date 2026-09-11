import Engine
import Foundation
import Lab
import Shared

// R7.2 — Voice (`DESIGN.md` §9.4): the microphone, the voice enrolled on this Mac, and the
// measurements. This is where the standalone enrollment window and the whole Lab UI end up, and it
// is the only place model names, latency and thermal state are allowed to appear (V3 §9.1,
// `DESIGN.md` §12.6 — never the pill, never the menu).

/// Voice. Three groups, three independent states: nothing here may blank the other two.
@MainActor
public final class VoiceSectionViewModel: ObservableObject {
    // MARK: Microphone
    @Published public private(set) var microphone: SectionState = .content
    @Published public private(set) var microphoneBanner: SectionBanner?

    // MARK: Enrollment
    @Published public private(set) var enrollment: SectionState = .content
    /// Non-nil while enrollment is running **inline in this pane** — never in its own window.
    @Published public private(set) var enrolling: SpeakerEnrollmentViewModel?

    // MARK: Benchmark
    @Published public private(set) var benchmark: SectionState = .content

    public let audio: AudioInputSettingsViewModel
    public let lab: LabPanelViewModel
    public let counters: BenchmarkViewModel
    private let permissions: OnboardingPermissionChecking
    private let profiles: SpeakerProfileStore
    private let makeEnrollment: (() -> SpeakerEnrollmentViewModel?)?
    /// False until the device list has been enumerated once, which is the only honest basis for
    /// "Looking for microphones…".
    @Published public private(set) var devicesEnumerated = false
    private var runTask: Task<Void, Never>?

    public init(audio: AudioInputSettingsViewModel? = nil,
                permissions: OnboardingPermissionChecking,
                lab: LabPanelViewModel,
                counters: BenchmarkViewModel? = nil,
                profiles: SpeakerProfileStore = SpeakerProfileStore(),
                makeEnrollment: (() -> SpeakerEnrollmentViewModel?)? = nil) {
        self.audio = audio ?? AudioInputSettingsViewModel()
        self.permissions = permissions
        self.lab = lab
        self.counters = counters ?? BenchmarkViewModel(report: BenchmarkViewModel.lastMeasured)
        self.profiles = profiles
        self.makeEnrollment = makeEnrollment
        refresh()
    }

    public func refresh() {
        refreshMicrophone()
        refreshEnrollment()
        refreshBenchmark()
    }

    // MARK: Microphone (§9.4)

    public func markDevicesEnumerated() {
        devicesEnumerated = true
        refreshMicrophone()
    }

    public func refreshMicrophone() {
        let status = permissions.status(of: .microphone)
        if status == .denied || status == .awaitingUserAction {
            microphoneBanner = nil
            microphone = .error(SectionCopy.microphoneOff,
                                detail: "System Settings › Privacy & Security › Microphone",
                                action: SectionCopy.openSystemSettings)
            return
        }
        guard devicesEnumerated else {
            microphone = .loading(SectionCopy.lookingForMicrophones)
            return
        }
        if audio.devices.isEmpty {
            microphoneBanner = nil
            microphone = .empty("No microphone is connected",
                                detail: "Plug one in, or turn on the Mac's built-in microphone.",
                                action: SectionCopy.chooseMicrophone)
            return
        }
        // A chosen device that vanished mid-session: §7.1's sentence, verbatim, over live content.
        let vanished = audio.selection != AudioInputSettingsViewModel.automatic
            && !audio.devices.contains { $0.uid == audio.selection }
        microphoneBanner = vanished
            ? SectionBanner(headline: DeliveryCopy.microphoneDisconnected, actionTitle: SectionCopy.chooseMicrophone)
            : nil
        microphone = .content
    }

    /// The picker is disabled until the enumeration answers — `DESIGN.md` §9.4's loading state.
    public var isMicrophonePickerEnabled: Bool { microphone.rendering == .content || microphone.rendering == .empty }

    // MARK: Enrollment (§9.4) — inline, never a window

    public var enrolledProfile: SpeakerProfile? { profiles.profile }
    public var isEnrolled: Bool { enrolledProfile != nil }

    public func refreshEnrollment() {
        if enrolling != nil { enrollment = .content; return }
        enrollment = isEnrolled
            ? .content
            : .empty(SectionCopy.noEnrollment, detail: SectionCopy.noEnrollmentDetail, action: "Enroll my voice")
    }

    /// Starts (or restarts) enrollment in this pane. Returns false when no recorder is wired, which
    /// is stated rather than pretended.
    @discardableResult
    public func beginEnrollment() -> Bool {
        guard let model = makeEnrollment?() else {
            enrollment = .error("Enrollment can't start", detail: "The microphone isn't available to this window right now.",
                                action: SectionCopy.tryAgain)
            return false
        }
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
        return true
    }

    /// Adopts an enrollment view model built elsewhere (the composition root owns the recorder).
    public func install(enrollment model: SpeakerEnrollmentViewModel) {
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
        profiles.delete()
        enrolling = nil
        refreshEnrollment()
    }

    // MARK: Benchmark (§9.4) — the whole Lab, folded in

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
