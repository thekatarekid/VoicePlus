import Foundation
import Testing
import Shared
@testable import Pipeline

// V5 I3 — per-turn stage diff: recorder ring (20), traced stages through the real runner (register
// scoping kept), secure fields never traced, cleanup reason notes, word diff.

private struct Rewrite: PipelineStage {
    let id: StageID
    let map: @Sendable (String) -> String
    func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        spans.map { $0.isLowConfidence ? $0.touched(by: id) : $0.rewritten(map($0.text), by: id) }
    }
}

private struct ScopedRewrite: RegisterScopedStage {
    let id: StageID
    let applicableRegisters: Set<Utterance.Register>
    func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        spans.map { $0.rewritten($0.text.uppercased(), by: id) }
    }
}

private func spans(_ text: String) -> [TranscriptSpan] {
    text.split(separator: " ").enumerated().map { i, w in
        TranscriptSpan(text: String(w), confidence: 0.9, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
    }
}

@Suite struct TurnTraceTests {
    @Test func recordsBeforeAfterPerStage() async throws {
        let rec = TurnTraceRecorder()
        let stages = TracedStage.wrapping([
            Rewrite(id: "itn") { $0 == "two" ? "2" : $0 },
            Rewrite(id: "cleanup") { $0 },
            Rewrite(id: "style") { $0 == "tickets" ? "tickets." : $0 },
        ], recorder: rec)
        var s = spans("book two tickets")
        var ctx = StageContext(appBundleID: "com.apple.mail")
        ctx.extra["unrelated"] = "x"
        for st in stages { s = try await st.process(s, context: ctx) }

        let turn = try #require(rec.latest)
        #expect(turn.input == "book two tickets")
        #expect(turn.output == "book 2 tickets.")
        #expect(turn.appBundleID == "com.apple.mail")
        #expect(turn.steps.map(\.stage) == ["itn", "cleanup", "style"])
        #expect(turn.changedSteps.map(\.stage) == ["itn", "style"])
        // Cleanup is a headline stage: listed even when it changed nothing.
        #expect(turn.explainedSteps.map(\.stage) == ["itn", "cleanup", "style"])
        #expect(turn.steps[0].before == "book two tickets" && turn.steps[0].after == "book 2 tickets")
    }

    @Test func keepsOnlyTheLastTwentyTurnsNewestFirst() async throws {
        let rec = TurnTraceRecorder()
        let stage = TracedStage(Rewrite(id: "style") { $0 }, recorder: rec, opensTurn: true)
        for i in 0..<25 { _ = try await stage.process(spans("turn \(i)"), context: StageContext()) }
        #expect(rec.recent.count == TurnTraceRecorder.capacity)
        #expect(rec.recent.first?.input == "turn 24")
        #expect(rec.recent.last?.input == "turn 5")
        rec.clear()
        #expect(rec.recent.isEmpty)
    }

    @Test func secureFieldIsNeverTraced() async throws {
        let rec = TurnTraceRecorder()
        let stages = TracedStage.wrapping([Rewrite(id: "itn") { $0 }, Rewrite(id: "style") { $0 }], recorder: rec)
        var ctx = StageContext()
        FieldContext(axRole: "AXTextField", axSubrole: "AXSecureTextField").write(into: &ctx)
        var s = spans("hunter two")
        for st in stages { s = try await st.process(s, context: ctx) }
        #expect(rec.recent.isEmpty)
    }

    @Test func cleanupReasonIsAttachedAsANote() async throws {
        let rec = TurnTraceRecorder()
        let cleanup = CleanupStage(generator: nil, mode: { .automatic }, observer: { rec.note(stage: .cleanup, code: $0.code) })
        let stages = TracedStage.wrapping([Rewrite(id: "itn") { $0 }, cleanup], recorder: rec)
        var s = spans("hello there")
        for st in stages { s = try await st.process(s, context: StageContext()) }
        let step = try #require(rec.latest?.steps.last)
        #expect(step.stage == .cleanup)
        #expect(step.note == "skipped:noModel")
        #expect(!step.changed)
    }

    @Test func runnerKeepsRegisterScopingAndMetrics() async throws {
        let rec = TurnTraceRecorder()
        let stages = TracedStage.wrapping([
            Rewrite(id: "itn") { $0 },
            ScopedRewrite(id: "shout", applicableRegisters: [.code]),
            Rewrite(id: "style") { $0 },
        ], recorder: rec)
        #expect(stages[1] is any RegisterScopedStage)
        let runner = PipelineRunner(stages: stages)
        let result = try await runner.run(spans("hello world"), context: StageContext())
        // The `.code`-only stage was skipped for a prose turn, exactly as without tracing.
        #expect(result.text == "hello world")
        #expect(result.metrics.first { $0.stage == "shout" }?.skipped == true)
        let turn = try #require(rec.latest)
        #expect(!turn.steps.map(\.stage).contains("shout"))
        #expect(turn.steps.map(\.stage) == ["itn", "style"])
    }

    @Test func eachRunOpensItsOwnTurn() async throws {
        let rec = TurnTraceRecorder()
        let runner = PipelineRunner(stages: TracedStage.wrapping([Rewrite(id: "style") { $0 }], recorder: rec))
        _ = try await runner.run(spans("one"), context: StageContext())
        _ = try await runner.run(spans("two"), context: StageContext())
        #expect(rec.recent.map(\.input) == ["two", "one"])
        #expect(rec.recent.allSatisfy { $0.steps.count == 1 })
    }

    @Test func titlesArePlainLanguage() {
        #expect(StageDiff.title(for: "itn") == "Numbers, dates and units")
        #expect(StageDiff.title(for: .cleanup) == "AI cleanup")
        #expect(StageDiff.title(for: "formatter.fieldRole") == "Field formatting")
        #expect(StageDiff.title(for: "custom.stage") == "custom.stage")
    }

    @Test func wordDiff() {
        let p = StageDiffText.pieces(before: "meet thursday no friday at two", after: "Meet Friday at 2.")
        #expect(p.contains(StageDiffText.Piece(.removed, "meet thursday no friday")) || p.contains { $0.kind == .removed })
        #expect(p.filter { $0.kind == .added }.map(\.text).joined(separator: " ") == "Meet Friday 2.")
        #expect(p.filter { $0.kind == .kept }.map(\.text) == ["at"])
        #expect(StageDiffText.pieces(before: "same words", after: "same words") == [StageDiffText.Piece(.kept, "same words")])
        #expect(StageDiffText.pieces(before: "", after: "new") == [StageDiffText.Piece(.added, "new")])
    }
}
