import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// S7b — Today (design §8.1, §9; DESIGN.md §9.1): held / recoverable text first, then recent
// dictations read from the turn store, each with an explicit tag; one base rendering per state;
// search over retained history only; Copy acknowledged only when verified; Discard confirmed when it
// destroys the only saved copy. Everything is driven through stubs of `TodayTurnReading`,
// `TodayPasteboard`, `RecoveryDestinations` and `TodayInjectionQueue` — no window server, no AX.

// MARK: - Stubs shared by the S7b suites

final class S7bTurns: TodayTurnReading, @unchecked Sendable {
    private let lock = NSLock()
    var entries: [TurnEntry]
    var failure: Error?
    var persistenceValue: TurnStore.Persistence = .keptUntilResolved
    var failedSaves: Set<TurnID> = []
    /// Holds `recentTurns` open until signalled, so the loading rendering can be observed.
    var block: DispatchSemaphore?
    private(set) var resolved: [TurnID] = []
    private(set) var insertions: [(TurnID, DeliveryOutcome)] = []
    private(set) var deleted: [TurnID] = []
    struct Boom: Error {}

    init(_ entries: [TurnEntry] = []) { self.entries = entries }

    func recentTurns(limit: Int) throws -> [TurnEntry] {
        block?.wait()
        return try lock.withLock {
            if let failure { throw failure }
            return Array(entries.sorted { $0.record.startedAt > $1.record.startedAt }.prefix(limit))
        }
    }

    func recoverableTurns(limit: Int) -> [TurnEntry] {
        lock.withLock { entries.filter(TodayDraft.isRecoverable).sorted { $0.record.startedAt > $1.record.startedAt } }
    }

    func turnEntry(_ id: TurnID) throws -> TurnEntry? {
        try lock.withLock {
            if let found = entries.first(where: { $0.id == id }) { return found }
            if let failure { throw failure }
            return nil
        }
    }

    var persistence: TurnStore.Persistence { persistenceValue }
    func saveFailed(_ id: TurnID) -> Bool { lock.withLock { failedSaves.contains(id) } }

    func markResolved(_ id: TurnID) {
        lock.withLock {
            resolved.append(id)
            if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].stage = .resolved }
        }
    }

    func recordInsertion(_ id: TurnID, outcome: DeliveryOutcome) {
        lock.withLock {
            insertions.append((id, outcome))
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].record.outcome = outcome
                entries[i].stage = outcome.isHeld ? .held : (outcome.writeReachedDestination ? .landed : .failed)
            }
        }
    }

    func delete(_ id: TurnID) {
        lock.withLock {
            deleted.append(id)
            entries.removeAll { $0.id == id }
        }
    }

    /// Replaces a turn's stage and outcome, as the turn controller would after a held resolution.
    func settle(_ id: TurnID, stage: TurnStage, outcome: DeliveryOutcome?) {
        lock.withLock {
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[i].stage = stage
            entries[i].record.outcome = outcome
        }
    }
}

final class S7bPasteboard: TodayPasteboard {
    var contents: String?
    var refuses = false
    /// Another app changes the pasteboard right after every write.
    var tampered: String?
    private(set) var writes: [String] = []

    func write(_ text: String) -> Bool {
        writes.append(text)
        guard !refuses else { return false }
        contents = tampered ?? text
        return true
    }

    func read() -> String? { contents }
}

@MainActor
final class S7bDestinations: RecoveryDestinations {
    var canReadFields = true
    var picked: RecoveryTarget?
    /// What has focus once the picked app is brought forward; nil = it never came forward.
    var afterForward: RecoveryTarget?
    var forwardFollowsPick = true
    private(set) var forwarded: [RecoveryTarget] = []
    private(set) var openedSettings = 0

    func pickedTarget() -> RecoveryTarget? { picked }

    func bringForward(_ target: RecoveryTarget) async -> RecoveryTarget? {
        forwarded.append(target)
        return forwardFollowsPick ? target : afterForward
    }

    func openAccessibilitySettings() { openedSettings += 1 }
}

@MainActor
final class S7bQueue: TodayInjectionQueue {
    var heldByTurn: [TurnID: UUID] = [:]
    var turnByHeld: [UUID: TurnID] = [:]
    var insertOutcome: DeliveryOutcome? = .delivered(verified: true, method: "ax")
    private(set) var insertedHeld: [UUID] = []
    private(set) var insertedText: [(String, RecoveryTarget)] = []
    private(set) var copied: [UUID] = []
    private(set) var discarded: [UUID] = []

    func turn(ofHeld id: UUID) -> TurnID? { turnByHeld[id] }
    func heldID(forTurn turn: TurnID) -> UUID? { heldByTurn[turn] }
    func insertHeld(_ id: UUID) -> DeliveryOutcome? { insertedHeld.append(id); return insertOutcome }
    func insert(text: String, turn: TurnID?, expecting target: RecoveryTarget) -> DeliveryOutcome? {
        insertedText.append((text, target))
        return insertOutcome
    }
    func copyHeld(_ id: UUID) -> Bool { copied.append(id); return true }
    func discardHeld(_ id: UUID) -> Bool { discarded.append(id); return true }
}

/// Builds records and a Today view model around the stubs.
@MainActor
struct S7bRig {
    static let base = Date(timeIntervalSinceReferenceDate: 780_000_000)

    let turns: S7bTurns
    let pasteboard = S7bPasteboard()
    let destinations = S7bDestinations()
    let queue = S7bQueue()
    let settings = InMemorySettingsStore()
    let model: TodaySectionViewModel
    private let box: Box

    /// Reference box so the view model's closures see the rig's current held list and results.
    final class Box {
        var held: [HeldItem] = []
        var actions: [(HeldItem, HeldAction)] = []
        var result: HeldActionResult = .inserted
    }

    init(_ entries: [TurnEntry] = [], held: [HeldItem] = [], turnsAvailable: Bool = true) {
        let turns = S7bTurns(entries)
        self.turns = turns
        let box = Box()
        box.held = held
        self.box = box
        var deps = OnboardingDependencies.mock()
        deps.settingsStore = self.settings
        let board = self.pasteboard, places = self.destinations, injector = self.queue, store = self.settings
        let services = TodayServices(turns: { turnsAvailable ? turns : nil },
                                     historyEnabled: { TodayHistorySettings.isEnabled(store) },
                                     injection: { injector },
                                     pasteboard: board,
                                     destinations: { places },
                                     turnsDidChange: Notification.Name("S7bTests.\(UUID().uuidString)"))
        model = TodaySectionViewModel(deps: deps,
                                      audio: AudioInputSettingsViewModel(defaults: UserDefaults(suiteName: "vp.s7b.\(UUID().uuidString)")!),
                                      mute: InMemoryMuteStore(),
                                      reader: nil,
                                      ambientCaptureOn: { false },
                                      heldProvider: { box.held },
                                      heldAction: { item, action in
                                          box.actions.append((item, action))
                                          if box.result != .unavailable { box.held.removeAll { $0.id == item.id } }
                                          return box.result
                                      },
                                      services: services)
    }

    var liveHeld: [HeldItem] {
        get { box.held }
        nonmutating set { box.held = newValue }
    }
    var actions: [(HeldItem, HeldAction)] { box.actions }
    func setHeldResult(_ result: HeldActionResult) { box.result = result }

    static func record(_ text: String, app: String? = "Mail", minutes: Double = 0, raw: String? = nil,
                       spans: [Range<Int>] = [], outcome: DeliveryOutcome? = nil) -> TurnRecord {
        TurnRecord(turnID: TurnID(), startedAt: base.addingTimeInterval(minutes * 60),
                   destination: .init(bundleID: "com.example.\(app ?? "none")", appName: app, role: "AXTextArea"),
                   rawText: raw ?? text, finalText: text, uncertainSpans: spans, outcome: outcome)
    }

    static func entry(_ record: TurnRecord, _ stage: TurnStage, persisted: Bool = true) -> TurnEntry {
        TurnEntry(record: record, stage: stage, updatedAt: record.startedAt, persisted: persisted)
    }
}

// MARK: - Today

@Suite("Today — held first, then recent dictations (S7b)")
@MainActor
struct TodayS7bTests {
    typealias Rig = S7bRig

    static let key = HotkeyService.defaultBinding.kind.label

    @Test("held and partial text comes first; recent rows are newest first with explicit tags")
    func heldFirstThenRows() async {
        let inserted = Rig.entry(Rig.record("The launch checklist is ready.", app: "Notes", minutes: 1,
                                            outcome: .delivered(verified: true, method: "ax")), .landed)
        let review = Rig.entry(Rig.record("Can we meet with Mira on Friday?", minutes: 5, spans: [17..<21],
                                          outcome: .delivered(verified: true, method: "paste")), .landed)
        let unconfirmed = Rig.entry(Rig.record("Open the configuration file.", app: "Editor", minutes: 2,
                                               outcome: .delivered(verified: false, method: "keystroke")), .landed)
        let partial = Rig.entry(Rig.record("Half of this landed.", app: "Slack", minutes: 3,
                                           outcome: .partial(method: "keystroke")), .landed)
        let held = Rig.entry(Rig.record("Text for Mail.", minutes: 4, outcome: .held(reason: "destination changed")), .held)
        let cancelled = Rig.entry(Rig.record("never mind", minutes: 6), .cancelled)
        let live = Rig.entry(Rig.record("still talking", minutes: 7), .listening)
        let rig = Rig([inserted, review, unconfirmed, partial, held, cancelled, live])
        await rig.model.reloadHistory()

        #expect(rig.model.page.isContent)
        #expect(rig.model.drafts.map(\.text) == ["Text for Mail.", "Half of this landed."], "held first, newest first")
        #expect(rig.model.drafts.map(\.kind) == [.held, .partial])
        #expect(rig.model.drafts[0].headline == "Text waiting for Mail")
        #expect(rig.model.drafts[0].consequence == "Destination changed. Nothing was inserted.")
        #expect(rig.model.drafts[1].headline == "Only part may have been inserted in Slack")

        // Chronological, newest first; still-live and cancelled turns are not history rows.
        #expect(rig.model.recent.map(\.excerpt) == ["Can we meet with Mira on Friday?", "Text for Mail.",
                                                    "Half of this landed.", "Open the configuration file.",
                                                    "The launch checklist is ready."])
        #expect(rig.model.recent.map(\.tag.label) == ["1 to review", "Held", "Unconfirmed", "Unconfirmed", "Inserted"])
        #expect(rig.model.recent[0].tag.opensTurn, "“1 to review” opens the turn")
        #expect(rig.model.recent[4].subtitle(timeStyle: { _ in "11:08" }) == "11:08 · Notes")
        #expect(rig.model.recent.allSatisfy { !$0.destination.isEmpty })
    }

    @Test("the tag table: DESIGN.md §4 Today tags, delivery evidence before review")
    func tagTable() {
        func tag(_ stage: TurnStage, _ outcome: DeliveryOutcome?, spans: [Range<Int>] = []) -> TodayTag? {
            TodayTag.of(Rig.entry(Rig.record("words here", spans: spans, outcome: outcome), stage))
        }
        #expect(tag(.landed, .delivered(verified: true, method: "ax")) == .inserted)
        #expect(tag(.landed, .delivered(verified: true, method: "ax"), spans: [0..<5, 6..<10]) == .toReview(2))
        #expect(tag(.landed, .delivered(verified: false, method: "ax"), spans: [0..<5]) == .unconfirmed,
                "an unconfirmed write says so even with an uncertain word")
        #expect(tag(.landed, .partial(method: "keystroke")) == .unconfirmed, "DESIGN.md §4: partial → Unconfirmed")
        #expect(tag(.held, .held(reason: "destination changed")) == .held)
        #expect(tag(.resolved, .held(reason: "destination changed")) == .notInserted, "copied or discarded held text")
        #expect(tag(.resolved, .partial(method: "keystroke")) == .unconfirmed, "a resolved partial is still partial")
        #expect(tag(.resolved, .delivered(verified: true, method: "ax")) == .undone)
        #expect(tag(.failed, .failed(reason: "every method threw")) == .notInserted)
        for stage in [TurnStage.starting, .listening, .listeningQuiet, .finishing, .finalPreview, .inserting,
                      .cancelled, .empty, .consumed] {
            #expect(tag(stage, nil) == nil, "\(stage) is not a history row")
        }
        #expect(TodayTag.inserted.tone == .good && TodayTag.held.tone == .warn && TodayTag.unconfirmed.tone == .warn)
        #expect(TodayTag.toReview(1).label == "1 to review")
    }

    @Test("empty: “Nothing dictated yet” with the configured key and Try dictation — never the old default key")
    func emptyNamesTheKey() async {
        let rig = Rig()
        await rig.model.reloadHistory()
        #expect(rig.model.page.rendering == .empty)
        #expect(rig.model.page.headline == "Nothing dictated yet")
        #expect(rig.model.page.detail == "Hold \(Self.key) and say something. Your recent words will appear here.")
        #expect(rig.model.page.actionTitle == "Try dictation")
        #expect(rig.model.page == SectionState.empty(.today, hotkey: Self.key))
        #expect(!(rig.model.page.detail ?? "").contains("Right Control"))
        #expect(rig.model.stateAction(for: rig.model.page) == .tryDictation)
        #expect(rig.model.page.isWellFormed)
    }

    @Test("history off is its own explained empty, not “No results” — and search does not change that")
    func historyOffVariant() async {
        let rig = Rig([Rig.entry(Rig.record("kept words", outcome: .delivered(verified: true, method: "ax")), .landed)])
        TodayHistorySettings.setEnabled(false, store: rig.settings)
        await rig.model.reloadHistory()
        #expect(rig.model.page.rendering == .empty)
        #expect(rig.model.page.headline == TodayCopy.historyOff)
        #expect(rig.model.page.actionTitle == "Review retention")
        #expect(rig.model.stateAction(for: rig.model.page) == .reviewRetention)
        #expect(rig.model.recent.isEmpty, "nothing is listed when history is off")
        await rig.model.searchChanged("kept")
        #expect(rig.model.page.headline == TodayCopy.historyOff, "search on history-off is not “No matches”")
        #expect(rig.model.page.isWellFormed)
    }

    @Test("history off still shows held text first, explained by its own retention")
    func historyOffKeepsHeld() async {
        let held = Rig.entry(Rig.record("held words", outcome: .held(reason: "destination changed")), .held)
        let rig = Rig([held])
        TodayHistorySettings.setEnabled(false, store: rig.settings)
        await rig.model.reloadHistory()
        #expect(rig.model.page.isContent)
        #expect(rig.model.drafts.count == 1)
        #expect(rig.model.drafts[0].retention.label == "Kept until resolved")
        #expect(rig.model.history.headline == TodayCopy.historyOff, "the recent group explains itself inline")
    }

    @Test("loading reads “Loading recent dictations…”, never the empty copy")
    func loadingIsNotEmpty() async {
        let rig = Rig([Rig.entry(Rig.record("hello", outcome: .delivered(verified: true, method: "ax")), .landed)])
        let gate = DispatchSemaphore(value: 0)
        rig.turns.block = gate
        #expect(rig.model.history.rendering == .loading, "first frame is loading, not empty")
        let running = Task { await rig.model.reloadHistory() }
        for _ in 0..<20 where rig.model.page.rendering != .loading { await Task.yield() }
        #expect(rig.model.page.rendering == .loading)
        #expect(rig.model.page.headline == "Loading recent dictations…")
        #expect(rig.model.page.detail == SectionCopy.loadingNote)
        #expect(rig.model.page.actionTitle == nil)
        gate.signal()
        await running.value
        #expect(rig.model.page.isContent)
        #expect(rig.model.recent.count == 1)
    }

    @Test("“History can’t be read” + Try again; held drafts stay on screen beside it")
    func errorKeepsHeldDrafts() async {
        let rig = Rig()
        rig.turns.failure = S7bTurns.Boom()
        await rig.model.reloadHistory()
        #expect(rig.model.page.rendering == .error)
        #expect(rig.model.page.headline == "History can’t be read")
        #expect(rig.model.page.detail == "Other working sections remain available.")
        #expect(rig.model.page.actionTitle == "Try again")
        #expect(rig.model.page.recoveryID == .S01)
        #expect(rig.model.stateAction(for: rig.model.page) == .retry)
        await rig.model.searchChanged("anything")
        #expect(rig.model.page.rendering == .error, "a search never turns an unreadable history into an empty one")

        // Held text never disappears because history can't be read.
        let rig2 = Rig([Rig.entry(Rig.record("held words", outcome: .held(reason: "destination changed")), .held)])
        rig2.turns.failure = S7bTurns.Boom()
        await rig2.model.reloadHistory()
        #expect(rig2.model.page.isContent)
        #expect(rig2.model.drafts.map(\.text) == ["held words"])
        #expect(rig2.model.history.rendering == .error)
        #expect(rig2.model.history.headline == "History can’t be read")
    }

    @Test("no turn store at all is “can’t be read”, not “Nothing dictated yet”")
    func noStoreIsNotEmpty() async {
        let rig = Rig(turnsAvailable: false)
        await rig.model.reloadHistory()
        #expect(rig.model.page.rendering == .error)
        #expect(rig.model.page.recoveryID == .S01)
    }

    @Test("partial: a refresh that fails keeps its rows and scopes the failure to a banner; retry is scoped")
    func partialAndRetry() async {
        let rig = Rig([Rig.entry(Rig.record("kept", outcome: .delivered(verified: true, method: "ax")), .landed)])
        await rig.model.reloadHistory()
        #expect(rig.model.recent.count == 1)
        rig.turns.failure = S7bTurns.Boom()
        await rig.model.reloadHistory()
        #expect(rig.model.page.isContent)
        #expect(rig.model.recent.count == 1, "rows already read stay")
        #expect(rig.model.historyBanner?.headline == "History can’t be read")
        #expect(rig.model.historyBanner?.recoveryID == .S01)
        #expect(rig.model.historyBanner?.diagnostics != nil, "raw detail only behind Copy diagnostics")

        rig.turns.failure = nil
        #expect(!rig.model.historyRetry.isRetrying)
        await rig.model.retryHistory()
        #expect(rig.model.historyBanner == nil)
        #expect(!rig.model.historyRetry.isRetrying)
    }

    @Test("search covers retained history only: text and app match; no match says so with Clear search")
    func searchRetainedHistory() async {
        let rig = Rig([
            Rig.entry(Rig.record("Can we meet on Friday?", minutes: 2, outcome: .delivered(verified: true, method: "ax")), .landed),
            Rig.entry(Rig.record("Ship the build", app: "Terminal", minutes: 1, outcome: .delivered(verified: true, method: "ax")), .landed),
            Rig.entry(Rig.record("Crème brûlée recipe", app: "Notes", minutes: 0, outcome: .delivered(verified: true, method: "ax")), .landed),
        ])
        await rig.model.reloadHistory()
        await rig.model.searchChanged("friday")
        #expect(rig.model.recent.map(\.excerpt) == ["Can we meet on Friday?"])
        await rig.model.searchChanged("terminal")
        #expect(rig.model.recent.map(\.destination) == ["Terminal"], "the destination app is searchable")
        await rig.model.searchChanged("creme")
        #expect(rig.model.recent.count == 1, "diacritics don't hide a match")
        await rig.model.searchChanged("zebra")
        #expect(rig.model.page.rendering == .empty)
        #expect(rig.model.page.headline == "No matches for “zebra”")
        #expect(rig.model.page.actionTitle == "Clear search")
        #expect(rig.model.stateAction(for: rig.model.page) == .clearSearch)
        await rig.model.clearHistorySearch()
        #expect(rig.model.search.isEmpty)
        #expect(rig.model.recent.count == 3)
    }

    @Test("Copy is acknowledged only when the pasteboard reads back the text; otherwise the draft stays (D08)")
    func copyVerifiedOnly() async throws {
        let heldEntry = Rig.entry(Rig.record("Can we meet?", outcome: .held(reason: "destination changed")), .held)
        let rig = Rig([heldEntry])
        await rig.model.reloadHistory()
        let draft = try #require(rig.model.drafts.first)

        rig.pasteboard.tampered = "something else"
        #expect(rig.model.copy(draft) == false)
        #expect(rig.model.notice == nil, "no “Copied” without verification")
        #expect(rig.model.draftNotices[draft.id]?.recoveryID == .D08)
        #expect(rig.model.draftNotices[draft.id]?.text == "Couldn’t copy your text")
        #expect(rig.turns.resolved.isEmpty, "an unverified copy resolves nothing")
        #expect(rig.model.drafts.count == 1)

        rig.pasteboard.tampered = nil
        #expect(rig.model.copy(draft))
        #expect(rig.model.notice == .copied)
        #expect(rig.pasteboard.contents == "Can we meet?")
        #expect(rig.turns.resolved == [heldEntry.id], "a verified copy resolves the held turn (not an insertion)")
        #expect(rig.model.drafts.isEmpty)
    }

    @Test("Copy through the pill's queue resolves that row too, and still verifies")
    func copyThroughLiveQueue() async {
        let turn = TurnID()
        var record = Rig.record("live held words", outcome: .held(reason: "destination changed"))
        record.turnID = turn
        let item = HeldItem(text: "live held words", destination: "Mail", reason: "destination changed")
        let rig = Rig([Rig.entry(record, .held)], held: [item])
        rig.queue.turnByHeld[item.id] = turn
        await rig.model.reloadHistory()
        #expect(rig.model.drafts.count == 1, "the turn and its live item are one draft")
        #expect(rig.model.drafts[0].heldID == item.id)
        #expect(rig.model.copy(rig.model.drafts[0]))
        #expect(rig.actions.map { $0.1 } == [.copy])
    }

    @Test("a live held item no turn accounts for is still shown, and is the only saved copy")
    func unclaimedLiveItem() async throws {
        let item = HeldItem(text: "latch words", destination: "Notes", reason: "never-inject list")
        let rig = Rig(held: [item])
        await rig.model.reloadHistory()
        let draft = try #require(rig.model.drafts.first)
        #expect(draft.turnID == nil && draft.heldID == item.id)
        #expect(draft.retention == .sessionOnly)
        #expect(draft.headline == "Text waiting for Notes")
        #expect(draft.consequence == "Dictation is off in this app. Nothing was inserted.")
        #expect(rig.model.discardNeedsConfirmation(draft), "no turn keeps these words")
    }

    @Test("Discard confirms only when it destroys the only saved copy")
    func discardConfirmation() async throws {
        let held = Rig.entry(Rig.record("held words", outcome: .held(reason: "destination changed")), .held)
        let rig = Rig([held])
        await rig.model.reloadHistory()
        let draft = try #require(rig.model.drafts.first)
        #expect(!rig.model.discardNeedsConfirmation(draft), "history keeps the turn, so this is not the only copy")
        rig.model.discard(draft)
        #expect(rig.turns.resolved == [held.id])
        #expect(rig.turns.deleted.isEmpty)

        let held2 = Rig.entry(Rig.record("private words", outcome: .held(reason: "destination changed")), .held)
        let off = Rig([held2])
        TodayHistorySettings.setEnabled(false, store: off.settings)
        await off.model.reloadHistory()
        let draft2 = try #require(off.model.drafts.first)
        #expect(off.model.discardNeedsConfirmation(draft2), "history off: this is the only saved copy")
        off.model.discard(draft2)
        #expect(off.turns.deleted == [held2.id], "the only copy goes when the user discards it")
    }

    @Test("the Spool note says “Ready when you are” only while it is true; blockers replace it")
    func spoolNoteIsTruthful() async {
        let rig = Rig()
        if rig.model.blockers.isEmpty {
            #expect(rig.model.spoolNote?.pose == .ready)
            #expect(rig.model.spoolNote?.text == "Spool · Ready when you are. Microphone closed.")
        } else {
            #expect(rig.model.spoolNote == nil, "not ready → no “Ready when you are”")
        }
        let muted = InMemoryMuteStore(muted: true)
        var deps = OnboardingDependencies.mock()
        deps.settingsStore = InMemorySettingsStore()
        let model = TodaySectionViewModel(deps: deps, mute: muted, ambientCaptureOn: { false },
                                          services: TodayServices(turns: { nil }, historyEnabled: { true }))
        #expect(!model.blockers.isEmpty)
        #expect(model.spoolNote == nil)
        #expect(TodaySectionCopy.route(forReadiness: "mute") == WindowRoute(.privacy))
        #expect(TodaySectionCopy.route(forReadiness: "model") == .settings(.models))
    }

    @Test("every Today state is well formed and all four renderings are reachable")
    func everyStateWellFormed() async {
        var states: [SectionState] = []
        let empty = Rig(); await empty.model.reloadHistory(); states.append(empty.model.page)
        let broken = Rig(); broken.turns.failure = S7bTurns.Boom(); await broken.model.reloadHistory(); states.append(broken.model.page)
        let content = Rig([Rig.entry(Rig.record("x y", outcome: .delivered(verified: true, method: "ax")), .landed)])
        await content.model.reloadHistory(); states.append(content.model.page)
        states.append(Rig().model.page)   // before the first read: loading
        for state in states { #expect(state.isWellFormed, "\(state.rendering): \(state.headline)") }
        #expect(Set(states.map(\.rendering)) == Set(SectionRendering.allCases))
    }

    @Test("formatting: excerpts, titles, words and the turn subtitle never leak tokens")
    func formatting() {
        #expect(TodayFormat.title("Can we meet with Mira on Friday?") == "Can we meet with Mira on…")
        #expect(TodayFormat.title("Ship it.") == "Ship it")
        #expect(TodayFormat.title("   ") == TodayCopy.untitledTurn)
        #expect(TodayFormat.words(1) == "1 word" && TodayFormat.words(9) == "9 words")
        let long = String(repeating: "word ", count: 40)
        #expect(TodayFormat.excerpt(long).hasSuffix("…") && TodayFormat.excerpt(long).count <= 73)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let record = S7bRig.record("Can we meet with Mira on Friday next week please", minutes: 0)
        let subtitle = TodayFormat.turnSubtitle(record, calendar: calendar, now: record.startedAt, timeStyle: { _ in "12:42" })
        #expect(subtitle == "Mail · Today, 12:42 · 10 words")
        var noApp = record
        noApp.destination.appName = nil
        #expect(TodayFormat.destination(noApp) == "Unknown app", "never a bundle ID in copy")
        #expect(TodayFormat.words(in: "Can we meet with Mira", spans: [17..<21, 40..<50]) == ["Mira"])
        #expect(TurnTextMarks.ranges(in: "Can we meet with Mira", spans: [17..<21, -1..<2, 3..<3, 19..<99])
                == [NSRange(location: 17, length: 4)])
    }

    @Test("Today draws no vanity counters: no stats, totals or words-today on the page")
    func noVanityCounters() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["App/Settings/TodaySectionView.swift", "App/Settings/TodayScreen.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for counter in ["stats(", "wordsToday", "zeroEdit", ".count)"] {
                #expect(!source.contains(counter), "\(file) draws \(counter)")
            }
        }
    }
}
