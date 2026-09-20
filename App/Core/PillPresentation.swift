import CoreGraphics
import Engine
import Foundation
import Shared

/// How long a pill state stays up (design §5, §6, §10; build doc S2 "Dwell").
///
/// The bug this began with (S5b): `RealEngine.stop()` emits `.landed` and `.idle` back to back, and the
/// pill slid in and straight back out; an error notice flashed for two frames. The rule stays narrow,
/// so it can never leave a stale pill in front of a live turn: **only a retraction is ever delayed.**
/// Any visible state replaces whatever is showing at once.
///
/// S2 sets the table to the verified design: inserted 650 ms; cancelled 800 ms; a quiet no-result
/// return 1.2 s (inside the design's 800–1600 ms fade); the final preview's dwell is S3's; and
/// held, unconfirmed, partial, error, unavailable, blocked and muted **stay until the user acts**
/// (design §10 "Error notices remain until action/dismissal"). No timed dismissal for those.
public enum PillDwell {
    public enum Rule: Equatable, Sendable {
        /// Retracts as soon as it is asked to.
        case none
        /// Stays at least this long once shown.
        case minimum(TimeInterval)
        /// Stays until the user acts on it (an action, Dismiss, or a new turn replacing it).
        case untilAction
    }

    /// D1 — "✓ Inserted in <app>" (design §5 step 7).
    public static let inserted: TimeInterval = 0.65
    /// C4 — "Cancelled · nothing inserted" (design §6).
    public static let cancelled: TimeInterval = 0.8
    /// A quiet no-result return (A06/A07/K03, `RecoveryTreatment.quietReturn`): inside
    /// `RecoveryCatalog.fadeWindow` (0.8–1.6 s).
    public static let quietReturn: TimeInterval = 1.2
    /// R2 — the safe-undo window (design §6).
    public static let undoWindow: TimeInterval = 5
    /// Legacy `.landing` acknowledgement: enough for the slide-in to register.
    public static let acknowledgement: TimeInterval = 0.6
    /// A notice raised outside any turn (a `.preview` line presented with no capture open) fades
    /// after this; it carries no recovery material, so it is not a sticky error.
    public static let transientNotice: TimeInterval = 4.0

    public static func rule(for state: PillState) -> Rule {
        switch state {
        case .hidden, .idle, .listening, .preview, .transform, .ready, .starting, .listeningQuiet, .latched,
             .finishing, .finalPreview, .inserting, .correcting, .editing, .meeting, .warning:
            return .none
        case .landing: return .minimum(acknowledgement)
        case .landed(let info): return info.verified ? .minimum(inserted) : .untilAction
        case .cancelled: return .minimum(cancelled)
        case .undoAvailable: return .minimum(undoWindow)
        case .held, .landedPartial, .unavailable, .muted: return .untilAction
        case .error(let message):
            return PillNotice.isQuietReturn(message) ? .minimum(quietReturn) : .untilAction
        }
    }

    /// The same table by design key (`design_copy.json` › `states`), including `blocked`, which has
    /// no `PillState` case of its own.
    public static func rule(forDesignKey key: String) -> Rule {
        switch key {
        case "inserted": return .minimum(inserted)
        case "cancelled": return .minimum(cancelled)
        case "undo": return .minimum(undoWindow)
        case "held", "unconfirmed", "partial", "error", "unavailable", "blocked", "muted": return .untilAction
        default: return .none
        }
    }

    /// Minimum time `state` must remain visible once shown; `.infinity` for states that stay until
    /// the user acts.
    public static func minimum(for state: PillState) -> TimeInterval {
        switch rule(for: state) {
        case .none: return 0
        case .minimum(let seconds): return seconds
        case .untilAction: return .infinity
        }
    }

    /// True for the states that stay until the user acts on them.
    public static func staysUntilAction(_ state: PillState) -> Bool { rule(for: state) == .untilAction }

    /// Is this a state the user is meant to *read and act on* (as opposed to watch)?
    public static func isNotice(_ state: PillState) -> Bool { staysUntilAction(state) }
}

/// Pure gate between "what the reducer says" and "what the panel draws". Owns no timers: the caller
/// asks, gets a decision, and schedules `flush` when told to hold.
public struct PillPresenter: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Draw this state now.
        case show(PillState)
        /// Keep drawing the current state until this instant, then call `flush`. `.distantFuture`
        /// means "until the user acts": nothing will flush it, only `dismiss` or a visible state.
        case hold(until: Date)
        /// Nothing to do.
        case unchanged
    }

    public private(set) var displayed: PillState = .hidden
    /// When `displayed` went up. `nil` before the first `request`.
    public private(set) var shownAt: Date?
    /// The retraction that is waiting for `displayed` to finish its dwell.
    public private(set) var pending: PillState?

    public init() {}

    /// The instant `displayed` may be replaced by a retraction; `.distantFuture` while it stays
    /// until the user acts.
    public func releaseTime() -> Date? {
        guard let shownAt else { return nil }
        switch PillDwell.rule(for: displayed) {
        case .none: return shownAt
        case .minimum(let seconds): return shownAt.addingTimeInterval(seconds)
        case .untilAction: return .distantFuture
        }
    }

    /// True while the current state is inside its guaranteed-legible window.
    public func isDwelling(now: Date) -> Bool {
        guard let release = releaseTime() else { return false }
        return now < release
    }

    public mutating func request(_ next: PillState, now: Date) -> Decision {
        // A visible state is always news — it never waits behind an older one.
        if next.isVisible { return commit(next, now: now) }
        if displayed == .hidden { pending = nil; return .unchanged }
        if let release = releaseTime(), now < release {
            pending = next
            return .hold(until: release)
        }
        return commit(next, now: now)
    }

    /// Take the current row down *now*, ignoring its dwell: the user acted on it (Insert here, Copy,
    /// Discard, Dismiss, Check text…). The dwell exists so a notice cannot flash past unread; it is not
    /// there to hold a row in front of someone who has just dealt with it.
    public mutating func dismiss(now: Date) -> Decision {
        pending = nil
        return commit(.hidden, now: now)
    }

    /// Apply a held retraction once its deadline has passed. Safe to call early or spuriously.
    public mutating func flush(now: Date) -> Decision {
        guard let pending else { return .unchanged }
        if let release = releaseTime(), now < release { return .hold(until: release) }
        return commit(pending, now: now)
    }

    private mutating func commit(_ state: PillState, now: Date) -> Decision {
        pending = nil
        guard state != displayed else { return .unchanged }
        displayed = state
        shownAt = now
        return .show(state)
    }
}

// MARK: - What a pill shows (S2)

/// The actions a pill button can carry. Raw values are the prototype's `data-pill-action` names
/// (`design_copy.json` › `pill` › `buttons` › `action`), plus the two the finishing and overflow rows add.
public enum PillActionKind: String, CaseIterable, Equatable, Sendable {
    case finish, commit, cancel, insert, copy, discard, check, dismiss, voice, unmute, models, undo
    case pause, stop, meeting, resume, review, permissions
    /// design §5: after 10 s of finishing, keep the valid partial text instead of waiting.
    case useAvailable
    /// design §4 "Transcript layout": long final text shows "N words · Review all".
    case reviewAll
    case editDraft, doneEditing, cancelEditing

    /// The held-queue action a held row's button maps onto.
    public var heldAction: HeldAction? {
        switch self {
        case .insert: return .insertHere
        case .copy: return .copy
        case .discard: return .discard
        default: return nil
        }
    }
}

public struct PillButton: Equatable, Hashable, Sendable, Identifiable {
    public var label: String
    public var action: PillActionKind
    public var primary: Bool

    public init(_ label: String, _ action: PillActionKind, primary: Bool = false) {
        self.label = label
        self.action = action
        self.primary = primary
    }

    public var id: String { action.rawValue + "·" + label }
    /// Accessibility identifier: `pill.action.<action>`.
    public var identifier: String { "pill.action.\(action.rawValue)" }
}

public enum PillTone: String, Equatable, Sendable { case normal, warn }

/// Everything about the current turn the pill needs that the `PillState` value does not carry: the
/// configured key, the destination named at key-down, the clock, the newest live words, the payload's
/// uncertain words. `PillViewModel` keeps it; tests build it directly.
public struct PillTurnContext: Equatable, Sendable {
    /// The configured dictation key as hints name it ("fn / 🌐").
    public var keyLabel: String
    /// The destination's display name from the key-down snapshot ("Mail").
    public var destination: String?
    /// When the turn began (the status-row timer counts from here).
    public var startedAt: Date?
    public var now: Date
    /// The newest transcript text of this turn; stays through finishing so the words never vanish.
    public var liveText: String
    /// Capture is open for this turn (between the first capture state and finishing).
    public var captureOpen: Bool
    /// The latch timer as last published (`LatchRuntime.onElapsed`).
    public var latchElapsed: TimeInterval?
    /// Low-confidence words of the final payload, normalised (`PillTextLane.normalized`).
    public var uncertainWords: Set<String>
    /// The uncertainty marks drawn on the final payload (S5 `UncertaintyMarkMapper`).
    public var uncertainCount: Int
    /// A rewrite marked a phrase or the whole result (T05): the rows read "Review this phrase".
    public var needsPhraseReview: Bool = false
    /// When `.finishing` began, for the 10 s "Use available text" / "Cancel" offer.
    public var finishingSince: Date?
    /// Deixis boxes drawn this turn (the chip row shows when > 0).
    public var chipCount: Int
    /// "Review all" was opened on this turn's final preview: the dwell is paused for review and the
    /// row offers Insert text / Cancel, as the manual preview does.
    public var reviewing: Bool = false

    public init(keyLabel: String = HotkeyBinding.default.label, destination: String? = nil, startedAt: Date? = nil,
                now: Date = Date(), liveText: String = "", captureOpen: Bool = false, latchElapsed: TimeInterval? = nil,
                uncertainWords: Set<String> = [], uncertainCount: Int = 0, finishingSince: Date? = nil,
                chipCount: Int = 0) {
        self.keyLabel = keyLabel
        self.destination = destination
        self.startedAt = startedAt
        self.now = now
        self.liveText = liveText
        self.captureOpen = captureOpen
        self.latchElapsed = latchElapsed
        self.uncertainWords = uncertainWords
        self.uncertainCount = max(0, uncertainCount)
        self.finishingSince = finishingSince
        self.chipCount = max(0, chipCount)
    }

    /// The real elapsed time the status row shows: the latch timer while latched, else since start.
    public var elapsed: TimeInterval {
        if let latchElapsed { return latchElapsed }
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    var destinationName: String? {
        guard let name = destination?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}

/// S2 — one pill state, rendered: status row, text lane, helper / key-hint row and action row, from the
/// verified design's copy (`PillDeck`, pinned to `design_copy.json` › `pill`) with the three runtime
/// substitutions — the real transcript for the sample, the real destination for "Mail", the configured
/// key for "Right Control" — and the real timer.
public struct PillContent: Equatable, Sendable {
    public enum Words: Equatable, Sendable {
        case none
        /// A fixed sentence of the state ("Ready for your words", "Nothing inserted").
        case fixed(String)
        /// Live words: the newest two lines with a leading fade.
        case live(String)
        /// The final payload: last two lines plus "N words · Review all"; uncertain words dotted.
        case final(String)

        public var text: String? {
            switch self {
            case .none: return nil
            case .fixed(let s), .live(let s), .final(let s): return s
            }
        }
    }

    public enum Trailing: Equatable, Sendable {
        case none
        case destination(String)
        case timer(TimeInterval)

        public var text: String? {
            switch self {
            case .none: return nil
            case .destination(let name): return name
            case .timer(let elapsed): return PillTimer.text(elapsed: elapsed)
            }
        }
    }

    /// The design key (`design_copy.json` › `states`) this content draws.
    public var designKey: String
    public var status: String
    public var tone: PillTone
    public var trailing: Trailing
    public var words: Words
    public var helper: String
    /// "Esc · cancel" beside the helper while capture is open (prototype `pillHtml`).
    public var escapeHint: Bool
    public var buttons: [PillButton]
    /// A notice the user must act on (`design_copy.json` › `notice`).
    public var notice: Bool
    /// The Spool pose key (`SpoolStateKey` raw value) — the character, not a write trigger.
    public var spoolKey: String

    public init(designKey: String, status: String, tone: PillTone = .normal, trailing: Trailing = .none,
                words: Words = .none, helper: String = "", escapeHint: Bool = false, buttons: [PillButton] = [],
                notice: Bool = false, spoolKey: String? = nil) {
        self.designKey = designKey
        self.status = status
        self.tone = tone
        self.trailing = trailing
        self.words = words
        self.helper = helper
        self.escapeHint = escapeHint
        self.buttons = buttons
        self.notice = notice
        self.spoolKey = spoolKey ?? designKey
    }

    public static let hidden = PillContent(designKey: "idle", status: "")

    public var isHidden: Bool { designKey == "idle" && status.isEmpty }
    public var isHint: Bool { designKey == "ready" }
    public var hasActions: Bool { !buttons.isEmpty }
    /// The Spool is drawn for every turn state; the chin and the hint never show the character.
    public var showsSpool: Bool { !isHidden && !isHint }

    public func surface(measure: (String) -> CGFloat) -> NotchGeometry.Surface {
        if isHidden { return .hidden }
        if isHint { return .hint(textWidth: measure(status)) }
        return hasActions ? .actionable : .active
    }

    /// What VoiceOver hears: the semantic state and the real outcome, never the animation (design §11).
    public var accessibilityLabel: String {
        [status, trailing.text, words.text, helper].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: Building

    public static func make(_ state: PillState, context c: PillTurnContext) -> PillContent {
        let key = c.keyLabel
        switch state {
        case .hidden:
            return .hidden
        case .ready(let hint):
            return PillContent(designKey: "ready", status: hint)
        case .idle, .starting:
            let words: Words = c.liveText.isEmpty ? .fixed(PillDeck.startingWords) : .live(c.liveText)
            return PillContent(designKey: "starting", status: PillDeck.startingStatus,
                               trailing: destinationTrailing(c), words: words, helper: PillDeck.startingHelper)
        case .listening:
            return listening(c)
        case .preview(let text):
            // A `.preview` line presented while no capture is open is a notice, never transcript text
            // under "Listening" (design §5: "Listening" only while capture is actually open).
            guard c.captureOpen else { return PillContent(designKey: "notice", status: text, spoolKey: "ready") }
            var live = c
            live.liveText = text
            return listening(live)
        case .listeningQuiet:
            return PillContent(designKey: "quiet", status: PillDeck.quietStatus, trailing: .timer(c.elapsed),
                               words: .live(liveOrListening(c)), helper: PillDeck.quietHelper, escapeHint: true)
        case .latched(let elapsed):
            var timed = c
            timed.latchElapsed = elapsed
            return PillContent(designKey: "latched", status: PillDeck.latchedStatus, trailing: .timer(elapsed),
                               words: .live(liveOrListening(timed)), helper: PillDeck.latchedHelper(key: key),
                               escapeHint: true, buttons: PillDeck.latchedButtons)
        case .warning:
            return PillContent(designKey: "warning", status: PillDeck.warningStatus, tone: .warn,
                               trailing: .timer(c.elapsed), words: .live(liveOrListening(c)),
                               helper: PillDeck.warningHelper, buttons: PillDeck.warningButtons)
        case .landing:
            return finishing(slow: false, c)
        case .finishing(let slow):
            return finishing(slow: slow, c)
        case .finalPreview(let info):
            var named = c
            if let d = info.destination { named.destination = d }
            let review = info.needsReview
            let manual = info.manual || c.reviewing
            return PillContent(designKey: review ? "uncertain" : "preview",
                               status: PillDeck.readyStatus(destination: named.destinationName,
                                                            uncertain: review ? info.uncertainCount : nil,
                                                            phrase: info.needsPhraseReview),
                               trailing: destinationTrailing(named), words: .final(info.text),
                               helper: info.paused ? "Paused · move away to insert" : (manual ? "Review, then insert when ready" : ""),
                               buttons: [PillButton("Edit draft", .editDraft),
                                         PillButton(info.paused || manual ? "Insert now" : String(format: "Insert in %.1fs", info.dwellRemaining), .commit),
                                         PillButton("Cancel", .cancel)],
                               spoolKey: review ? "uncertain" : "preview")
        case .inserting(let text):
            return PillContent(designKey: "inserting", status: PillDeck.insertingStatus(destination: c.destinationName),
                               trailing: destinationTrailing(c), words: .final(text), helper: PillDeck.insertingHelper)
        case .landed(let info):
            if info.verified {
                return PillContent(designKey: "inserted", status: PillDeck.insertedStatus(destination: c.destinationName),
                                   trailing: destinationTrailing(c), words: .final(info.text),
                                   helper: PillDeck.insertedHelper(uncertain: c.uncertainCount,
                                                                                   phrase: c.needsPhraseReview))
            }
            return PillContent(designKey: "unconfirmed", status: PillDeck.unconfirmedStatus, tone: .warn,
                               trailing: destinationTrailing(c), words: .final(info.text),
                               helper: PillDeck.unconfirmedHelper, buttons: PillDeck.unconfirmedButtons, notice: true)
        case .landedPartial(let text):
            return PillContent(designKey: "partial", status: PillDeck.partialStatus, tone: .warn,
                               trailing: destinationTrailing(c), words: .final(text), helper: PillDeck.partialHelper,
                               buttons: PillDeck.partialButtons, notice: true)
        case .held(let info):
            return held(info, c)
        case .unavailable:
            return PillContent(designKey: "unavailable", status: PillDeck.unavailableStatus, tone: .warn,
                               words: .fixed(PillDeck.unavailableWords), helper: PillDeck.unavailableHelper,
                               buttons: PillDeck.unavailableButtons, notice: true)
        case .error(let message):
            return error(message, c)
        case .transform(let info):
            return transform(info, c)
        case .muted:
            return PillContent(designKey: "muted", status: PillDeck.mutedStatus, words: .fixed(PillDeck.mutedWords),
                               helper: PillDeck.mutedHelper, buttons: PillDeck.mutedButtons)
        case .cancelled:
            return PillContent(designKey: "cancelled", status: PillDeck.cancelledStatus, trailing: destinationTrailing(c),
                               words: .fixed(PillDeck.cancelledWords), helper: PillDeck.cancelledHelper)
        case .correcting:
            return PillContent(designKey: "correcting", status: PillDeck.correctingStatus, trailing: destinationTrailing(c),
                               words: c.liveText.isEmpty ? .none : .final(c.liveText), helper: PillDeck.correctingHelper,
                               buttons: PillDeck.correctingButtons)
        case .editing:
            return PillContent(designKey: "editing", status: PillDeck.editingStatus(words: nil),
                               trailing: destinationTrailing(c), helper: PillDeck.editingHelper)
        case .undoAvailable:
            return PillContent(designKey: "undo", status: PillDeck.undoStatus(destination: c.destinationName),
                               trailing: destinationTrailing(c), words: c.liveText.isEmpty ? .none : .final(c.liveText),
                               helper: PillDeck.undoHelper, buttons: PillDeck.undoButtons)
        case .meeting(let info):
            return meeting(info)
        }
    }

    /// E1 — the blocking error, which has no `PillState` of its own: "Microphone access is off" or
    /// the named blocker's catalogue headline.
    public static func blocked(_ entry: RecoveryEntry? = nil, keyLabel: String = HotkeyBinding.default.label) -> PillContent {
        guard let entry, entry.id != .P01 else {
            return PillContent(designKey: "blocked", status: PillDeck.blockedStatus, tone: .warn,
                               words: .fixed(PillDeck.blockedWords), helper: PillDeck.blockedHelper,
                               buttons: PillDeck.blockedButtons, notice: true)
        }
        let rendered = entry.rendered(hotkey: keyLabel)
        return PillContent(designKey: "blocked", status: rendered.headline, tone: .warn,
                           words: .fixed(rendered.consequence), helper: PillDeck.blockedHelper,
                           buttons: [PillButton(rendered.action, entry.actionKind.pillAction ?? .permissions,
                                                primary: true)],
                           notice: true)
    }

    // MARK: Pieces

    private static func liveOrListening(_ c: PillTurnContext) -> String {
        c.liveText.isEmpty ? PillDeck.listeningPlaceholder : c.liveText
    }

    private static func destinationTrailing(_ c: PillTurnContext) -> Trailing {
        c.destinationName.map(Trailing.destination) ?? .none
    }

    private static func listening(_ c: PillTurnContext) -> PillContent {
        PillContent(designKey: "listening", status: PillDeck.listeningStatus, trailing: .timer(c.elapsed),
                    words: .live(liveOrListening(c)), helper: PillDeck.listeningHelper(key: c.keyLabel),
                    escapeHint: true)
    }

    private static func finishing(slow: Bool, _ c: PillTurnContext) -> PillContent {
        let waited = c.finishingSince.map { c.now.timeIntervalSince($0) } ?? 0
        let longWait = waited >= PillDeck.finishingOfferDelay
        let buttons: [PillButton] = longWait
            ? (c.liveText.isEmpty ? [] : [PillButton(PillDeck.useAvailableText, .useAvailable, primary: true)])
                + [PillButton(PillDeck.cancelLabel, .cancel, primary: c.liveText.isEmpty)]
            : []
        return PillContent(designKey: "finishing",
                           status: slow || waited >= PillState.finishingWarningDelay
                               ? PillDeck.finishingSlowStatus : PillDeck.finishingStatus,
                           trailing: destinationTrailing(c),
                           words: c.liveText.isEmpty ? .none : .live(c.liveText),
                           helper: PillDeck.finishingHelper, buttons: buttons)
    }

    private static func held(_ info: HeldPillInfo, _ c: PillTurnContext) -> PillContent {
        var named = c
        if !info.destination.isEmpty { named.destination = info.destination }
        let entry = RecoveryCatalog.entry(forDeliveryReason: info.reason)
        // D01 (the destination moved) is the design's H0 row verbatim; any other hold keeps the same
        // three actions under its own catalogue headline and consequence.
        let isDestinationChange = entry.id == .D01 || info.reason.isEmpty
        let rendered = entry.rendered(hotkey: c.keyLabel)
        return PillContent(designKey: "held",
                           status: isDestinationChange ? PillDeck.heldStatus : PillDeck.warnPrefix + rendered.headline,
                           tone: .warn, trailing: destinationTrailing(named), words: .final(info.text),
                           helper: isDestinationChange ? PillDeck.heldHelper : rendered.consequence,
                           buttons: PillDeck.heldButtons, notice: true)
    }

    /// S11 — every error row is a catalogue entry (`PillContent.recovery`). A message that is not a
    /// catalogue headline is never shown (design §10): with words recovered from the turn it is the
    /// prototype's error row E0 (T01, "Couldn’t finish this dictation"), otherwise the catch-all X08.
    private static func error(_ message: String, _ c: PillTurnContext) -> PillContent {
        let recovered = !c.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let entry = PillNotice.entry(forMessage: message) ?? RecoveryCatalog.entry(recovered ? .T01 : .X08)
        return recovery(entry, context: c)
    }

    private static func transform(_ info: TransformPillInfo, _ c: PillTurnContext) -> PillContent {
        switch info.stage {
        case .editing:
            return PillContent(designKey: "editing", status: PillDeck.editingStatus(words: info.editingWords),
                               trailing: destinationTrailing(c), helper: PillDeck.editingHelper)
        case .done(let changed) where changed > 0:
            return PillContent(designKey: "undo", status: PillDeck.undoStatus(destination: c.destinationName),
                               trailing: destinationTrailing(c), helper: PillDeck.undoHelper, buttons: PillDeck.undoButtons)
        case .done, .warm, .notice:
            return PillContent(designKey: "editing", status: info.headline, trailing: destinationTrailing(c),
                               helper: PillDeck.editingHelper, spoolKey: "ready")
        }
    }

    private static func meeting(_ info: MeetingPillInfo) -> PillContent {
        switch info.phase {
        case .recording:
            return PillContent(designKey: "meeting", status: info.headline, words: .fixed(info.detail),
                               helper: info.helper, buttons: PillDeck.meetingButtons)
        case .paused:
            return PillContent(designKey: "paused", status: info.headline, words: .fixed(info.detail),
                               helper: info.helper, buttons: PillDeck.pausedButtons)
        case .preparingNotes:
            return PillContent(designKey: "notes", status: info.headline, words: .fixed(info.detail),
                               helper: info.helper, buttons: PillDeck.notesButtons)
        }
    }
}

/// Maps a pill `.error(message:)` onto the recovery catalogue (S9), so a notice gets its problem,
/// consequence and recovery action, and a quiet no-result return fades instead of staying.
public enum PillNotice {
    /// The problem half of a "Problem — Action" sentence ("No speech detected — Try again").
    public static func headline(of message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: " — ") else { return trimmed }
        return String(trimmed[..<range.lowerBound])
    }

    /// The catalogue entry whose headline this message is (whole or its problem half); nil otherwise.
    /// A headline naming the prototype's key ("Hold Right Control a little longer") also matches the
    /// same sentence rendered with the configured key (owner decision, build doc §0).
    public static func entry(forMessage message: String) -> RecoveryEntry? {
        let whole = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let problem = headline(of: message).lowercased()
        return RecoveryCatalog.entries.first { entry in
            let h = entry.headline.lowercased()
            if h == whole || h == problem { return true }
            let key = PillCopy.prototypeHotkey.lowercased()
            guard let range = h.range(of: key) else { return false }
            let prefix = h[..<range.lowerBound], suffix = h[range.upperBound...]
            return [whole, problem].contains { candidate in
                candidate.count > prefix.count + suffix.count
                    && candidate.hasPrefix(prefix) && candidate.hasSuffix(suffix)
            }
        }
    }

    /// S11 — the entry a pill `.error(message:)` draws: the catalogue entry whose headline it is, or
    /// the catch-all X08 "VoicePlus couldn’t finish this step". Unrecognised text is never shown
    /// (design §10); every producer passes a catalogue headline (`PillState.recovery`).
    public static func entryOrCatchAll(forMessage message: String) -> RecoveryEntry {
        entry(forMessage: message) ?? RecoveryCatalog.entry(.X08)
    }

    /// A quiet no-result return (A06 no speech, A07 too short, K03 short press): fades, never sticks.
    public static func isQuietReturn(_ message: String) -> Bool {
        entry(forMessage: message)?.treatment == .quietReturn
    }

    /// The pill action a catalogue recovery action label names, when the pill can carry it out
    /// (`RecoveryActionKind.pillAction`); nil for a label that is not a catalogue action.
    public static func action(for label: String) -> PillActionKind? {
        RecoveryCatalog.entries.first { $0.action == label || $0.action.lowercased() == label.lowercased() }?
            .actionKind.pillAction
    }
}

/// S2 — the text lane's line breaking: natural-language words, wrapped forward at the lane width, so a
/// stable word never moves when later words arrive; the newest `maxLines` are shown, with a leading
/// fade when earlier lines scrolled away (design §4 "Transcript layout"). Words are never split: a
/// grapheme cluster or identifier wider than the lane gets a line of its own.
public enum PillTextLane {
    public struct Lines: Equatable, Sendable {
        /// The lines to draw, oldest first.
        public var lines: [String]
        /// Earlier lines exist above the first drawn one (draw the leading fade / "Review all").
        public var clippedLeading: Bool
        public var wordCount: Int
        public var totalLines: Int
    }

    public static func wrap(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if current.isEmpty || measure(candidate) <= width {
                current = candidate
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    public static func tail(_ text: String, width: CGFloat, maxLines: Int, measure: (String) -> CGFloat) -> Lines {
        let all = wrap(text, width: width, measure: measure)
        let keep = max(1, maxLines)
        let shown = Array(all.suffix(keep))
        return Lines(lines: shown, clippedLeading: all.count > keep,
                     wordCount: text.split(whereSeparator: \.isWhitespace).count, totalLines: all.count)
    }

    /// Word identity for confidence marks: lower-cased, surrounding punctuation dropped.
    public static func normalized(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces)).lowercased()
    }

    /// "42 words · Review all" (design §4).
    public static func reviewAllLabel(wordCount: Int) -> String {
        "\(wordCount) word\(wordCount == 1 ? "" : "s") · Review all"
    }
}
