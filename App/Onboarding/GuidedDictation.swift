import Foundation
import Shared

// MARK: - What the guided dictation actually achieved

/// The outcome of one press of "Dictate now", stated in terms of what happened rather than in terms
/// of "a function returned".
///
/// The 1.6.6 report is the reason this type exists. `runGuidedDictation` caught its error, threw it
/// away, and emitted the *success* event with an empty string; the state machine stored the empty
/// string; the view checked `landedText != nil` and drew a green "It landed. You're set." while the
/// pill next to it showed a red microphone and `invalidAudioData`. Two screens, one attempt, two
/// opposite claims — and the more visible one was wrong. Success is now a *case*, not the absence of
/// a nil, and there is no way to construct it without text.
public enum GuidedDictationOutcome: Equatable, Sendable {
    /// Transcribed **and** typed into the app the user was in. The only outcome that may say
    /// "It landed": it requires an injection that reported success, not merely a recogniser that
    /// returned.
    case landed(text: String, app: String?)
    /// Transcribed, shown on screen, and deliberately not typed anywhere.
    ///
    /// This is the honest result of pressing a button that lives *inside* the onboarding window:
    /// clicking it makes VoicePlus frontmost, so the text field the user was told to click into is
    /// no longer focused and nothing can land there. Saying so is the point — the old screen implied
    /// the opposite and then congratulated the user for it.
    case heard(text: String, recognizer: String)
    /// Capture ran, but less audio arrived than the recogniser's own floor. Carries what there was.
    case noSpeech(seconds: Double)
    /// Anything else, already in the words the user should read (see `EngineMessage.describe`).
    case failed(reason: String)

    /// Text VoicePlus heard, landed or not. Nil when there was nothing to hear.
    public var text: String? {
        switch self {
        case .landed(let text, _), .heard(let text, _): return text
        case .noSpeech, .failed: return nil
        }
    }

    /// Only ever non-nil for `.landed`. This is the predicate "It landed. You're set." reads.
    public var landedText: String? {
        if case .landed(let text, _) = self { return text }
        return nil
    }

    /// The failure, in plain language, or nil when the attempt worked.
    public var failureMessage: String? {
        switch self {
        case .landed, .heard:
            return nil
        case .noSpeech(let seconds):
            return seconds <= 0
                ? "No audio reached VoicePlus at all. Check the microphone in System Settings › Sound."
                : "That was only \(Self.tenths(seconds)) s of audio — too short to transcribe. Press Dictate now, wait a beat, then speak."
        case .failed(let reason):
            return reason
        }
    }

    static func tenths(_ seconds: Double) -> String { String(format: "%.1f", seconds) }

    /// One stable token per outcome for the log, so a support session can tell the four apart
    /// without the user having to describe a screenshot.
    public var logLabel: String {
        switch self {
        case .landed(let text, let app): return "landed \(text.count) chars into \(app ?? "the focused app")"
        case .heard(let text, let recognizer): return "heard \(text.count) chars via \(recognizer), not injected"
        case .noSpeech(let seconds): return "noSpeech after \(Self.tenths(seconds))s"
        case .failed(let reason): return "failed: \(reason)"
        }
    }
}

/// Result of handing one utterance to the real landing path (pipeline → injection → history).
/// `injected` is `LandingResult.landed`, i.e. the injector reported success — never "we tried".
public struct GuidedLanding: Equatable, Sendable {
    public var text: String
    public var injected: Bool
    public var appName: String?

    public init(text: String, injected: Bool, appName: String? = nil) {
        self.text = text
        self.injected = injected
        self.appName = appName
    }
}

// MARK: - Is there anything that can transcribe right now?

/// What will actually run if the user presses "Dictate now" this second.
///
/// P3: the model-choice screen used to hand straight over to a dictation test with no idea whether
/// anything could transcribe. Choosing "Best" on a clean Mac starts a 900 MB download and shows the
/// test screen immediately; the test then fails in whatever way the missing model happens to fail.
/// The screen now has to name the recogniser it is about to use before it offers the button.
public enum RecognizerReadiness: Equatable, Sendable {
    /// The models for the chosen tier are on disk. `name` is the catalog display name.
    case ready(name: String)
    /// The chosen tier is not on disk, but this recogniser will stand in for it.
    /// `awaiting` names what is still downloading, when something is.
    case fallback(name: String, awaiting: String?)
    /// Nothing on this Mac can transcribe right now.
    case unavailable(reason: String)

    /// Name of whatever will run, or nil when nothing can.
    public var recognizerName: String? {
        switch self {
        case .ready(let name), .fallback(let name, _): return name
        case .unavailable: return nil
        }
    }

    public var canTranscribe: Bool { recognizerName != nil }
}

// MARK: - The gate in front of the dictation test

/// Pure decision: may the test run, what does the button say, and what does the screen have to admit
/// before the user presses it. Kept free of AppKit and of the view model so the awkward
/// combinations (downloading + no fallback, failed download + a tiny model on disk) are unit tests
/// rather than something only reproducible with a real 900 MB download.
public enum GuidedDictationGate {
    public struct Decision: Equatable, Sendable {
        /// Whether "Dictate now" is enabled at all.
        public var canRun: Bool
        /// One line above the button saying what will happen. Never empty.
        public var banner: String
        /// True when `banner` is a warning rather than a statement of fact.
        public var isWarning: Bool

        public init(canRun: Bool, banner: String, isWarning: Bool) {
            self.canRun = canRun
            self.banner = banner
            self.isWarning = isWarning
        }
    }

    public static func decide(readiness: RecognizerReadiness,
                              download: OnboardingStateMachine.DownloadState) -> Decision {
        switch readiness {
        case .ready(let name):
            return Decision(canRun: true, banner: "Using \(name).", isWarning: false)
        case .fallback(let name, let awaiting):
            // The test still runs — refusing to let anyone try until a 900 MB download lands would
            // be its own dead end. What must not happen is running it while pretending the chosen
            // model is doing the work.
            if let awaiting {
                let progress = download.progressSuffix
                return Decision(canRun: true,
                                banner: "Using \(name) for now — \(awaiting) is still downloading\(progress).",
                                isWarning: false)
            }
            if case .failed(let why) = download {
                return Decision(canRun: true,
                                banner: "Using \(name). The download didn't finish (\(why)) — retry it from Settings › Models.",
                                isWarning: true)
            }
            return Decision(canRun: true, banner: "Using \(name).", isWarning: false)
        case .unavailable(let reason):
            return Decision(canRun: false, banner: reason, isWarning: true)
        }
    }
}
