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
    private var blocks = 0

    public init(audio: PipelineAudioSource) { self.audio = audio }

    public var signalPublisher: AnyPublisher<MicCheckSignal, Never> { subject.eraseToAnyPublisher() }

    public func startMonitoring() {
        subject.send(.starting)
        blocks = 0
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
                case .stopped:
                    return
                default:
                    break
                }
            }
        }
        do {
            try audio.start()
            Log.app.info("mic check: capture started on \(self.audio.deviceName ?? "default device")")
        } catch {
            // The old code logged this and left the UI claiming "very quiet" forever.
            Log.app.error("mic check could not start capture: \(error)")
            subject.send(.failed(Self.describe(error)))
        }
    }

    public func stopMonitoring() {
        reader?.cancel()
        reader = nil
        audio.stop()
        Log.app.debug("mic check: capture stopped after \(self.blocks) audio blocks")
    }

    static func describe(_ error: Error) -> String {
        guard let capture = error as? AudioCaptureError else { return String(describing: error) }
        switch capture {
        case .noInputDevice:
            return "No input device is available to VoicePlus. Microphone permission may be granted to an older copy of this app."
        default:
            return String(describing: capture)
        }
    }
}

/// Fallback meter for builds with no live pipeline (mock engine). Marked as not-real capture so the
/// mic-check screen cannot claim a working microphone on the strength of a fixture.
public final class EngineMicLevelPublisher: MicLevelPublishing {
    private let engine: any EngineProtocol
    private let subject = CurrentValueSubject<MicCheckSignal, Never>(.starting)
    private var cancellable: AnyCancellable?

    public init(engine: any EngineProtocol) { self.engine = engine }

    public var signalPublisher: AnyPublisher<MicCheckSignal, Never> { subject.eraseToAnyPublisher() }
    public var isRealCapture: Bool { false }

    public func startMonitoring() {
        subject.send(.starting)
        cancellable = engine.statePublisher.sink { [subject] state in
            if case .listening(let level) = state, level > 0 { subject.send(.level(level)) }
        }
        Task { [engine, subject] in
            do { try await engine.start(prewarm: true) } catch {
                Log.app.error("mic check could not start capture: \(error)")
                subject.send(.failed(String(describing: error)))
            }
        }
    }

    public func stopMonitoring() {
        cancellable = nil
        Task { [engine] in await engine.cancel() }
    }
}

/// Plain-language tiers → `ModelID`s on disk. Downloads go through `ModelManager`
/// (HF resume + SHA256); the chosen tier is persisted in settings.
public final class ModelManagerTiers: ModelManaging {
    public static let tierKey = "models.selectedTier"
    private let manager: ModelManager
    private let settings: SettingsStore
    private var presence: [ModelTier: Bool] = [:]

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
        var p: [ModelTier: Bool] = [:]
        for tier in ModelTier.allCases {
            var all = true
            for id in Self.models(for: tier) where await !manager.isPresent(id) { all = false }
            p[tier] = all
        }
        await MainActor.run { presence = p }
    }

    public func isInstalled(_ tier: ModelTier) -> Bool { presence[tier] ?? false }

    /// Model downloads are the one egress path outside the provider table: they honour the
    /// Data Panel kill switch and are logged to `network_log` like any other request (T3/T5).
    public func download(_ tier: ModelTier, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ids = Self.models(for: tier)
        for (i, id) in ids.enumerated() {
            if await manager.isPresent(id) { continue }
            let d = ModelCatalog.descriptor(id)
            let host = "huggingface.co"
            try EgressGate.shared.check(host: host)
            let base = Double(i) / Double(ids.count)
            let share = 1.0 / Double(ids.count)
            _ = try await manager.ensureAvailable(id) { info in progress(base + info.fraction * share) }
            _ = try? EgressGate.shared.log(stage: "model", provider: d.hfRepo, host: host, bytesOut: 0,
                                           bytesIn: Int(d.approxBytes), purpose: "model download \(d.displayName)")
        }
        await refresh()
    }

    public func select(_ tier: ModelTier) { settings.set(tier.rawValue, for: Self.tierKey) }

    public var selectedTier: ModelTier {
        settings.string(Self.tierKey).flatMap(ModelTier.init(rawValue:)) ?? .recommended
    }
}
