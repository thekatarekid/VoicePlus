import Engine
import Foundation

// R7.1 / S7a — the renderings every screen of the one window owes the user (design §9, `DESIGN.md`
// §9): content, empty, loading, error — exactly one at a time — plus a scoped banner for partial
// data. A section that has *partial* data keeps its content and carries the failure in a
// `SectionBanner` instead of flipping to `.error`: a readable store that lost one row must not blank
// the pane, and loading never masquerades as empty.
//
// This file is pure data. Every section's state is decided here or in its view model, never inside
// a `body`, so the states are testable on a toolchain with no XCTest and no UI testing at all.
// Copy for the design's screens comes from `Fixtures/design/design_copy.json` (`screens`,
// `emptyCopy`, `screenError`); `MainWindowShellS7aTests` holds every string here to that file.

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
    /// For `.error`: the recovery-catalogue entry the error renders (design §10). The page draws its
    /// "Data kept" line from the entry's data policy. `nil` for older, section-local errors.
    public var recoveryID: RecoveryID?

    public init(rendering: SectionRendering, headline: String = "", detail: String? = nil, actionTitle: String? = nil,
                recoveryID: RecoveryID? = nil) {
        self.rendering = rendering
        self.headline = headline
        self.detail = detail
        self.actionTitle = actionTitle
        self.recoveryID = recoveryID
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

    // MARK: The design's renderings for a screen (design §9; prototype `renderScreen`)

    /// The screen's empty state (`emptyCopy`): headline, body, one action. "Right Control" becomes
    /// the configured key (owner decision, build doc §0).
    public static func empty(_ screen: DesignScreen, hotkey: String) -> SectionState {
        let copy = screen.empty.rendered(hotkey: hotkey)
        return .empty(copy.headline, detail: copy.body, action: copy.action)
    }

    /// "Loading <screen>…" ("Verifying the speech model…" on Models) with the design's note that
    /// loading makes no empty-state claim. Never the empty copy: loading must not look like empty.
    /// A section whose design §9 row names a more specific wait ("Loading recent dictations…",
    /// "Opening saved text…", "Looking for microphones…") passes it as `headline`; the note stays.
    public static func loading(_ screen: DesignScreen, headline: String? = nil) -> SectionState {
        SectionState(rendering: .loading, headline: headline ?? screen.loadingHeadline, detail: SectionCopy.loadingNote)
    }

    /// The screen's error example (`screenError` → recovery catalogue).
    public static func error(_ screen: DesignScreen, hotkey: String) -> SectionState {
        .error(RecoveryCatalog.entry(screen.errorID).rendered(hotkey: hotkey))
    }

    /// Any catalogue entry as a whole-screen error: headline, consequence, its one recovery action.
    public static func error(_ entry: RecoveryEntry) -> SectionState {
        SectionState(rendering: .error, headline: entry.headline, detail: entry.consequence,
                     actionTitle: entry.action, recoveryID: entry.id)
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

/// A failure that sits *beside* content rather than replacing it — the scoped banner design §9 asks
/// for when a section still has something worth showing ("partial").
public struct SectionBanner: Equatable, Sendable, Identifiable {
    public var id: String { headline }
    public var headline: String
    public var actionTitle: String?
    /// Raw detail belongs behind "Copy diagnostics", never in the sentence (`DESIGN.md` §7.1).
    public var diagnostics: String?
    /// The consequence line under the headline.
    public var body: String?
    /// The catalogue entry the banner renders, when it renders one.
    public var recoveryID: RecoveryID?

    public init(headline: String, actionTitle: String? = nil, diagnostics: String? = nil,
                body: String? = nil, recoveryID: RecoveryID? = nil) {
        self.headline = headline
        self.actionTitle = actionTitle
        self.diagnostics = diagnostics
        self.body = body
        self.recoveryID = recoveryID
    }

    /// The prototype's "partial" variant: the entry's headline, its consequence plus "Available
    /// content stays readable.", and its one action — above content that stays on screen.
    public static func partial(_ entry: RecoveryEntry, diagnostics: String? = nil) -> SectionBanner {
        SectionBanner(headline: entry.headline, actionTitle: entry.action, diagnostics: diagnostics,
                      body: entry.consequence + SectionCopy.partialSuffix, recoveryID: entry.id)
    }

    /// The screen's own error example as a partial banner.
    public static func partial(_ screen: DesignScreen, hotkey: String, diagnostics: String? = nil) -> SectionBanner {
        .partial(RecoveryCatalog.entry(screen.errorID).rendered(hotkey: hotkey), diagnostics: diagnostics)
    }

    /// The error rendering's banner: the entry's words without the partial suffix.
    public static func recovery(_ entry: RecoveryEntry) -> SectionBanner {
        SectionBanner(headline: entry.headline, actionTitle: entry.action, body: entry.consequence, recoveryID: entry.id)
    }
}

// MARK: - The design's screens (design §8, §9; `design_copy.json`)

/// A page title and subtitle (`design_copy.json` › `screens`).
public struct ScreenCopy: Equatable, Sendable {
    public var title: String
    public var subtitle: String
}

/// An empty state: headline · body · one action (`design_copy.json` › `emptyCopy`).
public struct EmptyCopy: Equatable, Sendable {
    public var headline: String
    public var body: String
    public var action: String

    /// "Right Control" rendered as the configured key; nothing else in any string changes.
    public func rendered(hotkey: String) -> EmptyCopy {
        EmptyCopy(headline: PillState.withHotkey(headline, key: hotkey),
                  body: PillState.withHotkey(body, key: hotkey),
                  action: PillState.withHotkey(action, key: hotkey))
    }
}

/// Every screen of the verified prototype's picker (`design_v1.html` › `const screens`), keyed as the
/// copy fixture keys them. The window's sections and Settings' subpages map onto these; S7b–S7g,
/// S8 and S6 read their own screen's copy from here rather than retyping it.
public enum DesignScreen: String, CaseIterable, Sendable {
    case today, turn, meetings
    case meetingDetail = "meeting-detail"
    case dictionary, voice, privacy, settings, shortcuts, models, services, onboarding, menu, recovery

    /// The prototype's screen name (`const screens[i][1]`): the error rendering's title and the
    /// noun in "Loading <name>…".
    public var name: String {
        switch self {
        case .today: return "Today"
        case .turn: return "Turn detail"
        case .meetings: return "Meetings"
        case .meetingDetail: return "Meeting detail"
        case .dictionary: return "Dictionary & Apps"
        case .voice: return "Voice"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        case .shortcuts: return "Shortcuts"
        case .models: return "Models"
        case .services: return "Providers & Sync"
        case .onboarding: return "Onboarding"
        case .menu: return "Status menu"
        case .recovery: return "Recovery sheet"
        }
    }

    /// The page title and subtitle, verbatim. `nil` where the fixture has none (meeting detail and
    /// onboarding title themselves). Turn detail's and the recovery sheet's subtitles (and turn
    /// detail's title) are the prototype's sample data — S7b fills them from the real turn.
    public var page: ScreenCopy? {
        switch self {
        case .today: return ScreenCopy(title: "Today", subtitle: "Your words, right where you left them.")
        case .turn: return ScreenCopy(title: "Friday check-in", subtitle: "Mail · Today, 12:42 · 9 words")
        case .meetings: return ScreenCopy(title: "Meetings", subtitle: "Thoughts worth coming back to.")
        case .meetingDetail: return nil
        case .dictionary: return ScreenCopy(title: "Dictionary & Apps", subtitle: "Your spellings. Your way of writing.")
        case .voice: return ScreenCopy(title: "Voice", subtitle: "Make sure we hear you clearly.")
        case .privacy: return ScreenCopy(title: "Privacy", subtitle: "Know what is kept, and what leaves this Mac.")
        case .settings: return ScreenCopy(title: "Settings", subtitle: "Small adjustments. A familiar flow.")
        case .shortcuts: return ScreenCopy(title: "Shortcuts", subtitle: "One key. A clear beginning and end.")
        case .models: return ScreenCopy(title: "Models", subtitle: "Ready means verified and loaded.")
        case .services: return ScreenCopy(title: "Providers & Sync", subtitle: "Local first. Connections when you choose.")
        case .onboarding: return nil
        case .menu: return ScreenCopy(title: "A small, useful menu", subtitle: "Status and direct actions, one click away.")
        case .recovery: return ScreenCopy(title: "Your text is still here.", subtitle: "Destination changed · held for Mail")
        }
    }

    /// The empty state, verbatim (render with `rendered(hotkey:)` before display).
    public var empty: EmptyCopy {
        switch self {
        case .today: return EmptyCopy(headline: "Nothing dictated yet", body: "Hold Right Control and say something. Your recent words will appear here.", action: "Try dictation")
        case .turn: return EmptyCopy(headline: "No saved text here", body: "History may be off or this turn may have been deleted.", action: "Open Today")
        case .meetings: return EmptyCopy(headline: "No meetings yet", body: "Start a recording whenever you need notes. Calendar connection is optional.", action: "Start recording")
        case .meetingDetail: return EmptyCopy(headline: "No speech captured", body: "Check the microphone and system-audio tracks before your next meeting.", action: "Check capture")
        case .dictionary: return EmptyCopy(headline: "Make it sound like you", body: "Add a word VoicePlus keeps getting wrong.", action: "Add a word")
        case .voice: return EmptyCopy(headline: "No voice enrolled", body: "Enrollment is optional. Hold-to-talk works without it.", action: "Set up my voice")
        case .privacy: return EmptyCopy(headline: "Nothing is saved", body: "Your history is off. Recovery text has its own clearly labelled retention policy.", action: "Review retention")
        case .settings: return EmptyCopy(headline: "Using your defaults", body: "Personalize your shortcut and preview when you are ready.", action: "Open shortcuts")
        case .shortcuts: return EmptyCopy(headline: "No custom shortcuts", body: "Right Control is your default hold-to-talk key.", action: "Try default shortcut")
        case .models: return EmptyCopy(headline: "Install a speech model", body: "Dictation becomes available when a compatible model has been verified and loaded.", action: "Choose a model")
        case .services: return EmptyCopy(headline: "Nothing connected", body: "Local transcription works without a connected service or paired device.", action: "Explore options")
        case .onboarding: return EmptyCopy(headline: "Welcome to VoicePlus", body: "A few short steps, then hold a key and let your words arrive.", action: "Begin setup")
        case .menu: return EmptyCopy(headline: "VoicePlus is ready", body: "The menu is available even before your first dictation.", action: "Open VoicePlus")
        case .recovery: return EmptyCopy(headline: "No text waiting", body: "Every completed turn has been resolved.", action: "Back to Today")
        }
    }

    /// The screen's error example (`screenError`), a recovery-catalogue id.
    public var errorID: RecoveryID {
        switch self {
        case .today: return .S01
        case .turn: return .S03
        case .meetings: return .X02
        case .meetingDetail: return .N01
        case .dictionary: return .S02
        case .voice: return .A02
        case .privacy: return .S04
        case .settings: return .S02
        case .shortcuts: return .K01
        case .models: return .M02
        case .services: return .N02
        case .onboarding: return .P01
        case .menu: return .K05
        case .recovery: return .S03
        }
    }

    /// The prototype's loading headline: "Loading <name, lower-cased>…", and on Models the truthful
    /// "Verifying the speech model…" (a model is never Ready before verification and loading).
    public var loadingHeadline: String {
        self == .models ? SectionCopy.verifyingModel : "Loading \(name.lowercased())…"
    }

    /// The screens that carry a Spool surface note above their content (prototype `renderScreen`):
    /// Today and Privacy use `ready`, Turn detail and Recovery use `held`. `nil` elsewhere.
    var contentSpoolNote: (pose: SpoolStateKey, text: String)? {
        switch self {
        case .today, .privacy: return (.ready, SectionCopy.spoolReadyNote)
        case .turn, .recovery: return (.held, SectionCopy.spoolHeldNote)
        default: return nil
        }
    }
}

// MARK: - Retry and save (design §9)

/// Design §9: "Retry affects the failed scope and is disabled during the active retry." One per
/// scope (a banner, a row, a group) — never a window-wide retry.
@MainActor
public final class ScopedRetry: ObservableObject {
    @Published public private(set) var isRetrying = false

    public init() {}

    /// Runs `work` unless a retry of this scope is already running, in which case it does nothing and
    /// returns false. The control bound to `isRetrying` is disabled for the duration.
    @discardableResult
    public func run(_ work: () async -> Void) async -> Bool {
        guard !isRetrying else { return false }
        isRetrying = true
        defer { isRetrying = false }
        await work()
        return true
    }
}

/// Design §9: "A failed save keeps the entered value and the previous active value." The field shows
/// `entered`; the app keeps using `active` until a save succeeds; a failure is the catalogue's S02
/// ("Changes weren't saved" · "Your previous setting is still active." · Try again), inline.
public struct SettingDraft<Value: Equatable>: Equatable {
    /// What the app is using now.
    public private(set) var active: Value
    /// What the control shows — possibly not saved yet.
    public var entered: Value
    /// Set when the last save failed; cleared by a successful save or a revert.
    public private(set) var failure: RecoveryID?

    public init(_ value: Value) {
        active = value
        entered = value
        failure = nil
    }

    public var isUnsaved: Bool { entered != active }

    /// Saves `entered`. Success makes it active; failure keeps both values and records S02.
    @discardableResult
    public mutating func commit(_ save: (Value) throws -> Void) -> Bool {
        do {
            try save(entered)
            active = entered
            failure = nil
            return true
        } catch {
            failure = .S02
            return false
        }
    }

    /// Puts the active value back in the control.
    public mutating func revert() {
        entered = active
        failure = nil
    }

    /// The inline row error for the failed save, if any.
    public var failureBanner: SectionBanner? {
        failure.map { SectionBanner.recovery(RecoveryCatalog.entry($0)) }
    }
}

/// Every sentence the window is allowed to say in an empty, loading or error state, in one place.
///
/// Copy lives here rather than inside a `body` for two reasons: `DESIGN.md` quotes several of these
/// verbatim (the §7.1 strings are already `DeliveryCopy`'s), and a state's words are the only part
/// of it a test on this toolchain can see.
public enum SectionCopy {
    // MARK: The shell (S7a; prototype `renderScreen` and the sidebar `<footer>`)

    /// Loading makes no empty-state claim (prototype loading variant).
    public static let loadingNote = "No empty-state claim while the data is still loading."
    /// Models' loading headline.
    public static let verifyingModel = "Verifying the speech model…"
    /// The error rendering's subtitle.
    public static let errorSubtitle = "Your existing data has not been cleared."
    /// The eyebrow over the entry's data policy in the error rendering.
    public static let dataKept = "Data kept"
    /// The error rendering's footnote.
    public static let errorFootnote = "Technical details live behind diagnostics. A failure in this section does not disable unrelated sections."
    /// Appended to the consequence in the partial banner.
    public static let partialSuffix = " Available content stays readable."
    /// Sidebar footer: "<status> · On this Mac" over "Hold <key> to speak".
    public static let onThisMac = "On this Mac"
    public static func holdToSpeak(key: String) -> String { "Hold \(key) to speak" }
    /// The Spool surface notes above Today / Privacy (ready) and Turn detail / Recovery (held).
    public static let spoolReadyNote = "Spool · Ready when you are. Microphone closed."
    public static let spoolHeldNote = "Your text stays held until you resolve it."
    /// The toolbar search field's prompt.
    public static let searchPrompt = "Search"

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
