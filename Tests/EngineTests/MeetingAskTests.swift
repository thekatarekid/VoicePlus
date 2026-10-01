import Foundation
import Testing
@testable import Engine
import Shared

/// V5 M16 + M21 — Ask: 60 s windows, on-device embeddings, top-8 retrieval, routed `meeting.ask`,
/// timestamp citations, 30 s live re-index.
@Suite struct MeetingAskTests {
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

    struct FailingGenerator: MeetingTextGenerating {
        let routeName = "none"
        func generate(stage: StageID, system: String, user: String) async throws -> String {
            throw MeetingGenerationError.notConfigured
        }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    /// 20 minutes, one topic per minute; minute 12 is about the database migration.
    static func record(minutes: Int = 20) -> MeetingRecord {
        let topics = ["hiring plan", "marketing launch", "office move", "budget review", "design system", "customer churn",
                      "pricing tiers", "support backlog", "mobile release", "security audit", "travel policy", "quarterly goals",
                      "postgres database migration cutover weekend", "holiday schedule", "api deprecation", "onboarding flow",
                      "analytics dashboard", "vendor contract", "team offsite", "recruiting pipeline"]
        let utterances = (0..<minutes).flatMap { m -> [MeetingUtterance] in
            let t = Double(m * 60)
            return [MeetingUtterance(speaker: .you, text: "Let's talk about the \(topics[m % topics.count]).", range: t...(t + 10), confidence: 0.9),
                    MeetingUtterance(speaker: .others(1), text: "Sure, the \(topics[m % topics.count]) is on track.", range: (t + 20)...(t + 30), confidence: 0.9)]
        }
        return MeetingRecord(id: "m1", title: "Weekly", transcript: MeetingTranscript(utterances: utterances))
    }

    @Test func windowsAreSixtySeconds() {
        let w = MeetingRetrieval.windows(Self.record(minutes: 3).transcript, names: MeetingSpeakerNames([.others(1): "Priya"]))
        #expect(w.count == 3)
        #expect(w[1].start == 60 && w[1].end == 90)
        #expect(w[1].text.contains("[01:20] Priya: Sure"))
    }

    @Test func retrievesTopEightInOrderAndCitesTimestamps() async throws {
        let g = EchoGenerator(reply: "They plan the Postgres cutover for the weekend [12:00], confirmed at [12:20]. Also [99:00].")
        let asker = MeetingAsker(generator: g, embedder: HashingSentenceEmbedder())
        let answer = try await asker.ask("When is the postgres database migration?", about: Self.record(), live: false)
        #expect(g.calls.count == 1)
        #expect(g.calls[0].stage == .meetingAsk)
        #expect(g.calls[0].stage.rawValue == "meeting.ask")
        let user = g.calls[0].user
        let excerpts = user.components(separatedBy: "\n\n").filter { $0.hasPrefix("[") || $0.hasPrefix("Excerpts") }
        #expect(excerpts.count == MeetingRetrieval.topK)
        #expect(user.contains("postgres database migration"), "the relevant minute is retrieved")
        #expect(user.hasSuffix("Question: When is the postgres database migration?"))
        #expect(answer.citations == [720, 740], "only timestamps inside retrieved windows are kept")
        #expect(answer.route == "echo")
    }

    @Test func uncitedAnswersFallBackToRetrievedWindows() async throws {
        let g = EchoGenerator(reply: "The meeting did not cover it.")
        let asker = MeetingAsker(generator: g, embedder: HashingSentenceEmbedder())
        let answer = try await asker.ask("Anything about the moon?", about: Self.record(minutes: 2), live: false)
        #expect(answer.citations == [0, 60])
    }

    @Test func liveIndexRebuildsAtMostEveryThirtySeconds() async {
        let clock = Clock()
        let index = MeetingAskIndex(embedder: HashingSentenceEmbedder(), clock: { clock.now })
        var record = Self.record(minutes: 2)
        #expect(await index.refresh(record.transcript, live: true))
        record.transcript.utterances.append(MeetingUtterance(speaker: .you, text: "New words.", range: 125...127, confidence: 1))
        clock.now += 10
        #expect(await index.refresh(record.transcript, live: true) == false, "10 s after the last build: not yet")
        #expect(await index.windows.count == 2)
        clock.now += 21
        #expect(await index.refresh(record.transcript, live: true), "31 s: re-indexed")
        #expect(await index.windows.count == 3)
        clock.now += 100
        #expect(await index.refresh(record.transcript, live: true) == false, "unchanged transcript is not re-indexed")
        #expect(await index.builds == 2)
    }

    /// Verify fix: the Ask tab's 30 s loop captured the record when the tab opened; once an ask had
    /// indexed newer words, the loop's next rebuild put the old snapshot back and the following ask
    /// (inside 30 s) answered from it. A live index never goes back to an older transcript.
    @Test func liveIndexNeverGoesBackToAnOlderSnapshot() async {
        let clock = Clock()
        let index = MeetingAskIndex(embedder: HashingSentenceEmbedder(), clock: { clock.now })
        let opened = Self.record(minutes: 1)
        var current = opened
        #expect(await index.refresh(opened.transcript, live: true))
        current.transcript.utterances.append(MeetingUtterance(speaker: .you, text: "Ship on Friday.", range: 70...72, confidence: 1))
        clock.now += 31
        #expect(await index.refresh(current.transcript, live: true))
        #expect(await index.windows.count == 2)
        clock.now += 31
        #expect(await index.refresh(opened.transcript, live: true) == false, "stale snapshot is ignored")
        #expect(await index.windows.count == 2)
    }

    @Test func afterTheMeetingAChangedTranscriptReindexesAtOnce() async {
        let clock = Clock()
        let index = MeetingAskIndex(embedder: HashingSentenceEmbedder(), clock: { clock.now })
        var record = Self.record(minutes: 1)
        await index.refresh(record.transcript, live: false)
        record.transcript.utterances.append(MeetingUtterance(speaker: .you, text: "Late words.", range: 70...71, confidence: 1))
        #expect(await index.refresh(record.transcript, live: false))
    }

    @Test func generationFailureIsReported() async {
        let asker = MeetingAsker(generator: FailingGenerator(), embedder: HashingSentenceEmbedder())
        await #expect(throws: MeetingAskError.generation(.notConfigured)) {
            try await asker.ask("What happened?", about: Self.record(minutes: 1), live: false)
        }
        await #expect(throws: MeetingAskError.emptyQuestion) {
            try await asker.ask("  ", about: Self.record(minutes: 1), live: false)
        }
        await #expect(throws: MeetingAskError.nothingToSearch) {
            try await asker.ask("What?", about: MeetingRecord(title: "Empty"), live: false)
        }
    }

    @Test func hashingEmbedderIsDeterministicAndSeparatesTopics() async {
        let e = HashingSentenceEmbedder()
        let a = await e.embed(["database migration plan"])[0], b = await e.embed(["database migration plan"])[0]
        #expect(a == b)
        let q = MeetingRetrieval.normalised(e.vector("when is the database migration"))
        let near = MeetingRetrieval.normalised(e.vector("the database migration is on saturday"))
        let far = MeetingRetrieval.normalised(e.vector("holiday schedule for december"))
        #expect(MeetingRetrieval.cosine(q, near) > MeetingRetrieval.cosine(q, far))
    }

    @Test func appleSentenceEmbedderReturnsOneVectorPerText() async {
        let v = await NLSentenceEmbedder().embed(["hello there", "the migration is on saturday"])
        #expect(v.count == 2)
        #expect(v.allSatisfy { !$0.isEmpty })
    }
}

extension MeetingAskTests {
    @Test func excerptsAreCappedToTheBudgetBestFirst() {
        let ranked = [MeetingTextWindow(start: 120, end: 180, text: String(repeating: "a", count: 4_000)),
                      MeetingTextWindow(start: 0, end: 60, text: String(repeating: "b", count: 2_500)),
                      MeetingTextWindow(start: 60, end: 120, text: String(repeating: "c", count: 2_000))]
        let fit = MeetingRetrieval.fitting(ranked, budget: 7_000)
        #expect(fit.map(\.start) == [0, 120], "best two fit, returned in transcript order")
        let huge = [MeetingTextWindow(start: 5, end: 6, text: String(repeating: "x", count: 9_000))]
        #expect(MeetingRetrieval.fitting(huge).count == 1, "the best window is always kept")
    }
}
