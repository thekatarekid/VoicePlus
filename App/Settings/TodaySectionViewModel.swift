import Engine
import Foundation
import Shared

// R7.1 — Today / Timeline (`DESIGN.md` §9.1): what the app is ready to do right now, what still
// needs a hand, and what was said recently — in that order, because readiness and pending recovery
// are what a person opens this window for (V3 §9.4).
//
// S7b adds the design's Today (design §8.1): held / recoverable turns first, then recent dictations
// from the turn store, the turn detail and the recovery sheet — `TodaySectionViewModel+Turns.swift`.
// The readiness strip below still feeds the sidebar footer and Today's "Needs attention" group; the
// ambient Timeline below is one group of the page while ambient capture is on.
//
// The readiness strip is computed from cached state and is *never* blank: §9.1 forbids a loading
// state for it. Only the Timeline list loads, and the Timeline's store does not exist yet (it is
// R8's `AmbientTimeline`), so this view model takes a reader and renders "Timeline is off" until
// one is installed — the honest empty, never a blank list with no explanation.

/// One row of the Timeline: time, source, transcript. R8 fills these in; the shape is fixed here so
/// the section's states can be built and tested before the store exists.
public struct TimelineRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var source: String
    public var text: String

    public init(id: String = UUID().uuidString, time: Date, source: String, text: String) {
        self.id = id
        self.time = time
        self.source = source
        self.text = text
    }
}

/// What R8's ambient transcript store has to offer this section. Absent (nil) means ambient capture
/// has never run on this Mac, which is a different sentence from "nothing was said today".
///
/// R8.3 added the query and source-listing calls, both with defaults in `TodayTimeline.swift`, so a
/// store that only knows how to match text still compiles and still filters correctly — just less
/// efficiently. Deleting goes through here and nowhere else: clearing the search indexes is the
/// store's job (R8.1/R8.2), and a second delete path in the view would be the one that forgets.
public protocol AmbientTimelineReading: AnyObject, Sendable {
    func rows(matching query: String) async throws -> [TimelineRow]
    /// Text *and* source filters. Default: `rows(matching: String)` plus a source filter here.
    func rows(matching query: TimelineQuery) async throws -> [TimelineRow]
    /// Every source the store holds, independent of the current query. Default: `[]` — "no such
    /// index", and the section derives the filter row from the rows it has seen instead.
    func sources() async throws -> [TimelineSource]
    func delete(id: String) throws
    func deleteAll() throws
}

/// Today / Timeline. Pure state: no AppKit, no SwiftUI, so every rendering is assertable.
@MainActor
public final class TodaySectionViewModel: ObservableObject {
    /// One line of the readiness strip: a glyph, a word, and — where it is not ready — one action.
    /// Colour is never the only signal (`DESIGN.md` §12.9), which is why `word` is not optional.
    public struct ReadinessRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var glyph: String
        public var label: String
        public var word: String
        public var detail: String
        public var actionTitle: String?
        public var isReady: Bool
    }

    @Published public private(set) var readiness: [ReadinessRow] = []
    @Published public private(set) var held: [HeldItem] = []
    /// Per-row failures on the held list: a re-insert that failed keeps its row and gains one line
    /// (`DESIGN.md` §9.1), rather than the section flipping to an error.
    @Published public private(set) var heldRowErrors: [UUID: String] = [:]
    @Published public private(set) var timelineRows: [TimelineRow] = []
    @Published public private(set) var timeline: SectionState = .loading()
    @Published public private(set) var banner: SectionBanner?
    @Published public var search = ""
    /// The source filter row: every source the store holds (or, failing that, every source seen).
    @Published public private(set) var availableSources: [TimelineSource] = []
    /// Ticked sources. Empty = every source, which is why an untouched filter row hides nothing.
    @Published public private(set) var selectedSources: Set<String> = []
    /// Rows whose delete is in flight, so a row can say "Deleting…" without the section pretending
    /// it is already gone.
    @Published public private(set) var deletingRows: Set<String> = []
    /// A destructive scope waiting for a yes (`DESIGN.md` §5.2). Nil = nothing pending.
    @Published public private(set) var confirmation: TimelineConfirmation?
    /// Sources seen in any read this session — the fallback filter row for a store with no index.
    private var seenSources: Set<String> = []
    /// Read generation, so a slow read that has been superseded cannot land its rows on top of a
    /// newer one (type a letter, then another: the first answer must not win).
    private var readGeneration = 0

    // MARK: S7b — held text first, then recent dictations (design §8.1; `TodaySectionViewModel+Turns`)

    /// Held and partial text, newest first — shown before anything else, and kept on screen when
    /// history is off or cannot be read.
    @Published public internal(set) var drafts: [TodayDraft] = []
    /// "Recent dictations": the turns history keeps, filtered by the search.
    @Published public internal(set) var recent: [TodayTurnRow] = []
    /// The recent list's own rendering: loading / empty (nothing yet, history off, no matches) /
    /// error (S01) / content. `page` decides whether it is the whole page or one group of it.
    @Published public internal(set) var history: SectionState = .loading(.today, headline: TodayCopy.loadingRecent)
    /// A history read that failed with rows already on screen: they stay, the failure is scoped here.
    @Published public internal(set) var historyBanner: SectionBanner?
    /// A draft's own line: a copy that could not be verified (D08) keeps the draft and says so.
    @Published public internal(set) var draftNotices: [String: TodayNotice] = [:]
    /// The last page-level acknowledgement ("Copied…"), shown only after verification.
    @Published public internal(set) var notice: TodayNotice?
    /// Whether the ambient Timeline group is on the page (ambient capture on).
    @Published public internal(set) var ambientVisible = false
    /// The recovery sheet on screen, if any. Closing it keeps the draft (design §8.1).
    @Published public var recovery: RecoverySheetModel?
    /// The turn detail on screen instead of the list, if any.
    @Published public var detail: TurnDetailModel?
    /// Retry for the history read: scoped, disabled while it runs (design §9).
    public let historyRetry = ScopedRetry()

    let services: TodayServices
    var historyEntries: [TurnEntry] = []
    var historyGeneration = 0
    var historyLoadedOnce = false
    var turnsReload: Task<Void, Never>?

    let deps: OnboardingDependencies
    private let mute: any MuteStore
    private let audio: AudioInputSettingsViewModel
    private let reader: (any AmbientTimelineReading)?
    let ambientCaptureOn: () -> Bool
    let heldProvider: () -> [HeldItem]
    let heldAction: (HeldItem, HeldAction) -> HeldActionResult

    /// `services` defaults to the app's (`TodayServices.live`): the turn store, the live held queue,
    /// the general pasteboard and the real frontmost app.
    public init(deps: OnboardingDependencies,
                audio: AudioInputSettingsViewModel? = nil,
                mute: any MuteStore = UserDefaultsMuteStore(),
                reader: (any AmbientTimelineReading)? = nil,
                ambientCaptureOn: @escaping () -> Bool,
                heldProvider: @escaping () -> [HeldItem] = { [] },
                heldAction: @escaping (HeldItem, HeldAction) -> HeldActionResult = { _, _ in .unavailable },
                services: TodayServices? = nil) {
        self.deps = deps
        self.audio = audio ?? AudioInputSettingsViewModel()
        self.mute = mute
        self.reader = reader
        self.ambientCaptureOn = ambientCaptureOn
        self.heldProvider = heldProvider
        self.heldAction = heldAction
        self.services = services ?? .live(settings: deps.settingsStore, database: deps.database)
        refreshReadiness()
        refreshHeld()
    }

    // MARK: Readiness strip — cached state only, so it renders on the first frame

    public func refreshReadiness() {
        readiness = [keyRow, microphoneRow, modelRow, muteRow]
    }

    /// Resolved the way `GeneralSettingsViewModel` resolves it — the binding key the hotkey service
    /// actually reads wins over the older `SettingsKeys.hotkey` mirror.
    public var dictationKey: HotkeyChoice {
        deps.settingsStore.string(HotkeyService.bindingDefaultsKey).flatMap(HotkeyChoice.init(rawValue:))
            ?? deps.settingsStore.string(SettingsKeys.hotkey).flatMap(HotkeyChoice.init(rawValue:))
            ?? .default
    }

    /// The configured key's label ("fn / 🌐"), resolved the way the window's hints resolve it
    /// (`MainWindowViewModel.hotkeyLabel`): the stored binding, else the default. Every "Right
    /// Control" in design copy renders as this (owner decision, build doc §0).
    public var dictationKeyName: String {
        let stored = deps.settingsStore.string(HotkeyService.bindingDefaultsKey).flatMap(HotkeyBinding.Kind.init(rawValue:))
        return (stored ?? HotkeyService.defaultBinding.kind).label
    }

    private var keyRow: ReadinessRow {
        let note = dictationKey.permissionNote
        let needsPermission = deps.hotkeyRequiresPermission != nil
        return ReadinessRow(id: "key", glyph: "keyboard", label: "Dictation key",
                            word: needsPermission ? "Needs permission" : "Ready",
                            detail: needsPermission ? note : "Hold \(dictationKeyName) and say something.",
                            actionTitle: needsPermission ? SectionCopy.openSystemSettings : nil,
                            isReady: !needsPermission)
    }

    private var microphoneRow: ReadinessRow {
        let status = deps.permissions.status(of: .microphone)
        if status == .denied || status == .awaitingUserAction {
            return ReadinessRow(id: "microphone", glyph: "mic.slash", label: "Microphone",
                                word: "Off", detail: SectionCopy.microphoneOff,
                                actionTitle: SectionCopy.openSystemSettings, isReady: false)
        }
        return ReadinessRow(id: "microphone", glyph: "mic", label: "Microphone",
                            word: audio.devices.isEmpty ? "None" : "Ready", detail: audio.note,
                            actionTitle: audio.devices.isEmpty ? SectionCopy.chooseMicrophone : nil,
                            isReady: !audio.devices.isEmpty)
    }

    private var modelRow: ReadinessRow {
        if deps.models.isStackInstalled {
            return ReadinessRow(id: "model", glyph: "checkmark.seal", label: "Speech model",
                                word: "Ready", detail: "Installed and running on this Mac.", isReady: true)
        }
        switch deps.models.stackReadiness {
        case .ready:
            return ReadinessRow(id: "model", glyph: "checkmark.seal", label: "Speech model",
                                word: "Ready", detail: "Installed and running on this Mac.", isReady: true)
        case .fallback(let name, _):
            return ReadinessRow(id: "model", glyph: "arrow.down.circle", label: "Speech model",
                                word: "Installing",
                                detail: "Using \(name) until the stack finishes — \(ByteText.short(deps.models.remainingStackBytes)) to go.",
                                isReady: false)
        case .unavailable(let reason):
            return ReadinessRow(id: "model", glyph: "exclamationmark.triangle", label: "Speech model",
                                word: "Not ready", detail: reason,
                                actionTitle: "Open Settings", isReady: false)
        }
    }

    private var muteRow: ReadinessRow {
        let muted = mute.loadMuted()
        return ReadinessRow(id: "mute", glyph: muted ? "mic.slash.circle" : "mic.circle",
                            label: "Mute", word: muted ? "Muted" : "Not muted",
                            detail: muted ? "The microphone stays shut until you unmute — it survives a relaunch."
                                          : "Dictation can open the microphone.",
                            actionTitle: muted ? "Unmute" : nil, isReady: !muted)
    }

    /// Everything in the readiness strip that is not ready, for the "needs a hand" count.
    public var blockers: [ReadinessRow] { readiness.filter { !$0.isReady } }

    // MARK: Needs you — the held queue (§9.1, R2.3/R2.4)

    public func refreshHeld() {
        held = heldProvider()
        heldRowErrors = heldRowErrors.filter { id, _ in held.contains { $0.id == id } }
        rebuildDrafts()
    }

    public func perform(_ action: HeldAction, on item: HeldItem) {
        switch heldAction(item, action) {
        case .inserted, .copied, .discarded:
            heldRowErrors[item.id] = nil
        case .unavailable, .unknownItem:
            heldRowErrors[item.id] = SectionCopy.heldRowFailed
        }
        refreshHeld()
    }

    public var heldState: SectionState {
        held.isEmpty
            ? .empty("Nothing is waiting", detail: "Text that couldn't be typed waits here with Insert here, Copy and Discard.")
            : .content
    }

    // MARK: Timeline — the query (R8.3)

    /// What the section is asking the store for right now: search text plus the ticked sources.
    public var query: TimelineQuery { TimelineQuery(text: search, sources: selectedSources) }

    /// The rows, grouped the way `DESIGN.md` §9.1 asks for them: newest day first, newest row first.
    public var timelineDays: [TimelineDay] { TimelineDay.group(timelineRows) }

    /// The search field changed (`⌘F`). One read per change; a superseded read cannot land (below).
    public func setSearch(_ text: String) async {
        search = text
        await reloadTimeline()
    }

    /// `⎋` in the search field, and the action on the "No matches" empty.
    public func clearSearch() async {
        guard !search.isEmpty else { return }
        await setSearch("")
    }

    /// Tick or untick one source. Ticking every known source is the same as ticking none — both mean
    /// "everything" — so the last tick collapses back to the unfiltered query rather than to a list
    /// that hides a future source nobody ticked.
    public func toggle(source id: String) async {
        if selectedSources.contains(id) {
            selectedSources.remove(id)
        } else {
            selectedSources.insert(id)
            if !availableSources.isEmpty, selectedSources.count == availableSources.count {
                selectedSources.removeAll()
            }
        }
        await reloadTimeline()
    }

    /// The action on the "Nothing from these sources" empty.
    public func showEverySource() async {
        guard !selectedSources.isEmpty else { return }
        selectedSources.removeAll()
        await reloadTimeline()
    }

    public func isSelected(source id: String) -> Bool {
        selectedSources.isEmpty || selectedSources.contains(id)
    }

    // MARK: Timeline — reading

    /// `DESIGN.md` §9.1's empties, its one static loading row, and its banner error — now with
    /// search's and the filter row's own empties, each naming the way back out of itself.
    public func reloadTimeline() async {
        guard ambientCaptureOn() else {
            timelineRows = []
            availableSources = []
            timeline = .empty(SectionCopy.timelineOff, detail: SectionCopy.timelineOffDetail, action: SectionCopy.openPrivacy)
            return
        }
        // Ambient capture is on and there is no store: that is not "Timeline is off" — saying so
        // would tell the user to turn on something that is already on.
        guard let reader else {
            timelineRows = []
            availableSources = []
            timeline = .error(SectionCopy.timelineStoreMissing, detail: SectionCopy.timelineStoreMissingDetail,
                              action: SectionCopy.openPrivacy)
            return
        }
        readGeneration += 1
        let generation = readGeneration
        let asked = query
        timeline = asked.isSearching ? .loading(SectionCopy.timelineSearching) : .loading()
        do {
            let rows = try await reader.rows(matching: asked)
            let sources = (try? await reader.sources()) ?? []
            // Type a letter, then another: the first answer must not land on top of the second.
            guard generation == readGeneration else { return }
            timelineRows = rows
            refreshSources(stored: sources, from: rows)
            banner = nil
            timeline = rows.isEmpty ? emptyState(for: asked) : .content
        } catch {
            guard generation == readGeneration else { return }
            // Partial data keeps its content and gains a banner; no data at all is the error state.
            if timelineRows.isEmpty {
                timeline = asked.isSearching
                    ? .error(SectionCopy.timelineSearchFailed, action: SectionCopy.tryAgain)
                    : .error(SectionCopy.timelineUnreadable, action: SectionCopy.openPrivacy)
            } else {
                timeline = .content
                banner = SectionBanner(headline: asked.isSearching ? SectionCopy.timelineSearchFailed
                                                                   : SectionCopy.timelineUnreadable,
                                       actionTitle: asked.isSearching ? SectionCopy.tryAgain : SectionCopy.openPrivacy,
                                       diagnostics: "\(error)")
            }
        }
    }

    /// Which empty this is. Three distinct ones, because "nothing here" and "nothing matches what you
    /// typed" and "nothing from the sources you picked" need three different ways out.
    private func emptyState(for asked: TimelineQuery) -> SectionState {
        if asked.isSearching {
            return .empty(SectionCopy.timelineNoMatches, detail: SectionCopy.timelineNoMatchesDetail(asked.text),
                          action: SectionCopy.clearSearch)
        }
        if !asked.isEverySource {
            return .empty(SectionCopy.timelineNoMatchingSource, detail: SectionCopy.timelineNoMatchingSourceDetail,
                          action: SectionCopy.showEverySource)
        }
        return .empty(SectionCopy.nothingDictated, detail: SectionCopy.nothingDictatedDetail(key: dictationKeyName))
    }

    /// The filter row: the store's own index when it keeps one, otherwise every source seen this
    /// session. Either way it only grows, so filtering to one source cannot make the others vanish.
    private func refreshSources(stored: [TimelineSource], from rows: [TimelineRow]) {
        seenSources.formUnion(rows.map(\.source))
        seenSources.formUnion(stored.map(\.id))
        seenSources.formUnion(selectedSources)
        availableSources = seenSources.map(TimelineSource.named).sorted()
    }

    // MARK: Timeline — delete and delete-all

    /// Ask first (`DESIGN.md` §5.2). Nothing is deleted until `confirm()`.
    public func askToDelete(rowID: String) {
        guard let row = timelineRows.first(where: { $0.id == rowID }) else { return }
        confirmation = .row(id: row.id, text: row.text)
    }

    public func askToDeleteEverything() {
        confirmation = .everything(count: timelineRows.count)
    }

    public func cancelConfirmation() { confirmation = nil }

    /// Performs the pending destructive action, if there is one.
    public func confirm() async {
        guard let pending = confirmation else { return }
        confirmation = nil
        if let rowID = pending.rowID {
            await delete(rowID: rowID)
        } else {
            await deleteEverything()
        }
    }

    /// Deletes one row **through the store** — the only delete path, so R8.1/R8.2's index clearing
    /// always runs — and then believes the store rather than itself: the row leaves the list because
    /// a fresh read no longer has it, never because the call returned.
    public func delete(rowID: String) async {
        guard let reader else {
            banner = SectionBanner(headline: SectionCopy.timelineRowNotDeleted, actionTitle: SectionCopy.tryAgain,
                                   diagnostics: SectionCopy.timelineStoreMissingDetail)
            return
        }
        deletingRows.insert(rowID)
        defer { deletingRows.remove(rowID) }
        do {
            try reader.delete(id: rowID)
        } catch {
            // The row keeps its place. Dropping it here would tell the user it is gone when it is not.
            banner = SectionBanner(headline: SectionCopy.timelineRowNotDeleted, actionTitle: SectionCopy.tryAgain,
                                   diagnostics: "\(error)")
            return
        }
        await reloadTimeline()
        if timelineRows.contains(where: { $0.id == rowID }) {
            banner = SectionBanner(headline: SectionCopy.timelineRowStillThere, actionTitle: SectionCopy.tryAgain)
        }
    }

    /// Delete-all, same rule: through the store, then verified by a read. "Some of it is still here"
    /// is the honest headline when the store kept something, and it is `DESIGN.md` §9.5's wording.
    public func deleteEverything() async {
        guard let reader else {
            banner = SectionBanner(headline: SectionCopy.deleteAllPartial, actionTitle: SectionCopy.tryAgain,
                                   diagnostics: SectionCopy.timelineStoreMissingDetail)
            return
        }
        do {
            try reader.deleteAll()
        } catch {
            banner = SectionBanner(headline: SectionCopy.deleteAllPartial, actionTitle: SectionCopy.tryAgain,
                                   diagnostics: "\(error)")
            return
        }
        await reloadTimeline()
        if !timelineRows.isEmpty {
            banner = SectionBanner(headline: SectionCopy.deleteAllPartial, actionTitle: SectionCopy.tryAgain)
        }
    }

    // MARK: Timeline — privacy line (V3 §9.6)

    /// What ambient capture captures, saves and transmits, and how long it keeps it. Never a claim of
    /// literal zero network bytes: the last clause points at the Privacy log instead.
    public var timelinePrivacyNote: String {
        let days = AmbientRetentionSettings.days(deps.settingsStore)
        return SectionCopy.timelinePrivacy + " " + SectionCopy.timelineRetention(days: days)
    }
}
