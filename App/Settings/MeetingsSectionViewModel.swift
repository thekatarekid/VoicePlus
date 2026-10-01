import Combine
import Engine
import Foundation
import Shared

// S7c — Meetings (design §8.2, §9; prototype `meetings` and `meeting-detail`): the library, one
// meeting's detail, the unfinished-recording recovery, and "Start recording", which opens capture
// through the app's one `MeetingCaptureController` — the same capture the expanded panel and the pill's
// Q0 / Q1 / Q2 rows show.
//
// Manual recording never waits on Calendar or on the meeting-detection opt-in (design §8.2: "Calendar
// connection is optional; no calendar does not block manual recording"). The opt-in stays here as an
// ordinary switch, and still never asks macOS for anything on its own (`MeetingCoordinator`).

@MainActor
public final class MeetingsSectionViewModel: ObservableObject {
    // MARK: Library
    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var facts: [String: MeetingCaptureFacts] = [:]
    /// The library's one base rendering (design §9 Meetings row).
    @Published public private(set) var state: SectionState = .loading(.meetings)
    /// Partial failure: meetings whose files would not decode. The rest stay readable.
    @Published public private(set) var banner: SectionBanner?
    /// Meetings whose `meeting.json` would not decode: their own row, with Recover (from the text copy
    /// saved beside it) and Delete….
    @Published public private(set) var unreadableIDs: [String] = []
    /// What each unreadable row says about its meeting ("Product standup · Today" when the text copy
    /// names it), by id.
    @Published public private(set) var unreadableDetails: [String: String] = [:]
    /// Recordings that stopped before they were closed (a crash, a force quit): banner + row.
    @Published public private(set) var unfinished: [UnfinishedRecording] = []
    /// A recovery that failed, on the affected row only.
    @Published public private(set) var rowProblems: [String: SectionBanner] = [:]
    @Published public private(set) var recoveringID: String?
    /// The capture running now, if any: its row says Recording / Paused / Preparing notes.
    @Published public private(set) var live: MeetingLiveCapture?
    /// The meeting being captured, listed from the capture itself: it has a row from the moment
    /// capture opens, before its first words reach disk, and its words stay current while it runs.
    @Published public private(set) var liveRecord: MeetingRecord?
    /// Why "Start recording" could not record (X01), shown above the list until dismissed.
    @Published public private(set) var captureProblem: SectionBanner?
    @Published public var search = ""

    // MARK: Detail
    @Published public private(set) var selected: MeetingRecord?
    /// The detail's base rendering: content, "Preparing transcript…" or "No speech captured".
    @Published public private(set) var transcript: SectionState = .content
    @Published public var detailTab: MeetingDetailTab = .notes
    @Published public var transcriptQuery = ""
    @Published public private(set) var retryingNotes = false

    /// Scoped retry for the library read (design §9: disabled while it runs).
    public let retry = ScopedRetry()
    public let capture: MeetingCaptureController
    /// The configured key's label, for design copy that names it.
    public var hotkey = ""

    private let store: MeetingStore
    private let files: MeetingFilesStore
    private let settings: (any SettingsStore)?
    private let calendarAuthorized: () -> Bool
    private let setCaptureEnabled: (Bool) -> Void
    private let notesProvider: any MeetingNotesProvider
    private let askRouteProvider: () -> MeetingAskRoute?
    private let now: () -> Date
    /// Injected so a test can make the list slow, empty or broken without a filesystem.
    private let list: (MeetingStore) async throws -> (records: [MeetingRecord], unreadable: [String])
    private var subscriptions: Set<AnyCancellable> = []

    public init(store: MeetingStore = MeetingStore(),
                settings: (any SettingsStore)?,
                calendarAuthorized: @escaping () -> Bool = { EventKitCalendarSignal().isAuthorized },
                setCaptureEnabled: ((Bool) -> Void)? = nil,
                list: ((MeetingStore) async throws -> (records: [MeetingRecord], unreadable: [String]))? = nil,
                capture: MeetingCaptureController? = nil,
                notesProvider: any MeetingNotesProvider = ExtractiveNotesProvider(),
                askRoute: @escaping () -> MeetingAskRoute? = { nil },
                now: @escaping () -> Date = Date.init) {
        self.store = store
        self.files = MeetingFilesStore(store: store)
        self.settings = settings
        self.calendarAuthorized = calendarAuthorized
        let settingsStore = settings
        self.setCaptureEnabled = setCaptureEnabled ?? { on in
            settingsStore?.set(on, for: SettingsKeys.meetingCaptureEnabled)
        }
        self.list = list ?? { store in (records: store.list(), unreadable: MeetingsSectionViewModel.unreadable(in: store)) }
        self.capture = capture ?? .shared
        self.notesProvider = notesProvider
        self.askRouteProvider = askRoute
        self.now = now
        observeCapture()
    }

    /// Directories holding a `meeting.json` that does not decode. A directory without one (a meeting
    /// that has not written its first words yet) is not a failure.
    static func unreadable(in store: MeetingStore) -> [String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
        return ids.filter { id in
            let json = store.directory(for: id).appendingPathComponent("meeting.json")
            return FileManager.default.fileExists(atPath: json.path) && (try? store.load(id: id)) == nil
        }.sorted()
    }

    // MARK: Opt-in and Calendar (both optional for manual recording)

    /// The meeting-detection opt-in (`meeting.capture.enabled`): offer to record when a call starts.
    public var isCaptureEnabled: Bool {
        get { settings?.bool(SettingsKeys.meetingCaptureEnabled) ?? false }
        set {
            setCaptureEnabled(newValue)
            objectWillChange.send()
        }
    }

    public var isCalendarAuthorized: Bool { calendarAuthorized() }

    /// V5 M-d — the store the Settings › Meetings page reads and writes.
    var settingsStore: (any SettingsStore)? { settings }

    /// The prototype's footnote when Calendar is not connected; nothing when it is.
    public var calendarNote: String? { isCalendarAuthorized ? nil : MeetingsCopy.calendarNotConnected }

    // MARK: Library

    /// The library as listed: what is on disk, with the meeting being captured in place of (or ahead
    /// of) its own saved copy.
    public var libraryRecords: [MeetingRecord] { MeetingsLibrary.merge(meetings, live: liveRecord) }

    public var filtered: [MeetingRecord] { MeetingsLibrary.filter(libraryRecords, query: search) }

    public var rows: [MeetingRow] {
        let at = now()
        return filtered.map { MeetingsLibrary.row($0, facts: facts($0.id), live: live, now: at) }
    }

    /// True when a search hides every meeting: "No matches for …" + Clear search (design §9 Search).
    public var searchHidesEverything: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty && !libraryRecords.isEmpty && filtered.isEmpty
    }

    /// A meeting's capture facts. For the meeting being captured, the capture's own track state wins:
    /// a fallback to the microphone is labelled while it records, not only once it is saved.
    public func facts(_ id: String) -> MeetingCaptureFacts {
        var known = facts[id] ?? MeetingCaptureFacts()
        if let live, live.meetingID == id, !live.systemAudio { known.systemAudioCaptured = false }
        return known
    }

    /// Design §9's Meetings renderings: "Loading meetings…" while reading (never the empty copy),
    /// "No meetings yet" + Start recording when there are none, the list otherwise; a store that can't
    /// be read is X02 with a scoped retry, one unreadable meeting is a banner plus its own row.
    public func reload() async {
        await load(quietly: false)
    }

    /// `quietly`: a refresh behind content already on screen (a meeting just closed) keeps the list up
    /// instead of flashing "Loading meetings…".
    private func load(quietly: Bool) async {
        if !(quietly && state.isContent) { state = .loading(.meetings) }
        do {
            let result = try await list(store)
            meetings = result.records
            unreadableIDs = result.unreadable
            let at = now()
            unreadableDetails = Dictionary(uniqueKeysWithValues: result.unreadable.map {
                ($0, MeetingTextRecovery.rowDetail(files.text(for: $0), now: at))
            })
            facts = Dictionary(result.records.map { ($0.id, files.facts(for: $0.id)) }, uniquingKeysWith: { first, _ in first })
            banner = result.unreadable.isEmpty
                ? nil
                : .partial(.meetings, hotkey: hotkey, diagnostics: result.unreadable.joined(separator: "\n"))
            refreshUnfinished()
            if let id = selected?.id { selected = record(id: id) }
            state = resolved()
            refreshDetail()
        } catch {
            meetings = []
            unfinished = []
            banner = nil
            state = .error(.meetings, hotkey: hotkey)
        }
    }

    /// The error's and the partial banner's action: read the library again, once at a time.
    public func retryLoad() async {
        await retry.run { await self.reload() }
    }

    private func resolved() -> SectionState {
        if meetings.isEmpty && unreadableIDs.isEmpty && liveRecord == nil { return .empty(.meetings, hotkey: hotkey) }
        return .content
    }

    /// A meeting by id: the one being captured (current words), else the saved one.
    public func record(id: String) -> MeetingRecord? {
        libraryRecords.first { $0.id == id }
    }

    private func refreshUnfinished() {
        unfinished = meetings.filter { MeetingsLibrary.isUnfinished($0, live: live) }.map { record in
            let audio = files.retainedAudioDuration(for: record.id)
            return UnfinishedRecording(id: record.id, title: record.title,
                                       retained: audio ?? MeetingsLibrary.transcriptReach(record),
                                       hasAudio: audio != nil)
        }
    }

    // MARK: Start recording

    /// "Start recording": opens capture now. Calendar and the detection opt-in are not consulted.
    public func startRecording(title: String? = nil) async {
        captureProblem = nil
        await capture.start(title: title)
    }

    public func dismissCaptureProblem() {
        captureProblem = nil
        capture.dismissProblem()
    }

    /// Synchronous on the main actor (the controller is main-actor bound), so the library never shows a
    /// capture state older than the panel's. `@Published` emits the incoming value before it is stored.
    private func observeCapture() {
        capture.$state
            .sink { [weak self] state in self?.captureChanged(state) }
            .store(in: &subscriptions)
    }

    /// Mirrors the capture into the library: the live row (listed from the moment capture opens, its
    /// words kept current), its status, and a start problem as a notice. When the capture ends —
    /// closed, or failed to close — the library is read again behind the list, so the finished
    /// meeting (or its unfinished-recording banner) replaces the live row without a loading flash.
    func captureChanged(_ state: MeetingCaptureState) {
        let next = state.isActive
            ? state.meetingID.map { MeetingLiveCapture(meetingID: $0, phase: state.phase, systemAudio: state.systemAudio) }
            : nil
        let ended = live != nil && next == nil
        let record = state.liveRecord.map { live -> MeetingRecord in
            // The saved copy knows the meeting's real start; the capture knows its newest words.
            guard let saved = meetings.first(where: { $0.id == live.id }) else { return live }
            var merged = saved
            if live.transcript.utterances.count >= saved.transcript.utterances.count { merged.transcript = live.transcript }
            return merged
        }
        if ended, let finished = capture.lastFinished, finished.id == live?.meetingID {
            // Closed: the saved meeting takes the live row's place at once.
            meetings.removeAll { $0.id == finished.id }
            meetings.append(finished)
            meetings.sort { $0.startedAt > $1.startedAt }
            facts[finished.id] = files.facts(for: finished.id)
            if selected?.id == finished.id { selected = finished }
        }
        if record != liveRecord { liveRecord = record }
        if let record, selected?.id == record.id, selected != record { selected = record }
        if next != live {
            live = next
            refreshUnfinished()
            refreshDetail()
        }
        if ended {
            // Kept as it is until the library has been read again: never "No meetings yet" for a
            // meeting that has just been recorded.
            Task { await self.load(quietly: true) }
        } else if self.state.isContent || self.state.rendering == .empty {
            // A live row turns "No meetings yet" into a list; loading and error are left alone.
            let settled = resolved()
            if settled != self.state { self.state = settled }
        }
        switch state.problem {
        case .couldNotStart?, .unavailable?, .couldNotFinish?:
            captureProblem = state.problem?.banner
        case .systemAudioMissing?, .couldNotResume?, nil:
            // Mid-meeting notices belong to the panel and the pill, not the library.
            if !state.isActive { captureProblem = nil }
        }
    }

    // MARK: Unfinished recordings

    /// Recover: close the saved transcript as it is — never inventing speech — and prepare its notes.
    /// A notes failure still recovers the transcript. The affected row alone reports a failure.
    public func recover(id: String) async {
        guard recoveringID == nil, let record = meetings.first(where: { $0.id == id }) else { return }
        recoveringID = id
        defer { recoveringID = nil }
        var recovered = record
        let reach = max(MeetingsLibrary.transcriptReach(record), files.retainedAudioDuration(for: id) ?? 0)
        recovered.endedAt = record.startedAt.addingTimeInterval(reach)
        var captureFacts = files.facts(for: id)
        captureFacts.recovered = true
        do {
            recovered.notes = try await notesProvider.notes(for: record.transcript)
            captureFacts.notesFailure = nil
        } catch {
            recovered.notes = nil
            captureFacts.notesFailure = "\(error)"
        }
        do {
            try store.save(recovered)
            try? files.save(captureFacts, for: id)
            if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index] = recovered }
            facts[id] = captureFacts
            rowProblems[id] = nil
            if selected?.id == id { selected = recovered }
        } catch {
            rowProblems[id] = SectionBanner(headline: MeetingsCopy.recoverFailed, actionTitle: MeetingsCopy.recover,
                                            diagnostics: "\(error)", body: MeetingsCopy.recoverFailedDetail,
                                            recoveryID: .X02)
        }
        refreshUnfinished()
        refreshDetail()
    }

    /// Discard (after the view's confirmation): deletes the only saved copy of that recording.
    public func discard(id: String) {
        delete(id: id)
    }

    /// Recover on an unreadable row (X02): rebuilds the meeting from the text copy saved beside it —
    /// speakers, timestamps and words exactly as written, never an invented turn — sets the
    /// undecodable file aside instead of overwriting it, and prepares notes again (a notes failure
    /// still recovers the transcript). With no readable copy nothing changes and the row says so.
    public func recoverUnreadable(id: String) async {
        guard recoveringID == nil, unreadableIDs.contains(id) else { return }
        recoveringID = id
        defer { recoveringID = nil }
        guard let text = files.text(for: id), var record = MeetingTextRecovery.parse(text, id: id) else {
            rowProblems[id] = SectionBanner(headline: MeetingsCopy.recoverFailed, actionTitle: MeetingsCopy.showInFinder,
                                            diagnostics: "no readable \(MeetingFilesStore.textFileName) for \(id)",
                                            body: MeetingsCopy.unreadableNotRecovered, recoveryID: .X02)
            return
        }
        var captureFacts = files.facts(for: id)
        captureFacts.recovered = true
        captureFacts.rebuiltFromText = true
        do {
            record.notes = try await notesProvider.notes(for: record.transcript)
            captureFacts.notesFailure = nil
        } catch {
            record.notes = nil
            captureFacts.notesFailure = "\(error)"
        }
        do {
            try files.setAsideUnreadable(for: id)
            try store.save(record)
            try? files.save(captureFacts, for: id)
        } catch {
            rowProblems[id] = SectionBanner(headline: MeetingsCopy.recoverFailed, actionTitle: MeetingsCopy.recover,
                                            diagnostics: "\(error)", body: MeetingsCopy.recoverFailedDetail,
                                            recoveryID: .X02)
            return
        }
        unreadableIDs.removeAll { $0 == id }
        unreadableDetails[id] = nil
        rowProblems[id] = nil
        meetings.removeAll { $0.id == id }
        meetings.append(record)
        meetings.sort { $0.startedAt > $1.startedAt }
        facts[id] = captureFacts
        banner = unreadableIDs.isEmpty
            ? nil
            : .partial(.meetings, hotkey: hotkey, diagnostics: unreadableIDs.joined(separator: "\n"))
        refreshUnfinished()
        state = resolved()
    }

    /// The folder holding a meeting's files, for "Show in Finder".
    public func directory(for id: String) -> URL { store.directory(for: id) }

    // MARK: Detail

    public func select(_ record: MeetingRecord?) {
        selected = record
        transcriptQuery = ""
        refreshDetail()
    }

    public func open(id: String) {
        select(record(id: id))
    }

    public func closeDetail() { select(nil) }

    public var header: MeetingDetailHeader? {
        selected.map { MeetingDetailHeader(record: $0, facts: facts($0.id), now: now()) }
    }

    public var lines: [MeetingTranscriptLine] {
        selected.map { MeetingTranscriptLine.lines($0.transcript) } ?? []
    }

    /// The Transcript tab's search results.
    public var visibleLines: [MeetingTranscriptLine] { MeetingTranscriptLine.search(lines, query: transcriptQuery) }

    /// Notes for the Notes tab; `nil` when there are none (not prepared, or they failed).
    public var notes: MeetingNotesContent? {
        guard let selected, let notes = selected.notes, facts(selected.id).notesFailure == nil else { return nil }
        return MeetingNotesContent(notes)
    }

    /// Design §9 meeting detail: "Transcript remains when Notes fail" — the failure is a scoped banner
    /// over the Notes tab (the prototype's meeting-detail error, N01); the transcript is untouched.
    public var notesBanner: SectionBanner? {
        guard let selected, selected.endedAt != nil, live?.meetingID != selected.id else { return nil }
        guard facts(selected.id).notesFailure != nil || selected.notes == nil else { return nil }
        return .partial(.meetingDetail, hotkey: hotkey, diagnostics: facts(selected.id).notesFailure)
    }

    public var completedActionItems: Set<String> {
        Set(selected.map { facts($0.id).completedActionItems } ?? [])
    }

    /// Audio seeking appears only when the meeting kept its audio (design §8.2).
    public var retainedAudio: URL? { selected.flatMap { files.retainedAudio(for: $0.id) } }

    /// Why "No speech captured" happened, from the capture's own track record.
    public var trackExplanation: String? {
        guard let selected else { return nil }
        return facts(selected.id).systemAudioCaptured ? MeetingsCopy.tracksBoth : MeetingsCopy.tracksMicrophoneOnly
    }

    /// Labels for a paused or partially captured meeting, shown under the header.
    public var captureNotes: [String] {
        guard let selected else { return [] }
        let f = facts(selected.id)
        var notes: [String] = []
        if !f.systemAudioCaptured { notes.append(MeetingsCopy.tracksMicrophoneOnly) }
        if f.rebuiltFromText {
            notes.append(MeetingsCopy.rebuiltFromTextNote)
        } else if f.recovered {
            notes.append(MeetingsCopy.recoveredNote)
        }
        if f.pauseCount > 0 { notes.append(MeetingsCopy.pausedNote) }
        return notes
    }

    public var askRoute: MeetingAskRoute? { askRouteProvider() }

    private func refreshDetail() {
        guard let record = selected else {
            transcript = .content
            return
        }
        if let live, live.meetingID == record.id, live.phase == .preparingNotes {
            transcript = .loading(.meetingDetail, headline: MeetingsCopy.preparingTranscript)
        } else if record.transcript.utterances.isEmpty, live?.meetingID != record.id {
            let copy = DesignScreen.meetingDetail.empty.rendered(hotkey: hotkey)
            let explanation = trackExplanation.map { " " + $0 } ?? ""
            transcript = .empty(copy.headline, detail: copy.body + explanation, action: copy.action)
        } else {
            transcript = .content
        }
    }

    /// Notes' Retry: prepares the notes again from the saved transcript.
    public func retryNotes() async {
        guard !retryingNotes, var record = selected else { return }
        retryingNotes = true
        defer { retryingNotes = false }
        var captureFacts = facts(record.id)
        do {
            record.notes = try await notesProvider.notes(for: record.transcript)
            captureFacts.notesFailure = nil
            try store.save(record)
        } catch {
            captureFacts.notesFailure = "\(error)"
        }
        try? files.save(captureFacts, for: record.id)
        facts[record.id] = captureFacts
        if captureFacts.notesFailure == nil {
            selected = record
            if let index = meetings.firstIndex(where: { $0.id == record.id }) { meetings[index] = record }
        }
    }

    /// Ticks or unticks an action item; kept beside the meeting.
    public func setActionItem(_ item: String, done: Bool) {
        guard let id = selected?.id else { return }
        var captureFacts = facts(id)
        var items = captureFacts.completedActionItems.filter { $0 != item }
        if done { items.append(item) }
        captureFacts.completedActionItems = items
        facts[id] = captureFacts
        try? files.save(captureFacts, for: id)
    }

    // MARK: Delete and export

    /// Deletes a saved meeting (after the view's confirmation). The meeting being captured is not
    /// deleted from here: Stop it first.
    public func delete(id: String) {
        guard live?.meetingID != id else { return }
        do {
            try store.delete(id: id)
            meetings.removeAll { $0.id == id }
            unreadableIDs.removeAll { $0 == id }
            unreadableDetails[id] = nil
            facts[id] = nil
            rowProblems[id] = nil
            if selected?.id == id { select(nil) }
            if unreadableIDs.isEmpty { banner = nil }
            refreshUnfinished()
            state = resolved()
        } catch {
            rowProblems[id] = .recovery(.deletionPartial, diagnostics: "\(error)")   // S11: S04
        }
    }

    public func markdown(for record: MeetingRecord) -> String { record.markdown }
}
