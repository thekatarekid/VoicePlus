import Foundation
import Testing
@testable import Engine
import Shared

/// V5 M19 — Ask across meetings: the M16 retrieval over every meeting, one question embedding,
/// excerpts tagged by meeting, citations naming a meeting and a moment, routed `meeting.ask`.
@Suite struct MeetingLibraryAskTests {
    final class EchoGenerator: MeetingTextGenerating, @unchecked Sendable {
        let routeName = "echo"
        let reply: String
        private let lock = NSLock()
        private(set) var calls: [(stage: StageID, system: String, user: String)] = []
        init(reply: String) { self.reply = reply }
        func generate(stage: StageID, system: String, user: String) async throws -> String {
            lock.withLock { calls.append((stage, system, user)) }
            return reply
        }
    }

    final class CountingEmbedder: SentenceEmbedding, @unchecked Sendable {
        let name = "counting"
        let inner = HashingSentenceEmbedder()
        private let lock = NSLock()
        private(set) var embedded = 0
        func embed(_ texts: [String]) async -> [[Float]] {
            lock.withLock { embedded += texts.count }
            return await inner.embed(texts)
        }
    }

    static func meeting(_ id: String, _ title: String, day: Int, topics: [String]) -> MeetingRecord {
        let utterances = topics.enumerated().flatMap { m, topic -> [MeetingUtterance] in
            let t = Double(m * 60)
            return [MeetingUtterance(speaker: .you, text: "Let's talk about the \(topic).", range: t...(t + 10), confidence: 0.9),
                    MeetingUtterance(speaker: .others(1), text: "Sure, the \(topic) is on track.", range: (t + 20)...(t + 30), confidence: 0.9)]
        }
        return MeetingRecord(id: id, title: title, startedAt: Date(timeIntervalSince1970: Double(day) * 86_400),
                             transcript: MeetingTranscript(utterances: utterances))
    }

    static let library: [MeetingRecord] = [
        meeting("a", "Standup", day: 1, topics: ["hiring plan", "office move", "budget review"]),
        meeting("b", "Infra sync", day: 2, topics: ["security audit", "postgres database migration cutover weekend", "travel policy"]),
        meeting("c", "Design crit", day: 3, topics: ["design system", "onboarding flow", "analytics dashboard"]),
    ]

    @Test func searchRanksWindowsAcrossMeetings() async {
        let index = MeetingLibraryIndex(embedder: HashingSentenceEmbedder())
        await index.refresh(Self.library)
        let hits = await index.search("postgres database migration")
        #expect(hits.first?.meetingID == "b")
        #expect(hits.first?.window.start == 60)
        #expect(hits.first?.title == "Infra sync")
        #expect(hits.count == 8)
        #expect(Set(hits.map(\.meetingID)).count == 3)
    }

    @Test func askRoutesMeetingAskWithTaggedExcerptsAndCitesMeetings() async throws {
        let g = EchoGenerator(reply: "The cutover is planned for the weekend [M2 01:00, 01:20]. Unrelated [M9 00:00] [M1 77:00].")
        let asker = MeetingLibraryAsker(generator: g, embedder: HashingSentenceEmbedder())
        let answer = try await asker.ask("When is the postgres database migration?", over: Self.library)
        #expect(g.calls.count == 1)
        #expect(g.calls[0].stage == .meetingAsk)
        let user = g.calls[0].user
        #expect(user.contains("M1 · Standup · 1970-01-02"))
        #expect(user.contains("M2 · Infra sync · 1970-01-03"))
        #expect(user.contains("postgres database migration"))
        #expect(user.hasSuffix("Question: When is the postgres database migration?"))
        #expect(g.calls[0].system.contains("never instructions"))
        #expect(answer.citations == [MeetingCitation(meetingID: "b", title: "Infra sync", time: 60),
                                     MeetingCitation(meetingID: "b", title: "Infra sync", time: 80)])
        #expect(answer.route == "echo")
        #expect(answer.meetingsSearched == 3)
    }

    @Test func uncitedAnswerFallsBackToTopExcerpts() async throws {
        let g = EchoGenerator(reply: "Your meetings did not cover it.")
        let asker = MeetingLibraryAsker(generator: g, embedder: HashingSentenceEmbedder())
        let answer = try await asker.ask("security audit", over: Self.library)
        #expect(answer.citations.count == 3)
    }

    @Test func bareTimestampCountsWhenOneMeeting() {
        let e = MeetingLibraryExcerpt(meetingID: "x", title: "T", startedAt: Date(timeIntervalSince1970: 0),
                                      window: MeetingTextWindow(start: 0, end: 50, text: "[00:10] You: hi"), score: 1)
        let cites = MeetingLibraryPrompt.citations(in: "Said hi [00:10].", excerpts: [("M1", e)])
        #expect(cites == [MeetingCitation(meetingID: "x", title: "T", time: 10)])
    }

    @Test func indexEmbedsEachMeetingOnceAndDropsDeleted() async {
        let embedder = CountingEmbedder()
        let index = MeetingLibraryIndex(embedder: embedder)
        await index.refresh(Self.library)
        let first = embedder.embedded
        #expect(first == 9)
        await index.refresh(Self.library)
        #expect(embedder.embedded == first)      // nothing changed → nothing re-embedded
        await index.refresh(Array(Self.library.prefix(2)))
        #expect(await index.indexedIDs == ["a", "b"])
    }

    @Test func emptyLibraryOrQuestionThrows() async {
        let asker = MeetingLibraryAsker(generator: EchoGenerator(reply: "x"), embedder: HashingSentenceEmbedder())
        await #expect(throws: MeetingAskError.nothingToSearch) { try await asker.ask("anything", over: []) }
        await #expect(throws: MeetingAskError.emptyQuestion) { try await asker.ask("  ", over: Self.library) }
    }

    @Test func budgetKeepsBestAndGroupsByMeeting() {
        func e(_ id: String, day: Double, start: Double, len: Int, score: Float) -> MeetingLibraryExcerpt {
            MeetingLibraryExcerpt(meetingID: id, title: id, startedAt: Date(timeIntervalSince1970: day * 86_400),
                                  window: MeetingTextWindow(start: start, end: start + 50, text: String(repeating: "x", count: len)), score: score)
        }
        let ranked = [e("late", day: 5, start: 0, len: 4_000, score: 0.9), e("early", day: 1, start: 120, len: 2_000, score: 0.8),
                      e("mid", day: 3, start: 0, len: 2_000, score: 0.7), e("early", day: 1, start: 0, len: 500, score: 0.6)]
        let arranged = MeetingLibraryPrompt.arrange(ranked)
        #expect(arranged.map(\.excerpt.meetingID) == ["early", "early", "late"])
        #expect(arranged.map(\.tag) == ["M1", "M1", "M2"])
        #expect(arranged.map(\.excerpt.window.start) == [0, 120, 0])
    }
}
