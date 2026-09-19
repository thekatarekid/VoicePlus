import AppKit
import Engine
import Foundation
import Lab
import Shared
import SwiftUI
import Testing
@testable import VoicePlusApp

/// S7f — Privacy (design §8.5, §9; build doc S7f). The rows (microphone, typing access, optional
/// context = Screen Recording, history and audio retention, J1 recordings, meeting capture, sync),
/// the on-device-versus-service disclosure, the dated network activity list, the unreadable-log
/// error, scoped deletion with counts and a remaining list, hard mute with the closed-shutter Spool,
/// and the redacted diagnostics export with its exact preview.
///
/// Nothing here touches TCC, the real recordings folder, the real database or the live mute: the
/// checker, the Screen Recording access, the mute and the data store are fakes, folders are temporary.
@Suite("PrivacyS7fTests · S7f Privacy")
@MainActor
struct PrivacyS7fTests {

    // MARK: - Fixtures and fakes

    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static func copyFixture() throws -> [String: Any] {
        let data = try Data(contentsOf: packageRoot.appendingPathComponent("Fixtures/design/design_copy.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    nonisolated static func defaults() -> UserDefaults { UserDefaults(suiteName: "vp.privacy.\(UUID().uuidString)")! }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes one utterance the way `UtteranceRecorder.finish()` names it.
    static func writeRecording(_ stamp: String, in directory: URL, bytes: Int = 64) throws {
        for name in ["\(stamp)-raw.wav", "\(stamp)-processed.wav", "\(stamp).json"] {
            try Data(repeating: 1, count: bytes).write(to: directory.appendingPathComponent(name))
        }
    }

    final class FakeScreenRecording: ScreenRecordingAccess {
        var granted = false
        private(set) var requests = 0
        func preflight() -> Bool { granted }
        func request() -> Bool { requests += 1; return granted }
    }

    final class FakeMute: PrivacyMuteControlling {
        private(set) var isMuted: Bool
        private var handlers: [(Bool) -> Void] = []
        init(muted: Bool = false) { isMuted = muted }
        func setMuted(_ muted: Bool) { isMuted = muted; handlers.forEach { $0(muted) } }
        func observeMuted(_ handler: @escaping (Bool) -> Void) { handlers.append(handler); handler(isMuted) }
    }

    /// Counts per scope, a scope that cannot be counted, and a scripted remainder per delete.
    final class FakeData: PrivacyDataStoring {
        var counts: [PrivacyDataScope: PrivacyScopeCount] = [:]
        var unreadable: Set<PrivacyDataScope> = []
        var leftovers: [PrivacyDataScope: PrivacyRemainder] = [:]
        private(set) var deleted: [PrivacyDataScope] = []
        struct Unreadable: Error {}

        init(_ counts: [PrivacyDataScope: Int] = [:]) {
            for scope in PrivacyDataScope.allCases { self.counts[scope] = PrivacyScopeCount(items: counts[scope] ?? 0) }
        }

        func count(_ scope: PrivacyDataScope) throws -> PrivacyScopeCount {
            if unreadable.contains(scope) { throw Unreadable() }
            return counts[scope] ?? .zero
        }

        func delete(_ scope: PrivacyDataScope) -> PrivacyRemainder? {
            deleted.append(scope)
            if let left = leftovers[scope] {
                counts[scope] = PrivacyScopeCount(items: left.count ?? 0)
                return left
            }
            counts[scope] = .zero
            return nil
        }
    }

    struct Boom: Error {}

    static func model(store: SettingsStore = InMemorySettingsStore(),
                      defaults: UserDefaults = Self.defaults(),
                      database: AppDatabase? = nil,
                      load: ((Date) async throws -> [NetworkLogRecord])? = { _ in [] },
                      bytesToday: ((Date) throws -> Int)? = { _ in 0 },
                      gate: EgressGate? = nil,
                      data: (any PrivacyDataStoring)? = FakeData(),
                      recordings: URL? = nil,
                      mute: (any PrivacyMuteControlling)? = nil,
                      muteStore: (any MuteStore)? = InMemoryMuteStore(),
                      screen: FakeScreenRecording = FakeScreenRecording(),
                      opened: ((URL) -> Void)? = { _ in },
                      flags: FeatureFlagService? = .inMemory(),
                      now: Date = Date()) -> PrivacySectionViewModel {
        PrivacySectionViewModel(settings: store, flags: flags, gate: gate ?? EgressGate(defaults: defaults),
                                audio: AudioInputSettingsViewModel(defaults: defaults), database: database,
                                load: load, bytesToday: bytesToday, data: data,
                                recordingsDirectory: recordings ?? FileManager.default.temporaryDirectory
                                    .appendingPathComponent("vp-privacy-none-\(UUID().uuidString)"),
                                mute: mute, muteStore: muteStore, screenRecording: screen, openURL: opened,
                                clock: { now })
    }

    // MARK: - Access rows: microphone, typing access, optional context (G2)

    @Test("microphone: allowed / not asked (Allow…) / off and waiting (System Settings) — a word and a tag each")
    func microphoneRows() {
        let granted = PrivacyAccess.microphone(.granted)
        #expect(granted.status == "Allowed" && granted.tag == .good && granted.action == .none)
        let fresh = PrivacyAccess.microphone(.notDetermined)
        #expect(fresh.action == .request && fresh.actionTitle == "Allow…" && fresh.tag == .neutral)
        let denied = PrivacyAccess.microphone(.denied)
        #expect(denied.action == .openSettings && denied.tag == .warn && denied.status == "Off")
        let waiting = PrivacyAccess.microphone(.awaitingUserAction)
        #expect(waiting.action == .openSettings && waiting.status == "Waiting")
    }

    @Test("typing access is never promptable: every state but granted goes to System Settings")
    func typingRows() {
        #expect(PrivacyAccess.typing(.granted).action == .none)
        for status in [OnboardingPermissionStatus.notDetermined, .denied, .awaitingUserAction] {
            #expect(PrivacyAccess.typing(status).action == .openSettings)
            #expect(PrivacyAccess.typing(status).tag == .warn)
        }
    }

    @Test("Screen Recording is optional: scope first, asked once, never shown as a problem")
    func contextRows() {
        let fresh = PrivacyAccess.context(granted: false, requested: false)
        #expect(fresh.title == "Context from other apps")
        #expect(fresh.action == .explainThenRequest)
        #expect(fresh.detail == OptionalPermission.screenRecording.rationale, "the scope is stated before enabling")
        #expect(fresh.status == "Off · optional")
        let asked = PrivacyAccess.context(granted: false, requested: true)
        #expect(asked.action == .openSettings, "asked once already: the switch is in System Settings now")
        let on = PrivacyAccess.context(granted: true, requested: true)
        #expect(on.status == "Allowed" && on.tag == .good)
        for row in [fresh, asked, on] { #expect(row.tag != .warn, "an optional permission never looks like a fault") }
    }

    @Test("no checker reads as not asked, never as allowed")
    func noCheckerIsNotAllowed() {
        let rows = PrivacyAccess.rows(permissions: nil, screenRecordingGranted: false, screenRecordingRequested: false)
        #expect(rows.map(\.id) == ["privacy.access.microphone", "privacy.access.typing", "privacy.access.context"])
        #expect(!rows.contains { $0.status == "Allowed" })
        #expect(PrivacyAccess.processing.status == "On this Mac", "prototype: Dictation processing · On this Mac")
        #expect(PrivacyAccess.processing.detail == "On-device recognizer selected.")
    }

    @Test("row actions reach the real paths: the mic request, the panes, and the one Screen Recording ask")
    func accessActions() async throws {
        let store = InMemorySettingsStore()
        let screen = FakeScreenRecording()
        var opened: [URL] = []
        let model = Self.model(store: store, screen: screen, opened: { opened.append($0) })
        let checker = OnboardingMockPermissionChecker(results: [.microphone: .granted])
        model.permissions = checker
        await model.reload()
        let mic = try #require(model.access.first { $0.id == "privacy.access.microphone" })
        await model.perform(mic)
        #expect(checker.requests == [.microphone], "asking is the only way VoicePlus appears in the Microphone pane")
        #expect(model.access.first?.status == "Allowed")

        let typing = try #require(model.access.first { $0.id == "privacy.access.typing" })
        await model.perform(typing)
        #expect(checker.openedSettings == [.accessibility])

        let context = try #require(model.access.first { $0.id == "privacy.access.context" })
        #expect(context.action == .explainThenRequest)
        await model.perform(context)
        #expect(screen.requests == 1)
        #expect(DeixisSettings.screenRecordingRequested(store), "the deixis box reads the same key and never asks again")
        let after = try #require(model.access.first { $0.id == "privacy.access.context" })
        #expect(after.action == .openSettings)
        await model.perform(after)
        #expect(screen.requests == 1, "never asked a second time")
        #expect(opened.first?.absoluteString.contains("Privacy_ScreenCapture") == true)
    }

    // MARK: - On this Mac or a service

    @Test("nothing pinned: every step on this Mac; a provider pin names the service and says audio never goes")
    func processingDisclosure() {
        let store = InMemorySettingsStore()
        let local = PrivacyProcessing.rows(settings: store)
        #expect(local.map(\.id) == ["privacy.processing.speech", "privacy.processing.local"])
        let allLocal = local.allSatisfy { $0.onDevice }
        #expect(allLocal)
        #expect(local.last?.detail == "No service is selected, so every stage runs on this Mac.")

        store.set("provider:openai", for: SettingsKeys.routingPrefix + StageID.formatterEmail.rawValue)
        store.set("local", for: SettingsKeys.routingPrefix + StageID.formatterChat.rawValue)
        store.set("auto", for: SettingsKeys.routingPrefix + StageID.style.rawValue)
        // Transcription accepts no provider; a stored pin there sends nothing and is not listed.
        store.set("provider:openai", for: SettingsKeys.routingPrefix + StageID.asr.rawValue)
        let routed = PrivacyProcessing.rows(settings: store)
        #expect(routed.count == 3)
        let email = routed[1]
        #expect(email.title == "Email formatting" && email.status == "openai" && !email.onDevice)
        #expect(email.detail.contains("Audio is never sent"))
        #expect(routed.first?.detail == "Audio is transcribed on this Mac. It is never sent to a service.")
        #expect(routed.last?.detail == "Every other step runs on this Mac.")
    }

    @Test("sync: off, not paired, or paired — and what travels is named")
    func syncRow() {
        #expect(PrivacyProcessing.sync(available: false, paired: false).status == "Sync is off")
        #expect(PrivacyProcessing.sync(available: true, paired: false).status == "Not paired")
        let paired = PrivacyProcessing.sync(available: true, paired: true)
        #expect(paired.status == "Paired" && !paired.onDevice)
        #expect(paired.detail.contains("Never audio"))
    }

    // MARK: - Hard mute and the closed-shutter Spool

    @Test("hard mute: the Privacy switch drives the live mute; Spool shows the closed shutters; nothing unmutes itself")
    func hardMute() async {
        let mute = FakeMute()
        let model = Self.model(mute: mute)
        await model.reload()
        #expect(model.canControlMute)
        #expect(model.spoolNote.pose == .ready)
        #expect(model.spoolNote.text == "Spool · Ready when you are. Microphone closed.")

        model.setMuted(true)
        #expect(mute.isMuted && model.isMuted)
        #expect(model.spoolNote.pose == .muted, "design §8.9: closed-shutter Spool beside hard mute")
        #expect(model.spoolNote.text == "VoicePlus is muted. The microphone stays closed until you unmute.")
        #expect(model.spoolNote.text.hasPrefix(RecoveryCatalog.entry(.K05).headline))

        await model.reload()
        #expect(model.isMuted, "a reload never resumes capture")

        // Unmuted from the menu bar while the page is open: the page follows.
        mute.setMuted(false)
        #expect(!model.isMuted)
    }

    @Test("unwired mute: the persisted state still shows, and no switch pretends to close the microphone")
    func unwiredMute() async {
        let store = InMemoryMuteStore(muted: true)
        let model = Self.model(mute: nil, muteStore: store)
        await model.reload()
        #expect(!model.canControlMute || PrivacyWiring.mute != nil)
        if PrivacyWiring.mute == nil {
            #expect(model.isMuted)
            #expect(model.spoolNote.pose == .muted)
            model.setMuted(false)
            #expect(store.muted, "only the live mute may unmute")
        }
    }

    @Test("MuteController drives the page too, and a mute survives a relaunch")
    func muteControllerConformance() {
        let store = InMemoryMuteStore()
        let controller = MuteController(store: store)
        var seen: [Bool] = []
        controller.observeMuted { seen.append($0) }
        controller.setMuted(true)
        #expect(controller.isMuted && store.muted)
        #expect(MuteController(store: store).isMuted, "relaunch keeps the mute (never resumes on its own)")
        #expect(seen == [false, true])
    }

    // MARK: - Network activity: dated, destination, purpose, time, allowed / blocked

    @Test("the activity list is dated by day, newest first, with allowed and blocked rows")
    func datedActivity() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 19, hour: 12)))
        let yesterday = now.addingTimeInterval(-86_400)
        let lastWeek = now.addingTimeInterval(-3 * 86_400)
        let records = [
            NetworkLogRecord(id: 1, timestamp: yesterday, stage: "formatter.email", provider: "openai", host: "api.openai.com",
                             bytesOut: 120, bytesIn: 400, purpose: "format an email"),
            NetworkLogRecord(id: 2, timestamp: lastWeek, stage: "act.planner", provider: "openai", host: "api.openai.com",
                             bytesOut: 90, bytesIn: 10, purpose: ""),
            NetworkLogRecord(id: 3, timestamp: now.addingTimeInterval(-40 * 86_400), stage: "x", provider: "p", host: "old.example",
                             bytesOut: 1, bytesIn: 1, purpose: "outside the window"),
        ]
        let since = now.addingTimeInterval(-30 * 86_400)
        let days = NetworkActivity.days(records: records, blocked: [(now.addingTimeInterval(-60), "api.anthropic.com")],
                                        since: since, now: now, calendar: calendar)
        #expect(days.count == 3)
        #expect(days[0].title.hasPrefix("Today · "))
        #expect(days[1].title.hasPrefix("Yesterday · "))
        #expect(!days[2].title.hasPrefix("Today") && !days[2].title.hasPrefix("Yesterday"))
        let blocked = try #require(days[0].rows.first)
        #expect(blocked.status == .blocked && blocked.destination == "api.anthropic.com")
        #expect(blocked.purpose == "Refused while Block all network egress is on")
        let allowed = try #require(days[1].rows.first)
        #expect(allowed.status == .allowed && allowed.destination == "api.openai.com" && allowed.purpose == "format an email")
        #expect(days[2].rows.first?.purpose == "act.planner", "no purpose logged: the stage says what it was for")
        #expect(!days.flatMap(\.rows).contains { $0.destination == "old.example" }, "only the 30 days actually read")
        #expect(allowed.summary.contains("Allowed") && blocked.summary.contains("Blocked"))
    }

    @Test("loading reads “Reading activity…”; the empty is dated; a refused attempt is activity, not nothing")
    func activityStates() async {
        let defaults = Self.defaults()
        let gate = EgressGate(defaults: defaults)
        let model = Self.model(defaults: defaults, gate: gate)
        #expect(model.egress.rendering == .loading)
        #expect(model.egress.headline == "Reading activity…")
        await model.reload()
        #expect(model.egress.rendering == .empty)
        #expect(model.egress.headline == SectionCopy.nothingLeftThisMac)
        #expect(model.egress.detail?.contains("Checked ") == true, "the no-egress result is dated")
        #expect(model.bytesOutTodayLine.hasPrefix("Today: "))

        gate.isKillSwitchOn = true
        _ = gate.isAllowed(host: "api.openai.com")
        await model.reloadActivity()
        #expect(model.egress.isContent, "a blocked attempt is shown — the list never hides a refusal")
        #expect(model.activity.first?.rows.first?.status == .blocked)
    }

    @Test("an unreadable log is an error that never says nothing left; after rows, a banner keeps them")
    func unreadableLog() async {
        final class Flaky: @unchecked Sendable { var fail = true }
        let flaky = Flaky()
        let record = NetworkLogRecord(stage: "act.planner", provider: "openai", host: "api.openai.com",
                                      bytesOut: 120, bytesIn: 400, purpose: "plan an action")
        let model = Self.model(load: { _ in if flaky.fail { throw Boom() }; return [record] },
                               bytesToday: { _ in throw Boom() })
        await model.reload()
        #expect(model.egress.rendering == .error)
        #expect(model.egress.headline == SectionCopy.egressUnreadable)
        #expect(model.egress.actionTitle == SectionCopy.copyDiagnostics)
        #expect(model.egress.detail == "An unreadable log is not proof that nothing left this Mac.")
        #expect(!(model.egress.headline + (model.egress.detail ?? "")).contains("Nothing"))
        #expect(model.egress.isWellFormed)
        #expect(model.bytesOutTodayLine == "Today: can’t be read", "never “0 bytes” over an unreadable total")

        flaky.fail = false
        await model.reloadActivity()
        #expect(model.egress.isContent && model.activity.count == 1)
        flaky.fail = true
        await model.reloadActivity()
        #expect(model.egress.isContent, "rows already read stay on screen")
        #expect(model.activityBanner?.headline == SectionCopy.egressUnreadable)
        #expect(model.activityBanner?.body == "An unreadable log is not proof that nothing left this Mac.")
    }

    // MARK: - Recordings (J1)

    @Test("recordings: keep the last 100 or keep all, written where the recorder reads them")
    func recordingsRetention() {
        let store = InMemorySettingsStore()
        let model = Self.model(store: store)
        #expect(model.recordingsRetention == 100)
        #expect(model.retentionChoices == [100, 0])
        #expect(model.retentionChoices.map(model.retentionLabel) == ["Keep the last 100", "Keep all"])
        model.recordingsRetention = RecordingSettings.keepAll
        #expect(store.string(SettingsKeys.recordingsRetain) == "0")
        #expect(UtteranceRecorder.parseRetention(store.string(UtteranceRecorder.retainKey)) == 0)
        store.set("20", for: SettingsKeys.recordingsRetain)
        #expect(model.retentionChoices == [20, 100, 0], "a stored count is shown as itself, never relabelled")
        #expect(model.retentionLabel(20) == "Keep the last 20")
    }

    @Test("corpus label: saved and read back; a store that drops it keeps the typed value and the old label (S02)")
    func corpusLabel() {
        let store = InMemorySettingsStore()
        let model = Self.model(store: store)
        model.corpus.entered = "  real-room v2 "
        #expect(model.saveCorpus())
        #expect(RecordingSettings.corpusLabel(store) == "real-room v2")
        model.corpus.entered = ""
        #expect(model.saveCorpus())
        #expect(RecordingSettings.corpusLabel(store) == nil, "blank clears the label")

        let backing = InMemorySettingsStore()
        RecordingSettings.setCorpusLabel("tv-on", store: backing)
        let readOnly = Self.model(store: ReadOnlySettingsStore(backing))
        #expect(readOnly.corpus.active == "tv-on")
        readOnly.corpus.entered = "neighbour"
        #expect(!readOnly.saveCorpus())
        #expect(readOnly.corpus.entered == "neighbour", "the typed value stays in the field")
        #expect(readOnly.corpus.active == "tv-on", "the previous label stays active")
        #expect(readOnly.corpus.failureBanner?.headline == RecoveryCatalog.entry(.S02).headline)
    }

    @Test("folder size and count from the real recorder rule; Delete all removes only the recorder's files")
    func recordingsFolder() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRecording("2026-09-18-124200-001", in: dir)
        try Self.writeRecording("2026-09-18-124500-002", in: dir)
        try Data("keep me".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let model = Self.model(data: nil, recordings: dir)
        model.refreshInventory()
        #expect(model.recordings?.utterances == 2)
        #expect((model.recordings?.bytes ?? 0) == 6 * 64)
        #expect(model.recordingsSentence.hasPrefix("2 recordings · "))
        model.requestDeletion(.recordings)
        #expect(model.pendingDeletion?.title.hasPrefix("Delete 2 recordings") == true)
        model.confirmDeletion()
        #expect(model.remaining.isEmpty && model.banner == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["notes.txt"], "anything else in that folder is never deleted")
        #expect(model.recordings?.utterances == 0)
        #expect(model.recordingsSentence == "No recordings saved.")
    }

    // MARK: - Scoped deletion: scope and count first, what remains after

    @Test("a partial delete lists what remains by name (never a file name) under S04, and retry is scoped")
    func partialDeletion() async throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.writeRecording("2026-09-18-124200-001", in: dir)
        try Self.writeRecording("2026-09-18-124500-002", in: dir)
        final class Lock: @unchecked Sendable { var stuck = true }
        let lock = Lock()
        let data = LivePrivacyDataStore(database: nil, recordingsDirectory: dir, ambient: { nil }, turns: { nil },
                                        remove: { url in
                                            if lock.stuck && url.lastPathComponent.hasPrefix("2026-09-18-124500") { throw Boom() }
                                            try FileManager.default.removeItem(at: url)
                                        })
        let model = Self.model(data: data, recordings: dir)
        model.refreshInventory()
        model.delete([.recordings])
        let remainder = try #require(model.remaining.first)
        #expect(remainder.scope == .recordings && remainder.count == 1)
        #expect(remainder.line == "1 recording is still on this Mac.")
        #expect(remainder.items.count == 1 && remainder.items[0].hasPrefix("Recording from "))
        #expect(!remainder.items.contains { $0.contains(".wav") || $0.contains(".json") })
        let s04 = RecoveryCatalog.entry(.S04)
        #expect(model.banner?.headline == s04.headline)
        #expect(model.banner?.actionTitle == s04.action)
        #expect(model.banner?.body == s04.consequence + SectionCopy.partialSuffix)
        #expect(model.banner?.recoveryID == .S04)
        #expect(model.banner?.diagnostics?.contains("Recordings:") == true)
        #expect(model.recordings?.utterances == 1, "the count after a delete is recounted, not assumed")

        lock.stuck = false
        await model.retryDeletion()
        #expect(model.remaining.isEmpty && model.banner == nil)
        #expect(!model.deletionRetry.isRetrying)
    }

    @Test("retry deletes only the scopes that did not finish")
    func retryIsScoped() async {
        let data = FakeData([.recordings: 3, .networkActivity: 2, .dictationHistory: 5])
        data.leftovers[.networkActivity] = PrivacyRemainder(scope: .networkActivity, count: 2, items: ["2 rows of network activity"])
        let model = Self.model(data: data)
        model.refreshInventory()
        model.deleteAll()
        #expect(data.deleted == PrivacyDataScope.allCases)
        #expect(model.remaining.map(\.scope) == [.networkActivity])
        data.leftovers = [:]
        await model.retryDeletion()
        #expect(data.deleted == PrivacyDataScope.allCases + [.networkActivity])
        #expect(model.remaining.isEmpty)
    }

    @Test("confirmation names the scope, the count and what stays; cancel deletes nothing")
    func confirmationCopy() {
        let data = FakeData([.recordings: 20, .dictationHistory: 312, .heldText: 1, .ambientTranscripts: 40, .networkActivity: 18])
        data.counts[.recordings] = PrivacyScopeCount(items: 20, bytes: 20_000_000)
        let model = Self.model(data: data)
        model.refreshInventory()

        model.requestDeletion(.heldText)
        #expect(model.pendingDeletion?.title == "Delete 1 held text from this Mac?")
        #expect(model.pendingDeletion?.message.contains("only copy") == true)
        model.pendingDeletion = nil
        #expect(data.deleted.isEmpty)

        model.requestDeletion(.recordings)
        #expect(model.pendingDeletion?.title.hasPrefix("Delete 20 recordings (") == true)
        #expect(model.pendingDeletion?.message.contains("cannot be undone") == true)

        model.requestDeletion(nil)
        let everything = model.pendingDeletion?.message ?? ""
        for part in ["20 recordings", "312 dictations", "1 held text", "40 ambient entries", "18 rows of network activity"] {
            #expect(everything.contains(part), "“\(part)” missing from “\(everything)”")
        }
        model.confirmDeletion()
        #expect(data.deleted == PrivacyDataScope.allCases)
        #expect(model.pendingDeletion == nil)
    }

    @Test("a scope that cannot be counted is never shown as zero or nothing")
    func uncountedScope() {
        let data = FakeData([.recordings: 0])
        data.unreadable = [.networkActivity]
        let model = Self.model(data: data)
        model.refreshInventory()
        let inventory = model.inventory
        #expect(inventory?.line(.networkActivity) == PrivacyCopy.uncounted)
        #expect(inventory?.line(.recordings) == "Nothing to delete.")
        #expect(inventory?.isEmpty == false)
        #expect(model.deleteAllSummary.contains("every item in network activity log"))
    }

    @Test("the live store counts and deletes the database scopes, and keeps held text out of history")
    func liveStoreDatabase() throws {
        let database = try AppDatabase.inMemory()
        for i in 0..<3 {
            try database.insert(DictationRecord(startedAt: Date(), endedAt: nil, register: "prose", route: "dictate",
                                                appBundleID: nil, rawText: "raw \(i)", finalText: "final \(i)", spansJSON: "[]"))
        }
        _ = try database.insert(NetworkLogRecord(stage: "s", provider: "p", host: "h", bytesOut: 1, bytesIn: 1, purpose: "x"))
        _ = try database.insert(NetworkLogRecord(stage: "s", provider: "p", host: "h", bytesOut: 1, bytesIn: 1, purpose: "x"))
        let turns = TurnStore(database: database)
        _ = turns.save(TurnRecord(startedAt: Date(), destination: .init(appName: "Mail"), finalText: "sent"), stage: .landed)
        _ = turns.save(TurnRecord(startedAt: Date(), destination: .init(appName: "Mail"), finalText: "held"), stage: .held)
        turns.flush()

        let store = LivePrivacyDataStore(database: database, recordingsDirectory: try Self.tempDirectory(),
                                         ambient: { nil }, turns: { turns })
        #expect(try store.count(.dictationHistory).items == 3)
        #expect(try store.count(.networkActivity).items == 2)
        #expect(try store.count(.heldText).items == 1)

        #expect(store.delete(.dictationHistory) == nil)
        #expect(try store.count(.dictationHistory).items == 0)
        #expect(turns.recoverable().count == 1, "deleting history never touches held text")
        #expect(turns.recent().filter { !$0.isRecoverable }.isEmpty, "Today's settled turns went with history")

        #expect(store.delete(.networkActivity) == nil)
        #expect(try store.count(.networkActivity).items == 0)
        #expect(store.delete(.heldText) == nil)
        #expect(turns.recoverable().isEmpty)
    }

    // MARK: - History and audio: never "Nothing is saved" over data nobody counted

    @Test("history: Reading… before a count; the design's empty only when history is off and nothing is kept")
    func historyState() throws {
        let fixture = try Self.copyFixture()
        let empty = try #require((fixture["emptyCopy"] as? [String: [String]])?["privacy"])
        let data = FakeData()
        let store = InMemorySettingsStore()
        let model = Self.model(store: store, data: data)
        #expect(model.historyState.rendering == .loading)
        #expect(model.historyState.headline == "Reading what’s kept…")
        model.refreshInventory()
        #expect(model.savesDictationHistory, "history is on by default")
        #expect(model.historyState.isContent, "history on with nothing kept yet is never “Your history is off”")
        #expect(model.dictationHistorySentence == "No dictations kept yet. Only text is ever kept here, never audio.")
        model.savesDictationHistory = false
        #expect(model.historyState.rendering == .empty)
        #expect([model.historyState.headline, model.historyState.detail ?? "", model.historyState.actionTitle ?? ""] == empty,
                "design_copy.json emptyCopy.privacy, verbatim")
        data.counts[.dictationHistory] = PrivacyScopeCount(items: 1)
        model.refreshInventory()
        #expect(model.historyState.isContent)
        #expect(model.dictationHistorySentence == "1 dictation kept as text on this Mac. Audio is never part of it.")
        data.counts[.dictationHistory] = .zero
        model.refreshInventory()
        model.ambientCapture = true
        #expect(model.historyState.isContent, "ambient capture on means history is being kept")
    }

    @Test("Save dictation history: the prototype row, written to the key Today reads; held text stays separate")
    func saveDictationHistory() throws {
        let store = InMemorySettingsStore()
        let model = Self.model(store: store, data: FakeData([.heldText: 1]))
        model.refreshInventory()
        #expect(model.savesDictationHistory && TodayHistorySettings.isEnabled(store))
        #expect(model.dictationHistorySwitchSentence.hasPrefix("On."))
        #expect(model.dictationHistorySwitchSentence.contains("Recovery drafts are kept separately until resolved."),
                "the prototype row's sentence")

        model.savesDictationHistory = false
        #expect(store.bool(SettingsKeys.dictationHistory) == false)
        #expect(TodayHistorySettings.isEnabled(store) == false, "S7b's Today reads the same switch")
        #expect(model.dictationHistorySwitchSentence.hasPrefix("Off."))
        #expect(model.dictationHistorySwitchSentence == "Off. New dictations aren’t saved, and Today doesn’t list or search past ones. Recovery drafts are kept separately until resolved.",
                "says all the switch does: DictationHistoryGate stops new writes, Today lists nothing")
        #expect(model.persistsRecovery, "held text persistence is not the history switch")
        #expect(model.historyState.isContent, "a held text is kept: never “Nothing is saved” over it")
        #expect(model.diagnosticsFacts(now: Date()).settings.contains("Save dictation history: off"))

        model.savesDictationHistory = true
        #expect(store.bool(SettingsKeys.dictationHistory) == true)
    }

    @Test("unwired mute follows the persisted mute while the page is open (menu bar or pill mutes)")
    func unwiredMuteFollowsStore() async throws {
        guard PrivacyWiring.mute == nil else { return }
        let store = InMemoryMuteStore(muted: false)
        let model = Self.model(mute: nil, muteStore: store)
        model.refreshMute()
        #expect(!model.isMuted && !model.canControlMute)
        store.muted = true
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<50 where !model.isMuted { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(model.isMuted)
        #expect(model.spoolNote.pose == .muted, "closed shutters follow the real mute")
    }

    @Test("audio: Nothing is saved only when Retain audio is off and the folder was counted empty")
    func audioState() throws {
        let data = FakeData()
        let model = Self.model(data: data)
        #expect(model.audioState.rendering == .loading, "not counted yet: never the empty words")
        model.refreshInventory()
        model.refreshSaved()
        #expect(model.audioState.rendering == .empty && model.audioState.headline == "Nothing is saved")
        data.counts[.recordings] = PrivacyScopeCount(items: 3, bytes: 3_000)
        model.refreshInventory()
        model.refreshSaved()
        #expect(model.audioState.isContent, "recordings left from before are still saved")
        model.audioRetention = true
        #expect(model.saved.isContent)
    }

    @Test("held text persistence is its own switch: on by default, off = kept for this session only")
    func recoveryPersistence() {
        let store = InMemorySettingsStore()
        let model = Self.model(store: store)
        #expect(model.persistsRecovery)
        #expect(model.recoverySentence.contains("kept apart from history"))
        model.persistsRecovery = false
        #expect(TurnSettings.persistsRecovery(store) == false)
        #expect(model.recoverySentence.hasPrefix(TurnStore.sessionOnlyLabel))
    }

    // MARK: - Diagnostics: redacted by default, exact preview

    static func facts(audio: [DiagnosticsFile] = []) -> DiagnosticsFacts {
        DiagnosticsFacts(generatedAt: Date(timeIntervalSince1970: 1_800_000_000), appVersion: "1.11.0", osVersion: "macOS 26",
                         permissions: ["Microphone: Allowed"],
                         settings: ["Recordings folder: /Users/someone/Library/Application Support/VoicePlus/Recordings"],
                         kept: ["Recordings: 2 recordings"], network: ["api.openai.com: 1 request, 120 B out"],
                         flags: ["directedSpeech: off"],
                         transcripts: [DiagnosticsTranscript(time: Date(), app: "com.apple.mail", text: "Meet Mira on Friday")],
                         audio: audio)
    }

    @Test("redacted by default: no dictated text, no audio, no home path; the preview is the report plus its files")
    func redactedExport() {
        let redactor = DiagnosticsRedactor(home: "/Users/someone", user: "someone")
        let export = PrivacyDiagnostics.export(Self.facts(audio: [DiagnosticsFile(name: "a-raw.wav", bytes: 10)]),
                                               options: .redacted, redactor: redactor)
        #expect(!export.report.contains("Meet Mira"))
        #expect(!export.includesTranscripts && !export.includesAudio)
        #expect(export.files.map(\.name) == ["report.txt"])
        #expect(export.report.contains("Not included: dictated text, audio"))
        #expect(!export.report.contains("/Users/someone"))
        #expect(export.report.contains("~/Library/Application Support/VoicePlus/Recordings"))
        #expect(export.preview.hasPrefix(export.report))
        #expect(export.preview.contains("• report.txt"))
        #expect(export.files[0].bytes == Int64(export.report.utf8.count))
    }

    @Test("opt-in adds exactly the dictated text and the audio, and the preview lists them")
    func optInExport() {
        let export = PrivacyDiagnostics.export(Self.facts(audio: [DiagnosticsFile(name: "a-raw.wav", bytes: 10)]),
                                               options: DiagnosticsOptions(includeTranscripts: true, includeAudio: true),
                                               redactor: DiagnosticsRedactor(home: "", user: ""))
        #expect(export.report.contains("Meet Mira on Friday"))
        #expect(export.report.contains("[Dictated text — included because you turned it on]"))
        #expect(export.files.map(\.name) == ["report.txt", "audio/a-raw.wav"])
        #expect(export.preview.contains("• audio/a-raw.wav"))
    }

    @Test("write puts exactly the previewed files on disk, and a failed copy leaves nothing behind")
    func writeExport() throws {
        let parent = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("src.wav")
        try Data(repeating: 7, count: 32).write(to: source)
        let export = PrivacyDiagnostics.export(Self.facts(audio: [DiagnosticsFile(name: "src.wav", bytes: 32, source: source)]),
                                               options: DiagnosticsOptions(includeAudio: true),
                                               redactor: DiagnosticsRedactor(home: "", user: ""))
        let folder = try PrivacyDiagnostics.write(export, into: parent, folderName: "out")
        #expect(try String(contentsOf: folder.appendingPathComponent("report.txt"), encoding: .utf8) == export.report)
        #expect(try Data(contentsOf: folder.appendingPathComponent("audio/src.wav")) == Data(repeating: 7, count: 32))

        var broken = export
        broken.files.append(DiagnosticsFile(name: "audio/missing.wav", bytes: 1, source: parent.appendingPathComponent("missing.wav")))
        #expect(throws: (any Error).self) { try PrivacyDiagnostics.write(broken, into: parent, folderName: "half") }
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("half").path))
    }

    @Test("the page's export reads dictations only after the opt-in")
    func modelExport() throws {
        let database = try AppDatabase.inMemory()
        try database.insert(DictationRecord(startedAt: Date(), endedAt: nil, register: "prose", route: "dictate",
                                            appBundleID: "com.apple.mail", rawText: "r", finalText: "Launch checklist is ready",
                                            spansJSON: "[]"))
        let model = Self.model(database: database)
        #expect(!model.diagnosticsExport().report.contains("Launch checklist"))
        model.diagnosticsOptions.includeTranscripts = true
        #expect(model.diagnosticsExport().report.contains("Launch checklist is ready"))
        let parent = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let shown = model.diagnosticsExport()
        let folder = try #require(model.saveExport(shown, into: parent))
        #expect(try String(contentsOf: folder.appendingPathComponent("report.txt"), encoding: .utf8) == shown.report)
        #expect(model.exportStatus?.hasPrefix("Saved to ") == true)
    }

    // MARK: - The page: Spool note, header, partial banner

    @Test("page anatomy: Spool note, S04 banner over content after a partial delete, the fixture's title")
    func pageAnatomy() throws {
        let fixture = try Self.copyFixture()
        let screen = try #require((fixture["screens"] as? [String: [String: String]])?["privacy"])
        let data = FakeData([.recordings: 2])
        data.leftovers[.recordings] = PrivacyRemainder(scope: .recordings, count: 1, items: ["Recording from 18 Sep, 12:45"])
        let mute = FakeMute()
        let model = Self.model(data: data, mute: mute)
        model.refreshMute()
        var blocks = SectionPageAnatomy.blocks(copy: .section(.privacy), state: .content, banner: model.banner,
                                               spoolNote: model.spoolNote, hotkey: "fn / 🌐")
        #expect(SectionPageAnatomy.snapshot(blocks) == """
            spool-note[ready] Spool · Ready when you are. Microphone closed.
            header \(screen["title"]!) / \(screen["subtitle"]!)
            content
            """)
        model.delete([.recordings])
        model.setMuted(true)
        blocks = SectionPageAnatomy.blocks(copy: .section(.privacy), state: .content, banner: model.banner,
                                           spoolNote: model.spoolNote, hotkey: "fn / 🌐")
        let s04 = RecoveryCatalog.entry(.S04)
        #expect(SectionPageAnatomy.snapshot(blocks) == """
            spool-note[muted] VoicePlus is muted. The microphone stays closed until you unmute.
            banner ⚠ \(s04.headline) — \(s04.consequence)\(SectionCopy.partialSuffix) [\(s04.action)]
            header Privacy / Know what is kept, and what leaves this Mac.
            content
            """)
    }

    @Test("every state the page can produce is well formed, and its words carry no raw tokens")
    func statesAndVoice() async {
        let data = FakeData()
        let model = Self.model(data: data)
        var states = [model.egress, model.historyState, model.audioState]
        await model.reload()
        states += [model.egress, model.historyState, model.audioState, model.saved]
        let broken = Self.model(load: { _ in throw Boom() })
        await broken.reload()
        states.append(broken.egress)
        for state in states { #expect(state.isWellFormed, "“\(state.headline)” is malformed") }

        let rows = PrivacyAccess.rows(permissions: nil, screenRecordingGranted: false, screenRecordingRequested: false)
        var words = rows.flatMap { [$0.title, $0.detail, $0.status] }
        words += PrivacyProcessing.rows(settings: InMemorySettingsStore()).flatMap { [$0.title, $0.detail, $0.status] }
        words += PrivacyDataScope.allCases.flatMap { [$0.title, $0.noun(2), $0.leavesAlone] }
        words += states.flatMap { [$0.headline, $0.detail ?? ""] }
        for word in words {
            for token in ["_", "network_log", "dictation_history", ".wav", "Privacy_", "privacy.", "enum", "nil"] {
                #expect(!word.contains(token), "“\(word)” shows a raw token “\(token)”")
            }
        }
    }

    // MARK: - Reachability (the old Data and Flags tabs, the J1 rows)

    @Test("every re-homed Privacy marker and every S7f row is in the section's source")
    func markers() throws {
        let sources = try SettingsReachability.sourceFiles(for: .privacy).map {
            try String(contentsOf: Self.packageRoot.appendingPathComponent($0), encoding: .utf8)
        }.joined()
        let required = SettingsReachability.allItems.filter { $0.home == .privacy }.map(\.marker) + [
            "privacy.recordings.retention", "privacy.recordings.corpus", "privacy.recordings.reveal",
            "privacy.recordings.deleteAll", "privacy.hardMute", "privacy.meetingCapture", "privacy.sync",
            "privacy.recoveryPersistence", "privacy.saveDictationHistory", "privacy.processing", "privacy.delete.", "privacy.delete.remaining",
            "privacy.diagnostics.includeTranscripts", "privacy.diagnostics.includeAudio", "privacy.diagnostics.preview",
        ]
        for marker in required { #expect(sources.contains(marker), "“\(marker)” is not in the Privacy section") }
    }

    // MARK: - Pixel smoke

    @Test("pixel smoke: the Privacy content renders, and the muted note draws the closed-shutter cameo")
    func renders() throws {
        let store = InMemorySettingsStore()
        let model = Self.model(store: store, data: FakeData([.recordings: 2]), mute: FakeMute(muted: true))
        model.refreshInventory()
        model.refreshMute()
        let meetings = MeetingsSectionViewModel(settings: store, calendarAuthorized: { false },
                                                list: { _ in (records: [], unreadable: []) })
        let view = PrivacySectionView(model: model, meetings: meetings, sync: SyncSettingsViewModel(service: nil),
                                      settings: store, open: { _ in }, reviewRetention: {})
            .frame(width: 760, height: 2600)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 760)

        let note = SpoolNote(model.spoolNote.pose, model.spoolNote.text).frame(width: 400, height: 80)
        let noteImage = try #require(ImageRenderer(content: note).cgImage)
        #expect(noteImage.width > 0)
    }
}
