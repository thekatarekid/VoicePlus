import Combine
import Engine
import Foundation
import Shared

/// S8 — the composition root's half of onboarding: what only the running app can answer. Called by
/// `AppDelegate` through `OnboardingWindowController.configure`, so every way the window opens gets
/// the same wiring.
extension OnboardingDependencies {
    @MainActor
    mutating func wireLive(container: AppContainer, hotkey: HotkeyService, keyEvents: DictationKeyEvents,
                           makeEnrollment: @escaping @MainActor () -> SpeakerEnrollmentViewModel?) {
        self.keyEvents = keyEvents
        // I1 — the live service's binding, its own fn reading, and its rebind (which re-arms).
        self.dictationKey = { [weak hotkey] in hotkey?.binding.kind ?? HotkeyService.defaultBinding.kind }
        self.setDictationKey = { [weak hotkey] kind in hotkey?.setBinding(kind) }
        self.fnConflict = { kind in HotkeyService.fnConflict(for: HotkeyBinding(kind: kind)) }
        self.isVoiceEnrolled = { [weak container] in container?.latchController.profiles.profile != nil }
        // Model step: "Loading" is the engine really resolving the installed stack; "Ready" only
        // once that load returned (design §8.6).
        self.loadModel = { [weak container] in
            guard let container else { return .failed(RecoveryCatalog.entry(.M07).headline) }
            return await Self.loadInstalledModel(container: container)
        }
        // FX3 — a load that failed (or never ran) while a swap was pending retries itself once the
        // engine has actually changed.
        self.engineChanges = NotificationCenter.default
            .publisher(for: AppContainer.engineDidChangeNotification, object: container)
            .map { _ in () }
            .eraseToAnyPublisher()
        // V4.48 — the recorder-backed enrollment Voice › Enrollment runs. Its own completion is
        // replaced by onboarding's, so the profile is installed exactly once.
        self.makeEnrollment = {
            guard let enrollment = makeEnrollment() else { return nil }
            enrollment.onComplete = nil
            return enrollment
        }
        self.installVoiceProfile = { [weak container] profile in
            guard let container else { return false }
            return container.latchController.install(profile: profile) == .filtering
        }
    }

    /// Re-resolves the engine against what is on disk, then loads the model into memory. A mock
    /// engine (developer opt-in) has nothing to load.
    @MainActor
    static func loadInstalledModel(container: AppContainer) async -> OnboardingStateMachine.ModelLoadOutcome {
        await InstalledModelLoader(
            refreshEngine: { [weak container] in await container?.refreshEngineIfNeeded() },
            isMockEngine: { [weak container] in
                if case .mock? = container?.engineKind { return true }
                return false
            },
            modelName: { [weak container] in container?.activeModelName ?? "the speech model" },
            currentModel: { [weak container] in (container?.engine as? SwappableEngine)?.current as? RealEngine },
            stackOnDisk: { [weak container] in
                guard let manager = container?.modelManager else { return false }
                return await RecognizerFactory.chooseFinal(manager: manager) != nil
            }
        ).load()
    }
}

/// Anything whose speech model can be loaded into memory: `RealEngine` in the app, a fake in tests.
protocol PreloadableModel: AnyObject {
    var isModelLoaded: Bool { get }
    func preloadModel() async -> Bool
}

extension RealEngine: PreloadableModel {}

/// FX3 — the Model step's "Loading" → Ready / M07, over seams a test can drive.
///
/// The 1.11.1 fresh-install report: all three models were downloaded and verified, and the step
/// still said "The speech model isn't ready" — 7 ms *before* the engine swap that the download had
/// already started. The load asked for a refresh, the refresh returned at once because another was
/// running, and the box still held `UnavailableEngine`. `AppContainer.RefreshGate` now makes that
/// refresh wait; this type adds the belt to those braces: while what is on disk can recognise but
/// the engine has not swapped yet, it waits (bounded) instead of reporting a failure the user did
/// not cause. M07 is only ever said once the model really could not be loaded, and `why` (the
/// step's Details) says which of those it was.
struct InstalledModelLoader {
    /// Re-resolves the engine against what is on disk; returns once any swap it starts has landed.
    var refreshEngine: @MainActor () async -> Void
    var isMockEngine: @MainActor () -> Bool
    var modelName: @MainActor () -> String
    /// The engine's loadable model; nil while the box still holds `UnavailableEngine`.
    var currentModel: @MainActor () -> PreloadableModel?
    /// Whether what is on disk can recognise, i.e. whether a swap is still owed.
    var stackOnDisk: @MainActor () async -> Bool
    /// How long a pending swap is waited for before the step says M07.
    var swapTimeout: TimeInterval = 10
    /// Each poll also asks for a refresh, which joins one already running rather than stacking up.
    var pollInterval: TimeInterval = 0.25

    static let swapTimedOut = "The models are on this Mac, but the speech engine did not switch over to them in time."
    static let nothingOnDisk = "No installed speech model was found on this Mac."
    static let preloadFailed = "The models are on this Mac, but loading them into memory failed."

    @MainActor
    func load() async -> OnboardingStateMachine.ModelLoadOutcome {
        await refreshEngine()
        if isMockEngine() { return .loaded(name: modelName()) }
        var model = currentModel()
        if model == nil {
            guard await stackOnDisk() else { return .failed(Self.nothingOnDisk) }
            Log.app.notice("onboarding: the stack is on disk but the engine has not swapped yet — waiting up to \(Int(swapTimeout)) s")
            let deadline = Date().addingTimeInterval(swapTimeout)
            while model == nil, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(pollInterval, 0.01) * 1_000_000_000))
                await refreshEngine()
                model = currentModel()
            }
        }
        guard let model else { return .failed(Self.swapTimedOut) }
        let loaded = model.isModelLoaded ? true : await model.preloadModel()
        return loaded ? .loaded(name: modelName()) : .failed(Self.preloadFailed)
    }
}
