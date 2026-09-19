import Engine
import Foundation

/// S8 — every onboarding heading, body and primary action, verbatim from the verified prototype
/// (`design/design_v1.html`, the `onboarding` screen's `steps` table; `OnboardingCopyTests` reads that
/// table back and compares). Two rules from build doc §0 are applied here and nowhere else:
///
/// * **Owner decision — default key.** "Right Control" is rendered with the configured key label
///   (`PillState.withHotkey`); nothing else in the string changes.
/// * **Real product over simulation.** The prototype's Microphone body ends with a sentence that
///   narrates the prototype itself ("The real app requests the macOS permission here."). The real
///   app does exactly that, with the real prompt, so the narration is dropped and nothing else.
///
/// The Voice step is the owner's addition (V4.48); it uses the Voice section's own copy
/// (`design_copy.json` › `screens.voice`, `emptyCopy.voice`) plus V4.48's reading instruction.
public enum OnboardingCopy {
    public struct StepCopy: Equatable, Sendable {
        public var heading: String
        public var body: String
        public var action: String
    }

    // MARK: Verbatim prototype rows (design_v1.html › onboarding › steps)

    public static let prototypeWelcome = StepCopy(
        heading: "Your voice, a little closer.",
        body: "Hold a key. Speak naturally. See the sentence before it reaches your app.",
        action: "Begin setup")
    public static let prototypeMicrophone = StepCopy(
        heading: "Let VoicePlus hear you.",
        body: "Microphone access is needed only to capture your voice. The real app requests the macOS permission here.",
        action: "Allow microphone")
    public static let prototypeTypingAccess = StepCopy(
        heading: "Let your words reach the page.",
        body: "Accessibility lets VoicePlus insert text into your focused field. You can set this up later and use Copy.",
        action: "Allow typing access")
    public static let prototypeModel = StepCopy(
        heading: "Bring speech recognition on device.",
        body: "Choose a compatible model. Dictation is ready only after download, verification and loading.",
        action: "Install model")
    public static let prototypeTry = StepCopy(
        heading: "Try your first sentence.",
        body: "Hold Right Control. Watch Spool’s reels turn counterclockwise and words appear above the tape. Release, review, then watch a clockwise feed place your sentence.",
        action: "Try dictation")
    public static let prototypeReady = StepCopy(
        heading: "You’re ready.",
        body: "A small green dot means VoicePlus is available. The microphone opens when you start dictating.",
        action: "Open VoicePlus")

    /// The six prototype rows in the prototype's order.
    public static let prototypeSteps: [StepCopy] = [
        prototypeWelcome, prototypeMicrophone, prototypeTypingAccess, prototypeModel, prototypeTry, prototypeReady,
    ]

    /// The prototype's own narration, dropped in the real product (see the type doc).
    public static let prototypeNarration = "The real app requests the macOS permission here."

    // MARK: Voice section copy (design_copy.json › screens.voice / emptyCopy.voice)

    public static let voiceSubtitle = "Make sure we hear you clearly."
    public static let voiceEmptyTitle = "No voice enrolled"
    public static let voiceEmptyBody = "Enrollment is optional. Hold-to-talk works without it."
    public static let voiceEmptyAction = "Set up my voice"

    // MARK: Chrome (prototype `setup-back`, `setup-later`, eyebrow)

    public static let back = "Back"
    public static let setUpLater = "Set up later"
    public static let continueTitle = "Continue"

    /// "Setup · 3 of 7" — the prototype's eyebrow over the progress bar, counting the owner's step.
    public static func eyebrow(step: Int, of count: Int) -> String { "Setup · \(step) of \(count)" }

    // MARK: Rendered for this Mac

    /// A step's copy with the configured key named. `key` is `HotkeyBinding.label` ("fn / 🌐").
    public static func copy(for step: OnboardingStateMachine.Step, key: String) -> StepCopy {
        let row: StepCopy
        switch step {
        case .welcome: row = prototypeWelcome
        case .microphone:
            row = StepCopy(heading: prototypeMicrophone.heading,
                           body: withoutNarration(prototypeMicrophone.body),
                           action: prototypeMicrophone.action)
        case .accessibility: row = prototypeTypingAccess
        case .model: row = prototypeModel
        case .firstDictation: row = prototypeTry
        case .voice: row = StepCopy(heading: voiceSubtitle, body: voiceEmptyBody, action: voiceEmptyAction)
        case .done: row = prototypeReady
        }
        return StepCopy(heading: PillState.withHotkey(row.heading, key: key),
                        body: PillState.withHotkey(row.body, key: key),
                        action: PillState.withHotkey(row.action, key: key))
    }

    static func withoutNarration(_ body: String) -> String {
        body.replacingOccurrences(of: prototypeNarration, with: "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Voice step (V4.48 + H2)

    /// V4.48's instruction, with the real number of prompted lines (`SpeakerEnrollment`).
    public static var voiceInstruction: String {
        "Read these \(spelled(SpeakerEnrollment.requiredUtterances)) lines so VoicePlus knows your voice. It takes about 30 seconds."
    }

    /// H2's passive fallback, stated before the user chooses to skip.
    public static var voicePassiveFallback: String {
        "Skip it and VoicePlus learns your voice from your first \(SpeakerEnrollment.passiveUtterances) holds instead, then shows “\(LatchController.voiceLearnedMessage)” once."
    }

    public static let voiceSkip = "Skip for now"
    public static let voiceEnrolled = "Your voice is set up."
    public static let voiceEnrolledDetail = "Hands-free Latch only answers to you. You can re-enroll any time in Voice."

    // MARK: Model step (design §8.6: real byte progress → Verifying → Loading → Ready)

    public static let verifying = "Verifying…"
    public static let loading = "Loading…"
    public static func ready(_ name: String) -> String { "Ready · \(name) is verified and loaded." }
    public static let starting = "Starting the download…"
    public static let cancelDownload = "Cancel download"
    /// Design §8.7 "interrupted → retry / local model selection": keep going on what is on this Mac.
    public static func continueWith(_ name: String) -> String { "Continue with \(name)" }

    // MARK: Try step (I1)

    public static func pressKeyPrompt(_ key: String) -> String { "Press \(key) once so VoicePlus can hear the key." }
    public static let checkKey = "Check the key"
    public static func pressNow(_ key: String) -> String { "Press \(key) now…" }
    public static let pressedIt = "I pressed it"
    public static func nothingArrived(_ key: String, attempt: Int) -> String {
        "Nothing arrived from \(key) (\(attempt) of \(FnKeyProbe.attemptsBeforeFallback)). Press it again."
    }
    public static func keyWorks(_ key: String) -> String { "\(key) reaches VoicePlus." }
    public static func fallbackOffer(from key: String, to fallback: String) -> String {
        "Your keyboard isn’t reporting \(key) to macOS. Use \(fallback) instead?"
    }
    public static func useFallback(_ fallback: String) -> String { "Use \(fallback)" }
    public static func tryAgain(_ key: String) -> String { "Try \(key) again" }
    public static let continueAnyway = "Continue anyway"
    public static let practiceFieldLabel = "Practice field"
    /// How "It landed in …" names the field.
    public static let practiceFieldName = "the practice field"
    public static let practiceFieldNote = "Safe to type in: nothing here is sent anywhere."
    public static let example = "Example"
    public static let notInserted = "Heard you, but nothing reached the practice field. Click into it and hold the key again."
    public static let buttonFallback = "Key not working? Dictate with a button instead."
    public static let reviewed = "Reviewed"
    public static let correctionRefused = "The practice field changed, so the word was left as it is."

    // MARK: Ready

    public static let copyOnlyLabel = "Copy-only setup"

    static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return words.indices.contains(n) ? words[n] : String(n)
    }
}
