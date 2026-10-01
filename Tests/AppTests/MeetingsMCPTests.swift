import Engine
import Foundation
import Providers
import Shared
import Testing
@testable import VoicePlusApp

// V5 M23 — the app side of the meetings MCP server: the setting is off by default and then
// nothing listens (HTTP never started, stdio refuses with exit 2); on, the server starts and stops
// with it; the store-backed source lists, reads (with speaker names), finds the live meeting and
// searches.

private struct EmptySource: MCPMeetingSource {
    func listMeetings(limit: Int) async -> [MCPMeetingSummary] { [] }
    func transcript(id: String) async -> MCPMeetingTranscript? { nil }
    func liveTranscript() async -> MCPMeetingTranscript? { nil }
    func search(_ query: String, limit: Int) async -> [MCPSearchHit] { [] }
}

private func tempStore() -> MeetingStore {
    MeetingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("vp-m23-\(UUID().uuidString)", isDirectory: true))
}

private func meeting(_ id: String, _ title: String, start: Double, ended: Bool, _ lines: [String]) -> MeetingRecord {
    let us = lines.enumerated().map { i, t in
        MeetingUtterance(speaker: i % 2 == 0 ? .you : .others(1), text: t, range: Double(i * 10)...Double(i * 10 + 5), confidence: 0.9)
    }
    return MeetingRecord(id: id, title: title, startedAt: Date(timeIntervalSince1970: start),
                         endedAt: ended ? Date(timeIntervalSince1970: start + 600) : nil, transcript: MeetingTranscript(utterances: us))
}

@Suite("V5 M23 meetings MCP", .serialized)
struct MeetingsMCPTests {
    @Test func offByDefaultMeansNoServer() async {
        final class Count: @unchecked Sendable { var made = 0 }
        let count = Count()
        let settings = InMemorySettingsStore()
        let controller = MeetingsMCPController(settings: settings, secrets: InMemorySecretStore(), port: 0,
                                               makeSource: { count.made += 1; return EmptySource() })
        #expect(!controller.isEnabled)
        await controller.apply()
        #expect(!controller.isRunning)
        #expect(controller.url == nil)
        #expect(count.made == 0, "permission off → the server is never even built")
    }

    @Test func turningItOnStartsAndOffStops() async {
        let settings = InMemorySettingsStore()
        let secrets = InMemorySecretStore()
        let controller = MeetingsMCPController(settings: settings, secrets: secrets, port: 0, makeSource: { EmptySource() })
        await controller.setEnabled(true)
        #expect(settings.bool(MeetingsMCPSettings.enabledKey) == true)
        #expect(controller.isRunning)
        #expect(controller.url?.host == "127.0.0.1")
        let token = controller.token()
        #expect(token.count == 64 && (try? secrets.get(MeetingsMCPSettings.tokenKey)) == token, "token kept in the secret store")
        #expect(controller.token() == token)
        await controller.setEnabled(false)
        #expect(!controller.isRunning)
        #expect(controller.url == nil)
    }

    @Test func stdioRefusesWhileOff() async {
        let settings = InMemorySettingsStore()
        final class Served: @unchecked Sendable { var count = 0 }
        let served = Served()
        #expect(MeetingsMCPStdio.requested(["VoicePlusApp", "--mcp-stdio"]))
        #expect(!MeetingsMCPStdio.requested(["VoicePlusApp"]))
        #expect(await MeetingsMCPStdio.run(settings: settings, store: tempStore(), serve: { _ in served.count += 1 }) == 2)
        #expect(served.count == 0)
        settings.set(true, for: MeetingsMCPSettings.enabledKey)
        #expect(await MeetingsMCPStdio.run(settings: settings, store: tempStore(), serve: { _ in served.count += 1 }) == 0)
        #expect(served.count == 1)
    }

    @Test func storeSourceListsReadsWithNamesAndFindsLive() async throws {
        let store = tempStore()
        try store.save(meeting("old", "Sync", start: 1_000, ended: true, ["Let's go with Postgres.", "I'll write the plan."]))
        let live = meeting("now", "Standup", start: 2_000, ended: false, ["Morning.", "Shipped the build."])
        try FileMeetingSpeakerNames(store: store).save(MeetingSpeakerNames([.others(1): "Sam"]), for: "old")
        let source = StoreMeetingSource(store: store, live: { live }, rank: { q, records, k in
            records.filter { $0.id == "old" }.map {
                MeetingLibraryExcerpt(meetingID: $0.id, title: $0.title, startedAt: $0.startedAt,
                                      window: MeetingTextWindow(start: 0, end: 15, text: q), score: 1)
            }
        })
        let list = await source.listMeetings(limit: 10)
        #expect(list.map(\.id) == ["now", "old"], "the live capture is listed before its first save")
        #expect(list[0].isLive && !list[1].isLive)
        #expect(list[1].speakers == ["You", "Sam"])
        let t = try #require(await source.transcript(id: "old"))
        #expect(t.lines.map(\.speaker) == ["You", "Sam"])
        #expect(t.lines[1].start == 10)
        #expect(await source.transcript(id: "missing") == nil)
        #expect(await source.liveTranscript()?.meeting.id == "now")
        let hits = await source.search("postgres", limit: 3)
        #expect(hits.map(\.meetingID) == ["old"])

        // Through the server, end to end.
        let server = MCPServer(source: source)
        let out = try #require(await server.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_live_transcript","arguments":{}}}"#.utf8)))
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("Shipped the build."))
    }

    @Test func diskLiveIsTheFreshUnfinishedMeeting() async throws {
        let store = tempStore()
        try store.save(meeting("done", "Done", start: 3_000, ended: true, ["a"]))
        try store.save(meeting("abandoned", "Crashed", start: 1_000, ended: false, ["b"]))
        let past = Date().addingTimeInterval(-3_600)
        try FileManager.default.setAttributes([.modificationDate: past],
                                              ofItemAtPath: store.directory(for: "abandoned").appendingPathComponent("meeting.json").path)
        #expect(await StoreMeetingSource.diskLive(store)() == nil, "an unfinished meeting untouched for an hour is not live")
        try store.save(meeting("rec", "Recording", start: 2_000, ended: false, ["c"]))
        #expect(await StoreMeetingSource.diskLive(store)()?.id == "rec")
    }
}
