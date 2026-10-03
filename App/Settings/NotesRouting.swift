import Foundation
import Injection
import Pipeline
import Shared

// V5 N2 — the routes into Notes (§O). One pure decision, `NotesRoute.decide`, over the signals the
// intent arbiter has at the end of an utterance; and one writer, `NotesRouter`, that stores the words
// when the decision says so.
//
// The arbiter (O3 `UtteranceDecision`, O4 `IntentArbiter`, lane 5b) is the only authority on what an
// utterance *is* (§10). This file does not compete with it: when the arbiter has decided `note`, it
// passes that in (`arbiterChoseNote`) and the route only names *why* (the source tag the row shows).
// Until the arbiter lands, the same signals reach this function from the existing paths (latch
// delivery with no focused field, K4 "another voice" in latch, the wake verb), so Notes fills up from
// day one and nothing changes shape when 5b wires `UtteranceOwner.note` here.
//
// Precedence is "most explicit first": the user saying "note …" outranks everything; a declined ask
// is the user's own choice; then the context that makes typing unsafe (an agent running, a meeting,
// no field, an app switch); then the ambient bands.

/// Everything Notes needs to know about one finished utterance.
public struct NotesRouteSignals: Equatable, Sendable {
    /// There is somewhere to type: a readable field, or (N3 delivery ladder) an unreadable one in
    /// an app that still has a focused window. False only when there is no window at all.
    public var hasFocusedField: Bool
    /// The frontmost app changed between the start and the end of the segment.
    public var appSwitchedMidSegment: Bool
    /// The wake-verb parse, when the session was latched and the utterance started with one.
    public var wakeVerb: WakeVerbParse?
    /// The ambient decision band, when the utterance came from ambient listening.
    public var ambientBand: AmbientBand?
    /// The user declined the ask-band prompt for this utterance.
    public var declinedAsk: Bool
    /// The ambient mode is Listen & note (L1).
    public var listenAndNote: Bool
    /// The utterance was latched (hands-free) speech.
    public var latched: Bool
    /// A meeting is being recorded.
    public var meetingActive: Bool
    /// An agent (computer-use) action is running.
    public var agentActionRunning: Bool
    /// The arbiter (O4) already decided `note` for this utterance.
    public var arbiterChoseNote: Bool
    /// H24 — the app the words were meant for (the key-down destination), stored with the note.
    public var intendedApp: String?

    public init(hasFocusedField: Bool = true, appSwitchedMidSegment: Bool = false, wakeVerb: WakeVerbParse? = nil,
                ambientBand: AmbientBand? = nil, declinedAsk: Bool = false, listenAndNote: Bool = false,
                latched: Bool = false, meetingActive: Bool = false, agentActionRunning: Bool = false,
                arbiterChoseNote: Bool = false, intendedApp: String? = nil) {
        self.intendedApp = intendedApp
        self.hasFocusedField = hasFocusedField
        self.appSwitchedMidSegment = appSwitchedMidSegment
        self.wakeVerb = wakeVerb
        self.ambientBand = ambientBand
        self.declinedAsk = declinedAsk
        self.listenAndNote = listenAndNote
        self.latched = latched
        self.meetingActive = meetingActive
        self.agentActionRunning = agentActionRunning
        self.arbiterChoseNote = arbiterChoseNote
    }
}

/// O-b 5's bands as Notes reads them (thresholds live in 5b's `DecisionBands`).
public enum AmbientBand: String, Equatable, Sendable {
    case act, ask, note, ignore
}

/// The route decision: where the words go, and with which source tag.
public enum NotesRoute: Equatable, Sendable {
    /// Not a note — deliver / act / ask / ignore as the caller already would.
    case passThrough
    /// Store in Notes. `text` is what to store (the wake verb stripped).
    case note(NoteSource, text: String)

    public var source: NoteSource? {
        if case .note(let s, _) = self { return s }
        return nil
    }

    public static func decide(_ text: String, _ s: NotesRouteSignals) -> NotesRoute {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .passThrough }
        if let parse = s.wakeVerb, parse.kind == .note {
            let payload = parse.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.isEmpty ? .passThrough : .note(.wakeVerb, text: payload)
        }
        if s.declinedAsk { return .note(.declinedAsk, text: trimmed) }

        // Ambient speech: only the note band (lower-middle) — or anything that was not acted on while
        // in Listen & note — becomes a note. Ambient never reaches the field from here.
        if let band = s.ambientBand {
            switch band {
            case .note: return .note(s.listenAndNote ? .listenAndNote : .lowerMiddle, text: trimmed)
            case .act, .ask: return s.listenAndNote ? .note(.listenAndNote, text: trimmed) : .passThrough
            case .ignore: return .passThrough
            }
        }

        if s.agentActionRunning { return .note(.agentRunning, text: trimmed) }
        if s.latched && s.meetingActive { return .note(.meetingAside, text: trimmed) }
        if s.appSwitchedMidSegment { return .note(.appSwitch, text: trimmed) }
        if !s.hasFocusedField { return .note(.noField, text: trimmed) }
        if s.arbiterChoseNote { return .note(s.latched ? .latch : .lowerMiddle, text: trimmed) }
        return .passThrough
    }
}

/// Stores routed utterances. The one writer every route calls; returns the decision so the caller
/// knows whether to deliver.
public final class NotesRouter: @unchecked Sendable {
    public let store: NotesStore
    /// Told after a note is stored (pill chip, menu row). Called on the caller's thread.
    public var onNoted: ((NoteSource, String) -> Void)?

    public init(store: NotesStore) { self.store = store }

    /// Decides and, for a note, stores. A store failure is logged and reported as `.passThrough`, so
    /// the caller falls back to its normal path rather than losing the words.
    @discardableResult
    public func route(_ text: String, signals: NotesRouteSignals, at date: Date? = nil) -> NotesRoute {
        let decision = NotesRoute.decide(text, signals)
        guard case .note(let source, let body) = decision else { return decision }
        do {
            guard let id = try store.add(body, source: source, at: date, intendedApp: signals.intendedApp,
                                         reason: source.defaultReason) else { return .passThrough }
            onNoted?(source, id)
            return decision
        } catch {
            Log.app.error("notes: \(source.rawValue) note not stored: \(error)")
            return .passThrough
        }
    }

    /// K4: latched speech from another voice (`TurnAnchoredVoice` `.routeToNotes`). Explicitly a
    /// note, whatever the field says.
    @discardableResult
    public func routeOtherVoice(_ text: String, meetingActive: Bool, at date: Date? = nil,
                                intendedApp: String? = nil) -> String? {
        try? store.add(text, source: meetingActive ? .meetingAside : .latch, at: date, speaker: .others(1),
                       intendedApp: intendedApp, reason: meetingActive ? .meetingAside : .otherVoice)
    }
}

/// The composition seam. `install` builds the one Notes store and router at launch, points the pill
/// chip (N3) and the menu row at its count, and gives the window "Insert here". The arbiter (5b) and
/// the latch path reach the router through `NotesWiring.router` — the one writer — until they are
/// handed it directly.
@MainActor
public enum NotesWiring {
    public private(set) static var store: NotesStore?
    public private(set) static var router: NotesRouter?
    private static var feed: NotesChipFeed?

    /// `openNotes` opens the window at Notes; `insert` types into the app behind the window.
    public static func install(database: AppDatabase?, settings: (any SettingsStore)?,
                               pill: PillViewModel, status: StatusItemController,
                               openNotes: @escaping () -> Void,
                               insert: @escaping (String) async -> Bool) {
        let store = NotesStore(database: database, settings: settings)
        _ = try? store.sweepExpired()
        let router = NotesRouter(store: store)
        NotesFunnel.current = store
        let feed = NotesChipFeed(store: store, settings: settings)
        feed.onCount = { [weak pill, weak status] count in
            MainActor.assumeIsolated {
                pill?.notesCount = count
                status?.rebuild()
            }
        }
        pill.onOpenNotes = openNotes
        status.notesUnread = { [weak feed] in feed?.count ?? 0 }
        status.onOpenNotes = openNotes
        MainWindowController.environment.notesStore = store
        MainWindowController.environment.insertNote = insert
        self.store = store
        self.router = router
        self.feed = feed
        // H23 — the held queue is retired: every former hold (and Escape after words) goes to Notes.
        routeFormerHolds(turns: TurnStore.current, focusGuard: TurnWiring.current?.controller.focusGuard,
                         heldRoute: .shared)
    }

    /// H23 — installs the Notes sink on the turn store (a `.held` / cancelled-with-words turn) and on
    /// the injector's `FocusGuard` (every `hold`), then clears rows an earlier version left held
    /// (H27: settled, not re-noted — they duplicate text that already landed). A password field is never saved. A failed save keeps the words in history with Copy.
    nonisolated public static func routeFormerHolds(
        turns: TurnStore?, focusGuard: FocusGuard?, heldRoute: HeldNotesRoute? = nil,
        save: @escaping (String, String?, NoteReason) -> Result<String, NotesFunnelError> = {
            NotesFunnel.save(text: $0, intendedApp: $1, reason: $2)
        }
    ) {
        turns?.notesSink = save
        heldRoute?.install(save: save)
        focusGuard?.notesSink = { [weak turns] item in
            // Defence in depth: FocusGuard already drops secure items before the sink.
            guard let reason = NoteReason.forHeld(reason: item.reason) else { return true }
            let app = TurnOutcome.clean(item.destinationName)
            let result = save(item.text, app, reason)
            let outcome = NotesFunnel.outcome(of: result, intendedApp: app, reason: reason)
            if let id = item.turnID { turns?.setExtras(id, save: false) { outcome.write(into: &$0) } }
            if case .success = result {
                // The delivery pill shows this outcome, not a held row (no second save).
                heldRoute?.noted(item.text, outcome)
                return true
            }
            return false
        }
        turns?.settleStaleHeldRows()
    }

    /// N2 live route #1: a latched "note …" is stored by the router (source `.wakeVerb`) and claimed,
    /// so the lander never types it. The lander's existing claim consumer (act / "not you") is kept;
    /// both claims are always consumed so neither leaks into the next utterance.
    public static func wireWakeVerb(_ preRoute: WakeVerbPreRoute, lander: UtteranceLander) {
        guard let router else { return }
        preRoute.noteSink = Self.noteSink(router)
        let prior = lander.actClaimConsumer
        lander.actClaimConsumer = { [weak preRoute] in
            let other = prior?() ?? false
            let note = preRoute?.consumeNoteClaim() ?? false
            return other || note
        }
    }

    /// N2 live routes #2–#4 (landing time, hold and latch alike): no focused field, a latch during a
    /// meeting, an agent (computer-use) action running. `latched`, `meetingActive` and
    /// `agentRunning` are read per landing.
    public static func wireLander(_ lander: UtteranceLander, latched: @escaping () -> Bool,
                                  meetingActive: @escaping () -> Bool, agentRunning: @escaping () -> Bool) {
        guard let router else { return }
        lander.notesClaim = landingClaim(router, latched: latched, meetingActive: meetingActive, agentRunning: agentRunning)
    }

    /// N2 live routes #5–#6 (inside the latch runtime): an app switch mid-segment, and K4 — latched
    /// speech the speaker guard judged to be another voice.
    public static func wireLatch(_ latch: LatchRuntime, meetingActive: @escaping () -> Bool) {
        guard let router else { return }
        latch.notesRoute = latchRoute(router, meetingActive: meetingActive)
    }

    nonisolated static func landingClaim(_ router: NotesRouter, latched: @escaping () -> Bool,
                                         meetingActive: @escaping () -> Bool,
                                         agentRunning: @escaping () -> Bool) -> (String, Bool) -> NoteSource? {
        { text, hasField in
            let signals = NotesRouteSignals(hasFocusedField: hasField, latched: latched(),
                                            meetingActive: meetingActive(), agentActionRunning: agentRunning())
            return router.route(text, signals: signals).source
        }
    }

    nonisolated static func latchRoute(_ router: NotesRouter,
                                       meetingActive: @escaping () -> Bool) -> (String, LatchNotesRoute) -> Bool {
        { text, route in
            switch route {
            case .appSwitch:
                let signals = NotesRouteSignals(appSwitchedMidSegment: true, latched: true, meetingActive: meetingActive())
                return router.route(text, signals: signals).source != nil
            case .otherVoice:
                guard let id = router.routeOtherVoice(text, meetingActive: meetingActive()) else { return false }
                router.onNoted?(meetingActive() ? .meetingAside : .latch, id)
                return true
            }
        }
    }

    /// The sink the wake-verb pre-route calls: true when the payload was stored.
    nonisolated static func noteSink(_ router: NotesRouter) -> @Sendable (WakeVerbParse) -> Bool {
        { [router] parse in
            router.route(parse.payload, signals: NotesRouteSignals(wakeVerb: parse, latched: true)).source != nil
        }
    }
}

// MARK: - H24 the one funnel into Notes

/// Why a Notes save did not happen. The caller keeps the words in history with Copy (§2
/// "Couldn't save to Notes").
public enum NotesFunnelError: Error, Equatable, Sendable {
    /// No Notes store is installed (headless runs, before launch finished).
    case noStore
    /// Nothing to save.
    case emptyText
    /// The write failed.
    case writeFailed(String)
}

/// H24 — every "not typed" path saves through here: the words, the app they were meant for, and why.
/// Returns the note's id, or why it was not saved. Never types anything; never called for a password
/// field (a secure turn saves nothing anywhere).
public enum NotesFunnel {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: NotesStore?

    /// The app's store, set by `NotesWiring.install`.
    public static var current: NotesStore? {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    @discardableResult
    public static func save(text: String, intendedApp: String?, reason: NoteReason, at date: Date? = nil,
                            store: NotesStore? = nil) -> Result<String, NotesFunnelError> {
        guard let store = store ?? current else { return .failure(.noStore) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.emptyText) }
        do {
            guard let id = try store.add(text, source: NoteSource.of(reason), at: date,
                                         intendedApp: intendedApp, reason: reason) else { return .failure(.emptyText) }
            return .success(id)
        } catch {
            Log.app.error("notes funnel: \(reason.rawValue) note not stored: \(error)")
            return .failure(.writeFailed(String(describing: error)))
        }
    }

    /// The turn outcome a save came to (H25): saved / cancelled to Notes, or "Couldn't save to Notes".
    public static func outcome(of result: Result<String, NotesFunnelError>, intendedApp: String?,
                               reason: NoteReason) -> TurnOutcome {
        switch result {
        case .success: return reason == .cancelled ? .cancelledToNotes(intendedApp: intendedApp)
                                                  : .savedToNotes(intendedApp: intendedApp, reason: reason)
        case .failure: return .notesSaveFailed(intendedApp: intendedApp)
        }
    }
}

/// H23 verify — what the delivery pill does with a `.held` landing now that the held queue is
/// retired. A hold `FocusGuard` already saved to Notes shows its outcome ("Saved to Notes · <why>")
/// instead of a held row; a hold that never reached `FocusGuard` (a selected-text edit's recovery)
/// is saved here; a password field keeps nothing. `nil` (no route installed: tests, headless) keeps
/// the legacy held row; a failed save returns `.notesSaveFailed` so the caller keeps the words with
/// Copy.
public final class HeldNotesRoute: @unchecked Sendable {
    public static let shared = HeldNotesRoute()
    private let lock = NSLock()
    private var save: ((String, String?, NoteReason) -> Result<String, NotesFunnelError>)?
    /// Texts `FocusGuard` saved to Notes, newest last, until the pill consumes them.
    private var recent: [(text: String, outcome: TurnOutcome)] = []
    private let recentLimit = 20

    public init() {}

    public func install(save: @escaping (String, String?, NoteReason) -> Result<String, NotesFunnelError>) {
        lock.withLock { self.save = save }
    }

    /// `FocusGuard`'s sink stored `text` in Notes with `outcome`.
    public func noted(_ text: String, _ outcome: TurnOutcome) {
        lock.withLock {
            recent.append((text, outcome))
            if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        }
    }

    /// The outcome of a `.held(reason)` landing of `text` meant for `destination`.
    public func route(text: String, destination: String, reason: String) -> TurnOutcome? {
        if FocusGuard.isSecureReason(reason) { return .refusedSecure }
        let (already, save) = lock.withLock { () -> (TurnOutcome?, ((String, String?, NoteReason) -> Result<String, NotesFunnelError>)?) in
            if let index = recent.lastIndex(where: { $0.text == text }) {
                return (recent.remove(at: index).outcome, self.save)
            }
            return (nil, self.save)
        }
        if let already { return already }
        guard let save else { return nil }
        guard let noteReason = NoteReason.forHeld(reason: reason) else { return .refusedSecure }
        let app = TurnOutcome.clean(destination)
        return NotesFunnel.outcome(of: save(text, app, noteReason), intendedApp: app, reason: noteReason)
    }
}
