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
        await container.refreshEngineIfNeeded()
        if case .mock = container.engineKind { return .loaded(name: container.activeModelName) }
        guard let real = (container.engine as? SwappableEngine)?.current as? RealEngine else {
            return .failed(RecoveryCatalog.entry(.M07).headline)
        }
        let loaded = real.isModelLoaded ? true : await real.preloadModel()
        return loaded ? .loaded(name: container.activeModelName) : .failed(RecoveryCatalog.entry(.M07).headline)
    }
}
