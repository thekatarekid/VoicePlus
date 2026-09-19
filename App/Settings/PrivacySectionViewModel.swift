import AppKit
import Combine
import Engine
import Foundation
import Lab
import Shared

// R7.2 / S7f — Privacy (design §8.5, §9): what is captured, what is kept, what leaves this Mac — and
// the switch that turns each off. The standalone Data Panel window folds in here (Diagnostics), kill
// switch included.
//
// The one sentence this section is never allowed to say is "zero bytes" (V3 §9.6), and it never says
// "Nothing has left this Mac" over a log it could not read (design §9). The empty state is scoped and
// dated, over a window this view model actually queried. Every count the page shows was read, and a
// deletion is always followed by a recount (`PrivacyDataStoring`).

/// Where the ambient-capture retention setting lives. R8.2 owns the enforcement; the preference is
/// here so the switch that promises it is not a placeholder.
public enum AmbientRetentionSettings {
    public static let daysKey = "ambient.retention.days"
    public static let defaultDays = 7
    public static let choices = [1, 7, 30, 90]

    public static func days(_ store: (any SettingsStore)?) -> Int {
        guard let raw = store?.string(daysKey), let days = Int(raw), choices.contains(days) else { return defaultDays }
        return days
    }

    public static func setDays(_ days: Int, store: (any SettingsStore)?) {
        store?.set(String(days), for: daysKey)
    }
}

/// A deletion waiting for confirmation: its scopes, and the words that name them and their counts.
public struct PrivacyDeletionRequest: Identifiable, Equatable, Sendable {
    public var scopes: [PrivacyDataScope]
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var id: String { scopes.map(\.rawValue).joined(separator: "+") }
}

/// Privacy. The switches render from settings at once; network activity and the counts load.
@MainActor
public final class PrivacySectionViewModel: ObservableObject {
    /// How far back the log is read, and therefore the only period the empty state may claim.
    public static let windowDays = 30
    /// Dictations offered to a diagnostics export when the user opts in.
    public static let exportTranscriptLimit = 20

    // MARK: Network activity
    @Published public private(set) var records: [NetworkLogRecord] = []
    @Published public private(set) var activity: [NetworkActivityDay] = []
    @Published public private(set) var bytesOutToday = 0
    /// False when today's total could not be read — then the page says so instead of "0 bytes".
    @Published public private(set) var bytesOutTodayKnown = false
    @Published public private(set) var egress: SectionState = .loading(PrivacyCopy.readingActivity)
    /// A read that failed after rows were already on screen: the rows stay, the failure sits beside them.
    @Published public private(set) var activityBanner: SectionBanner?
    @Published public private(set) var lastChecked: Date?

    // MARK: Kept on this Mac
    @Published public private(set) var saved: SectionState = .content
    /// nil until the first count (then the History block reads "Reading…", never "Nothing is saved").
    @Published public private(set) var inventory: PrivacyInventory?
    @Published public private(set) var recordings: RecordingsUsage?
    /// What a partial deletion left behind, by scope (design §8.5).
    @Published public private(set) var remaining: [PrivacyRemainder] = []
    /// The page's partial banner: S04 after a deletion that did not finish.
    @Published public private(set) var banner: SectionBanner?
    @Published public var pendingDeletion: PrivacyDeletionRequest?
    @Published public var corpus: SettingDraft<String>

    // MARK: Access and mute
    @Published public private(set) var access: [PrivacyAccessRow] = []
    @Published public private(set) var isMuted = false
    @Published public private(set) var canControlMute = false

    // MARK: Diagnostics
    @Published public var diagnosticsOptions = DiagnosticsOptions.redacted
    @Published public private(set) var exportStatus: String?

    /// Retries are scoped: deleting again never refreshes the log, and the reverse (design §9).
    public let deletionRetry = ScopedRetry()
    public let activityRetry = ScopedRetry()

    public let audio: AudioInputSettingsViewModel
    /// The window's checker (`OnboardingDependencies.permissions`), handed over by `PrivacyScreen`.
    public var permissions: OnboardingPermissionChecking?

    private let settings: (any SettingsStore)?
    private let flags: FeatureFlagService?
    private let gate: EgressGate
    private let database: AppDatabase?
    private let data: any PrivacyDataStoring
    public let recordingsDirectory: URL
    private let injectedMute: (any PrivacyMuteControlling)?
    private let muteStore: any MuteStore
    private let screenRecording: ScreenRecordingAccess
    private let openURL: (URL) -> Void
    private let clock: () -> Date
    private let load: (Date) async throws -> [NetworkLogRecord]
    private let bytesToday: (Date) throws -> Int
    private var observingMute: ObjectIdentifier?
    private var persistedMuteFollower: AnyCancellable?

    public init(settings: (any SettingsStore)?,
                flags: FeatureFlagService?,
                gate: EgressGate = .shared,
                audio: AudioInputSettingsViewModel? = nil,
                database: AppDatabase? = nil,
                load: ((Date) async throws -> [NetworkLogRecord])? = nil,
                bytesToday: ((Date) throws -> Int)? = nil,
                deleteEverything: (() throws -> Int)? = nil,
                data: (any PrivacyDataStoring)? = nil,
                recordingsDirectory: URL? = nil,
                mute: (any PrivacyMuteControlling)? = nil,
                muteStore: (any MuteStore)? = nil,
                screenRecording: ScreenRecordingAccess? = nil,
                openURL: ((URL) -> Void)? = nil,
                clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.flags = flags
        self.gate = gate
        self.database = database
        self.audio = audio ?? AudioInputSettingsViewModel()
        let directory = recordingsDirectory ?? UtteranceRecorder.directory()
        self.recordingsDirectory = directory
        self.data = data ?? LivePrivacyDataStore(database: database, recordingsDirectory: directory,
                                                 deleteNetworkLog: deleteEverything)
        self.injectedMute = mute
        self.muteStore = muteStore ?? UserDefaultsMuteStore()
        self.screenRecording = screenRecording ?? SystemScreenRecordingAccess()
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
        self.clock = clock
        self.load = load ?? { since in
            guard let database else { return [] }
            return try database.networkLog(since: since, limit: 5_000)
        }
        self.bytesToday = bytesToday ?? { since in
            guard let database else { return 0 }
            return try database.bytesEgressed(since: since)
        }
        self.corpus = SettingDraft(RecordingSettings.corpusLabel(settings) ?? "")
        refreshSaved()
    }

    // MARK: Loading

    /// Everything the page reads: access, mute, the counts, then the network log.
    public func reload(now: Date? = nil) async {
        let now = now ?? clock()
        refreshAccess()
        refreshMute()
        refreshInventory()
        await reloadActivity(now: now)
        refreshSaved()
    }

    // MARK: Access (design §8.5 rows: microphone, typing access, optional context)

    public func refreshAccess() {
        access = PrivacyAccess.rows(permissions: permissions,
                                    screenRecordingGranted: screenRecording.preflight(),
                                    screenRecordingRequested: DeixisSettings.screenRecordingRequested(settings))
    }

    /// A row's one action. `.explainThenRequest` arrives here only after the view showed the scope.
    public func perform(_ row: PrivacyAccessRow) async {
        switch (row.id, row.action) {
        case (_, .none):
            break
        case ("privacy.access.microphone", .request):
            _ = await permissions?.request(.microphone)
        case ("privacy.access.microphone", .openSettings):
            permissions?.openSystemSettings(for: .microphone)
        case ("privacy.access.typing", _):
            permissions?.openSystemSettings(for: .accessibility)
        case ("privacy.access.context", .explainThenRequest):
            enableScreenRecording()
        case ("privacy.access.context", _):
            if let url = OptionalPermission.screenRecording.settingsURLs.first { openURL(url) }
        default:
            break
        }
        refreshAccess()
    }

    /// G2 — the one Screen Recording request, made from here after the scope was stated. Recorded
    /// in the key the deixis box reads, so a box never asks a second time.
    public func enableScreenRecording() {
        DeixisSettings.noteScreenRecordingRequested(store: settings)
        screenRecording.request()
        refreshAccess()
    }

    // MARK: Hard mute (closed-shutter Spool)

    private var muteControl: (any PrivacyMuteControlling)? { injectedMute ?? PrivacyWiring.mute }

    public func refreshMute() {
        guard let control = muteControl else {
            canControlMute = false
            isMuted = muteStore.loadMuted()
            followPersistedMute()
            return
        }
        persistedMuteFollower = nil
        canControlMute = true
        let id = ObjectIdentifier(control)
        if observingMute != id {
            observingMute = id
            // `MuteController` calls observers on the mutating thread: apply at once on the main
            // thread (the page's own switch, the menu bar), hop there from anywhere else.
            control.observeMuted { [weak self] muted in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.isMuted = muted }
                } else {
                    Task { @MainActor in self?.isMuted = muted }
                }
            }
        }
        isMuted = control.isMuted
    }

    /// Unwired: the live `MuteController` persists every change to the mute store
    /// (`UserDefaultsMuteStore`, `ambient.muted`), so a mute from the menu bar or the pill still
    /// reaches this page — its status tag and the closed-shutter Spool — while it is open.
    private func followPersistedMute() {
        guard persistedMuteFollower == nil else { return }
        persistedMuteFollower = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.muteControl == nil else { return }
                    let muted = self.muteStore.loadMuted()
                    if muted != self.isMuted { self.isMuted = muted }
                }
            }
    }

    /// Mute closes every capture and ends latch (`SessionCoordinator.muteEngaged`); unmute is only
    /// ever this explicit action — nothing here resumes on its own.
    public func setMuted(_ muted: Bool) {
        guard let control = muteControl else { return }
        control.setMuted(muted)
        isMuted = control.isMuted
    }

    /// The Spool surface note: the design's ready line, or the closed-shutter pose beside hard mute
    /// (design §8.9 "Privacy / mute"). The permission and retention rows stay authoritative.
    var spoolNote: (pose: SpoolStateKey, text: String) {
        let key = SpoolSurfacePolicy.appearance(on: .privacy, activity: isMuted ? .muted : .idle)?.key ?? .ready
        return (key, isMuted ? PrivacyCopy.mutedNote : SectionCopy.spoolReadyNote)
    }

    // MARK: Captured

    /// Ambient capture: its **own** switch, off by default (V3 §8, §9.4, R8.1).
    ///
    /// Until R8.1 this wrote the `directedSpeech` feature flag. That conflated two unrelated things:
    /// `directedSpeech` is the hands-free experiment, which V3 §8 says "stays off", and the latch
    /// runtime reads it (`LatchController.isEnabled`). Turning on a transcript Timeline would have
    /// armed a hands-free path, and turning hands-free off would have silently emptied the Timeline.
    /// The key is now `ambient.capture.enabled` and is shared with nothing.
    public var ambientCapture: Bool {
        get { AmbientCaptureSettings.isEnabled(settings) }
        set {
            AmbientCaptureSettings.setEnabled(newValue, store: settings)
            objectWillChange.send()
            refreshSaved()
        }
    }

    /// "Keep what other people said too." Off by default: without it a voice that is not the enrolled
    /// user is discarded rather than stored (V3 §8), and it is a *third* switch because widening
    /// capture to the room is not implied by turning the Timeline on.
    public var capturesEverySpeaker: Bool {
        get { AmbientCaptureSettings.capturesEverySpeaker(settings) }
        set {
            AmbientCaptureSettings.setCapturesEverySpeaker(newValue, store: settings)
            objectWillChange.send()
        }
    }

    public static let enrolledSpeakerOnlyNote =
        "Ambient capture only keeps what your enrolled voice said, as transcript. Nothing is typed anywhere, and it never reaches an injection path."

    /// What the Privacy section says under the retention picker, from the policy that enforces it.
    public var retentionSentence: String { AmbientRetentionPolicy(days: retentionDays).sentence }

    public var retentionDays: Int {
        get { AmbientRetentionSettings.days(settings) }
        set {
            AmbientRetentionSettings.setDays(newValue, store: settings)
            objectWillChange.send()
        }
    }

    /// Recovery persistence (S11): independent of history (design §8.1, §12). Off = "Kept for this
    /// session only".
    public var persistsRecovery: Bool {
        get { TurnSettings.persistsRecovery(settings) }
        set {
            TurnSettings.setPersistsRecovery(newValue, store: settings)
            objectWillChange.send()
        }
    }

    public var recoverySentence: String { persistsRecovery ? PrivacyCopy.recoveryOn : PrivacyCopy.recoveryOff }

    /// "Save dictation history" (design §8.5 prototype row). The key is S7b's
    /// (`TodayHistorySettings`, `history.dictation.enabled`): Today and its search read it, and
    /// Today's history-off "Review retention" lands on this switch. Held text is not history — it
    /// stays under `persistsRecovery`, whatever this says. Off stops new dictations being saved (W3H
    /// `DictationHistoryGate`); what is already kept stays until deleted, so the counts are read again
    /// on every toggle — the History group's "Nothing is saved" is never claimed from an old count.
    public var savesDictationHistory: Bool {
        get { TodayHistorySettings.isEnabled(settings) }
        set {
            TodayHistorySettings.setEnabled(newValue, store: settings)
            refreshInventory()
            objectWillChange.send()
        }
    }

    public var dictationHistorySwitchSentence: String {
        savesDictationHistory ? PrivacyCopy.saveHistoryOn : PrivacyCopy.saveHistoryOff
    }

    /// Audio retention is a *separate* switch from transcript retention (`DESIGN.md` §9.5), and it is
    /// the existing "save recordings" setting — the same key the recorder reads, not a second one.
    public var audioRetention: Bool {
        get { audio.saveRecordings }
        set {
            audio.saveRecordings = newValue
            objectWillChange.send()
            refreshSaved()
        }
    }

    public var audioRetentionSentence: String { audioRetention ? PrivacyCopy.retainAudioOn : PrivacyCopy.retainAudioOff }

    // MARK: Recordings (J1: keep the last 100 / keep all, corpus label, folder size, reveal, delete)

    /// `RecordingSettings.defaultRetention` (100) or `keepAll` (0); read by `UtteranceRecorder` at
    /// every save.
    public var recordingsRetention: Int {
        get { RecordingSettings.retention(settings) }
        set {
            RecordingSettings.setRetention(newValue, store: settings)
            objectWillChange.send()
        }
    }

    /// The two choices the design offers, plus whatever other count is stored (never silently
    /// re-labelled as one of them).
    public var retentionChoices: [Int] {
        var choices = [RecordingSettings.defaultRetention, RecordingSettings.keepAll]
        let current = recordingsRetention
        if !choices.contains(current) { choices.insert(current, at: 0) }
        return choices
    }

    public func retentionLabel(_ count: Int) -> String {
        count == RecordingSettings.keepAll ? PrivacyCopy.keepAll : PrivacyCopy.keepLast(count)
    }

    /// Saves the corpus label. The value is read back: a store that did not keep it is a failed save
    /// (S02 inline), the typed label stays in the field and the previous label stays active.
    @discardableResult
    public func saveCorpus() -> Bool {
        let store = settings
        return corpus.commit { value in
            RecordingSettings.setCorpusLabel(value, store: store)
            guard RecordingSettings.corpusLabel(store) == UtteranceRecorder.normalizedCorpusLabel(value) else {
                throw PrivacySaveError.notKept
            }
        }
    }

    public var recordingsSentence: String { PrivacyCopy.recordingsDetail(recordings) }

    public func revealRecordings() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([recordingsDirectory])
    }

    // MARK: Transmitted

    public var killSwitch: Bool {
        get { gate.isKillSwitchOn }
        set { gate.isKillSwitchOn = newValue; objectWillChange.send() }
    }

    public var windowSentence: String {
        "Every request VoicePlus made in the last \(Self.windowDays) days, and how many bytes went each way."
    }

    public var bytesOutTodayLine: String { PrivacyCopy.bytesOutToday(bytesOutTodayKnown ? bytesOutToday : nil) }

    /// Reads the log for the last 30 days and merges this session's refused attempts. An unreadable
    /// log is an error (or, over rows already shown, a banner) — never the dated empty.
    public func reloadActivity(now: Date? = nil) async {
        let now = now ?? clock()
        if !egress.isContent { egress = .loading(PrivacyCopy.readingActivity) }
        let since = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        do {
            records = try await load(since)
            do {
                bytesOutToday = try bytesToday(Calendar.current.startOfDay(for: now))
                bytesOutTodayKnown = true
            } catch {
                bytesOutTodayKnown = false
            }
            activityBanner = nil
            activity = NetworkActivity.days(records: records, blocked: gate.blockedAttempts, since: since, now: now)
            lastChecked = now
            egress = activity.isEmpty
                ? .empty(SectionCopy.nothingLeftThisMac,
                         detail: SectionCopy.nothingLeftDetail + " " + PrivacyCopy.checked(now, since: since))
                : .content
        } catch {
            bytesOutTodayKnown = false
            if activity.isEmpty {
                egress = SectionState(rendering: .error, headline: SectionCopy.egressUnreadable,
                                      detail: PrivacyCopy.unreadableIsNotProof, actionTitle: SectionCopy.copyDiagnostics)
                activityBanner = SectionBanner(headline: SectionCopy.egressUnreadable, diagnostics: "\(error)")
            } else {
                egress = .content
                activityBanner = SectionBanner(headline: SectionCopy.egressUnreadable, actionTitle: SectionCopy.copyDiagnostics,
                                               diagnostics: "\(error)", body: PrivacyCopy.unreadableIsNotProof)
            }
        }
    }

    /// The raw cause behind an unreadable log, for Copy diagnostics.
    public var activityDiagnostics: String { activityBanner?.diagnostics ?? SectionCopy.egressUnreadable }

    // MARK: Kept on this Mac

    public func refreshInventory() {
        inventory = data.inventory()
        recordings = inventory?.count(.recordings).map { RecordingsUsage(utterances: $0.items, bytes: $0.bytes ?? 0) }
    }

    /// The Audio group's state: the design's "Nothing is saved" only when Retain audio is off *and*
    /// the folder was counted and holds no recordings. Recordings left from before keep it content.
    public func refreshSaved() {
        let leftover = (recordings?.utterances ?? 0) > 0
        saved = audioRetention || leftover
            ? .content
            : .empty(SectionCopy.nothingSaved, detail: PrivacyCopy.noRecordingsDetail)
    }

    /// What the Audio group draws: "Reading…" until the folder has been counted, so "Nothing is
    /// saved" is never shown over recordings nobody has looked for (design §9).
    public var audioState: SectionState {
        recordings == nil && saved.rendering == .empty ? .loading(PrivacyCopy.readingKept) : saved
    }

    /// What the History group draws. The design's empty ("Nothing is saved — Your history is off.
    /// Recovery text has its own clearly labelled retention policy." · Review retention) only when
    /// it is true: Save dictation history *and* ambient capture are off, and the count found no
    /// dictation history, no held text and no ambient transcript. History on with nothing kept yet
    /// is content ("No dictations kept yet"), never "Your history is off". "Reading…" before the
    /// first count.
    public var historyState: SectionState {
        guard let inventory else { return .loading(PrivacyCopy.readingKept) }
        let historyScopes: [PrivacyDataScope] = [.dictationHistory, .heldText, .ambientTranscripts]
        let empty = !savesDictationHistory && !ambientCapture
            && historyScopes.allSatisfy { inventory.count($0)?.items == 0 }
        return empty ? .empty(.privacy, hotkey: PillCopy.prototypeHotkey) : .content
    }

    public var dictationHistorySentence: String {
        guard let count = inventory?.count(.dictationHistory) else {
            return inventory == nil ? PrivacyCopy.readingKept : PrivacyCopy.dictationHistoryUnreadable
        }
        return PrivacyCopy.dictationHistoryDetail(count.items)
    }

    // MARK: Deletion (scope and count up front; what remains, by name, after)

    /// Stages a confirmation for one scope, or for everything when `scope` is nil.
    public func requestDeletion(_ scope: PrivacyDataScope?) {
        if inventory == nil { refreshInventory() }
        pendingDeletion = scope.map(request(for:)) ?? everythingRequest
    }

    func request(for scope: PrivacyDataScope) -> PrivacyDeletionRequest {
        let line = inventory?.count(scope).map { count -> String in
            let size = count.bytes.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
            return scope.noun(count.items) + size
        }
        let what = line ?? "every item in \(scope.title.lowercased())"
        return PrivacyDeletionRequest(scopes: [scope],
                                      title: "Delete \(what) from this Mac?",
                                      message: "\(scope.leavesAlone) \(PrivacyCopy.cannotBeUndone)",
                                      confirmTitle: "Delete \(scope.title.lowercased())")
    }

    var everythingRequest: PrivacyDeletionRequest {
        PrivacyDeletionRequest(scopes: PrivacyDataScope.allCases,
                               title: "Delete everything saved on this Mac?",
                               message: deleteAllSummary,
                               confirmTitle: "Delete everything")
    }

    /// What the confirmation has to name before it deletes anything (`DESIGN.md` §9.5).
    public var deleteAllSummary: String {
        guard let inventory else {
            return "This deletes every saved recording, dictation, held text, ambient transcript and row of network activity on this Mac. \(PrivacyCopy.cannotBeUndone)"
        }
        let parts = PrivacyDataScope.allCases.map { scope -> String in
            guard let count = inventory.count(scope) else { return "every item in \(scope.title.lowercased())" }
            return scope.noun(count.items)
        }
        return "This deletes \(Self.list(parts)) from this Mac. Settings and learned words stay. \(PrivacyCopy.cannotBeUndone)"
    }

    public func confirmDeletion() {
        guard let request = pendingDeletion else { return }
        pendingDeletion = nil
        delete(request.scopes)
    }

    /// Deletes each scope, then recounts. Anything left is listed by scope under an S04 banner.
    public func delete(_ scopes: [PrivacyDataScope]) {
        var left = remaining.filter { !scopes.contains($0.scope) }
        for scope in scopes {
            if let remainder = data.delete(scope) { left.append(remainder) }
        }
        remaining = left.sorted { a, b in
            (PrivacyDataScope.allCases.firstIndex(of: a.scope) ?? 0) < (PrivacyDataScope.allCases.firstIndex(of: b.scope) ?? 0)
        }
        if remaining.isEmpty {
            banner = nil
        } else {
            let reasons = remaining.compactMap { r in r.reason.flatMap { $0.isEmpty ? nil : "\(r.scope.title): \($0)" } }
            banner = .partial(RecoveryCatalog.entry(.S04), diagnostics: reasons.isEmpty ? nil : reasons.joined(separator: "\n"))
        }
        if scopes.contains(.recordings) { audio.objectWillChange.send() }
        refreshInventory()
        refreshSaved()
        if scopes.contains(.networkActivity) {
            Task { await reloadActivity() }
        }
    }

    /// S04's "Retry deletion": only the scopes that did not finish, disabled while it runs.
    public func retryDeletion() async {
        await deletionRetry.run { [weak self] in
            guard let self else { return }
            self.delete(self.remaining.map(\.scope))
        }
    }

    /// Everything saved, in one go (the old "Delete everything saved…").
    public func deleteAll() {
        delete(PrivacyDataScope.allCases)
    }

    // MARK: Diagnostics export (redacted by default, previewed exactly)

    public func diagnosticsExport(now: Date? = nil) -> DiagnosticsExport {
        PrivacyDiagnostics.export(diagnosticsFacts(now: now ?? clock()), options: diagnosticsOptions)
    }

    func diagnosticsFacts(now: Date) -> DiagnosticsFacts {
        let onOff: (Bool) -> String = { $0 ? "on" : "off" }
        var settingsLines = [
            "Hard mute: \(onOff(isMuted))",
            "Block all network egress: \(onOff(killSwitch))",
            "Save dictation history: \(onOff(savesDictationHistory))",
            "Ambient capture: \(onOff(ambientCapture)), transcripts kept \(retentionDays) day\(retentionDays == 1 ? "" : "s")",
            "Keep what other people said too: \(onOff(capturesEverySpeaker))",
            "Keep held text until resolved: \(onOff(persistsRecovery))",
            "Retain audio: \(onOff(audioRetention)), \(retentionLabel(recordingsRetention).lowercased())",
            "Corpus label: \(RecordingSettings.corpusLabel(settings) == nil ? "not set" : "set")",
            "Screen Recording asked: \(DeixisSettings.screenRecordingRequested(settings) ? "yes" : "no")",
        ]
        settingsLines += PrivacyProcessing.rows(settings: settings).map { "\($0.title): \($0.status)" }
        let kept = PrivacyDataScope.allCases.map { scope in
            "\(scope.title): " + (inventory.map { $0.line(scope) } ?? "not counted")
        }
        var network = NetworkActivity.byDestination(records).map {
            "\($0.destination): \($0.requests) request\($0.requests == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: Int64($0.bytesOut), countStyle: .binary)) out"
        }
        let refused = gate.blockedAttempts.count
        network.append(refused == 0 ? "Refused while blocked: none this session" : "Refused while blocked: \(refused) this session")
        if !egress.isContent && egress.rendering == .error { network.append("The log could not be read.") }
        let flagLines = flags.map { service in
            service.knownFlags.map { "\($0.id): \(onOff(service.isEnabled($0)))\(service.override(for: $0) != nil ? " (overridden)" : "")" }
        } ?? []
        var transcripts: [DiagnosticsTranscript] = []
        if diagnosticsOptions.includeTranscripts, let database {
            let rows = (try? database.recentDictations(limit: Self.exportTranscriptLimit)) ?? []
            transcripts = rows.map { DiagnosticsTranscript(time: $0.startedAt, app: $0.appBundleID, text: $0.finalText) }
        }
        var audioFiles: [DiagnosticsFile] = []
        if diagnosticsOptions.includeAudio {
            audioFiles = PrivacyRecordingFiles.files(in: recordingsDirectory).map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return DiagnosticsFile(name: url.lastPathComponent, bytes: Int64(size), source: url)
            }
        }
        return DiagnosticsFacts(generatedAt: now,
                                appVersion: MainWindowController.appVersion,
                                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                permissions: access.map { "\($0.title): \($0.status)" },
                                settings: settingsLines, kept: kept, network: network, flags: flagLines,
                                transcripts: transcripts, audio: audioFiles)
    }

    /// Writes `export` — the one the preview showed — into `parent` and reports where, or that
    /// nothing was written. Without one it builds the current export.
    @discardableResult
    public func saveExport(_ export: DiagnosticsExport? = nil, into parent: URL) -> URL? {
        let now = clock()
        do {
            let folder = try PrivacyDiagnostics.write(export ?? diagnosticsExport(now: now), into: parent,
                                                      folderName: PrivacyDiagnostics.folderName(at: now))
            exportStatus = PrivacyCopy.exportSaved(DiagnosticsRedactor.current(folder.path))
            return folder
        } catch {
            exportStatus = PrivacyCopy.exportFailed
            return nil
        }
    }

    // MARK: Helpers

    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}

enum PrivacySaveError: Error { case notKept }
