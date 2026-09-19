import Engine
import Foundation

/// S11 — onboarding's error paths as recovery-catalogue entries (design §10; §9 "Onboarding: stay on
/// the failed step, preserve completed steps"). The step shows the entry's headline, consequence and
/// its own one action; the technical cause, when there is one, sits behind a Details disclosure.
enum OnboardingRecovery {
    /// What the onboarding window can do for an entry's action. Only the entry's own action is ever
    /// offered — there is no universal "Try again" (design §10).
    enum Step: Equatable, Sendable {
        /// The retry of a practice turn: clear the verdict and run the test again (A05–A07, K03).
        case retryDictation
        /// The permission's own System Settings pane (P01–P03).
        case openSettings(OnboardingPermission)
        /// Sound settings, where the input device is chosen (A01–A05, A08).
        case openSoundSettings
        /// Load the installed model again (M07).
        case retryModelLoad
        /// Download the model again (M02–M04).
        case installModels
        /// Nothing this window can do for the action; the step stays, and the action's own surface
        /// (Settings, Today) is where it is taken.
        case none
    }

    static func step(for id: RecoveryID) -> Step {
        switch id.actionKind {
        case .retryTurn: return .retryDictation
        case .openSetting:
            switch id.permission {
            case .microphone?: return .openSettings(.microphone)
            case .accessibility?: return .openSettings(.accessibility)
            case .inputMonitoring?: return .openSettings(.inputMonitoring)
            case nil: return .none
            }
        case .chooseMicrophone, .testMicrophone, .checkMicrophone: return .openSoundSettings
        case .retryLoad: return .retryModelLoad
        case .restartDownload: return .installModels
        default: return .none
        }
    }

    /// The practice dictation's failure, as the entry it names; nil when it worked.
    static func entry(for outcome: GuidedDictationOutcome?) -> RecoveryEntry? {
        outcome?.recoveryID.map(RecoveryCatalog.entry)
    }

    /// The microphone check's verdict as the entry it is: no samples (A05), quiet or clipped input
    /// (A08, the verdict's own guidance kept beside it), a capture that could not start (A03), or no
    /// grant (P01). Nil for waiting and a pass.
    static func entry(for verdict: OnboardingStateMachine.MicVerdict) -> RecoveryEntry? {
        switch verdict {
        case .waiting, .good: return nil
        case .noAudio: return RecoveryCatalog.entry(.A05)
        case .tooQuiet, .clipping: return RecoveryCatalog.entry(.A08)
        case .unavailable: return RecoveryCatalog.entry(.A03)
        case .permissionRequired: return RecoveryCatalog.entry(.P01)
        }
    }

    /// The technical cause behind the verdict, for the Details disclosure only.
    static func detail(for verdict: OnboardingStateMachine.MicVerdict) -> String? {
        if case .unavailable(let reason) = verdict, !reason.isEmpty { return reason }
        return nil
    }
}
