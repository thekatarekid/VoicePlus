import Foundation
import Testing
import Shared
@testable import Pipeline

// N26 — "skip cleanup" is its own switch, separate from "style off".

private func spans(_ words: [String]) -> [TranscriptSpan] {
    words.enumerated().map { i, w in
        TranscriptSpan(text: w, confidence: 0.9, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
    }
}

private func stage(_ gen: ScriptedCleanup, log: OutcomeLog? = nil) -> CleanupStage {
    CleanupStage(generator: gen, mode: { .always }, outputGuard: { CleanupGuard(entityGuard: nil) },
                 observer: { log?.add($0) })
}

@Suite struct CleanupSkipN26Tests {
    @Test func styleOffAloneNoLongerSkipsCleanup() async throws {
        let gen = ScriptedCleanup { _ in "meet at five, I mean six" }
        var ctx = StageContext(); ctx.extra[StyleStage.enabledKey] = "false"
        _ = try await stage(gen).process(spans(["meet", "at", "five", "I", "mean", "six"]), context: ctx)
        #expect(gen.prompts.count == 1)
    }

    @Test func skipKeySkipsWithVerbatimReason() async throws {
        let gen = ScriptedCleanup { _ in "X" }
        let log = OutcomeLog()
        var ctx = StageContext(); ctx.extra[CleanupStage.skipKey] = "true"
        let out = try await stage(gen, log: log).process(spans(["meet", "at", "five"]), context: ctx)
        #expect(out.renderedText == "meet at five")
        #expect(gen.prompts.isEmpty)
        #expect(log.all == [.skipped("verbatim")])
    }

    @Test func keepEdgesUndoesCapitalAndAddedPeriod() async throws {
        let gen = ScriptedCleanup { _ in "Meet at six." }
        var ctx = StageContext()
        ctx.extra[StyleStage.enabledKey] = "false"
        ctx.extra[CleanupStage.keepEdgesKey] = "true"
        let out = try await stage(gen).process(spans(["meet", "at", "five", "no", "six"]), context: ctx)
        #expect(out.renderedText == "meet at six")
    }

    @Test func withoutKeepEdgesTheModelsEdgesStand() async throws {
        let gen = ScriptedCleanup { _ in "Meet at six." }
        let out = try await stage(gen).process(spans(["meet", "at", "five", "no", "six"]), context: StageContext())
        #expect(out.renderedText == "Meet at six.")
    }

    @Test func keepingEdgesTable() {
        #expect(CleanupStage.keepingEdges(of: "meet at five no six", in: "Meet at six.") == "meet at six")
        #expect(CleanupStage.keepingEdges(of: "Meet at five no six.", in: "meet at six") == "Meet at six")
        #expect(CleanupStage.keepingEdges(of: "is it five no six?", in: "Is it six?") == "is it six?")
        #expect(CleanupStage.keepingEdges(of: "", in: "Hello.") == "Hello")
        #expect(CleanupStage.keepingEdges(of: "iPhone notes", in: "iPhone notes.") == "iPhone notes")
    }
}
