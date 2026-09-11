import Foundation

// R7.1 — the four renderings every section of the one window owes the user (`DESIGN.md` §9):
// content, empty, loading, error. Exactly one at a time. A section that has *partial* data keeps
// its content and carries the failure in a `SectionBanner` instead of flipping to `.error` — the
// spec's "no spinner and content simultaneously" rule cuts the other way too: a readable store
// that lost one row must not blank the pane.
//
// This file is pure data. Every section's state is decided here or in its view model, never inside
// a `body`, so the states are testable on a toolchain with no XCTest and no UI testing at all.

/// Which of the four renderings a section is showing.
public enum SectionRendering: String, CaseIterable, Equatable, Sendable {
    case content, empty, loading, error
}

/// One section's rendering plus the copy that goes with it.
///
/// `headline` is empty **only** for `.content`; every other rendering says something. `DESIGN.md`
/// §9 requires an explanation in each empty (never a bare empty list) and one action in each error
/// (never a raw message with no way out), which `isWellFormed` enforces and the tests assert for
/// every state the window can produce.
public struct SectionState: Equatable, Sendable {
    public var rendering: SectionRendering
    public var headline: String
    public var detail: String?
    /// The one action offered. `nil` for `.content` and `.loading`.
    public var actionTitle: String?

    public init(rendering: SectionRendering, headline: String = "", detail: String? = nil, actionTitle: String? = nil) {
        self.rendering = rendering
        self.headline = headline
        self.detail = detail
        self.actionTitle = actionTitle
    }

    public static let content = SectionState(rendering: .content)

    public static func empty(_ headline: String, detail: String? = nil, action: String? = nil) -> SectionState {
        SectionState(rendering: .empty, headline: headline, detail: detail, actionTitle: action)
    }

    /// Static text, never a spinner: `DESIGN.md` §6 bans motion here under reduced motion, and the
    /// window is not allowed to have two different loading looks.
    public static func loading(_ headline: String = "Loading…") -> SectionState {
        SectionState(rendering: .loading, headline: headline)
    }

    public static func error(_ headline: String, detail: String? = nil, action: String? = nil) -> SectionState {
        SectionState(rendering: .error, headline: headline, detail: detail, actionTitle: action)
    }

    public var isContent: Bool { rendering == .content }

    /// `DESIGN.md` §9 / §7.1 in one predicate: content says nothing extra, empty explains itself,
    /// loading is a single line, an error names a way out.
    public var isWellFormed: Bool {
        switch rendering {
        case .content: return headline.isEmpty && detail == nil && actionTitle == nil
        case .empty: return !headline.isEmpty && (detail != nil || actionTitle != nil)
        case .loading: return !headline.isEmpty && actionTitle == nil
        case .error: return !headline.isEmpty && actionTitle != nil
        }
    }
}

/// A failure that sits *beside* content rather than replacing it — the banner and row errors
/// `DESIGN.md` §9 asks for when a section still has something worth showing.
public struct SectionBanner: Equatable, Sendable, Identifiable {
    public var id: String { headline }
    public var headline: String
    public var actionTitle: String?
    /// Raw detail belongs behind "Copy diagnostics", never in the sentence (`DESIGN.md` §7.1).
    public var diagnostics: String?

    public init(headline: String, actionTitle: String? = nil, diagnostics: String? = nil) {
        self.headline = headline
        self.actionTitle = actionTitle
        self.diagnostics = diagnostics
    }
}

/// Every sentence the window is allowed to say in an empty, loading or error state, in one place.
///
/// Copy lives here rather than inside a `body` for two reasons: `DESIGN.md` quotes several of these
/// verbatim (the §7.1 strings are already `DeliveryCopy`'s), and a state's words are the only part
/// of it a test on this toolchain can see.
public enum SectionCopy {
    // MARK: Today / Timeline (§9.1)
    public static let nothingDictated = "Nothing dictated yet"
    public static func nothingDictatedDetail(key: String) -> String { "Hold \(key) and say something." }
    public static let timelineOff = "Timeline is off"
    public static let timelineOffDetail = "Turn on ambient capture in Privacy"
    public static let timelineUnreadable = "Timeline can't be read"
    public static let openPrivacy = "Open Privacy"
    public static let heldRowFailed = "That didn't land — Try again"

    // MARK: Meetings (§9.2)
    public static let noMeetings = "No meetings captured yet."
    public static let meetingCaptureOff = "Meeting capture is off"
    public static let meetingCaptureOffDetail = "Turn it on to keep transcripts of calls on this Mac."
    public static let calendarOff = "Calendar access is off"
    public static let openSystemSettings = "Open System Settings"
    public static let meetingsUnreadable = "Meetings can't be read"
    public static let meetingUnreadableRow = "This transcript can't be read"
    public static let loadingTranscript = "Loading transcript…"

    // MARK: Dictionary / Apps (§9.3)
    public static let noTerms = "No terms yet"
    public static let noTermsDetail = "Add a word VoicePlus keeps getting wrong"
    public static let importFromContacts = "Import from Contacts"
    public static let noAppSettings = "No app-specific settings"
    public static let noAppSettingsDetail = "Every app uses your defaults."
    /// The existing string is kept verbatim (`DESIGN.md` §9.3).
    public static let contactsDenied = "Contacts access was denied — Open System Settings"
    public static let notSaved = "Changes weren't saved"
    public static let tryAgain = "Try again"

    // MARK: Voice (§9.4)
    public static let noEnrollment = "No voice enrolled"
    public static let noEnrollmentDetail = "Enrollment is optional. It helps ambient capture tell you apart."
    public static let noMeasurements = "No measurements yet"
    public static let runBenchmark = "Run benchmark"
    public static let lookingForMicrophones = "Looking for microphones…"
    public static let microphoneOff = "Microphone access is off"
    public static let chooseMicrophone = "Choose microphone"
    public static let copyDiagnostics = "Copy diagnostics"
    public static func benchmarkFailed(stage: String) -> String { "The benchmark stopped during \(stage)" }

    // MARK: Privacy (§9.5)
    /// Scoped and dated, never "zero bytes, ever" (V3 §9.6).
    public static let nothingLeftThisMac = "Nothing has left this Mac in the last 30 days"
    public static let nothingLeftDetail = "This counts every request VoicePlus made, including ones it refused to make."
    public static let nothingSaved = "Nothing is saved"
    public static let nothingSavedDetail = "With history on, transcripts of what you dictate would be kept on this Mac."
    public static let egressUnreadable = "The egress log can't be read"
    public static let deleteAllPartial = "Some of it is still here"

    // MARK: Settings (§9.6)
    public static let nothingConnected = "Nothing connected"
    public static let nothingConnectedDetail = "Transcription is local either way — a subscription never changes it."
    public static let settingNotSaved = "Not saved"
}
