import Foundation

/// S8 — "Resume setup at unfinished step" (design §8.7). Kept out of `SettingsStore.swift` (owned by
/// another task this wave), in this extension.
public extension SettingsKeys {
    /// `OnboardingStateMachine.Step.rawValue` of the step the user last stood on; absent once
    /// onboarding is finished.
    static let onboardingResumeStep = "onboarding.resumeStep"
}

/// Where an unfinished onboarding picks up. Written on every step change, cleared when Ready is
/// reached, and read when the window opens — so "Set up later", the close button and a quit all
/// leave setup where the user left it.
public struct OnboardingResume {
    public let store: SettingsStore

    public init(store: SettingsStore) { self.store = store }

    /// The step to reopen on, or nil for a fresh start: onboarding already finished, nothing stored,
    /// or a value this build does not know. Welcome and Ready are never resumed onto.
    public var step: OnboardingStateMachine.Step? {
        guard store.bool(SettingsKeys.onboardingCompleted) != true,
              let raw = store.string(SettingsKeys.onboardingResumeStep),
              let step = OnboardingStateMachine.Step(rawValue: raw),
              step != .welcome, step != .done else { return nil }
        return step
    }

    public func save(_ step: OnboardingStateMachine.Step) {
        guard step != .done else { clear(); return }
        store.set(step.rawValue, for: SettingsKeys.onboardingResumeStep)
    }

    public func clear() { store.set(nil as String?, for: SettingsKeys.onboardingResumeStep) }
}
