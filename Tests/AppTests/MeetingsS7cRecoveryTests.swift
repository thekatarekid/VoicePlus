import Combine
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S7c — the live row, X02 recovery of an unreadable meeting, and confirmed removal (design §8.2,
/// §9, recovery catalogue X02). Temp directories and a scripted capture only; no microphone, TCC or
/// window server.
@MainActor
@Suite("S7c Meetings — live row and recovery", .serialized)
struct MeetingsS7cRecoveryTests {
    typealias S = MeetingsS7cTests

    /// Counts library reads so a test can wait for the quiet re-read after capture ends.
    final class Reads {
        var count = 0
    }

    static func model(store: MeetingStore, capture: MeetingCaptureController, reads: Reads? = nil,
                      notes: any MeetingNotesProvider = ExtractiveNotesProvider()) -> MeetingsSectionViewModel {
        MeetingsSectionViewModel(store: store, settings: InMemorySettingsStore(), calendarAuthorized: { false },
                                 list: { store in
                                     reads?.count += 1
                                     return (records: store.list(), unreadable: MeetingsSectionViewModel.unreadable(in: store))
                                 },
                                 capture: capture, notesProvider: notes, now: { S.now })
    }

    static func capture(_ driver: ScriptedMeetingDriver) -> MeetingCaptureController {
        let capture = MeetingCaptureController(driver: driver)
        capture.tickInterval = 0
        capture.now = { S.now }
        return capture
    }

    // MARK: - The live row

    @Test("Start recording lists the meeting at once, keeps its words current, and the saved meeting takes its place")
    func liveRowFromStart() async throws {
        let store = S.temp()
        let driver = ScriptedMeetingDriver()
        let capture = Self.capture(driver)
        let reads = Reads()
        let model = Self.model(store: store, capture: capture, reads: reads)
        await model.reload()
        #expect(model.state.rendering == .empty, "No meetings yet + Start recording")

        await model.startRecording(title: "Standup")
        #expect(model.state.isContent, "a meeting being recorded is never 'No meetings yet'")
        var renderings: [SectionRendering] = []
        let watch = model.$state.sink { renderings.append($0.rendering) }
        defer { watch.cancel() }
        let row = try #require(model.rows.first)
        #expect(model.rows.count == 1)
        #expect(row.id == driver.record.id && row.title == "Standup")
        #expect(row.status == .recording && row.isLive && !row.offersRecovery)
        #expect(row.detail == "Today · Recording")
        #expect(model.unfinished.isEmpty, "the capture running now is not an unfinished recording")

        // Its words reach the open detail while it records, before anything is saved.
        model.open(id: row.id)
        #expect(model.selected?.id == row.id)
        driver.say(S.utterance(.you, "Hello there.", 0, 2))
        try await S.waitUntil { model.selected?.transcript.utterances.count == 1 }
        #expect(model.lines.first?.eyebrow == "00:00 · You")

        // Paused, then microphone-only: the row says so while it runs.
        await capture.pause()
        #expect(model.rows.first?.status == .paused)
        driver.loseSystemAudio()
        try await S.waitUntil { model.rows.first?.label == MeetingsCopy.microphoneOnly }
        #expect(model.captureNotes.contains(MeetingsCopy.tracksMicrophoneOnly))
        model.delete(id: row.id)
        #expect(model.rows.first?.id == row.id, "the meeting being recorded is not deleted from the list")

        // Stop: the saved meeting replaces the live row at once; the re-read happens behind it.
        try store.save(driver.record)
        #expect(await capture.stop() != nil)
        #expect(model.liveRecord == nil)
        #expect(model.rows.map(\.id) == [driver.record.id])
        #expect(model.rows.first?.isLive == false)
        #expect(model.selected?.id == driver.record.id)
        try await S.waitUntil { reads.count == 2 }
        #expect(model.state.isContent)
        #expect(!renderings.contains(.empty) && !renderings.contains(.loading),
                "no 'No meetings yet' or 'Loading meetings…' flash around a meeting just recorded")
    }

    @Test("a meeting that could not be closed comes back as an unfinished recording on its own row")
    func stopFailureOffersRecovery() async throws {
        let store = S.temp()
        let driver = ScriptedMeetingDriver()
        driver.stopError = S.Boom()
        let capture = Self.capture(driver)
        let reads = Reads()
        let model = Self.model(store: store, capture: capture, reads: reads)
        try store.save(S.standup(id: "fine"))
        await model.reload()
        await model.startRecording(title: "Standup")
        // What the session wrote as it went: words, no end.
        try store.save(MeetingRecord(id: driver.record.id, title: "Standup", startedAt: S.now.addingTimeInterval(-600),
                                     transcript: MeetingTranscript(utterances: [S.utterance(.you, "Kept words.", 3, 204)])))
        #expect(await capture.stop() == nil)
        #expect(model.captureProblem?.recoveryID == .X01)
        try await S.waitUntil { reads.count == 2 }
        #expect(model.unfinished.map(\.id) == [driver.record.id])
        #expect(model.unfinished.first?.body == "3:24 of transcript is available on this Mac.")
        let rows = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
        #expect(rows[driver.record.id]?.offersRecovery == true)
        #expect(rows["fine"]?.status == .notesReady, "the other meetings are untouched")
    }

    // MARK: - X02: an unreadable meeting

    static func corrupt(_ store: MeetingStore, id: String) throws {
        try Data("{ not json".utf8).write(to: store.directory(for: id).appendingPathComponent("meeting.json"))
    }

    @Test("an unreadable meeting is rebuilt from its text copy: speakers, timestamps and words as saved, nothing overwritten")
    func rebuildFromText() async throws {
        let store = S.temp()
        let original = S.standup()
        try store.save(original)
        try Self.corrupt(store, id: original.id)
        try store.save(S.standup(id: "fine", startedAt: S.now.addingTimeInterval(-26 * 3600)))
        let model = Self.model(store: store, capture: MeetingCaptureController())
        await model.reload()
        #expect(model.unreadableIDs == [original.id])
        #expect(model.banner != nil, "partial: a banner, the other meetings stay")
        #expect(model.rows.map(\.id) == ["fine"])
        let day = MeetingsLibrary.dayText(original.startedAt, now: S.now)
        #expect(model.unreadableDetails[original.id] == "Product standup · \(day)", "named, never a raw id")

        await model.recoverUnreadable(id: original.id)
        #expect(model.unreadableIDs.isEmpty)
        #expect(model.banner == nil)
        #expect(model.rowProblems[original.id] == nil)
        let rebuilt = try store.load(id: original.id)
        #expect(rebuilt.title == original.title)
        #expect(rebuilt.startedAt == original.startedAt)
        #expect(rebuilt.endedAt == original.endedAt)
        #expect(rebuilt.transcript.utterances.map(\.speaker) == original.transcript.utterances.map(\.speaker))
        #expect(rebuilt.transcript.utterances.map(\.text) == original.transcript.utterances.map(\.text))
        #expect(rebuilt.transcript.utterances.map(\.range.lowerBound) == [14, 19])
        #expect(MeetingTranscriptLine.lines(rebuilt.transcript).allSatisfy { !$0.isUncertain },
                "the text copy keeps no confidence: no mark is claimed")
        #expect(rebuilt.notes != nil, "notes prepared again from the transcript")

        let dir = store.directory(for: original.id)
        let aside = try String(contentsOf: dir.appendingPathComponent(MeetingFilesStore.setAsideFileName), encoding: .utf8)
        #expect(aside == "{ not json", "the unreadable file is set aside, not overwritten")
        let text = try String(contentsOf: dir.appendingPathComponent(MeetingFilesStore.setAsideTextFileName), encoding: .utf8)
        #expect(text == original.markdown, "the text it was rebuilt from is kept as it was")

        #expect(model.facts(original.id).rebuiltFromText && model.facts(original.id).recovered)
        let row = try #require(model.rows.first { $0.id == original.id })
        #expect(row.status == .notesReady && row.label == MeetingsCopy.partialCapture)
        #expect(model.rows.first { $0.id == "fine" }?.status == .notesReady)
        model.open(id: original.id)
        #expect(model.captureNotes.contains(MeetingsCopy.rebuiltFromTextNote))
        #expect(!model.captureNotes.contains(MeetingsCopy.recoveredNote))
    }

    @Test("with no readable text copy, Recover changes nothing and says so on that row only")
    func rebuildWithoutText() async throws {
        let store = S.temp()
        try FileManager.default.createDirectory(at: store.directory(for: "lost"), withIntermediateDirectories: true)
        try Self.corrupt(store, id: "lost")
        try store.save(S.standup(id: "fine"))
        let model = Self.model(store: store, capture: MeetingCaptureController())
        await model.reload()
        #expect(model.unreadableDetails["lost"] == MeetingsCopy.savedOnThisMac)
        await model.recoverUnreadable(id: "lost")
        #expect(model.unreadableIDs == ["lost"])
        let problem = try #require(model.rowProblems["lost"])
        #expect(problem.headline == MeetingsCopy.recoverFailed)
        #expect(problem.body == MeetingsCopy.unreadableNotRecovered)
        #expect(problem.actionTitle == MeetingsCopy.showInFinder)
        #expect(model.rowProblems["fine"] == nil)
        let json = try String(contentsOf: store.directory(for: "lost").appendingPathComponent("meeting.json"), encoding: .utf8)
        #expect(json == "{ not json", "files unchanged")
        #expect(model.directory(for: "lost") == store.directory(for: "lost"))
    }

    @Test("the text-copy reader names only real speakers and refuses anything it would have to guess")
    func textCopyParser() throws {
        let doc = """
        # Planning
        _2026-09-18T12:00:00Z_

        ## Summary
        _(nothing captured)_

        ## Transcript
        - **You** [00:05] Start.
        - **Others** [01:10] Then this.
        - **Others 3** [75:03] Much later: with a colon.
        """
        let record = try #require(MeetingTextRecovery.parse(doc, id: "p"))
        #expect(record.title == "Planning")
        #expect(record.transcript.utterances.map(\.speaker) == [.you, .others(1), .others(3)])
        #expect(record.transcript.utterances.map(\.range.lowerBound) == [5, 70, 4503])
        #expect(record.transcript.utterances.map(\.range.upperBound) == [70, 4503, 4503])
        #expect(record.transcript.utterances.last?.text == "Much later: with a colon.")
        #expect(record.endedAt == record.startedAt.addingTimeInterval(4503), "no saved end: closed at the last words")

        #expect(MeetingTextRecovery.parse(doc.replacingOccurrences(of: "**Others 3**", with: "**Mira**"), id: "p") == nil,
                "an unknown speaker is never guessed")
        #expect(MeetingTextRecovery.parse(doc.replacingOccurrences(of: "# Planning", with: ""), id: "p") == nil)
        #expect(MeetingTextRecovery.parse(doc.replacingOccurrences(of: "_2026-09-18T12:00:00Z_", with: "_soon_"), id: "p") == nil)
        #expect(MeetingTextRecovery.parse(doc.replacingOccurrences(of: "[01:10]", with: "[1:99]"), id: "p") == nil)

        // Round trip through what MeetingStore writes.
        let original = S.standup()
        let again = try #require(MeetingTextRecovery.parse(original.markdown, id: original.id))
        #expect(again.transcript.utterances.map(\.text) == original.transcript.utterances.map(\.text))
        #expect(again.endedAt == original.endedAt)
    }

    @Test("capture facts written before a field existed still read, with that field's default")
    func factsDecodeOlderFiles() throws {
        let older = try JSONDecoder().decode(MeetingCaptureFacts.self, from: Data(#"{"systemAudioCaptured": false, "pauseCount": 2}"#.utf8))
        #expect(older == MeetingCaptureFacts(systemAudioCaptured: false, pauseCount: 2))
        let full = MeetingCaptureFacts(systemAudioCaptured: false, pauseCount: 1, pausedSeconds: 30, notesFailure: "x",
                                       recovered: true, rebuiltFromText: true, completedActionItems: ["a"])
        #expect(try JSONDecoder().decode(MeetingCaptureFacts.self, from: JSONEncoder().encode(full)) == full)
    }

    // MARK: - Removal is confirmed

    @Test("every removal of the only saved copy is confirmed with its own words")
    func removalCopy() {
        let unfinished = UnfinishedRecording(id: "cut", title: "Standup", retained: 204, hasAudio: true)
        #expect(MeetingRemoval.discard(unfinished).title == "Discard unfinished recording?")
        #expect(MeetingRemoval.discard(unfinished).message == "This deletes the only saved copy of 3:24 of this meeting. It can't be undone.")
        #expect(MeetingRemoval.discard(unfinished).confirm == "Discard recording")
        let delete = MeetingRemoval.delete(id: "s", title: "Product standup")
        #expect(delete.title == "Delete “Product standup”?")
        #expect(delete.message == MeetingsCopy.deleteMessage && delete.confirm == "Delete meeting")
        #expect(MeetingRemoval.deleteUnreadable(id: "x").title == MeetingsCopy.deleteUnreadableTitle)
        #expect(Set([MeetingRemoval.discard(unfinished).id, delete.id, MeetingRemoval.deleteUnreadable(id: "x").id]) == ["cut", "s", "x"])

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = (try? String(contentsOf: root.appendingPathComponent("App/Settings/MeetingsSectionView.swift"), encoding: .utf8)) ?? ""
        #expect(!view.contains("model.delete(id: row.id)") && !view.contains("model.delete(id: id)"),
                "rows never delete without the confirmation")
        #expect(view.contains("pending = .delete(") && view.contains("pending = .deleteUnreadable("))
    }

    // MARK: - The meeting prompt

    @Test("the meeting prompt uses the pill's own dark inks; recording is primary, Ignore is quiet")
    func promptStyle() throws {
        #expect(MeetingPromptView.isPrimary(.record) && MeetingPromptView.isPrimary(.joinAndRecord))
        #expect(!MeetingPromptView.isPrimary(.ignore))
        #expect(MeetingPromptView.label(for: .joinAndRecord) == "Join & Record")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/UI/MeetingPromptPanel.swift"), encoding: .utf8)
        #expect(source.contains("Tokens.Pill.Token.background"))
        #expect(!source.contains(".teal") && !source.contains(".regularMaterial"))
    }
}
