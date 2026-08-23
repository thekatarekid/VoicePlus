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
        NSWorkspace.shared.open(permission.settingsURL)
    }
}

/// Mic-check meter: runs the engine's capture path and maps `.listening(level:)` to 0…1.
/// Cancels (never finalises) on stop so nothing is typed during onboarding.
public final class EngineMicLevelPublisher: MicLevelPublishing {
    private let engine: any EngineProtocol
    private let subject = PassthroughSubject<Float, Never>()
    private var cancellable: AnyCancellable?

    public init(engine: any EngineProtocol) { self.engine = engine }

    public var levelPublisher: AnyPublisher<Float, Never> { subject.eraseToAnyPublisher() }

    public func startMonitoring() {
        cancellable = engine.statePublisher.sink { [subject] state in
            if case .listening(let level) = state { subject.send(level) }
        }
        Task { [engine] in
            do { try await engine.start(prewarm: true) } catch { Log.app.notice("mic check could not start capture: \(error)") }
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
