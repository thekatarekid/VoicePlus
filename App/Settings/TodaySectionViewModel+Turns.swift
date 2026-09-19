import Engine
import Foundation
import Shared

// S7b — Today's turn half (design §8.1, §9; `DESIGN.md` §9.1): held / recoverable text first, then
// recent dictations read from the turn store (S11), search over retained history only, and every
// action a held draft offers — Review (the recovery sheet), Copy (acknowledged only when verified),
// Insert here (explicit re-target) and Discard (confirmed when it destroys the only saved copy).
//
// The page renders exactly one base state (`page`): loading "Loading recent dictations…", empty
// ("Nothing dictated yet" + the key; the history-off variant; "No matches for …"), error ("History
// can't be read" + Try again) or content — and held drafts always make it content, so a history
// that cannot be read never hides the text that is waiting.

/// A one-line acknowledgement or problem beside a draft or at the top of the page.
public struct TodayNotice: Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable { case good, warn }

    public var text: String
    public var detail: String?
    public var tone: Tone
    /// The recovery entry behind a problem notice, when there is one.
    public var recoveryID: RecoveryID?

    public init(text: String, detail: String? = nil, tone: Tone, recoveryID: RecoveryID? = nil) {
        self.text = text
        self.detail = detail
        self.tone = tone
        self.recoveryID = recoveryID
    }

    /// Only ever raised after the pasteboard was read back (design §8.1).
    public static let copied = TodayNotice(text: TodayCopy.copied, tone: .good)

    public static func problem(_ id: RecoveryID) -> TodayNotice {
        let entry = RecoveryCatalog.entry(id)
        return TodayNotice(text: entry.headline, detail: entry.consequence, tone: .warn, recoveryID: id)
    }
}

/// What the recovery sheet and the turn detail ask of Today: the drafts, the turn store, and the one
/// implementation of every held-text action, so the pill row, the status menu, Today and the sheet
/// can never disagree about what happened to a draft.
@MainActor
public protocol TodayDraftHost: AnyObject {
    var historyEnabled: Bool { get }
    var hotkeyLabel: String { get }
    var pasteboard: any TodayPasteboard { get }
    var destinations: any RecoveryDestinations { get }
    func turnReader() -> (any TodayTurnReading)?
    /// The draft as it is now (matched by turn, else by held item), or nil once it was resolved.
    func currentDraft(_ draft: TodayDraft) -> TodayDraft?
    func draft(forTurn turn: TurnID) -> TodayDraft?
    /// Insert here, after the sheet revalidated `target`. Nil when no insertion path exists.
    func insert(_ draft: TodayDraft, into target: RecoveryTarget) -> DeliveryOutcome?
    /// Copies with a read-back check and resolves the draft. False when the copy is not verified.
    func copy(_ draft: TodayDraft) -> Bool
    func discard(_ draft: TodayDraft)
    func discardNeedsConfirmation(_ draft: TodayDraft) -> Bool
    func deleteTurn(_ id: TurnID)
    func presentRecovery(_ draft: TodayDraft)
    func closeRecovery()
    func closeTurn()
}

extension TodaySectionViewModel: TodayDraftHost {
    /// How many turns Today reads. Search works on these (retained history only).
    static let historyLimit = 200

    // MARK: The page's one rendering

    /// The page's base rendering. Held drafts (and the ambient group) make it content whatever the
    /// history read did; otherwise it is the history's own rendering.
    public var page: SectionState {
        if !drafts.isEmpty || ambientVisible || history.isContent { return .content }
        return history
    }

    public var historyEnabled: Bool { services.historyEnabled() }
    public var hotkeyLabel: String { dictationKeyName }
    public var pasteboard: any TodayPasteboard { services.pasteboard }
    public var destinations: any RecoveryDestinations { services.destinations() }
    public func turnReader() -> (any TodayTurnReading)? { services.turns() }

    // MARK: Reading

    /// Held and partial drafts from the turn store's memory and the live held queue. Synchronous:
    /// neither can fail, which is why held text survives an unreadable history.
    func rebuildDrafts() {
        let reader = services.turns()
        let queue = services.injection()
        drafts = TodayDraft.merge(recoverable: reader?.recoverableTurns(limit: 50) ?? [], live: heldProvider(),
                                  turnOf: { queue?.turn(ofHeld: $0) },
                                  saveFailed: { reader?.saveFailed($0) ?? false })
        draftNotices = draftNotices.filter { id, _ in drafts.contains { $0.id == id } }
    }

    /// Everything the page shows: drafts, then the history read (off the main thread), then the
    /// search. A read superseded by a newer one never lands.
    public func reloadHistory() async {
        rebuildDrafts()
        ambientVisible = ambientCaptureOn()
        guard historyEnabled else {
            historyGeneration += 1
            historyEntries = []
            recent = []
            historyBanner = nil
            history = .empty(TodayCopy.historyOff, detail: TodayCopy.historyOffDetail, action: TodayCopy.reviewRetention)
            return
        }
        guard let reader = services.turns() else {
            // No turn store to ask: history cannot be read, which is not the same as "nothing yet".
            historyGeneration += 1
            historyEntries = []
            recent = []
            history = .error(RecoveryCatalog.entry(.S01).rendered(hotkey: hotkeyLabel))
            return
        }
        historyGeneration += 1
        let generation = historyGeneration
        // Loading only while nothing readable is on screen: a refresh keeps the rows it has.
        if !history.isContent { history = .loading(.today, headline: TodayCopy.loadingRecent) }
        let limit = Self.historyLimit
        let result = await Task.detached(priority: .userInitiated) {
            Result { try reader.recentTurns(limit: limit) }
        }.value
        guard generation == historyGeneration else { return }
        switch result {
        case .success(let entries):
            historyLoadedOnce = true
            historyEntries = entries
            historyBanner = nil
            applySearch()
        case .failure(let error):
            let s01 = RecoveryCatalog.entry(.S01).rendered(hotkey: hotkeyLabel)
            if recent.isEmpty {
                // Nothing readable: a search must not turn this into "Nothing dictated yet".
                historyLoadedOnce = false
                historyEntries = []
                history = .error(s01)
            } else {
                // Partial: the rows already read stay; the failure is scoped to a banner.
                history = .content
                historyBanner = .partial(s01, diagnostics: "\(error)")
            }
        }
    }

    /// "History can't be read" › Try again — scoped, and disabled while it runs.
    public func retryHistory() async {
        await historyRetry.run { await self.reloadHistory() }
    }

    /// The turn store changed (a new turn, a resolution): reload once things settle.
    public func turnsChanged() {
        turnsReload?.cancel()
        turnsReload = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.reloadHistory()
            await self.detail?.reload()
            self.recovery?.refreshDraft()
        }
    }

    // MARK: Search — retained history only

    /// Filters what the last read returned. Search never reaches past retained history: with
    /// history off there is nothing to search and the page says so (not "No results").
    public func applySearch() {
        guard historyEnabled, historyLoadedOnce || !historyEntries.isEmpty else { return }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = historyEntries.filter { Self.matches($0, query) }.compactMap(TodayTurnRow.init)
        recent = rows
        guard rows.isEmpty else {
            history = .content
            return
        }
        history = query.isEmpty
            ? .empty(.today, hotkey: hotkeyLabel)
            : .empty(TodayCopy.noMatches(query), detail: TodayCopy.noMatchesDetail, action: TodayCopy.clearSearch)
    }

    /// The search field changed (the shell's toolbar search, `⌘F`).
    public func searchChanged(_ text: String) async {
        if search != text { search = text }
        applySearch()
        await reloadTimeline()
    }

    /// "No matches for …" › Clear search.
    public func clearHistorySearch() async {
        search = ""
        applySearch()
        await reloadTimeline()
    }

    static func matches(_ entry: TurnEntry, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let record = entry.record
        return [record.finalText, record.rawText, record.destination.appName ?? ""].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: Opening things

    public func presentRecovery(_ draft: TodayDraft) {
        notice = nil
        recovery = RecoverySheetModel(draft: draft, host: self)
    }

    public func closeRecovery() {
        recovery = nil
        refreshHeld()
    }

    /// Turn detail for a row ("1 to review" and a row click open it).
    public func openTurn(_ id: TurnID) {
        let model = TurnDetailModel(turnID: id, host: self)
        detail = model
        Task { await model.reload() }
    }

    public func closeTurn() { detail = nil }

    // MARK: Drafts — the one implementation of every held-text action

    public func currentDraft(_ draft: TodayDraft) -> TodayDraft? {
        rebuildDrafts()
        if let turn = draft.turnID, let match = drafts.first(where: { $0.turnID == turn }) { return match }
        if let held = draft.heldID { return drafts.first { $0.heldID == held } }
        return nil
    }

    public func draft(forTurn turn: TurnID) -> TodayDraft? {
        rebuildDrafts()
        return drafts.first { $0.turnID == turn }
    }

    /// Insert here into the field the sheet revalidated. The pill's queue first (so its row and the
    /// menu drop it), then the injector's own queue, then — for text held before a relaunch, which
    /// no live queue has — one write that refuses unless focus is still `target`. Every path posts
    /// once; the outcome is the stack's, never assumed.
    public func insert(_ draft: TodayDraft, into target: RecoveryTarget) -> DeliveryOutcome? {
        defer { refreshHeld() }
        let reader = services.turns()
        if let heldID = draft.heldID, let item = heldProvider().first(where: { $0.id == heldID }) {
            let result = heldAction(item, .insertHere)
            return outcome(after: result, turn: draft.turnID, reader: reader)
        }
        guard let queue = services.injection() else { return nil }
        if let turn = draft.turnID, let heldID = queue.heldID(forTurn: turn) {
            return queue.insertHeld(heldID)
        }
        let outcome = queue.insert(text: draft.text, turn: draft.turnID, expecting: target)
        if let turn = draft.turnID, let outcome { reader?.recordInsertion(turn, outcome: outcome) }
        return outcome
    }

    /// What an insertion through the pill's queue came to. The turn record carries the stack's own
    /// outcome (`FocusGuard.onResolved` → the turn controller); without one, an insertion that
    /// reported success is unconfirmed — never assumed verified.
    private func outcome(after result: HeldActionResult, turn: TurnID?, reader: (any TodayTurnReading)?) -> DeliveryOutcome {
        let recorded = turn.flatMap { try? reader?.turnEntry($0) }?.record.outcome
        switch result {
        case .inserted:
            if let recorded, recorded.writeReachedDestination { return recorded }
            let unconfirmed = DeliveryOutcome.delivered(verified: false, method: "")
            if let turn { reader?.recordInsertion(turn, outcome: unconfirmed) }
            return unconfirmed
        case .copied, .discarded, .unavailable, .unknownItem:
            return recorded ?? .failed(reason: "every method threw")
        }
    }

    /// Copy, acknowledged only when verified: write, read back, resolve, read back again. A copy
    /// that is not verified keeps the draft held and says so (D08).
    @discardableResult
    public func copy(_ draft: TodayDraft) -> Bool {
        let board = services.pasteboard
        guard board.copyVerified(draft.text) else {
            draftNotices[draft.id] = .problem(.D08)
            return false
        }
        resolve(draft, .copy)
        // Resolving through the held queue writes the pasteboard again; believe only a read.
        guard board.read() == draft.text else {
            notice = .problem(.D08)
            return false
        }
        draftNotices[draft.id] = nil
        notice = .copied
        return true
    }

    /// Discard. The only saved copy (history off, or text no turn keeps) asks first — the view calls
    /// this only after that confirmation. With history on the turn stays in history as "Not inserted".
    public func discard(_ draft: TodayDraft) {
        resolve(draft, .discard)
        notice = nil
    }

    /// Discard destroys the only saved copy when history is off or no turn keeps the words.
    public func discardNeedsConfirmation(_ draft: TodayDraft) -> Bool {
        !historyEnabled || draft.turnID == nil
    }

    /// Copy / Discard through whichever queue holds the words, then the turn record.
    func resolve(_ draft: TodayDraft, _ action: HeldAction) {
        let reader = services.turns()
        if let heldID = draft.heldID, let item = heldProvider().first(where: { $0.id == heldID }) {
            _ = heldAction(item, action)
        } else if let turn = draft.turnID, let queue = services.injection(), let heldID = queue.heldID(forTurn: turn) {
            _ = action == .copy ? queue.copyHeld(heldID) : queue.discardHeld(heldID)
        }
        if let turn = draft.turnID {
            if action == .discard && !historyEnabled {
                // History is off: nothing else keeps these words, so they go.
                reader?.delete(turn)
            } else {
                reader?.markResolved(turn)
            }
        }
        refreshHeld()
    }

    /// Turn detail › Delete (after its confirmation): the turn, and any held copy of its words.
    public func deleteTurn(_ id: TurnID) {
        let reader = services.turns()
        if let draft = drafts.first(where: { $0.turnID == id }) {
            if let heldID = draft.heldID, let item = heldProvider().first(where: { $0.id == heldID }) {
                _ = heldAction(item, .discard)
            } else if let queue = services.injection(), let heldID = queue.heldID(forTurn: id) {
                _ = queue.discardHeld(heldID)
            }
        }
        reader?.delete(id)
        historyEntries.removeAll { $0.id == id }
        refreshHeld()
        applySearch()
    }
}

// MARK: - The page's actions and Spool note

/// What an empty or error rendering's one action does on Today.
public enum TodayStateAction: Equatable, Sendable {
    /// "Try dictation" — Settings › Shortcuts, where the key and its test live.
    case tryDictation
    /// "Review retention" (history off) — Privacy.
    case reviewRetention
    /// "Clear search" (no matches).
    case clearSearch
    /// "Try again" (S01) — the history read, scoped.
    case retry
    case none
}

extension TodaySectionViewModel {
    public func stateAction(for state: SectionState) -> TodayStateAction {
        switch state.actionTitle {
        case DesignScreen.today.empty.action?: return .tryDictation
        case TodayCopy.reviewRetention?: return .reviewRetention
        case TodayCopy.clearSearch?: return .clearSearch
        case RecoveryCatalog.entry(.S01).action?: return .retry
        default: return .none
        }
    }

    /// The prototype's Spool surface note over Today's content — "Spool · Ready when you are.
    /// Microphone closed." — shown only while it is true (every readiness row ready). When something
    /// is not ready the page shows what needs attention instead, and no note claims otherwise.
    var spoolNote: (pose: SpoolStateKey, text: String)? {
        guard blockers.isEmpty, let cameo = SpoolSurfacePolicy.cameo(screen: .today, variant: .content),
              let note = cameo.note else { return nil }
        return (cameo.key, note)
    }
}
