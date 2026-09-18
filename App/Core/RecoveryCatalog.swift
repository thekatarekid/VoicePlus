import Actions
import Engine
import Foundation
import Injection
import Lab
import Pipeline
import Providers
import Shared
import Sync

// MARK: - Entry

/// How Spool presents a recovery entry (design_v1 §10 "Spool recovery rules"). A presentation
/// mapping, never a new error category: the entry's copy and data policy stay authoritative.
/// Each treatment is one `spool_spec.json` › `errorPoses` pose and its Spool state key.
public enum RecoveryTreatment: String, CaseIterable, Sendable {
    /// Stops the reels and visibly secures the ribbon.
    case heldTape
    /// Still, asymmetric eyes; the user reviews something.
    case attentiveReview
    /// Parks the mechanism and points to the missing capability.
    case setupLatch
    /// Mute or secure-field capture prohibition.
    case closedShutters
    /// A transient no-result outcome.
    case quietReturn
    /// Never smiles or feeds again.
    case unconfirmedHold
    /// Keeps valid capture moving.
    case liveWarning
    /// Does not hijack a healthy active dictation.
    case scopedNotice
    /// K04: the current turn keeps its true pose; no second set of spinning reels.
    case keepCurrentTurn

    /// The prototype's name for the pose (`errorPoses[id].pose`).
    public var poseName: String {
        switch self {
        case .heldTape: return "Held tape"
        case .attentiveReview: return "Attentive review"
        case .setupLatch: return "Setup latch"
        case .closedShutters: return "Closed shutters"
        case .quietReturn: return "Quiet return"
        case .unconfirmedHold: return "Unconfirmed hold"
        case .liveWarning: return "Live warning"
        case .scopedNotice: return "Scoped screen notice"
        case .keepCurrentTurn: return "Keep current turn"
        }
    }

    /// The Spool state (`spool_spec.json` › `statePoses` key) the pose is drawn with
    /// (`errorPoses[id].key`). For `keepCurrentTurn` it is the pose of the turn already running.
    public var poseKey: String {
        switch self {
        case .heldTape: return "held"
        case .attentiveReview: return "correcting"
        case .setupLatch: return "blocked"
        case .closedShutters: return "muted"
        case .quietReturn: return "cancelled"
        case .unconfirmedHold: return "unconfirmed"
        case .liveWarning: return "warning"
        case .scopedNotice: return "ready"
        case .keepCurrentTurn: return "finishing"
        }
    }

    /// Design §10: error and held notices stay until the user acts; only transient
    /// cancellation / too-short hints may fade.
    public var dismissal: RecoveryDismissal {
        switch self {
        case .quietReturn: return .fades
        case .liveWarning, .keepCurrentTurn: return .whileConditionHolds
        default: return .untilAction
        }
    }
}

/// When a recovery notice may leave the screen (design_v1 §10).
public enum RecoveryDismissal: Equatable, Sendable {
    /// Remains until the user acts or dismisses it. No timed dismissal.
    case untilAction
    /// A transient no-result hint; may fade after `RecoveryCatalog.fadeWindow`.
    case fades
    /// Follows a live condition (capture continuing, a turn finishing) and leaves with it.
    case whileConditionHolds
}

/// The catalogue's families, spelled as the design spells them (`design_copy.json` › `errors[].family`).
public enum RecoveryFamily: String, CaseIterable, Sendable {
    case permissions = "Permissions"
    case shortcut = "Shortcut"
    case audio = "Audio"
    case models = "Models"
    case transcription = "Transcription"
    case delivery = "Delivery"
    case storage = "Storage"
    case services = "Services"
    case meetings = "Meetings"
    case voice = "Voice"
    case dictionary = "Dictionary"
    case sync = "Sync"
    case system = "System"
}

/// One row of design_v1 §10: problem, accurate consequence, one recovery action, data policy.
public struct RecoveryEntry: Equatable, Hashable, Sendable, Identifiable {
    public let id: RecoveryID
    public let family: RecoveryFamily
    /// What causes it, in the design's words. Documentation for surfaces; never shown as a headline.
    public let trigger: String
    /// The user-facing headline. Never a raw enum token, filename or path.
    public let headline: String
    /// Supporting copy: what did and did not happen.
    public let consequence: String
    /// The one primary recovery action (design §10: Retry is never a universal button).
    public let action: String
    /// What happens to the user's text and audio.
    public let dataPolicy: String
    public let treatment: RecoveryTreatment
    /// No producer exists yet: the entry is catalogued so the surface is designed before the failure
    /// is detected (the design's "defensive coverage" / "proposed" evidence). S11 and later tasks
    /// that add a producer map it and drop the flag.
    public let isDefensive: Bool

    init(_ id: RecoveryID, _ family: RecoveryFamily, _ treatment: RecoveryTreatment, defensive: Bool = false,
         trigger: String, headline: String, consequence: String, action: String, data: String) {
        self.id = id
        self.family = family
        self.treatment = treatment
        self.isDefensive = defensive
        self.trigger = trigger
        self.headline = headline
        self.consequence = consequence
        self.action = action
        self.dataPolicy = data
    }

    /// The Spool state the entry's pose is drawn with.
    public var poseKey: String { treatment.poseKey }
    public var dismissal: RecoveryDismissal { treatment.dismissal }

    /// Owner decision (build doc §0): the prototype's "Right Control" is rendered with the configured
    /// key label; nothing else in any string changes.
    public func rendered(hotkey: String) -> RecoveryEntry {
        func key(_ text: String) -> String { PillState.withHotkey(text, key: hotkey) }
        return RecoveryEntry(id, family, treatment, defensive: isDefensive,
                             trigger: trigger, headline: key(headline), consequence: key(consequence),
                             action: key(action), data: key(dataPolicy))
    }
}

// MARK: - Catalogue

/// Design_v1 §10's recovery catalogue: all 59 entries and the mapping from what went wrong — a thrown
/// `Error`, a `DeliveryOutcome` or `DeliveryReason`, a permission state, an `EngineState`, a session
/// stop, a repair refusal or a named app condition — to the one entry that explains it.
///
/// Copy is verbatim from the verified prototype (`Fixtures/design/design_copy.json` › `errors`, Spool
/// treatment from `Fixtures/spool/spool_spec.json` › `errorPoses`), asserted by `RecoveryCatalogTests`.
/// Mapping never returns raw error text: that goes to `Log` (`EngineMessage.technicalDetail`).
/// Consumers switch to it in S11.
public enum RecoveryCatalog {
    /// Design §10: transient cancellation / too-short hints may fade after 800–1600 ms.
    public static let fadeWindow: ClosedRange<TimeInterval> = 0.8...1.6

    /// The entry for an id. Every `RecoveryID` has exactly one.
    public static func entry(_ id: RecoveryID) -> RecoveryEntry {
        byID[id]!
    }

    private static let byID: [RecoveryID: RecoveryEntry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    // MARK: Errors

    /// The entry for any thrown error; `X08` "VoicePlus couldn’t finish this step" when nothing
    /// recognises it. Layers above the engine are tried first, then `EngineMessage.classify`.
    public static func entry(for error: Error) -> RecoveryEntry {
        entry(recoveryID(for: error))
    }

    /// `entry(for:)` for a surface that is about to show it: the error's own text (which may name a
    /// path, model id, OSStatus or HTTP body) goes to `log` with the entry's id, and only the
    /// catalogue entry comes back. Design §10: technical causes live in diagnostics, never the headline.
    public static func report(_ error: Error, log: Log = .app) -> RecoveryEntry {
        let found = entry(for: error)
        log.error("recovery \(found.id.rawValue): \(EngineMessage.technicalDetail(error))")
        return found
    }

    public static func recoveryID(for error: Error) -> RecoveryID {
        switch error {
        case let refusal as SessionCoordinator.Refusal: return recoveryID(refusal)
        case let provider as ProviderError: return recoveryID(provider)
        case let routing as ProviderRoutingError:
            if case .unavailable = routing { return .N01 }
            return .N04
        case let connector as ConnectorError: return recoveryID(connector)
        // The network kill switch refused the request; the original text stands.
        case is EgressGate.Denied: return .N04
        case let access as SystemAccessError: return recoveryID(access)
        case let transform as TransformError:
            if case .uncertainInstruction = transform { return .T05 }
            return .T03
        case is RefinementTimedOut: return .T03
        // The listen-only event tap (region drawing, timeline) is refused without Input Monitoring.
        case is InputRecorderError: return .P03
        // A snippet (dictionary-side entry) that could not be saved; the previous value stands.
        case is SnippetError: return .S02
        case is PairingError, is SyncCryptoError, is PairingPayload.ParseError: return .X05
        default: return EngineMessage.classify(error) ?? .X08
        }
    }

    private static func recoveryID(_ refusal: SessionCoordinator.Refusal) -> RecoveryID {
        switch refusal {
        // A dictation already holds the microphone: the design's "Start while processing" (K04).
        // Anything else holding it is another internal recorder (A09).
        case .busy(let holder): return holder == .hotkey || holder == .menu ? .K04 : .A09
        case .muted: return .K05
        // `.awaitingRestart`: the screen locked or the Mac slept mid-capture (the design's "lock,
        // sleep" trigger) — and any later way a session can end without the user.
        default: return .K02
        }
    }

    private static func recoveryID(_ error: ProviderError) -> RecoveryID {
        switch error {
        case .unavailable, .timeout: return .N01
        case .unauthorized: return .N02
        case .http(let status, _):
            switch status {
            case 401: return .N02
            case 402, 403, 429: return .N03
            case 408, 500...599: return .N01
            default: return .N04
            }
        case .malformedResponse, .cancelled, .capabilityMissing, .flagDisabled: return .N04
        }
    }

    /// Connectors are services too: the same N01–N04 split as `ProviderError`.
    private static func recoveryID(_ error: ConnectorError) -> RecoveryID {
        switch error {
        case .notSignedIn, .unauthorized: return .N02
        case .timeout: return .N01
        case .http(let status, _):
            switch status {
            case 401: return .N02
            case 402, 403, 429: return .N03
            case 408, 500...599: return .N01
            default: return .N04
            }
        case .malformedResponse, .unsupported: return .N04
        }
    }

    private static func recoveryID(_ error: SystemAccessError) -> RecoveryID {
        switch error {
        case .accessibilityNotTrusted: return .P02
        case .noFocusedElement, .attributeNotSettable: return .D02
        // `.axError`, `.eventPostFailed`: the write failed before anything was posted.
        default: return .D05
        }
    }

    // MARK: Delivery

    /// The entry for a delivery outcome; nil for a delivery readback confirmed.
    public static func entry(for outcome: DeliveryOutcome) -> RecoveryEntry? {
        switch outcome {
        case .delivered(let verified, _): return verified ? nil : entry(.D06)
        case .partial: return entry(.D07)
        case .held(let reason), .failed(let reason): return entry(forDeliveryReason: reason)
        }
    }

    /// The entry for a reason string carried by `DeliveryOutcome.held` / `.failed` (`DeliveryReason`,
    /// `InjectionRefusal` raw values). Keyword fallbacks mirror `DeliveryCopy.category(of:)`; an
    /// unrecognised reason is a failed insertion (D05), never the reason itself.
    public static func entry(forDeliveryReason reason: String) -> RecoveryEntry {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch r {
        case DeliveryReason.destinationChanged: return entry(.D01)
        case DeliveryReason.noDestination: return entry(.D02)
        case DeliveryReason.everyMethodThrew: return entry(.D05)
        case DeliveryReason.secureField: return entry(.D03)
        case DeliveryReason.neverInject: return entry(.D04)
        default: break
        }
        if r.contains("secure field") || r.contains("password") { return entry(.D03) }
        if r.contains("never-inject") || r.contains("never inject") { return entry(.D04) }
        // The exact "no destination" is D02 above; any other destination / focus / target wording
        // means the place the text was going to is no longer the place it would land.
        if r.contains("destination") || r.contains("focus") || r.contains("target") { return entry(.D01) }
        if r.contains("microphone") || r.contains("mic ") || r == "mic" || r.contains("input device")
            || r.contains("device disconnected") || r.contains("no input") {
            return entry(.A02)
        }
        if r.contains("no speech") || r.contains("silence") || r.contains("silent") || r.contains("empty")
            || r.contains("nothing heard") {
            return entry(.A06)
        }
        return entry(.D05)
    }

    public static func entry(for refusal: InjectionRefusal) -> RecoveryEntry {
        switch refusal {
        case .secureField: return entry(.D03)
        case .neverInject: return entry(.D04)
        }
    }

    // MARK: Permissions

    /// A permission as the recovery surfaces see it.
    public struct PermissionState: Equatable, Sendable {
        public var permission: Permission
        public var status: PermissionStatus
        /// Granted in System Settings but not honoured by this process — a stale TCC grant
        /// (`AppCodeIdentity.pinsThisBuild`) or Input Monitoring, which macOS hands over only at
        /// launch (`RelaunchAdvisor`). Only a relaunch finishes setup.
        public var needsRelaunch: Bool

        public init(_ permission: Permission, _ status: PermissionStatus, needsRelaunch: Bool = false) {
            self.permission = permission
            self.status = status
            self.needsRelaunch = needsRelaunch
        }
    }

    /// Nil while there is nothing to recover: granted, or not asked yet (that is the pre-prompt's job).
    public static func entry(for state: PermissionState) -> RecoveryEntry? {
        if state.needsRelaunch { return entry(.P04) }
        switch state.status {
        case .denied, .awaitingUserAction: return permissionIDs[state.permission].map { entry($0) }
        default: return nil
        }
    }

    /// A lookup, not a switch, so a permission added later has no entry until one is designed.
    private static let permissionIDs: [Permission: RecoveryID] = [
        .microphone: .P01, .accessibility: .P02, .inputMonitoring: .P03,
    ]

    // MARK: Engine and session state

    /// Nil for every healthy state. `.error` carries a headline `EngineMessage.describe` produced, so
    /// it maps back to that entry; any other text is unrecognised (X08).
    public static func entry(for state: EngineState) -> RecoveryEntry? {
        switch state {
        case .error(let message): return entry(forHeadline: message) ?? entry(.X08)
        case .unavailable: return entry(.M01)
        case .warning: return entry(.A08)
        default: return nil
        }
    }

    /// The entry whose verbatim headline this is.
    public static func entry(forHeadline headline: String) -> RecoveryEntry? {
        entries.first { $0.headline == headline }
    }

    /// Nil when the user ended the session themselves.
    public static func entry(for reason: SessionCoordinator.StopReason) -> RecoveryEntry? {
        switch reason {
        case .muted: return entry(.K05)
        case .locked, .slept: return entry(.K02)
        case .preempted: return entry(.A09)
        case .deviceLost: return entry(.A02)
        default: return nil
        }
    }

    /// A repair ("scratch that", "replace … with …") that found the text changed (D10). Nil for the
    /// informational refusals (nothing to scratch, too late), which are not failures.
    public static func entry(for reason: RepairSuggestion.Reason) -> RecoveryEntry? {
        reason.isRegionMismatch ? entry(.D10) : nil
    }

    // MARK: Named conditions

    /// Conditions the app already detects that are not thrown errors. Each names its producer.
    public enum Signal: CaseIterable, Sendable {
        /// `HotkeyService`: Carbon `RegisterEventHotKey` refused the chord.
        case shortcutUnavailable
        /// `HotkeyStateMachine`: released before `holdThreshold` (250 ms).
        case pressTooShort
        /// `PipelineAudioSource` `.noSpeech`; `DeliveryCopy.noSpeechDetected`.
        case noSpeech
        /// Under `RealEngine.minimumUtteranceSeconds`, the recogniser's 0.3 s floor.
        case tooShortToTranscribe
        /// `SectionCopy.timelineUnreadable`, `.meetingsUnreadable`, `.egressUnreadable`.
        case historyUnreadable
        /// `SectionCopy.notSaved`.
        case changesNotSaved
        /// `SectionCopy.deleteAllPartial`.
        case deletionPartial
        /// `SectionCopy.calendarOff`; system audio denied (microphone-only meeting capture).
        case meetingPermissionMissing
        /// `SectionCopy.meetingUnreadableRow`.
        case meetingUnreadable
        /// `SectionCopy.contactsDenied`; `BiasVocabulary.LoadError`.
        case wordImportFailed
    }

    public static func entry(for signal: Signal) -> RecoveryEntry {
        switch signal {
        case .shortcutUnavailable: return entry(.K01)
        case .pressTooShort: return entry(.K03)
        case .noSpeech: return entry(.A06)
        case .tooShortToTranscribe: return entry(.A07)
        case .historyUnreadable: return entry(.S01)
        case .changesNotSaved: return entry(.S02)
        case .deletionPartial: return entry(.S04)
        case .meetingPermissionMissing: return entry(.X01)
        case .meetingUnreadable: return entry(.X02)
        case .wordImportFailed: return entry(.X04)
        }
    }

    // MARK: Data

    /// All 59 entries in the design's order.
    public static let entries: [RecoveryEntry] = [
        RecoveryEntry(.P01, .permissions, .setupLatch,
                      trigger: "Microphone denied or revoked",
                      headline: "Microphone access is off",
                      consequence: "Recording cannot start. Nothing was typed.",
                      action: "Open Microphone settings", data: "No new audio"),
        RecoveryEntry(.P02, .permissions, .scopedNotice,
                      trigger: "Accessibility denied or revoked",
                      headline: "Allow VoicePlus to type",
                      consequence: "Dictation can be reviewed here; automatic insertion is unavailable.",
                      action: "Open Accessibility settings", data: "Keep completed text in recovery"),
        RecoveryEntry(.P03, .permissions, .setupLatch,
                      trigger: "Legacy event tap lacks Input Monitoring",
                      headline: "The shortcut needs permission",
                      consequence: "Only the selected legacy listener needs this grant.",
                      action: "Open Input Monitoring", data: "Keep existing drafts; request relaunch after grant"),
        RecoveryEntry(.P04, .permissions, .setupLatch,
                      trigger: "Permission granted but process has stale grant",
                      headline: "Reopen VoicePlus to finish setup",
                      consequence: "Save held text before relaunch.",
                      action: "Reopen VoicePlus", data: "Persist recovery first; block relaunch if save fails"),

        RecoveryEntry(.K01, .shortcut, .setupLatch,
                      trigger: "Hotkey collision or registration failure",
                      headline: "This shortcut is already in use",
                      consequence: "Your previous shortcut stays active.",
                      action: "Choose another shortcut", data: "Preserve prior binding"),
        RecoveryEntry(.K02, .shortcut, .heldTape,
                      trigger: "Missing key-up, lock, sleep or listener interruption",
                      headline: "Dictation stopped",
                      consequence: "Recording is closed. Start again when ready.",
                      action: "Review recovered text", data: "Keep completed segments; label incomplete segment"),
        RecoveryEntry(.K03, .shortcut, .quietReturn,
                      trigger: "Press shorter than 250 ms",
                      headline: "Hold Right Control a little longer",
                      consequence: "Nothing was typed. First isolated tap is quiet; teach only after repeated misses.",
                      action: "Try again", data: "Discard sub-threshold capture"),
        RecoveryEntry(.K04, .shortcut, .keepCurrentTurn,
                      trigger: "Start while processing or session owned elsewhere",
                      headline: "Finishing your previous dictation",
                      consequence: "A second session has not started.",
                      action: "Wait or cancel", data: "Keep active turn"),
        RecoveryEntry(.K05, .shortcut, .closedShutters,
                      trigger: "Hard mute is enabled",
                      headline: "VoicePlus is muted",
                      consequence: "The microphone stays closed until you unmute.",
                      action: "Unmute", data: "No capture"),

        RecoveryEntry(.A01, .audio, .setupLatch,
                      trigger: "No input device",
                      headline: "No microphone found",
                      consequence: "Recording has not started.",
                      action: "Choose microphone", data: "No new audio"),
        RecoveryEntry(.A02, .audio, .heldTape,
                      trigger: "Device disappears during capture",
                      headline: "Microphone disconnected",
                      consequence: "Recording stopped. Review any words already captured.",
                      action: "Choose microphone", data: "Keep decoded partial text; recover audio only if available"),
        RecoveryEntry(.A03, .audio, .setupLatch,
                      trigger: "Input source cannot be selected or opened",
                      headline: "Couldn’t start this microphone",
                      consequence: "Nothing was recorded.",
                      action: "Choose microphone", data: "No new audio"),
        RecoveryEntry(.A04, .audio, .setupLatch,
                      trigger: "Sample-rate or device-format mismatch",
                      headline: "This microphone needs reconnecting",
                      consequence: "Recording could not start with this audio format.",
                      action: "Choose microphone", data: "Keep previous drafts"),
        RecoveryEntry(.A05, .audio, .setupLatch,
                      trigger: "Recorder opens but receives no samples",
                      headline: "No audio is reaching VoicePlus",
                      consequence: "Check the selected input and its mute switch.",
                      action: "Test microphone", data: "Do not invent transcript"),
        RecoveryEntry(.A06, .audio, .quietReturn,
                      trigger: "Samples arrive but no speech is detected",
                      headline: "No speech detected",
                      consequence: "Nothing was typed.",
                      action: "Try again", data: "Discard silence; retain no fake transcript"),
        RecoveryEntry(.A07, .audio, .quietReturn,
                      trigger: "Too little usable audio for decoder",
                      headline: "That was too short to transcribe",
                      consequence: "Nothing was typed. Hold the key through the sentence.",
                      action: "Try again", data: "No usable text"),
        RecoveryEntry(.A08, .audio, .liveWarning,
                      trigger: "Quiet, clipped or noisy input",
                      headline: "Your microphone sounds unclear",
                      consequence: "Keep live words visible with a small quality warning.",
                      action: "Check microphone", data: "Capture continues; do not hide transcript"),
        RecoveryEntry(.A09, .audio, .setupLatch,
                      trigger: "Another internal recorder owns input",
                      headline: "Microphone is in use",
                      consequence: "Do not start a second conflicting audio session.",
                      action: "Open active session", data: "Keep active recording"),

        RecoveryEntry(.M01, .models, .setupLatch,
                      trigger: "No usable recognizer installed",
                      headline: "Install a speech model",
                      consequence: "Dictation is off until a model is ready.",
                      action: "Open Models", data: "No capture advertised as ready"),
        RecoveryEntry(.M02, .models, .setupLatch,
                      trigger: "Download incomplete or scratch file missing",
                      headline: "The speech model didn’t finish downloading",
                      consequence: "Dictation needs a complete model.",
                      action: "Download again", data: "Keep a previously working model"),
        RecoveryEntry(.M03, .models, .setupLatch,
                      trigger: "Checksum or size verification fails",
                      headline: "The model download couldn’t be verified",
                      consequence: "The incomplete model will not be loaded.",
                      action: "Download again", data: "Quarantine invalid model; preserve working model"),
        RecoveryEntry(.M04, .models, .setupLatch,
                      trigger: "Network or HTTP download failure",
                      headline: "Model download paused",
                      consequence: "Your connection interrupted the download.",
                      action: "Retry download", data: "Resume only verified resumable data"),
        RecoveryEntry(.M05, .models, .setupLatch,
                      trigger: "Disk is full or files cannot be written",
                      headline: "Not enough space to finish setup",
                      consequence: "The current working model stays available.",
                      action: "Manage storage", data: "Keep existing usable files"),
        RecoveryEntry(.M06, .models, .setupLatch,
                      trigger: "Model unsupported on this Mac",
                      headline: "This model can’t run on this Mac",
                      consequence: "Choose a model compatible with this system.",
                      action: "Choose another model", data: "Preserve current selection until replacement works"),
        RecoveryEntry(.M07, .models, .setupLatch,
                      trigger: "Warm-up slow or loading fails",
                      headline: "The speech model isn’t ready",
                      consequence: "After 2 seconds name the wait; after failure offer recovery.",
                      action: "Retry loading", data: "Hold partial text only if it exists"),
        RecoveryEntry(.M08, .models, .heldTape,
                      trigger: "Model disappears during active use",
                      headline: "The speech model became unavailable",
                      consequence: "Recording has stopped. Your completed words are kept.",
                      action: "Open Models", data: "Keep completed text; no silent model switch"),

        RecoveryEntry(.T01, .transcription, .heldTape,
                      trigger: "Decoder throws or returns invalid output",
                      headline: "Couldn’t finish this dictation",
                      consequence: "Review the words recovered so far, if any.",
                      action: "Review recovered text", data: "Keep valid partial text; Try again if none"),
        RecoveryEntry(.T02, .transcription, .heldTape, defensive: true,
                      trigger: "Final recognition exceeds deadline",
                      headline: "This is taking longer than usual",
                      consequence: "Recording has stopped. Nothing has been inserted yet.",
                      action: "Use available text", data: "Offer available text after 10 s; never insert late result twice"),
        RecoveryEntry(.T03, .transcription, .attentiveReview,
                      trigger: "Rewrite or provider refinement fails",
                      headline: "Cleanup is unavailable",
                      consequence: "The original transcript is still ready to review.",
                      action: "Use original text", data: "Preserve original and discard invalid rewrite"),
        RecoveryEntry(.T04, .transcription, .attentiveReview, defensive: true,
                      trigger: "Confidence metadata unavailable",
                      headline: "Confidence isn’t available for this result",
                      consequence: "Do not claim that unmarked words were checked.",
                      action: "Review text", data: "Preserve transcript; no invented confidence"),
        RecoveryEntry(.T05, .transcription, .attentiveReview,
                      trigger: "Rewrite changes uncertain word alignment",
                      headline: "Review this phrase",
                      consequence: "Uncertainty belongs to the smallest reliably aligned phrase.",
                      action: "Review phrase", data: "Keep source-to-final provenance"),

        RecoveryEntry(.D01, .delivery, .heldTape,
                      trigger: "Focus, selection or target content changes",
                      headline: "Destination changed — text held",
                      consequence: "Nothing was typed into the new destination.",
                      action: "Insert here", data: "Keep final text and uncertainty spans"),
        RecoveryEntry(.D02, .delivery, .heldTape,
                      trigger: "No editable target or read-only field",
                      headline: "Choose a text field",
                      consequence: "Your words are ready here.",
                      action: "Copy text", data: "Keep final text; explicit insertion only"),
        RecoveryEntry(.D03, .delivery, .closedShutters,
                      trigger: "Password or secure field",
                      headline: "VoicePlus is paused in this field",
                      consequence: "No dictation is inserted into secure fields.",
                      action: "Dismiss", data: "No new secure-field capture; prior draft remains private"),
        RecoveryEntry(.D04, .delivery, .heldTape,
                      trigger: "App excluded by user or never-inject policy",
                      headline: "Dictation is off in this app",
                      consequence: "Your app rule prevents insertion.",
                      action: "Review app rule", data: "Keep already-completed ordinary dictation"),
        RecoveryEntry(.D05, .delivery, .heldTape,
                      trigger: "All insertion methods fail before writing",
                      headline: "Couldn’t insert your text",
                      consequence: "Your text is kept here.",
                      action: "Copy text", data: "Keep final text; retry only after safe target check"),
        RecoveryEntry(.D06, .delivery, .unconfirmedHold,
                      trigger: "Readback unavailable after insertion attempt",
                      headline: "Inserted · not confirmed",
                      consequence: "Check the field before trying again.",
                      action: "Check text", data: "Keep record marked unconfirmed; never auto-retry"),
        RecoveryEntry(.D07, .delivery, .unconfirmedHold,
                      trigger: "Readback shows partial or mismatched insertion",
                      headline: "Only part may have been inserted",
                      consequence: "Check the destination to avoid duplicate text.",
                      action: "Review result", data: "Keep original and readback separately"),
        RecoveryEntry(.D08, .delivery, .heldTape, defensive: true,
                      trigger: "Clipboard fallback blocked or clipboard changes",
                      headline: "Couldn’t copy your text",
                      consequence: "Your words are still available for manual selection.",
                      action: "Select text", data: "Keep draft; restore clipboard only if still owned"),
        RecoveryEntry(.D09, .delivery, .attentiveReview, defensive: true,
                      trigger: "Cannot locate trustworthy word rectangles",
                      headline: "Word marks aren’t available in this app",
                      consequence: "The text can be inserted, but review marks stay in VoicePlus.",
                      action: "Review words", data: "Preserve spans in history; no floating inaccurate marks"),
        RecoveryEntry(.D10, .delivery, .attentiveReview,
                      trigger: "Destination changes before correction or undo",
                      headline: "The text has changed",
                      consequence: "Your correction has not replaced anything.",
                      action: "Copy correction", data: "Keep proposed correction; invalidate stale range"),
        RecoveryEntry(.D11, .delivery, .heldTape, defensive: true,
                      trigger: "New hotkey while text is held",
                      headline: "You have text waiting",
                      consequence: "Resolve or save this draft before a new dictation.",
                      action: "Review held text", data: "Never overwrite held draft"),

        RecoveryEntry(.S01, .storage, .scopedNotice,
                      trigger: "History or timeline read fails",
                      headline: "History can’t be read",
                      consequence: "Other working sections remain available.",
                      action: "Try again", data: "Do not clear store or claim it is empty"),
        RecoveryEntry(.S02, .storage, .scopedNotice,
                      trigger: "Setting, dictionary or app rule save fails",
                      headline: "Changes weren’t saved",
                      consequence: "Your previous setting is still active.",
                      action: "Try again", data: "Keep entered value and indicate unsaved state"),
        RecoveryEntry(.S03, .storage, .heldTape, defensive: true,
                      trigger: "Draft or transcript persistence fails",
                      headline: "This text hasn’t been saved",
                      consequence: "Keep this window open until you copy it.",
                      action: "Copy text", data: "Keep in memory; do not claim crash-safe recovery"),
        RecoveryEntry(.S04, .storage, .scopedNotice,
                      trigger: "Deletion succeeds only for some items",
                      headline: "Some items couldn’t be deleted",
                      consequence: "Show precisely which items remain.",
                      action: "Retry deletion", data: "Preserve accurate count and failure list"),
        RecoveryEntry(.S05, .storage, .heldTape, defensive: true,
                      trigger: "App quits or crashes during capture",
                      headline: "An unfinished recording was found",
                      consequence: "Recover only audio or text that is actually on disk.",
                      action: "Recover", data: "Show retained duration and location; never imply missing audio exists"),

        RecoveryEntry(.N01, .services, .scopedNotice,
                      trigger: "Remote provider offline or timeout",
                      headline: "The service isn’t responding",
                      consequence: "Local transcription still works when its model is ready.",
                      action: "Retry service", data: "Keep local result; no silent cloud fallback"),
        RecoveryEntry(.N02, .services, .scopedNotice,
                      trigger: "Credentials rejected",
                      headline: "Reconnect this service",
                      consequence: "The current request was not completed.",
                      action: "Reconnect", data: "Keep local drafts; never show API key in error"),
        RecoveryEntry(.N03, .services, .scopedNotice,
                      trigger: "Rate limit, quota or billing rejection",
                      headline: "This service is temporarily unavailable",
                      consequence: "Show retry time when the provider supplies one.",
                      action: "Use local option", data: "Keep local transcript; no automatic paid upgrade"),
        RecoveryEntry(.N04, .services, .scopedNotice,
                      trigger: "Malformed, unsupported or disabled provider response",
                      headline: "This service couldn’t complete the request",
                      consequence: "The original text has been preserved.",
                      action: "Review service settings", data: "No partial rewrite replaces original"),

        RecoveryEntry(.X01, .meetings, .scopedNotice,
                      trigger: "System audio or Calendar permission absent",
                      headline: "Meeting setup needs attention",
                      consequence: "Name the missing permission; microphone-only capture may still work.",
                      action: "Review permissions", data: "Keep available mic track; label missing track"),
        RecoveryEntry(.X02, .meetings, .heldTape,
                      trigger: "Recording interrupted or transcript unreadable",
                      headline: "This meeting needs recovery",
                      consequence: "Keep other meetings visible and isolate the affected row.",
                      action: "Recover meeting", data: "Preserve saved audio/text; never fabricate speaker turns"),
        RecoveryEntry(.X03, .voice, .scopedNotice,
                      trigger: "Enrollment too short or speaker model unavailable",
                      headline: "Couldn’t finish voice setup",
                      consequence: "Hold-to-talk still works; speaker filtering stays off.",
                      action: "Try voice setup again", data: "Keep prior enrollment until replacement succeeds"),
        RecoveryEntry(.X04, .dictionary, .scopedNotice,
                      trigger: "Contacts denied or import malformed",
                      headline: "Couldn’t import these words",
                      consequence: "Existing dictionary entries are unchanged.",
                      action: "Review import", data: "Preview valid entries and list rejected rows"),
        RecoveryEntry(.X05, .sync, .scopedNotice,
                      trigger: "Pairing mismatch, bad key or tampered payload",
                      headline: "Devices couldn’t be paired safely",
                      consequence: "Nothing from this transfer was applied.",
                      action: "Pair again", data: "Keep local data; do not weaken verification"),
        RecoveryEntry(.X06, .sync, .scopedNotice, defensive: true,
                      trigger: "Peer offline or concurrent edits conflict",
                      headline: "Sync needs attention",
                      consequence: "Local dictation continues. Review conflicting edits.",
                      action: "Review sync", data: "Keep both versions until resolved"),
        RecoveryEntry(.X07, .system, .scopedNotice, defensive: true,
                      trigger: "Update fails or is interrupted",
                      headline: "The update didn’t finish",
                      consequence: "Keep using the installed version.",
                      action: "Retry update", data: "Do not discard drafts or replace working app early"),
        RecoveryEntry(.X08, .system, .heldTape,
                      trigger: "Unexpected unmapped error",
                      headline: "VoicePlus couldn’t finish this step",
                      consequence: "Say whether text exists and whether anything may have been inserted.",
                      action: "Open recovery", data: "Preserve available data; technical details in diagnostics"),
    ]
}
