import Combine
import Foundation
import Shared

/// Drives `OnboardingStateMachine` with real side effects from `OnboardingDependencies`.
@MainActor
public final class OnboardingViewModel: ObservableObject {
    @Published public private(set) var machine: OnboardingStateMachine
    @Published public var micLevel: Float = 0
    @Published public var dictationPreview: String = ""
    @Published public var isDictating = false
    @Published public var contactsOutcome: ContactsImportOffer.Outcome?
    @Published public var showContactsOffer = false

    public let deps: OnboardingDependencies
    public let contactsOffer: ContactsImportOffer
    public var onFinished: ((Bool) -> Void)?

    private var micCancellable: AnyCancellable?
    private var downloadTask: Task<Void, Never>?
    private var dictationTask: Task<Void, Never>?

    public init(dependencies: OnboardingDependencies) {
        deps = dependencies
        var initial: [OnboardingPermission: OnboardingPermissionStatus] = [:]
        for p in OnboardingPermission.allCases { initial[p] = dependencies.permissions.status(of: p) }
        machine = OnboardingStateMachine(initialStatuses: initial)
        contactsOffer = ContactsImportOffer(store: dependencies.contacts, database: dependencies.database,
                                            settings: dependencies.settingsStore)
    }

    public var step: OnboardingStateMachine.Step { machine.step }

    public func send(_ event: OnboardingStateMachine.Event) {
        let effects = machine.handle(event)
        for effect in effects { perform(effect) }
    }

    // MARK: Side effects

    private func perform(_ effect: OnboardingStateMachine.SideEffect) {
        switch effect {
        case .requestPermission(let p):
            Task { [weak self] in
                guard let self else { return }
                let status = await deps.permissions.request(p)
                send(.permissionResult(p, status))
            }
        case .checkPermission(let p):
            send(.permissionResult(p, deps.permissions.status(of: p)))
        case .openSystemSettings(let p):
            deps.permissions.openSystemSettings(for: p)
        case .startMicMonitoring:
            deps.micLevel.startMonitoring()
            micCancellable = deps.micLevel.levelPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] level in
                    self?.micLevel = level
                    self?.send(.micLevel(level))
                }
        case .stopMicMonitoring:
            micCancellable = nil
            deps.micLevel.stopMonitoring()
        case .selectModel(let tier):
            deps.models.select(tier)
        case .startDownload(let tier):
            guard !deps.models.isInstalled(tier) else { send(.downloadFinished); return }
            downloadTask?.cancel()
            downloadTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await deps.models.download(tier) { progress in
                        Task { @MainActor [weak self] in self?.send(.downloadProgress(progress)) }
                    }
                    send(.downloadFinished)
                } catch {
                    send(.downloadFailed(error.localizedDescription))
                }
            }
        case .beginGuidedDictation:
            break  // user holds the key / presses the button; see `runGuidedDictation`
        case .finish(let skipped):
            deps.settingsStore.set(true, for: SettingsKeys.onboardingCompleted)
            showContactsOffer = !contactsOffer.alreadyOffered
            onFinished?(skipped)
        }
    }

    public func openSettings(for p: OnboardingPermission) { perform(.openSystemSettings(p)) }

    /// Runs one utterance through the engine so the last step is *doing*, not watching.
    public func runGuidedDictation() {
        guard !isDictating else { return }
        isDictating = true
        dictationPreview = ""
        dictationTask = Task { [weak self] in
            guard let self else { return }
            let engine = deps.engine
            let events = engine.events()
            let consumer = Task { [weak self] in
                for await event in events {
                    if case .partial(let spans) = event {
                        await MainActor.run { self?.dictationPreview = spans.map(\.text).joined(separator: " ") }
                    }
                }
            }
            do {
                try await engine.start(prewarm: true)
                let spans = try await engine.stop()
                let text = spans.map(\.text).joined(separator: " ")
                dictationPreview = text
                send(.dictationLanded(text))
            } catch {
                send(.dictationLanded(""))
            }
            consumer.cancel()
            isDictating = false
        }
    }

    public func acceptContactsImport() {
        Task { [weak self] in
            guard let self else { return }
            contactsOutcome = await contactsOffer.accept()
            showContactsOffer = false
        }
    }

    public func declineContactsImport() {
        contactsOutcome = contactsOffer.decline()
        showContactsOffer = false
    }
}
