import Engine
import Foundation
import Providers
import Shared
import Testing
@testable import VoicePlusApp

// V5 M19 — Ask across meetings: the library header's Ask goes over every listed meeting through
// `meeting.ask` (RoutingTable), citations open the cited meeting's transcript, and the model-free
// ranking (MCP `search`) works before any model is installed.

private final class AnswerEngine: LocalLLMEngine, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var users: [String] = []
    func load(modelPath: URL) async throws {}
    func unload() async {}
    func generate(system: String, user: String, maxTokens: Int, deadline: Date) async throws -> String {
        lock.withLock { users.append(user) }
        return "Sam owns the migration plan [M1 00:04]."
    }
}

private func record(_ id: String, _ title: String, day: Double, _ lines: [String]) -> MeetingRecord {
    let utterances = lines.enumerated().map { i, text in
        MeetingUtterance(speaker: i % 2 == 0 ? .you : .others(1), text: text, range: Double(i * 4)...Double(i * 4 + 3), confidence: 0.9)
    }
    return MeetingRecord(id: id, title: title, startedAt: Date(timeIntervalSince1970: day * 86_400),
                         endedAt: Date(timeIntervalSince1970: day * 86_400 + 600), transcript: MeetingTranscript(utterances: utterances))
}

private let library = [
    record("a", "Sync", day: 20_000, ["Let's go with Postgres.", "I'll write the migration plan."]),
    record("b", "Offsite", day: 20_001, ["The offsite is in Goa.", "Book the flights by Friday."]),
]

@Suite("V5 M19 ask across meetings", .serialized)
struct MeetingsAskAcrossTests {
    @Test func askAcrossRunsMeetingAskOverTheWholeLibrary() async throws {
        let engine = AnswerEngine()
        let inner = LlamaCppProvider(config: LlamaCppConfig(modelPath: URL(fileURLWithPath: "/tmp/none.gguf")),
                                     residency: ModelResidency(budgetBytes: 4 << 30), engine: engine, fileExists: { _ in true })
        let table = RoutingTable(providers: [], logger: InMemoryNetworkLogger())
        let intelligence = MeetingIntelligence()
        await #expect(throws: MeetingAskError.generation(.notConfigured)) {
            _ = try await intelligence.askAcross("x", over: library, liveID: nil)
        }
        intelligence.install(routing: table, settings: InMemorySettingsStore(), local: MeetingLocalLLMProvider(inner: inner),
                             embedder: HashingSentenceEmbedder())
        let answer = try await intelligence.askAcross("Who writes the migration plan?", over: library, liveID: nil)
        #expect(table.choice(for: .meetingAsk) == .provider(MeetingLocalLLMProvider.providerID))
        #expect(answer.meetingsSearched == 2)
        #expect(answer.citations == [MeetingCitation(meetingID: "a", title: "Sync", time: 4)])
        let user = try #require(engine.users.first)
        #expect(user.contains("M1 · Sync"))
        #expect(user.contains("M2 · Offsite"))
    }

    @Test func searchWorksWithoutAModel() async {
        let hits = await MeetingIntelligence().search("flights to Goa", over: library, k: 1)
        #expect(hits.map(\.meetingID) == ["b"])
    }

    @MainActor @Test func libraryAskPassesListedMeetingsAndCitationsOpenTheMeeting() async throws {
        let vm = MeetingsSectionViewModel(store: MeetingStore(root: FileManager.default.temporaryDirectory
                                              .appendingPathComponent("vp-m19-\(UUID().uuidString)")),
                                          settings: InMemorySettingsStore(), calendarAuthorized: { false },
                                          list: { _ in (records: library, unreadable: []) },
                                          capture: MeetingCaptureController())
        await vm.reload()
        final class Box: @unchecked Sendable { var seen: (String, [String], String?)? }
        let box = Box()
        let answer = try await vm.askAcross("flights?") { q, records, live in
            box.seen = (q, records.map(\.id), live)
            return MeetingLibraryAnswer(text: "Friday [M2 00:04]", citations: [MeetingCitation(meetingID: "b", title: "Offsite", time: 4)],
                                        route: "Local", meetingsSearched: records.count)
        }
        #expect(box.seen?.0 == "flights?")
        #expect(Set(box.seen?.1 ?? []) == ["a", "b"])
        #expect(box.seen?.2 == nil)
        #expect(vm.open(answer.citations[0]))
        #expect(vm.selected?.id == "b")
        #expect(vm.detailTab == .transcript)
        #expect(!vm.open(MeetingCitation(meetingID: "gone", title: "Gone", time: 0)))
    }

    @Test func disclosureNamesWhereExcerptsGo() {
        #expect(MeetingsAskAcrossCopy.disclosure(MeetingAskRoute(name: "claude CLI", isLocal: false)).contains("sent there"))
        #expect(MeetingsAskAcrossCopy.disclosure(MeetingAskRoute(name: "Mini", isLocal: true)).contains("stay here"))
        #expect(MeetingsAskAcrossCopy.citation(MeetingCitation(meetingID: "b", title: "Offsite", time: 64)) == "Offsite · 01:04")
    }
}
