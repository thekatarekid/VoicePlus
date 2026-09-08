import AppKit
import Combine
import Engine
import Foundation
import Lab
import Shared

/// Onboarding's permission protocol over the app's TCC-backed `PermissionChecking`.
public final class LivePermissionChecker: OnboardingPermissionChecking {
    private let checker: PermissionChecking
    public init(checker: PermissionChecking) { self.checker = checker }

    static func map(_ p: OnboardingPermission) -> Permission {
        switch p {
        case .microphone: return .microphone
        case .inputMonitoring: return .inputMonitoring
        case .accessibility: return .accessibility
        }
    }

    static func map(_ s: PermissionStatus) -> OnboardingPermissionStatus {
        switch s {
        case .granted: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .awaitingUserAction: return .awaitingUserAction
        }
    }

    public func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        Self.map(checker.status(of: Self.map(permission)))
    }

    public func request(_ permission: OnboardingPermission) async -> OnboardingPermissionStatus {
        await withCheckedContinuation { c in
            checker.request(Self.map(permission)) { c.resume(returning: Self.map($0)) }
        }
    }

    public func openSystemSettings(for permission: OnboardingPermission) {
        PermissionSettingsOpener.open(permission.core)
    }
}

/// Mic-check meter fed by the audio pipeline's own `.level(rms:)` channel — the one built for this
/// and, until now, consumed by nobody.
///
/// It deliberately does *not* touch the ASR engine: `RealEngine.start(prewarm:)` resolves the CoreML
/// model first (which the mic-check step runs *before* the model step, so it can fail outright),
/// emits one synthetic `listening(level: 0)` before any sample exists, and stops emitting levels the
/// moment a preview recognizer moves the state to `.previewing`. Metering the pipeline directly also
/// guarantees no recognizer runs and nothing can be typed during onboarding.
public final class PipelineMicLevelPublisher: MicLevelPublishing {
    private let audio: PipelineAudioSource
    private let subject = CurrentValueSubject<MicCheckSignal, Never>(.starting)
    private var reader: Task<Void, Never>?
    private var starter: Task<Void, Never>?
    private var blocks = 0
    private let stateLock = NSLock()
    private var stopped = false

    public init(audio: PipelineAudioSource) { self.audio = audio }

    /// The mic check's **own** capture graph — the point being that metering a microphone needs no
    /// ASR model at all.
    ///
    /// Before 1.6.9 onboarding borrowed whatever `AppContainer` had: a live pipeline when a
    /// recognizer existed, and otherwise `EngineMicLevelPublisher`, which forwarded the *mock*
    /// engine's fixture-derived `listening(level:)` numbers. On a fresh install (no model on disk —
    /// the only state onboarding ever runs in) the meter therefore filled and the step passed with
    /// the user silent and no microphone open. After 329af01 that same install builds
    /// `UnavailableEngine`, which emits no levels at all, so the meter was dead instead of fake.
    ///
    /// This is the same object graph `MicSelfTest` and `EngineFactory.make()` build —
    /// `AcousticCaptureSource(wrapping: CoreAudioCaptureSource(), profile: .default)` →
    /// `AudioPipeline` → `PipelineAudioSource` — minus the recognizer. Nothing here can transcribe,
    /// so nothing here can type.
    public static func standalone() -> PipelineMicLevelPublisher {
        let capture = AcousticCaptureSource(wrapping: CoreAudioCaptureSource(), profile: .default)
        let pipeline = AudioPipeline(source: capture, vad: EnergyVAD())
        Log.app.info("onboarding mic meter: standalone capture graph (no ASR engine involved)")
        return PipelineMicLevelPublisher(audio: PipelineAudioSource(pipeline: pipeline))
    }

    public var signalPublisher: AnyPublisher<MicCheckSignal, Never> { subject.eraseToAnyPublisher() }
    /// Real hardware, always: this class only ever reports what the capture stack measured.
    public var isRealCapture: Bool { true }

    public func startMonitoring() {
        subject.send(.starting)
        blocks = 0
        stateLock.withLock { stopped = false }
        let events = audio.pipeline.events()
        reader = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .level(let rms):
                    self.blocks += 1
                    if self.blocks == 1 { Log.app.info("mic check: first audio block reached the meter") }
                    // Same normalisation the pill uses, so the two meters agree.
                    self.subject.send(.level(min(1, rms * 4)))
                case .captureFailed(let reason):
                    // The pipeline's no-audio watchdog. Before 1.6.4 this state was indistinguishable
                    // from a very quiet room, which is exactly how the user got a dead level bar.
                    Log.app.error("mic check: \(reason)")
                    self.subject.send(.failed(reason))
                case .stopped:
                    return
                default:
                    break
                }
            }
        }
        // `PipelineAudioSource.start()` waits on the HAL for up to `startTimeout` (measured: 4.7 s
        // on a Continuity Camera mic). Onboarding calls this from the main actor, so the waiting
        // happens off it — a slow device must not freeze the window.
        starter = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, !self.isStopped else { return }
            do {
                try self.audio.start()
                // A `stopMonitoring()` that landed while the HAL was opening must still win, or the
                // microphone stays live after the screen is gone.
                if self.isStopped { self.audio.stop(); return }
                Log.app.info("mic check: capture started on \(self.audio.deviceName ?? "default device")")
            } catch {
                // The old code logged this and left the UI claiming "very quiet" forever.
                Log.app.error("mic check could not start capture: \(error)")
                self.subject.send(.failed(Self.describe(error)))
            }
        }
    }

    public func stopMonitoring() {
        stateLock.withLock { stopped = true }
        reader?.cancel()
        reader = nil
        starter = nil
        audio.stop()
        Log.app.debug("mic check: capture stopped after \(self.blocks) audio blocks")
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    static func describe(_ error: Error) -> String {
        guard let capture = error as? AudioCaptureError else { return String(describing: error) }
        switch capture {
        case .noInputDevice:
            return "No input device is available to VoicePlus. Microphone permission may be granted to an older copy of this app."
        case .formatMismatch(let hardware, let client):
            return hardware == 0
                ? "The microphone could not be opened. macOS reported no input format for this device."
                : "VoicePlus could not agree a format with the microphone (\(Int(hardware)) Hz hardware vs \(Int(client)) Hz). Capture was stopped instead of running silently."
        case .noAudio:
            return "No sound is reaching VoicePlus. Capture started but not one audio block arrived."
        default:
            return String(describing: capture)
        }
    }
}

// `EngineMicLevelPublisher` was deleted in 1.6.9. It forwarded `EngineState.listening(level:)` —
// for the mock engine, a number derived from a transcript fixture with no microphone anywhere in
// the chain — and marked itself `isRealCapture = false`, which bought nothing: the state machine
// still turned those levels into a `.good` verdict and the screen only added a footnote. There is
// no longer any engine-derived path into the mic check; see `PipelineMicLevelPublisher.standalone()`.

/// The real models behind each friendly tier name, read from `ModelCatalog` so the picker can never
/// drift from what is actually downloaded.
///
/// P4: the picker used to show "Fast / Balanced / Best" and a hardcoded size, and all three sizes
/// were wrong — "Best" advertised "~1.2 GB" for what is really two models totalling 900 MB. The
/// names were nowhere on screen at all, so there was no way to tell what the 1.2 GB was.
public extension ModelTier {
    var models: [ModelID] { ModelManagerTiers.models(for: self) }
    var descriptors: [ModelDescriptor] { models.map(ModelCatalog.descriptor) }
    /// Catalog display names, e.g. ["Parakeet TDT 0.6B v3", "Parakeet Realtime EOU 120M (160 ms)"].
    var modelNames: [String] { descriptors.map(\.displayName) }
    /// What the picker prints next to the friendly word: the real model names, joined.
    var modelNameLine: String { modelNames.joined(separator: " + ") }
    var approximateBytes: Int64 { descriptors.reduce(0) { $0 + $1.approxBytes } }
    var sizeLabel: String { ByteText.short(approximateBytes) }
}

/// Plain-language tiers → `ModelID`s on disk. Downloads go through `ModelManager`
/// (HF resume + SHA256); the chosen tier is persisted in settings.
public final class ModelManagerTiers: ModelManaging {
    public static let tierKey = "models.selectedTier"
    /// The name `EngineFactory` logs for the silent fallback, so the onboarding screen and the log
    /// call the same thing by the same name.
    public static let appleSpeechName = "Apple Speech (on-device)"
    private let manager: ModelManager
    private let settings: SettingsStore
    private var presence: [ModelTier: Bool] = [:]
    /// Per-model presence, so `readiness` can name the model that will actually stand in for a tier
    /// that is not on disk yet — a tier-level bool cannot answer that.
    private var modelPresence: [ModelID: Bool] = [:]
    /// Injected so the "nothing can transcribe" branch is reachable in a test on a Mac where Apple
    /// Speech happens to be available.
    public var appleSpeechAvailable: () -> Bool = { AppleSpeechRecognizer.isAvailable() }
    /// Fired after `refresh()` has re-read the models directory — a download landing, or a tier
    /// that turned out to be installed already. `AppContainer` uses it to re-resolve the engine.
    public var onModelsChanged: (() -> Void)?

    public init(manager: ModelManager, settings: SettingsStore) {
        self.manager = manager
        self.settings = settings
        Task { await refresh() }
    }

    public static func models(for tier: ModelTier) -> [ModelID] {
        switch tier {
        case .fast: return [.parakeetTDTCTC110m]
        case .balanced: return [.parakeetTDTv3]
        case .best: return [.parakeetTDTv3, .parakeetEOU160]
        }
    }

    public func refresh() async {
        var models: [ModelID: Bool] = [:]
        for id in ModelID.allCases { models[id] = await manager.isPresent(id) }
        var byTier: [ModelTier: Bool] = [:]
        for tier in ModelTier.allCases {
            byTier[tier] = Self.models(for: tier).allSatisfy { models[$0] == true }
        }
        let (tiers, perModel) = (byTier, models)
        await MainActor.run {
            let before = Set(modelPresence.filter(\.value).keys)
            let after = Set(perModel.filter(\.value).keys)
            let changed = before != after
            presence = tiers
            modelPresence = perModel
            // Only when what is on disk actually moved: the first refresh (from `init`) and every
            // no-op poll must not make the composition root re-resolve the engine.
            if changed { onModelsChanged?() }
        }
    }

    public func isInstalled(_ tier: ModelTier) -> Bool { presence[tier] ?? false }

    /// Model downloads are the one egress path outside the provider table: they honour the
    /// Data Panel kill switch and are logged to `network_log` like any other request (T3/T5).
    ///
    /// Progress is byte-weighted across the models that are actually missing, so a tier whose big
    /// model is already on disk does not spend half the bar on a file it never fetches. The
    /// denominator is the catalog's advertised size, which is what the picker promised and which —
    /// unlike a per-response `Content-Length` — does not move while the bar is on screen.
    public func download(_ tier: ModelTier, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        var pending: [ModelDescriptor] = []
        for id in Self.models(for: tier) where await !manager.isPresent(id) {
            pending.append(ModelCatalog.descriptor(id))
        }
        guard !pending.isEmpty else { await refresh(); return }
        let total = max(pending.reduce(Int64(0)) { $0 + $1.approxBytes }, 1)
        let count = pending.count
        var completed: Int64 = 0
        let host = "huggingface.co"
        for (index, d) in pending.enumerated() {
            try EgressGate.shared.check(host: host)
            let done = completed
            _ = try await manager.ensureAvailable(d.id) { info in
                let received = done + Int64(min(max(info.fraction, 0), 1) * Double(d.approxBytes))
                progress(ModelDownloadProgress(fraction: Double(received) / Double(total),
                                               bytesReceived: received, bytesExpected: total,
                                               modelName: d.displayName, index: index + 1, count: count))
            }
            completed += d.approxBytes
            progress(ModelDownloadProgress(fraction: Double(completed) / Double(total),
                                           bytesReceived: completed, bytesExpected: total,
                                           modelName: d.displayName, index: index + 1, count: count))
            _ = try? EgressGate.shared.log(stage: "model", provider: d.hfRepo, host: host, bytesOut: 0,
                                           bytesIn: Int(d.approxBytes), purpose: "model download \(d.displayName)")
        }
        await refresh()
    }

    public func select(_ tier: ModelTier) { settings.set(tier.rawValue, for: Self.tierKey) }

    public var selectedTier: ModelTier {
        settings.string(Self.tierKey).flatMap(ModelTier.init(rawValue:)) ?? .recommended
    }

    /// Mirrors `RecognizerFactory.chooseFinal` — full TDT v3, else the tiny one, else Apple Speech —
    /// so the screen names the recogniser the engine will really pick rather than guessing.
    public func readiness(for tier: ModelTier) -> RecognizerReadiness {
        if isInstalled(tier) { return .ready(name: tier.modelNames.first ?? tier.title) }
        let awaiting = tier.descriptors.filter { modelPresence[$0.id] != true }.map(\.displayName).first
        for id in [ModelID.parakeetTDTv3, .parakeetTDTCTC110m] where modelPresence[id] == true {
            return .fallback(name: ModelCatalog.descriptor(id).displayName, awaiting: awaiting)
        }
        if appleSpeechAvailable() { return .fallback(name: Self.appleSpeechName, awaiting: awaiting) }
        return .unavailable(reason: "No speech model has finished downloading yet, and macOS' own on-device recogniser isn't available on this Mac. There is nothing to transcribe with until the download lands.")
    }
}
