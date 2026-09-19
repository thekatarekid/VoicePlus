import AppKit
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S7c — Meetings: library, detail, capture panel (design §8.2, §8.9, §9; prototype `meetings` and
/// `meeting-detail`). Everything runs on in-memory stores, temp directories and scripted capture; the
/// live microphone, system audio, TCC and the window server are not exercised.
@MainActor
@Suite("S7c Meetings", .serialized)
struct MeetingsS7cTests {
    // MARK: - Fixtures

    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let en = Locale(identifier: "en_GB")
    /// 18 September 2026, 15:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_789_743_600)

    static func temp() -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-s7c-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return MeetingStore(root: root)
    }

    static func utterance(_ speaker: MeetingSpeaker, _ text: String, _ from: TimeInterval, _ to: TimeInterval,
                          confidence: Float = 0.9) -> MeetingUtterance {
        MeetingUtterance(speaker: speaker, text: text, range: from...to, confidence: confidence)
    }

    static func standup(id: String = "standup", startedAt: Date? = nil,
                        minutes: Double = 24, notes: Bool = true) -> MeetingRecord {
        let startedAt = startedAt ?? now.addingTimeInterval(-3 * 3600)
        let transcript = MeetingTranscript(utterances: [
            utterance(.you, "We agreed to move the design review to Friday.", 14, 18),
            utterance(.others(1), "Friday works. I will share the prototype before then.", 19, 24, confidence: 0.3),
        ])
        return MeetingRecord(id: id, title: "Product standup", startedAt: startedAt,
                             endedAt: startedAt.addingTimeInterval(minutes * 60), transcript: transcript,
                             notes: notes ? ExtractiveNotesProvider.generate(transcript) : nil)
    }

    static func model(store: MeetingStore? = nil, records: [MeetingRecord], unreadable: [String] = [],
                      settings: InMemorySettingsStore = InMemorySettingsStore(),
                      calendar: Bool = false, capture: MeetingCaptureController? = nil,
                      notes: any MeetingNotesProvider = ExtractiveNotesProvider(),
                      save: Bool = false) -> MeetingsSectionViewModel {
        let store = store ?? temp()
        if save { for record in records { _ = try? store.save(record) } }
        return MeetingsSectionViewModel(store: store, settings: settings, calendarAuthorized: { calendar },
                                        list: { _ in (records: records, unreadable: unreadable) },
                                        capture: capture ?? MeetingCaptureController(),
                                        notesProvider: notes, now: { now })
    }

    struct Boom: Error {}

    struct FailingNotes: MeetingNotesProvider {
        let name = "failing"
        func notes(for transcript: MeetingTranscript) async throws -> MeetingNotes { throw Boom() }
    }

    // MARK: - Library rows

    @Test("rows read like the prototype: Today · 24 min · Notes ready, Yesterday · 38 min · Transcript saved")
    func rows() {
        let today = Self.standup()
        let yesterday = MeetingRecord(id: "planning", title: "Weekly planning",
                                      startedAt: Self.now.addingTimeInterval(-26 * 3600),
                                      endedAt: Self.now.addingTimeInterval(-26 * 3600 + 38 * 60))
        let a = MeetingsLibrary.row(today, facts: MeetingCaptureFacts(), live: nil, now: Self.now, calendar: Self.utc, locale: Self.en)
        let b = MeetingsLibrary.row(yesterday, facts: MeetingCaptureFacts(), live: nil, now: Self.now, calendar: Self.utc, locale: Self.en)
        #expect(a.title == "Product standup")
        #expect(a.detail == "Today · 24 min · Notes ready")
        #expect(b.detail == "Yesterday · 38 min · Transcript saved")
        #expect(a.label == nil && !a.offersRecovery)

        // Paused time is not meeting time; partial captures are labelled.
        let paused = MeetingsLibrary.row(today, facts: MeetingCaptureFacts(systemAudioCaptured: false, pausedSeconds: 4 * 60),
                                         live: nil, now: Self.now, calendar: Self.utc, locale: Self.en)
        #expect(paused.detail == "Today · 20 min · Notes ready")
        #expect(paused.label == MeetingsCopy.microphoneOnly)
        let recovered = MeetingsLibrary.row(today, facts: MeetingCaptureFacts(recovered: true), live: nil, now: Self.now,
                                            calendar: Self.utc, locale: Self.en)
        #expect(recovered.label == MeetingsCopy.partialCapture)
        // A notes failure never claims "Notes ready".
        let failed = MeetingsLibrary.row(today, facts: MeetingCaptureFacts(notesFailure: "x"), live: nil, now: Self.now,
                                         calendar: Self.utc, locale: Self.en)
        #expect(failed.status == .transcriptSaved)

        // The capture running now: Recording / Paused / Preparing notes, never "needs recovery".
        var running = today
        running.endedAt = nil
        for (phase, status) in [(MeetingCaptureState.Phase.recording, MeetingRow.Status.recording),
                                (.paused, .paused), (.preparingNotes, .preparingNotes)] {
            let row = MeetingsLibrary.row(running, facts: MeetingCaptureFacts(), live: MeetingLiveCapture(meetingID: running.id, phase: phase),
                                          now: Self.now, calendar: Self.utc, locale: Self.en)
            #expect(row.status == status)
            #expect(!row.offersRecovery)
        }
        let orphan = MeetingsLibrary.row(running, facts: MeetingCaptureFacts(), live: nil, now: Self.now, calendar: Self.utc, locale: Self.en)
        #expect(orphan.status == .needsRecovery && orphan.offersRecovery)
        #expect(orphan.detail == "Today · Needs recovery")
    }

    @Test("durations and dates: under a minute, other days by date, other years with the year")
    func durationAndDates() {
        #expect(MeetingsLibrary.durationText(20) == "Under 1 min")
        #expect(MeetingsLibrary.durationText(24 * 60 + 10) == "24 min")
        let earlier = Self.now.addingTimeInterval(-5 * 86_400)
        #expect(MeetingsLibrary.dayText(earlier, now: Self.now, calendar: Self.utc, locale: Self.en) == "13 September")
        let lastYear = Self.now.addingTimeInterval(-400 * 86_400)
        #expect(MeetingsLibrary.dateText(lastYear, now: Self.now, calendar: Self.utc, locale: Self.en).hasSuffix("2025"))
    }

    // MARK: - States (design §9 Meetings row)

    @Test("No meetings yet + Start recording, whatever the opt-in and Calendar say")
    func emptyIsTheDesigns() async {
        for (optIn, calendar) in [(false, false), (true, false), (false, true), (true, true)] {
            let settings = InMemorySettingsStore()
            settings.set(optIn, for: SettingsKeys.meetingCaptureEnabled)
            let model = Self.model(records: [], settings: settings, calendar: calendar)
            await model.reload()
            #expect(model.state.rendering == .empty)
            #expect(model.state.headline == "No meetings yet")
            #expect(model.state.detail == "Start a recording whenever you need notes. Calendar connection is optional.")
            #expect(model.state.actionTitle == "Start recording")
            #expect(model.state.isWellFormed)
            #expect(model.calendarNote == (calendar ? nil : "Calendar is not connected. You can still record meetings manually."))
        }
    }

    @Test("Loading meetings… never looks like empty; a broken store is X02 with a scoped retry")
    func loadingAndError() async {
        let model = Self.model(records: [])
        #expect(model.state.rendering == .loading)
        #expect(model.state.headline == "Loading meetings…")
        #expect(model.state.detail == SectionCopy.loadingNote)
        #expect(model.state.actionTitle == nil)

        var fail = true
        let record = Self.standup()
        let broken = MeetingsSectionViewModel(store: Self.temp(), settings: nil, calendarAuthorized: { false },
                                              list: { _ in if fail { throw Boom() }; return (records: [record], unreadable: []) },
                                              capture: MeetingCaptureController())
        await broken.reload()
        #expect(broken.state.rendering == .error)
        #expect(broken.state.headline == "This meeting needs recovery")
        #expect(broken.state.actionTitle == "Recover meeting")
        #expect(broken.state.recoveryID == .X02)
        #expect(broken.state.isWellFormed)
        fail = false
        await broken.retryLoad()
        #expect(broken.state.isContent)
        #expect(broken.meetings == [record])
    }

    @Test("one unreadable meeting is a banner plus its own row; the other rows stay")
    func partial() async {
        let model = Self.model(records: [Self.standup()], unreadable: ["broken-id"])
        await model.reload()
        #expect(model.state.isContent)
        #expect(model.rows.map(\.title) == ["Product standup"])
        #expect(model.unreadableIDs == ["broken-id"])
        #expect(model.banner?.recoveryID == .X02)
        #expect(model.banner?.diagnostics == "broken-id")
        #expect(model.banner?.body?.hasSuffix(SectionCopy.partialSuffix) == true)
    }

    @Test("a folder without meeting.json (a meeting that has not spoken yet) is not unreadable")
    func unreadableNeedsAFile() throws {
        let store = Self.temp()
        try FileManager.default.createDirectory(at: store.directory(for: "fresh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.directory(for: "bad"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: store.directory(for: "bad").appendingPathComponent("meeting.json"))
        #expect(MeetingsSectionViewModel.unreadable(in: store) == ["bad"])
    }

    @Test("toolbar search filters by title and words; no matches offers Clear search")
    func search() async {
        let model = Self.model(records: [Self.standup(), MeetingRecord(id: "other", title: "Budget", startedAt: Self.now, endedAt: Self.now)])
        await model.reload()
        model.search = "prototype"
        #expect(model.rows.map(\.id) == ["standup"])
        model.search = "zebra"
        #expect(model.searchHidesEverything)
        #expect(MeetingsCopy.noMatches("zebra") == "No matches for “zebra”")
    }

    // MARK: - Start recording (no calendar never blocks manual start)

    @Test("Start recording opens capture with Calendar denied and the opt-in off")
    func manualStartIgnoresCalendar() async {
        let driver = ScriptedMeetingDriver()
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        let settings = InMemorySettingsStore()
        settings.set(false, for: SettingsKeys.meetingCaptureEnabled)
        let model = Self.model(records: [], settings: settings, calendar: false, capture: capture)
        await model.reload()
        await model.startRecording(title: "Standup")
        #expect(driver.calls == ["start:Standup"])
        #expect(capture.state.phase == .recording)
        #expect(settings.bool(SettingsKeys.meetingCaptureEnabled) == false, "starting manually never flips the opt-in")
    }

    @Test("with no capture wired, Start says so (X01) instead of pretending to record")
    func startUnavailable() async {
        let capture = MeetingCaptureController()
        let model = Self.model(records: [], capture: capture)
        await model.startRecording()
        #expect(capture.state.phase == .idle)
        #expect(capture.state.problem == .unavailable)
        model.captureChanged(capture.state)
        #expect(model.captureProblem?.recoveryID == .X01)
        #expect(model.captureProblem?.headline == "Meeting setup needs attention")
        #expect(model.captureProblem?.actionTitle == "Review permissions")
    }

    // MARK: - Capture: panel and pill mirror one state (Q0 / Q1 / Q2)

    @Test("Q0 → Q1 → Q0 → Q2 → idle: the pill and the panel say the same thing at every step")
    func pillAndPanelMirror() async throws {
        let driver = ScriptedMeetingDriver()
        let gate = MeetingStopGate()
        driver.stopGate = gate
        var clock = Self.now
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        capture.now = { clock }
        var pushed: [MeetingPillInfo?] = []
        capture.onPillInfo = { pushed.append($0) }

        func mirrored(_ phase: MeetingPillInfo.Phase?) {
            let info = capture.pillInfo
            let panel = MeetingPanelContent(state: capture.state, now: clock)
            #expect(info?.phase == phase)
            #expect(panel.pillPhase == phase)
            #expect(panel.status == (info?.headline ?? MeetingPanelContent.idleStatus))
            #expect(panel.detail == (info?.detail ?? ""))
            #expect(pushed.last.flatMap { $0 } == info)
        }

        #expect(await capture.start(title: "Standup"))
        mirrored(.recording)
        clock = clock.addingTimeInterval(65)
        var panel = MeetingPanelContent(state: capture.state, now: clock)
        #expect(panel.timer == "1:05")
        #expect(panel.status == "Meeting · recording")
        #expect(panel.detail == "Microphone + system audio · 1:05")
        #expect(panel.buttons == [.pause, .stop])
        #expect(panel.tracks.map(\.condition) == [.recording, .recording])
        #expect(panel.spool.key == .meeting)
        #expect(panel.spool.animates == false, "a static compact cassette beside the transcript")

        await capture.pause()
        mirrored(.paused)
        #expect(driver.calls.last == "pause", "panel pause closes the same capture")
        clock = clock.addingTimeInterval(30)
        panel = MeetingPanelContent(state: capture.state, now: clock)
        #expect(panel.timer == "1:05", "the timer does not run while paused")
        #expect(panel.status == "Meeting paused")
        #expect(panel.buttons == [.resume, .stop])
        #expect(panel.tracks.map(\.condition) == [.paused, .paused])
        #expect(panel.spool.key == .paused)

        await capture.resume()
        mirrored(.recording)
        clock = clock.addingTimeInterval(10)
        #expect(capture.state.elapsed(at: clock) == 75)

        let stopping = Task { await capture.stop() }
        try await Self.waitUntil { driver.calls.contains("stop") }
        mirrored(.preparingNotes)
        panel = MeetingPanelContent(state: capture.state, now: clock)
        #expect(panel.status == "Preparing meeting notes")
        #expect(panel.buttons.isEmpty)
        #expect(panel.spool.key == .notes)
        #expect(panel.tracks.first?.condition == .stopped, "no microphone is recording")
        await gate.open()
        let record = await stopping.value
        #expect(record?.id == driver.record.id)
        #expect(driver.summary == MeetingCaptureSummary(pauseCount: 1, pausedSeconds: 30))
        mirrored(nil)
        #expect(pushed.last! == nil, "the meeting row leaves the pill")
        #expect(capture.lastFinished?.id == driver.record.id)
    }

    @Test("system audio denied → microphone-only capture with a visible missing-track notice")
    func microphoneOnly() async {
        let driver = ScriptedMeetingDriver()
        driver.systemAudio = false
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        capture.now = { Self.now }
        #expect(await capture.start(title: "Call"))
        #expect(capture.state.phase == .recording, "denial never blocks the microphone track")
        let panel = MeetingPanelContent(state: capture.state, now: Self.now)
        #expect(panel.tracks.map(\.condition) == [.recording, .missing])
        #expect(panel.tracks[1].accessibilityLabel == "System audio: Not recording")
        #expect(panel.notice?.recoveryID == .X01)
        #expect(panel.notice?.body == "System audio permission is missing — recording from your microphone only.")
        #expect(capture.pillInfo?.detail == "Microphone only · 0:00")
        // The notice stays for as long as the track is missing.
        capture.dismissProblem()
        #expect(capture.state.problem == .systemAudioMissing)

        // Lost mid-meeting: the same notice appears.
        let both = ScriptedMeetingDriver()
        let second = MeetingCaptureController(driver: both)
        second.tickInterval = 0
        #expect(await second.start(title: "Call"))
        #expect(MeetingPanelContent(state: second.state, now: Self.now).notice == nil)
        both.loseSystemAudio()
        try? await Self.waitUntil { !second.state.systemAudio }
        #expect(second.state.problem == .systemAudioMissing)
        #expect(MeetingPanelContent(state: second.state, now: Self.now).tracks[1].condition == .missing)
    }

    @Test("a failed start records nothing and says so; a failed resume stays paused")
    func failures() async {
        let driver = ScriptedMeetingDriver()
        driver.startError = Boom()
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        #expect(await capture.start() == false)
        #expect(capture.state.phase == .idle)
        #expect(capture.state.problem == .couldNotStart)
        #expect(capture.pillInfo == nil)

        let resumable = ScriptedMeetingDriver()
        resumable.resumeError = Boom()
        let other = MeetingCaptureController(driver: resumable)
        other.tickInterval = 0
        await other.start()
        await other.pause()
        await other.resume()
        #expect(other.state.phase == .paused)
        #expect(other.state.problem == .couldNotResume)
        #expect(other.pillInfo?.phase == .paused)
    }

    @Test("live words reach the panel's transcript, merged like the saved transcript")
    func liveTranscript() async throws {
        let driver = ScriptedMeetingDriver()
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        await capture.start()
        driver.say(Self.utterance(.you, "Hello", 0, 1))
        driver.say(Self.utterance(.you, "there.", 1.2, 2))
        driver.say(Self.utterance(.others(1), "Hi!", 3, 4, confidence: 0.2))
        try await Self.waitUntil { capture.state.utterances.count == 2 }
        let lines = MeetingTranscriptLine.lines(capture.state.transcript)
        #expect(lines.map(\.eyebrow) == ["00:00 · You", "00:03 · Others"])
        #expect(lines[0].text == "Hello there.")
        #expect(lines[1].isUncertain)
    }

    // MARK: - The pill

    @Test("the meeting row takes an idle pill, never a dictation turn, and leaves when capture ends")
    func pillMirror() {
        let info = MeetingPillInfo(phase: .recording, elapsed: 3)
        #expect(MeetingPillMirror.next(for: info, shown: .hidden) == .meeting(info))
        #expect(MeetingPillMirror.next(for: info, shown: .ready(hint: "x")) == .meeting(info))
        #expect(MeetingPillMirror.next(for: info, shown: .meeting(info)) == nil)
        #expect(MeetingPillMirror.next(for: info, shown: .listening(level: 0)) == nil)
        #expect(MeetingPillMirror.next(for: nil, shown: .meeting(info)) == .hidden)
        #expect(MeetingPillMirror.next(for: nil, shown: .listening(level: 0)) == nil)

        let pill = PillViewModel()
        MeetingPillMirror.apply(info, to: pill)
        #expect(pill.state == .meeting(info))
        MeetingPillMirror.apply(nil, to: pill)
        #expect(pill.state == .hidden)
    }

    @Test("the pill's Pause / Resume / Stop / Expand act on a manual meeting only")
    func pillButtons() async throws {
        let driver = ScriptedMeetingDriver()
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        let panel = MeetingPanelController(capture: capture)
        #expect(MeetingCaptureWiring.handle(.pause, capture: capture, panel: panel) == false, "no meeting: caller routes it")
        await capture.start()
        #expect(MeetingCaptureWiring.handle(.pause, capture: capture, panel: panel))
        try await Self.waitUntil { capture.state.phase == .paused }
        #expect(MeetingCaptureWiring.handle(.resume, capture: capture, panel: panel))
        try await Self.waitUntil { capture.state.phase == .recording }
        #expect(MeetingCaptureWiring.handle(.commit, capture: capture, panel: panel) == false)
        #expect(MeetingCaptureWiring.handle(.stop, capture: capture, panel: panel))
        try await Self.waitUntil { capture.state.phase == .idle }
        #expect(driver.calls.first?.hasPrefix("start:") == true)
        #expect(Array(driver.calls.dropFirst()) == ["pause", "resume", "stop"])
    }

    // MARK: - Panel geometry (design §4: 560 × 360 preferred)

    @Test("the expanded panel is 560 × 360 under the housing, clamped on a small display")
    func panelFrame() {
        let notched = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32, notchWidth: 200, menuBarHeight: 32)
        let frame = MeetingPanelController.frame(on: notched)
        #expect(frame.size == CGSize(width: 560, height: 360))
        #expect(frame.maxY == CGFloat(950), "top edge at the bottom of the forbidden band")
        #expect(frame.midX == CGFloat(756))
        #expect(NotchGeometry.clearsHousing(frame, on: notched))

        let external = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), menuBarHeight: 24)
        #expect(MeetingPanelController.frame(on: external).maxY == CGFloat(1080 - 24) - NotchGeometry.floatingGap)

        let tiny = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 400, height: 300), menuBarHeight: 24)
        let small = MeetingPanelController.frame(on: tiny)
        #expect(small.width <= CGFloat(400 - 16) && small.height <= CGFloat(300 - 24))
        #expect(tiny.frame.contains(small))
    }

    // MARK: - Unfinished recordings

    @Test("an unfinished recording: banner above the list, Recover on its row only, the others untouched")
    func unfinishedBanner() async {
        var interrupted = Self.standup(id: "cut", notes: false)
        interrupted.endedAt = nil
        interrupted.transcript.utterances.append(Self.utterance(.you, "And one more thing.", 190, 204))
        let fine = Self.standup(id: "fine")
        let model = Self.model(records: [interrupted, fine])
        await model.reload()
        #expect(model.unfinished.map(\.id) == ["cut"])
        let banner = model.unfinished[0]
        #expect(banner.headline == "An unfinished recording was found")
        #expect(banner.body == "3:24 of transcript is available on this Mac.")
        #expect(UnfinishedRecording(id: "a", title: "A", retained: 204, hasAudio: true).body == "3:24 of audio is available on this Mac.")
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        #expect(rows["cut"]?.offersRecovery == true)
        #expect(rows["fine"]?.offersRecovery == false)
        #expect(rows["fine"]?.status == .notesReady)

        // The meeting being recorded right now is not "unfinished".
        model.captureChanged(Self.liveState(id: "cut", phase: .recording))
        #expect(model.unfinished.isEmpty)
        #expect(model.rows.first { $0.id == "cut" }?.status == .recording)
    }

    @Test("Recover closes the saved transcript as it is and prepares notes — never inventing a turn")
    func recover() async throws {
        let store = Self.temp()
        var interrupted = Self.standup(id: "cut", notes: false)
        interrupted.endedAt = nil
        let model = Self.model(store: store, records: [interrupted, Self.standup(id: "fine")], save: true)
        await model.reload()
        await model.recover(id: "cut")
        let recovered = try store.load(id: "cut")
        #expect(recovered.transcript == interrupted.transcript, "speaker turns are kept exactly")
        #expect(recovered.endedAt == interrupted.startedAt.addingTimeInterval(24))
        #expect(recovered.notes != nil)
        #expect(model.unfinished.isEmpty)
        #expect(model.facts("cut").recovered)
        #expect(model.rows.first { $0.id == "cut" }?.label == MeetingsCopy.partialCapture)
        #expect(model.rows.first { $0.id == "fine" }?.status == .notesReady)
        #expect(MeetingFilesStore(store: store).facts(for: "cut").recovered, "kept beside the meeting")
    }

    @Test("Recover with failing notes keeps the transcript; the Notes banner never hides it")
    func recoverWithoutNotes() async throws {
        let store = Self.temp()
        var interrupted = Self.standup(id: "cut", notes: false)
        interrupted.endedAt = nil
        let model = Self.model(store: store, records: [interrupted], notes: FailingNotes(), save: true)
        await model.reload()
        await model.recover(id: "cut")
        #expect(try store.load(id: "cut").endedAt != nil)
        model.open(id: "cut")
        #expect(model.transcript.isContent)
        #expect(model.notes == nil)
        #expect(model.notesBanner?.recoveryID == .N01)
        #expect(model.notesBanner?.body?.hasSuffix(SectionCopy.partialSuffix) == true)
        #expect(model.lines.count == 2, "the transcript stays usable")
        #expect(model.rows.first?.status == .transcriptSaved)
    }

    @Test("Discard removes only that recording")
    func discard() async throws {
        let store = Self.temp()
        var interrupted = Self.standup(id: "cut")
        interrupted.endedAt = nil
        let model = Self.model(store: store, records: [interrupted, Self.standup(id: "fine")], save: true)
        await model.reload()
        #expect(model.unfinished.first?.discardMessage.contains("0:24") == true)
        model.discard(id: "cut")
        #expect(model.meetings.map(\.id) == ["fine"])
        #expect(model.unfinished.isEmpty)
        #expect((try? store.load(id: "fine")) != nil)
        #expect((try? store.load(id: "cut")) == nil)
    }

    // MARK: - Detail

    @Test("detail header: title · 18 September · 24 min · Saved on this Mac; tabs Notes / Transcript / Ask")
    func detailHeader() {
        let header = MeetingDetailHeader(record: Self.standup(), facts: MeetingCaptureFacts(), now: Self.now,
                                         calendar: Self.utc, locale: Self.en)
        #expect(header.title == "Product standup")
        #expect(header.subtitle == "18 September · 24 min · Saved on this Mac")
        #expect(MeetingDetailTab.allCases.map(\.title) == ["Notes", "Transcript", "Ask"])
        #expect(MeetingPanelTab.allCases.map(\.title) == ["Transcript", "Notes", "Ask"])
    }

    @Test("Notes: Summary, Decisions, Action items; ticks are kept beside the meeting")
    func notes() async throws {
        let store = Self.temp()
        let transcript = MeetingTranscript(utterances: [
            Self.utterance(.you, "We agreed to keep the current launch date.", 0, 4),
            Self.utterance(.others(1), "I will share the updated prototype by Friday.", 5, 9),
        ])
        let record = MeetingRecord(id: "m", title: "Launch", startedAt: Self.now, endedAt: Self.now.addingTimeInterval(600),
                                   transcript: transcript, notes: ExtractiveNotesProvider.generate(transcript))
        let model = Self.model(store: store, records: [record], save: true)
        await model.reload()
        model.open(id: "m")
        let notes = try #require(model.notes)
        #expect(!notes.summary.isEmpty)
        #expect(notes.decisions == ["We agreed to keep the current launch date."])
        #expect(notes.actionItems == ["Others: I will share the updated prototype by Friday."])
        model.setActionItem(notes.actionItems[0], done: true)
        #expect(model.completedActionItems == [notes.actionItems[0]])
        #expect(MeetingFilesStore(store: store).facts(for: "m").completedActionItems == [notes.actionItems[0]])
        #expect(model.notesBanner == nil)
    }

    @Test("Transcript: speaker labels, timestamps, uncertainty marks and search")
    func transcriptLines() async {
        let model = Self.model(records: [Self.standup()])
        await model.reload()
        model.open(id: "standup")
        #expect(model.lines.map(\.eyebrow) == ["00:14 · You", "00:19 · Others"])
        #expect(model.lines.map(\.isUncertain) == [false, true])
        model.transcriptQuery = "PROTOTYPE"
        #expect(model.visibleLines.map(\.id) == [1])
        model.transcriptQuery = "others"
        #expect(model.visibleLines.map(\.id) == [1], "search matches the speaker label too")
        model.transcriptQuery = "zebra"
        #expect(model.visibleLines.isEmpty)
        #expect(MeetingTranscriptLine.uncertainBelow == TranscriptSpan.lowConfidenceThreshold)
        #expect(MeetingTranscriptLine.clock(3725) == "1:02:05")
    }

    @Test("audio seeking only when audio was retained")
    func audioSeek() async throws {
        let store = Self.temp()
        let model = Self.model(store: store, records: [Self.standup()], save: true)
        await model.reload()
        model.open(id: "standup")
        #expect(model.retainedAudio == nil)
        try Data().write(to: store.directory(for: "standup").appendingPathComponent("audio.wav"))
        #expect(model.retainedAudio?.lastPathComponent == "audio.wav")
        #expect(MeetingsCopy.audioOnlyWhenRetained == "Audio playback appears only when audio is retained.")
    }

    @Test("Ask is disabled with “Needs a configured service” and discloses the route")
    func ask() async {
        let model = Self.model(records: [Self.standup()])
        #expect(model.askRoute == nil)
        #expect(MeetingAskRoute.disclosure(nil) == "Route: none configured. Nothing leaves this Mac.")
        let view = MeetingAskView(route: nil, onOpenProviders: {}, dark: false)
        #expect(view.isEnabled == false)
        #expect(MeetingsCopy.askNeedsService == "Needs a configured service")
        #expect(MeetingsCopy.askHeadline == "Choose how to ask.")
        let cloud = MeetingAskRoute(name: "Acme", isLocal: false)
        #expect(cloud.disclosure == "Route: Acme. This meeting’s transcript is sent there when you ask.")
        // A route alone does not enable Ask: nothing answers yet (Ask ships in a later wave).
        #expect(MeetingAskView(route: cloud, onOpenProviders: {}, dark: false).isEnabled == false)
    }

    @Test("No speech captured explains the tracks; Preparing transcript… while notes are made")
    func detailStates() async {
        let silent = MeetingRecord(id: "quiet", title: "Quiet call", startedAt: Self.now, endedAt: Self.now.addingTimeInterval(60))
        let store = Self.temp()
        try? MeetingFilesStore(store: store).save(MeetingCaptureFacts(systemAudioCaptured: false), for: "quiet")
        let model = Self.model(store: store, records: [silent, Self.standup()])
        await model.reload()
        model.open(id: "quiet")
        #expect(model.transcript.rendering == .empty)
        #expect(model.transcript.headline == "No speech captured")
        #expect(model.transcript.detail == "Check the microphone and system-audio tracks before your next meeting. "
                + MeetingsCopy.tracksMicrophoneOnly)
        #expect(model.transcript.actionTitle == "Check capture")
        #expect(model.transcript.isWellFormed)

        model.open(id: "standup")
        model.captureChanged(Self.liveState(id: "standup", phase: .preparingNotes))
        #expect(model.transcript.rendering == .loading)
        #expect(model.transcript.headline == "Preparing transcript…")
        #expect(model.transcript.isWellFormed)
        #expect(model.notesBanner == nil, "no failure claim while notes are still being prepared")
        model.captureChanged(MeetingCaptureState())
        #expect(model.transcript.isContent)
    }

    @Test("the detection opt-in keeps its key and never gates the library")
    func optIn() async {
        let settings = InMemorySettingsStore()
        let model = Self.model(records: [Self.standup()], settings: settings)
        await model.reload()
        #expect(model.isCaptureEnabled == false)
        model.isCaptureEnabled = true
        #expect(settings.bool(SettingsKeys.meetingCaptureEnabled) == true)
        #expect(model.state.isContent)
    }

    // MARK: - Live driver (fake sources, no hardware)

    @Test("the live driver: system audio refused → microphone-only; pause/resume keep the meeting clock")
    func liveDriver() async throws {
        let store = Self.temp()
        var microphones: [MeetingFakeSource] = []
        let driver = MeetingSessionCaptureDriver(
            makeSession: { prompt in
                MeetingSession(title: prompt.title, transcriber: MeetingEchoTranscriber(), labeler: ChannelLabeler(), store: store)
            },
            makeCapture: {
                let mic = MeetingFakeSource()
                microphones.append(mic)
                return DualCapture(mic: mic, system: MeetingFakeSource(failsToStart: true),
                                   micVAD: MeetingAlwaysSpeechVAD(), systemVAD: MeetingAlwaysSpeechVAD())
            },
            makeMicrophoneOnly: { mic in
                let tee = MicrophoneOnlySource(microphone: mic)
                return DualCapture(mic: tee, system: tee.reference, micVAD: MeetingAlwaysSpeechVAD(), systemVAD: MeetingNeverSpeechVAD())
            },
            store: store)
        driver.drainInterval = 60
        let started = try await driver.start(title: "Manual", onUtterance: { _ in }, onSystemAudioLost: {})
        #expect(started.systemAudio == false)
        #expect(microphones.count == 1)
        #expect(microphones[0].isRunning)
        microphones[0].push(seconds: 0.5)
        await driver.pause()
        #expect(microphones[0].isRunning == false, "pause closes the microphone")
        try await driver.resume()
        #expect(microphones.count == 2)
        microphones[1].push(seconds: 0.25)
        let record = try await driver.stop(MeetingCaptureSummary(pauseCount: 1, pausedSeconds: 5))
        #expect(record.id == started.meetingID)
        #expect(record.endedAt != nil)
        let reach = record.transcript.utterances.map(\.range.upperBound).max() ?? 0
        #expect(abs(reach - 0.75) < 0.001, "the second stretch continues where the first stopped, not at 0:00")
        #expect(record.transcript.utterances.allSatisfy { $0.speaker == .you })
        let facts = MeetingFilesStore(store: store).facts(for: record.id)
        #expect(facts.systemAudioCaptured == false)
        #expect(facts == MeetingCaptureFacts(systemAudioCaptured: false, pauseCount: 1, pausedSeconds: 5))
        #expect(try store.load(id: record.id).transcript == record.transcript, "saved as it was closed")
    }

    @Test("the live driver saves the transcript when notes fail, and refuses to start without a session")
    func liveDriverFailures() async throws {
        let store = Self.temp()
        let driver = MeetingSessionCaptureDriver(
            makeSession: { prompt in
                MeetingSession(title: prompt.title, transcriber: MeetingEchoTranscriber(), labeler: ChannelLabeler(),
                               notesProvider: FailingNotes(), store: store)
            },
            makeCapture: {
                DualCapture(mic: MeetingFakeSource(), system: MeetingFakeSource(), micVAD: MeetingAlwaysSpeechVAD(), systemVAD: MeetingNeverSpeechVAD())
            },
            store: store)
        driver.drainInterval = 60
        let started = try await driver.start(title: "Notes fail", onUtterance: { _ in }, onSystemAudioLost: {})
        #expect(started.systemAudio)
        let record = try await driver.stop(MeetingCaptureSummary(pauseCount: 0, pausedSeconds: 0))
        #expect(record.endedAt != nil)
        #expect(record.notes == nil)
        #expect(MeetingFilesStore(store: store).facts(for: record.id).notesFailure != nil)
        #expect(try store.load(id: record.id).endedAt != nil)

        let none = MeetingSessionCaptureDriver(makeSession: { _ in nil }, makeCapture: { nil }, store: store)
        await #expect(throws: MeetingSessionCaptureDriver.Failure.noSession) {
            _ = try await none.start(title: "x", onUtterance: { _ in }, onSystemAudioLost: {})
        }
    }

    @Test("microphone-only capture feeds a silent reference as long as the microphone")
    func silentReference() throws {
        let mic = MeetingFakeSource()
        let tee = MicrophoneOnlySource(microphone: mic)
        var micCount = 0
        var referenceCount = 0
        var referencePeak: Float = 0
        tee.sink = { micCount += $0.count }
        tee.reference.sink = { buffer in
            referenceCount += buffer.count
            referencePeak = max(referencePeak, buffer.map(abs).max() ?? 0)
        }
        try tee.start()
        mic.push(seconds: 0.5)
        #expect(micCount == 8000)
        #expect(referenceCount == 8000)
        #expect(referencePeak == 0)
        tee.stop()
        #expect(!mic.isRunning)
    }

    @Test("later stretches are placed on the meeting clock")
    func shift() {
        let chunk = MeetingChunk(channel: .mic, chunk: AudioChunk(samples: [0], range: 1...3, reason: .flush))
        #expect(MeetingSessionCaptureDriver.shift([chunk], by: 0) == [chunk])
        #expect(MeetingSessionCaptureDriver.shift([chunk], by: 4).first?.range == 5...7)
    }

    // MARK: - The section still hangs off the shell

    @Test("Meetings keeps its entry point, the opt-in switch and search wiring")
    func entryPoint() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appendingPathComponent("App/Settings/MeetingsScreen.swift"), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent("App/Settings/MeetingsSectionView.swift"), encoding: .utf8)
        #expect(screen.contains("struct MeetingsScreen: SectionScreen"))
        #expect(screen.contains("MeetingsSectionView("))
        #expect(view.contains("meetings.captureEnabled"))
        #expect(view.contains("SectionPage(PageCopy(.meetings)"))
    }

    // MARK: - Helpers

    static func liveState(id: String, phase: MeetingCaptureState.Phase) -> MeetingCaptureState {
        var state = MeetingCaptureState()
        state.meetingID = id
        state.phase = phase
        return state
    }

    static func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw Boom() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Test doubles

/// Waits until opened.
actor MeetingStopGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A scripted capture: records calls, can fail, can hold `stop` open.
final class ScriptedMeetingDriver: MeetingCaptureDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    var systemAudio = true
    var startError: Error?
    var resumeError: Error?
    var stopGate: MeetingStopGate?
    private(set) var summary: MeetingCaptureSummary?
    let record = MeetingRecord(id: "scripted", title: "Scripted", startedAt: Date(), endedAt: Date())
    private var onUtterance: (@Sendable (MeetingUtterance) -> Void)?
    private var onLost: (@Sendable () -> Void)?

    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    func start(title: String, onUtterance: @escaping @Sendable (MeetingUtterance) -> Void,
               onSystemAudioLost: @escaping @Sendable () -> Void) async throws -> MeetingCaptureStart {
        if let startError { throw startError }
        log("start:\(title)")
        self.onUtterance = onUtterance
        self.onLost = onSystemAudioLost
        return MeetingCaptureStart(meetingID: record.id, systemAudio: systemAudio)
    }

    func pause() async { log("pause") }

    func resume() async throws {
        if let resumeError { throw resumeError }
        log("resume")
    }

    func stop(_ summary: MeetingCaptureSummary) async throws -> MeetingRecord {
        log("stop")
        self.summary = summary
        if let stopGate { await stopGate.wait() }
        return record
    }

    func say(_ utterance: MeetingUtterance) { onUtterance?(utterance) }
    func loseSystemAudio() { onLost?() }
}

/// A capture source the test pushes samples into.
final class MeetingFakeSource: AudioCaptureSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    var device: AudioDeviceInfo? { nil }
    private(set) var isRunning = false
    let failsToStart: Bool

    init(failsToStart: Bool = false) { self.failsToStart = failsToStart }

    func prewarm() throws {}
    func start() throws {
        if failsToStart { throw AudioCaptureError.noInputDevice }
        isRunning = true
    }
    func stop() { isRunning = false }
    func switchDevice(to device: AudioDeviceInfo?) throws {}

    func push(seconds: Double) {
        let samples = (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        samples.withUnsafeBufferPointer { sink?($0) }
    }
}

final class MeetingAlwaysSpeechVAD: VADProtocol, @unchecked Sendable {
    let name = "always"
    let frameSize = 512
    private var started = false
    func reset() async { started = false }
    func process(frame: [Float]) async throws -> VADStep {
        defer { started = true }
        return VADStep(probability: 1, isSpeech: true, event: started ? nil : .speechStart(at: 0))
    }
}

final class MeetingNeverSpeechVAD: VADProtocol, @unchecked Sendable {
    let name = "never"
    let frameSize = 512
    func reset() async {}
    func process(frame: [Float]) async throws -> VADStep { VADStep(probability: 0, isSpeech: false) }
}

/// One span per chunk, covering the chunk.
struct MeetingEchoTranscriber: MeetingTranscriber {
    func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] {
        [TranscriptSpan(text: "words", confidence: 0.9, audioRange: 0...chunk.duration)]
    }
}
