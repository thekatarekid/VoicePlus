import Engine
import Foundation
import Injection
import Lab
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// R7.1 — the one window's shell and, for every section, its four renderings: **content**, **empty**,
/// **loading**, **error** (`DESIGN.md` §9).
///
/// This toolchain has no XCTest, no UI testing and no simulator, so a SwiftUI `body` cannot be
/// exercised. What can be — and what the states actually live in — are the section view models:
/// every rendering is a value they compute, so every rendering is asserted here by driving the same
/// inputs the real window drives them with.
@Suite("the one window: sections, and every section's four states")
@MainActor
struct MainWindowShellTests {

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "vp.window.\(UUID().uuidString)")! }

    // MARK: - The shell

    @Test("six sections, in the order DESIGN §9 fixes, with ⌘1–⌘6 in that order")
    func sectionOrder() {
        #expect(MainWindowSection.allCases == [.today, .meetings, .dictionary, .voice, .privacy, .settings])
        #expect(MainWindowSection.allCases.map(\.shortcutIndex) == [1, 2, 3, 4, 5, 6])
        #expect(MainWindowSection.allCases.map(\.shortcutKey) == ["1", "2", "3", "4", "5", "6"])
        // Sidebar labels, detail titles and subtitles all exist: a section with no name is a bug the
        // compiler cannot catch.
        for section in MainWindowSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.detailTitle.isEmpty)
            #expect(!section.subtitle.isEmpty)
            #expect(!section.systemImage.isEmpty)
        }
        #expect(MainWindowSection.dictionary.detailTitle == "Dictionary & Apps") // S7a: design_copy.json › screens
        // ⌘F needs somewhere to go in exactly the three sections that have a search field (§5.2).
        #expect(MainWindowSection.allCases.filter(\.hasSearchField) == [.today, .meetings, .dictionary])
    }

    @Test("the window remembers its section, and an unknown value opens Today rather than failing")
    func rememberedSection() {
        let store = InMemorySettingsStore()
        #expect(MainWindowSection.remembered(store) == .today)
        MainWindowSection.remember(.privacy, store: store)
        #expect(store.string(MainWindowSection.selectionKey) == "privacy")
        #expect(MainWindowSection.remembered(store) == .privacy)
        store.set("a-section-from-a-future-build", for: MainWindowSection.selectionKey)
        #expect(MainWindowSection.remembered(store) == .today)
        #expect(MainWindowSection.remembered(nil) == .today)
    }

    @Test("the four renderings are mutually exclusive, and each one is well formed")
    func stateVocabulary() {
        #expect(SectionRendering.allCases.count == 4)
        #expect(SectionState.content.isContent)
        #expect(SectionState.content.isWellFormed)
        // An empty explains itself; an error names a way out; loading is one static line.
        #expect(SectionState.empty("Nothing yet", detail: "Do the thing").isWellFormed)
        #expect(!SectionState.empty("Nothing yet").isWellFormed, "an empty list with no explanation is banned by §9.1")
        #expect(SectionState.loading().isWellFormed)
        #expect(SectionState.loading().headline == "Loading…")
        #expect(SectionState.error("It broke", action: "Try again").isWellFormed)
        #expect(!SectionState.error("It broke").isWellFormed, "an error with no action is the dead end §11 forbids")
        // Content says nothing extra: no section may pair content with a headline.
        #expect(!SectionState(rendering: .content, headline: "spinner").isWellFormed)
    }

    // MARK: - Today / Timeline (§9.1)

    /// A stand-in for R8's `AmbientTimeline` store: this section's states exist before the store does.
    final class StubTimeline: AmbientTimelineReading, @unchecked Sendable {
        var rows: [TimelineRow]
        var failure: Error?
        var deleteFailure: Error?
        /// Holds the read open so the loading rendering can be observed while it is happening.
        var gate: Gate?
        init(rows: [TimelineRow] = [], failure: Error? = nil) { self.rows = rows; self.failure = failure }
        struct Boom: Error {}
        func rows(matching query: String) async throws -> [TimelineRow] {
            await gate?.wait()
            if let failure { throw failure }
            return query.isEmpty ? rows : rows.filter { $0.text.contains(query) }
        }
        func delete(id: String) throws {
            if let deleteFailure { throw deleteFailure }
            rows.removeAll { $0.id == id }
        }
        func deleteAll() throws {
            if let deleteFailure { throw deleteFailure }
            rows = []
        }
    }

    private func today(ambient: Bool, reader: (any AmbientTimelineReading)?,
                       held: [HeldItem] = [],
                       heldAction: @escaping (HeldItem, HeldAction) -> HeldActionResult = { _, _ in .inserted },
                       permissions: [OnboardingPermission: OnboardingPermissionStatus] = [:]) -> TodaySectionViewModel {
        var deps = OnboardingDependencies.mock()
        let checker = OnboardingMockPermissionChecker(results: [:])
        checker.statuses = permissions
        deps.permissions = checker
        return TodaySectionViewModel(deps: deps,
                                     audio: AudioInputSettingsViewModel(defaults: Self.defaults()),
                                     mute: InMemoryMuteStore(),
                                     reader: reader,
                                     ambientCaptureOn: { ambient },
                                     heldProvider: { held },
                                     heldAction: heldAction)
    }

    @Test("the readiness strip is never blank, and it survives a Timeline that cannot be read")
    func readinessStripIsAlwaysThere() async {
        let model = today(ambient: true, reader: StubTimeline(failure: StubTimeline.Boom()))
        #expect(model.readiness.map(\.id) == ["key", "microphone", "model", "mute"])
        for row in model.readiness {
            #expect(!row.word.isEmpty, "colour is never the only signal (§12.9) — every row carries a word")
            #expect(!row.detail.isEmpty)
        }
        await model.reloadTimeline()
        #expect(model.timeline.rendering == .error)
        #expect(model.timeline.headline == SectionCopy.timelineUnreadable)
        #expect(model.timeline.actionTitle == RecoveryCatalog.entry(.S01).action)   // S11: S01, scoped Try again
        #expect(model.readiness.count == 4, "the strip must still be on screen when the Timeline is broken")
    }

    @Test("two distinct empties: ambient off says so, and nothing-dictated names the key")
    func twoDistinctEmpties() async {
        let off = today(ambient: false, reader: StubTimeline(rows: [TimelineRow(time: .now, source: "ambient", text: "hello")]))
        await off.reloadTimeline()
        #expect(off.timeline.rendering == .empty)
        #expect(off.timeline.headline == SectionCopy.timelineOff)
        #expect(off.timeline.detail == SectionCopy.timelineOffDetail)

        let on = today(ambient: true, reader: StubTimeline())
        await on.reloadTimeline()
        #expect(on.timeline.rendering == .empty)
        #expect(on.timeline.headline == SectionCopy.nothingDictated)
        #expect(on.timeline.detail?.contains(on.dictationKeyName) == true)
        #expect(on.timeline.isWellFormed)
    }

    @Test("loading is a single static row, and content is rows plus search")
    func timelineLoadingAndContent() async {
        let stub = StubTimeline(rows: [TimelineRow(time: .now, source: "ambient", text: "kept")])
        let gate = Gate()
        stub.gate = gate
        let model = today(ambient: true, reader: stub)
        #expect(model.timeline.rendering == .loading, "the initial rendering is loading, never a blank list")
        // Hold the read open: the rendering *while* it runs is loading, and nothing else.
        let running = Task { await model.reloadTimeline() }
        await Task.yield()
        #expect(model.timeline.rendering == .loading)
        #expect(model.timelineRows.isEmpty, "a section may never show a spinner and content at once (§9)")
        gate.open()
        await running.value
        #expect(model.timeline.isContent)
        #expect(model.timelineRows.count == 1)
        // A delete that fails keeps the row and puts the failure in a banner, not in a blank pane.
        stub.deleteFailure = StubTimeline.Boom()
        await model.delete(rowID: model.timelineRows[0].id)
        #expect(model.timelineRows.count == 1)
        #expect(model.banner != nil)
        #expect(model.timeline.isContent)
    }

    @Test("partial data keeps its content and puts the failure in a banner (§9)")
    func partialTimelineKeepsContent() async {
        let stub = StubTimeline(rows: [TimelineRow(time: .now, source: "ambient", text: "kept")])
        let model = today(ambient: true, reader: stub)
        await model.reloadTimeline()
        #expect(model.timeline.isContent)
        stub.failure = StubTimeline.Boom()
        await model.reloadTimeline()
        #expect(model.timeline.isContent, "rows already on screen must not vanish because a refresh failed")
        #expect(model.banner?.headline == SectionCopy.timelineUnreadable)
        #expect(model.banner?.diagnostics != nil, "raw detail goes behind Copy diagnostics, never in the sentence")
    }

    @Test("a held item that will not re-insert keeps its row and gains a row error")
    func heldRowError() {
        let item = HeldItem(text: "words with nowhere to go", destination: "Notes", reason: "never-inject")
        let model = today(ambient: false, reader: nil, held: [item], heldAction: { _, _ in .unavailable })
        #expect(model.held.count == 1)
        #expect(model.heldState.isContent)
        model.perform(.insertHere, on: item)
        #expect(model.heldRowErrors[item.id] == SectionCopy.heldRowFailed)
        #expect(model.held.count == 1, "held text is never silently dropped")

        let ok = today(ambient: false, reader: nil, held: [item], heldAction: { _, _ in .inserted })
        ok.perform(.insertHere, on: item)
        #expect(ok.heldRowErrors.isEmpty)
        // Nothing held at all is its own explained empty, not a bare gap.
        let none = today(ambient: false, reader: nil)
        #expect(none.heldState.rendering == .empty)
        #expect(none.heldState.isWellFormed)
    }

    // MARK: - Meetings (§9.2)

    private func meetingsStore() -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-meetings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MeetingStore(root: root)
    }

    // S7c: design §8.2 / §9 — one empty ("No meetings yet" + Start recording) whatever the detection
    // opt-in and Calendar say; neither ever blocks manual recording. `MeetingsS7cTests` covers the rest.
    @Test("capture off, Calendar denied and nothing recorded share the design's empty with Start recording")
    func meetingEmpties() async {
        let store = InMemorySettingsStore()
        let off = MeetingsSectionViewModel(store: meetingsStore(), settings: store,
                                           calendarAuthorized: { false },
                                           list: { _ in (records: [], unreadable: []) })
        await off.reload()
        #expect(off.state.headline == DesignScreen.meetings.empty.headline)
        #expect(off.state.actionTitle == DesignScreen.meetings.empty.action)
        #expect(off.state.isWellFormed)

        store.set(true, for: SettingsKeys.meetingCaptureEnabled)
        let denied = MeetingsSectionViewModel(store: meetingsStore(), settings: store,
                                              calendarAuthorized: { false },
                                              list: { _ in (records: [], unreadable: []) })
        await denied.reload()
        #expect(denied.state.headline == DesignScreen.meetings.empty.headline)
        #expect(denied.state.actionTitle == DesignScreen.meetings.empty.action)
        #expect(denied.calendarNote != nil)

        let nothing = MeetingsSectionViewModel(store: meetingsStore(), settings: store,
                                               calendarAuthorized: { true },
                                               list: { _ in (records: [], unreadable: []) })
        await nothing.reload()
        #expect(nothing.state.headline == DesignScreen.meetings.empty.headline)
    }

    @Test("meetings: loading, content, a per-meeting row error, and a whole-store error")
    func meetingStates() async {
        let settings = InMemorySettingsStore()
        settings.set(true, for: SettingsKeys.meetingCaptureEnabled)
        let record = MeetingRecord(title: "Standup", startedAt: .now, endedAt: .now.addingTimeInterval(600))
        let content = MeetingsSectionViewModel(store: meetingsStore(), settings: settings,
                                                calendarAuthorized: { true },
                                                list: { _ in (records: [record], unreadable: ["broken-id"]) })
        #expect(content.state.rendering == .loading)
        await content.reload()
        #expect(content.state.isContent)
        #expect(content.meetings.count == 1)
        // One unreadable meeting is a row plus a banner — never the whole list going dark.
        #expect(content.unreadableIDs == ["broken-id"])
        #expect(content.banner?.diagnostics == "broken-id")

        struct Boom: Error {}
        let broken = MeetingsSectionViewModel(store: meetingsStore(), settings: settings,
                                               calendarAuthorized: { true },
                                               list: { _ in throw Boom() })
        await broken.reload()
        #expect(broken.state.rendering == .error)
        #expect(broken.state.recoveryID == DesignScreen.meetings.errorID)
        #expect(broken.state.headline == RecoveryCatalog.entry(.X02).headline)
        #expect(broken.state.actionTitle == RecoveryCatalog.entry(.X02).action)
    }

    @Test("a meeting with no words says so instead of showing an empty transcript pane")
    func emptyTranscript() async {
        let settings = InMemorySettingsStore()
        settings.set(true, for: SettingsKeys.meetingCaptureEnabled)
        let record = MeetingRecord(title: "Silent call")
        let model = MeetingsSectionViewModel(store: meetingsStore(), settings: settings,
                                             calendarAuthorized: { true },
                                             list: { _ in (records: [record], unreadable: []) })
        await model.reload()
        model.select(record)
        #expect(model.transcript.rendering == .empty)
        #expect(model.transcript.isWellFormed)
    }

    // MARK: - Dictionary / Apps (§9.3)

    private func dictionaryApps(defaults: UserDefaults, database: AppDatabase?) -> DictionaryAppsSectionViewModel {
        let model = DictionaryAppsSectionViewModel(dictionary: DictionaryViewModel(database: database),
                                                   learned: LearnedDictionaryViewModel(loop: nil, store: nil),
                                                   personas: PersonasViewModel(database: database),
                                                   snippets: SnippetsViewModel(store: InMemorySnippetStore()),
                                                   defaults: defaults)
        // S7d: words go through the store the screen connects on appear (`DictionaryAppsScreen`).
        model.connect(database: database)
        return model
    }

    // S7d: design §8.3 / §9 copy — Dictionary "Make it sound like you" · "Add a word VoicePlus keeps
    // getting wrong." · Add a word; Apps "Every app uses your defaults". `DictionaryAppsS7dTests` has the rest.
    @Test("dictionary and apps have their own empties, and adding to either turns it into content")
    func dictionaryAndAppsStates() throws {
        let database = try AppDatabase.inMemory()
        let defaults = Self.defaults()
        let model = dictionaryApps(defaults: defaults, database: database)
        #expect(model.dictionaryState.headline == DesignScreen.dictionary.empty.headline)
        #expect(model.dictionaryState.detail == "Add a word VoicePlus keeps getting wrong.")
        #expect(model.dictionaryState.actionTitle == DesignScreen.dictionary.empty.action)
        #expect(model.appsState.headline == "Every app uses your defaults")
        #expect(model.appsState.isWellFormed)

        #expect(DictionaryViewModel(database: database).add(term: "Katare"))
        model.reload()
        #expect(model.dictionaryState.isContent)

        // The never-inject switch (R2.3) had no UI before R7.2; setting it writes the key Injection
        // reads, and the row it creates is what makes Apps content.
        model.setNeverInject(true, bundleID: "com.apple.keychainaccess")
        #expect(model.isNeverInject("com.apple.keychainaccess"))
        #expect(defaults.string(forKey: InjectionSettingsKeys.neverInject)?.contains("com.apple.keychainaccess") == true)
        #expect(model.appsState.isContent)
        #expect(model.apps.contains { $0.bundleID == "com.apple.keychainaccess" && $0.neverInject })
        #expect(DictionaryAppsSectionViewModel.neverInjectConsequence == "Dictation is held here, never typed")

        model.setNeverInject(false, bundleID: "com.apple.keychainaccess")
        #expect(!model.isNeverInject("com.apple.keychainaccess"))
    }

    @Test("a Contacts denial and a failed write are banners over the list, with the existing wording")
    func dictionaryFailures() throws {
        let model = dictionaryApps(defaults: Self.defaults(), database: try AppDatabase.inMemory())
        model.reportContactsDenied()
        #expect(model.banner?.headline == SectionCopy.contactsDenied)
        #expect(model.banner?.actionTitle == SectionCopy.openSystemSettings)
        model.reportWriteFailure("disk full")
        #expect(model.banner?.headline == SectionCopy.notSaved)
        #expect(model.banner?.diagnostics == "disk full")
        model.clearBanner()
        #expect(model.banner == nil)
    }

    // MARK: - Voice (§9.4)

    private func voice(permissions: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                       counters: BenchmarkViewModel? = nil,
                       choices: [LabConfigChoice] = []) -> VoiceSectionViewModel {
        let checker = OnboardingMockPermissionChecker(results: [:])
        checker.statuses = permissions
        let lab = LabPanelViewModel(choices: choices, runner: LabRunner(clock: { 0 }, hardware: "test", thermal: { .nominal }))
        return VoiceSectionViewModel(audio: AudioInputSettingsViewModel(defaults: Self.defaults()),
                                     permissions: checker,
                                     lab: lab,
                                     counters: counters ?? BenchmarkViewModel(report: nil),
                                     profiles: SpeakerProfileStore(url: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("vp-profile-\(UUID().uuidString).json")),
                                     makeEnrollment: nil)
    }

    @Test("microphone: enumerating is a loading state, a denial is an error with the system path")
    func microphoneStates() {
        let model = voice()
        #expect(model.microphone.rendering == .loading)
        #expect(model.microphone.headline == SectionCopy.lookingForMicrophones)
        #expect(!model.isMicrophonePickerEnabled, "the picker is disabled while the list is unknown")
        model.markDevicesEnumerated()
        #expect(model.microphone.rendering != .loading)
        #expect(model.isMicrophonePickerEnabled)

        let denied = voice(permissions: [.microphone: .denied])
        #expect(denied.microphone.rendering == .error)
        // S11: the catalogue's P01 — headline, consequence and "Open Microphone settings".
        #expect(denied.microphone.headline == SectionCopy.microphoneOff)
        #expect(denied.microphone.actionTitle == RecoveryCatalog.entry(.P01).action)
        #expect(denied.microphone.detail == RecoveryCatalog.entry(.P01).consequence)
        #expect(denied.microphone.recoveryID == .P01)
    }

    @Test("enrollment: the empty says it is optional, and with no recorder wired it says that too")
    func enrollmentStates() {
        let model = voice()
        #expect(model.enrollment.rendering == .empty)
        #expect(model.enrollment.headline == SectionCopy.noEnrollment)
        #expect(model.enrollment.detail == SectionCopy.noEnrollmentDetail)
        #expect(!model.isEnrolled)
        // No recorder: an honest error, not a button that does nothing.
        #expect(model.beginEnrollment() == false)
        #expect(model.enrollment.rendering == .error)
        #expect(model.enrollment.isWellFormed)
    }

    @Test("enrollment runs inline in the Voice pane and hands the finished profile on")
    func enrollmentRunsInline() {
        let embedder = OnboardingTestEmbedder()
        let enrollment = SpeakerEnrollmentViewModel(embedder: embedder, record: { [] })
        let model = voice()
        model.install(enrollment: enrollment)
        #expect(model.enrolling === enrollment, "enrollment lives in this pane, never in its own window")
        #expect(model.enrollment.isContent)
        model.cancelEnrollment()
        #expect(model.enrolling == nil)
        #expect(model.enrollment.rendering == .empty)
    }

    @Test("benchmark: empty offers the run, a run is loading with a percentage, a failure names the stage")
    func benchmarkStates() {
        let empty = voice()
        #expect(empty.benchmark.rendering == .empty)
        #expect(empty.benchmark.headline == SectionCopy.noMeasurements)
        #expect(empty.benchmark.actionTitle == SectionCopy.runBenchmark)

        let running = voice()
        running.lab.phase = .running(done: 1, total: 4)
        running.refreshBenchmark()
        #expect(running.benchmark.rendering == .loading)
        #expect(running.benchmarkProgressText == "25%", "the percentage is text, not only a bar (§9.4)")

        let failed = voice()
        failed.lab.phase = .failed("biasing on: the fixture suite is missing")
        failed.refreshBenchmark()
        #expect(failed.benchmark.rendering == .error)
        #expect(failed.benchmark.headline == SectionCopy.benchmarkFailed(stage: "biasing on"))
        #expect(failed.benchmark.actionTitle == SectionCopy.copyDiagnostics)
        #expect(failed.benchmark.headline.contains("fixture suite") == false,
                "the raw detail belongs behind Copy diagnostics, never in the sentence")
        #expect(failed.diagnostics == "biasing on: the fixture suite is missing")

        // R4.1b's recorded counters are data, so the group is content even before a local run.
        let measured = voice(counters: BenchmarkViewModel(report: BenchmarkViewModel.lastMeasured))
        #expect(measured.benchmark.isContent)
        measured.cancelRun()
        #expect(measured.lab.phase == .idle)
    }

    // MARK: - Privacy (§9.5)

    private func privacy(defaults: UserDefaults,
                         load: ((Date) async throws -> [NetworkLogRecord])? = nil) -> PrivacySectionViewModel {
        PrivacySectionViewModel(settings: InMemorySettingsStore(),
                                flags: .inMemory(),
                                gate: EgressGate(defaults: defaults),
                                audio: AudioInputSettingsViewModel(defaults: defaults),
                                database: nil,
                                load: load,
                                bytesToday: { _ in 0 },
                                deleteEverything: { 0 })
    }

    @Test("the egress empty is scoped and dated — it never claims zero bytes ever (V3 §9.6)")
    func egressEmptyIsScoped() async {
        let model = privacy(defaults: Self.defaults(), load: { _ in [] })
        #expect(model.egress.rendering == .loading)
        await model.reload()
        #expect(model.egress.rendering == .empty)
        #expect(model.egress.headline == "Nothing has left this Mac in the last 30 days")
        #expect(!model.egress.headline.lowercased().contains("zero"))
        #expect(model.windowSentence.contains("30 days"))
        #expect(PrivacySectionViewModel.windowDays == 30)
    }

    @Test("egress: content when there are rows, error when the log will not read")
    func egressStates() async {
        let record = NetworkLogRecord(stage: "act.planner", provider: "openai", host: "api.openai.com",
                                      bytesOut: 120, bytesIn: 400, purpose: "plan an action")
        let content = privacy(defaults: Self.defaults(), load: { _ in [record] })
        await content.reload()
        #expect(content.egress.isContent)
        #expect(content.records.count == 1)

        struct Boom: Error {}
        let broken = privacy(defaults: Self.defaults(), load: { _ in throw Boom() })
        await broken.reload()
        #expect(broken.egress.rendering == .error)
        #expect(broken.egress.headline == SectionCopy.egressUnreadable)
        #expect(broken.egress.actionTitle == SectionCopy.copyDiagnostics)
    }

    @Test("the switches render from settings immediately: ambient off, seven days, audio separate")
    func privacySwitches() {
        let defaults = Self.defaults()
        let model = privacy(defaults: defaults, load: { _ in [] })
        #expect(model.ambientCapture == false, "ambient capture is off by default (V3 §9.4)")
        model.ambientCapture = true
        #expect(model.ambientCapture)
        #expect(model.retentionDays == AmbientRetentionSettings.defaultDays)
        #expect(AmbientRetentionSettings.defaultDays == 7)
        model.retentionDays = 30
        #expect(model.retentionDays == 30)
        // Audio retention is its own switch, and it is the *existing* recorder key, not a new mirror.
        // V5 F3: every dictation is stored unless the user turns it off.
        #expect(model.audioRetention == true)
        model.audioRetention = false
        #expect(UtteranceRecorder.isEnabled(defaults) == false)
        model.audioRetention = true
        #expect(UtteranceRecorder.isEnabled(defaults))
        #expect(model.saved.isContent, "with recordings on, Saved has content")
        model.audioRetention = false
        model.refreshSaved()
        #expect(model.saved.rendering == .empty)
        #expect(model.saved.headline == SectionCopy.nothingSaved)
        // The kill switch came from the Data Panel window and still writes the gate's own key.
        #expect(model.killSwitch == false)
        model.killSwitch = true
        #expect(defaults.bool(forKey: EgressGate.killSwitchKey))
        #expect(!model.deleteAllSummary.isEmpty)
    }

    // MARK: - Settings (§9.6)

    @Test("Settings has no loading state, one real empty, and a per-row not-saved error")
    func settingsStates() {
        let none = SettingsSectionViewModel(connectedProviders: { [] })
        #expect(none.state.isContent, "settings are local — they render immediately (§9.6)")
        #expect(none.providers.rendering == .empty)
        #expect(none.providers.headline == SectionCopy.nothingConnected)
        #expect(none.providers.detail?.contains("local") == true)
        #expect(none.flags.isContent, "flags show the list with none marked, never an empty pane")

        let connected = SettingsSectionViewModel(connectedProviders: { ["OpenAI"] })
        #expect(connected.providers.isContent)

        none.reportNotSaved("settings.launchAtLogin")
        #expect(none.rowError("settings.launchAtLogin")?.contains(SectionCopy.settingNotSaved) == true)
        none.clearNotSaved("settings.launchAtLogin")
        #expect(none.rowError("settings.launchAtLogin") == nil)
    }

    // MARK: - Every state, in one sweep

    @Test("every state the window can produce is well formed")
    func everyStateIsWellFormed() async {
        var states: [SectionState] = [.content]
        let t = today(ambient: false, reader: nil)
        await t.reloadTimeline()
        states += [t.timeline, t.heldState]
        let stub = StubTimeline(failure: StubTimeline.Boom())
        let broken = today(ambient: true, reader: stub)
        await broken.reloadTimeline()
        states.append(broken.timeline)
        let ok = today(ambient: true, reader: StubTimeline(rows: [TimelineRow(time: .now, source: "a", text: "b")]))
        await ok.reloadTimeline()
        states.append(ok.timeline)

        let settings = InMemorySettingsStore()
        let meetings = MeetingsSectionViewModel(store: meetingsStore(), settings: settings,
                                                calendarAuthorized: { true },
                                                list: { _ in (records: [], unreadable: []) })
        await meetings.reload()
        states += [meetings.state, meetings.transcript]

        let dictionary = dictionaryApps(defaults: Self.defaults(), database: try? AppDatabase.inMemory())
        states += [dictionary.dictionaryState, dictionary.appsState]

        let v = voice()
        states += [v.microphone, v.enrollment, v.benchmark]
        let deniedMic = voice(permissions: [.microphone: .denied])
        states.append(deniedMic.microphone)

        let p = privacy(defaults: Self.defaults(), load: { _ in [] })
        await p.reload()
        states += [p.egress, p.saved]

        let s = SettingsSectionViewModel()
        states += [s.state, s.providers, s.flags]

        for state in states {
            #expect(state.isWellFormed, "state \(state.rendering) “\(state.headline)” is malformed")
        }
        // And every rendering is represented, so this sweep is not vacuous.
        #expect(Set(states.map(\.rendering)) == Set(SectionRendering.allCases))
    }
}

/// A one-shot gate, so an async read can be held open while its loading state is asserted.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        let c = continuation
        continuation = nil
        opened = true
        lock.unlock()
        c?.resume()
    }
}

/// A three-dimension embedder that accepts anything: enough to drive the enrollment view model.
final class OnboardingTestEmbedder: SpeakerEmbedder, @unchecked Sendable {
    let name = "test"
    let dimension = 3
    func embed(_ samples: [Float]) throws -> SpeakerEmbedding {
        SpeakerEmbedding(vector: [1, 0, 0], embedder: name)
    }
}
