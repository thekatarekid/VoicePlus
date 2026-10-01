import Foundation
import Testing
import Pipeline
import Shared
@testable import VoicePlusApp

// V5 I3 — app side of "Why did it write that?": wiring (every stage traced, cleanup reason noted),
// the sheet model (newest first, clear), the menu row (absent until a turn exists), copy.

@Suite struct WhyItWroteThatTests {
    private func spans(_ text: String) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 0.9, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
        }
    }

    @Test func wiringTracesEveryStageAndNotesCleanup() async throws {
        let rec = TurnTraceRecorder()
        let stages = TurnTraceWiring.traced([StyleStage(), CleanupStage(generator: nil, mode: { .automatic })], recorder: rec)
        #expect(stages.map(\.id) == [.style, "cleanup"])
        let runner = PipelineRunner(stages: stages)
        _ = try await runner.run(spans("hello there"), context: StageContext())
        let turn = try #require(rec.latest)
        #expect(turn.steps.map(\.stage) == [.style, "cleanup"])
        #expect(turn.steps.last?.note == "skipped:noModel")
        #expect(WhyItWroteThatCopy.noChange(turn.steps.last?.note) == "No change · no cleanup model installed")
    }

    @Test @MainActor func modelListsNewestFirstAndClears() async throws {
        let rec = TurnTraceRecorder()
        let stage = TracedStage(StyleStage(), recorder: rec, opensTurn: true)
        _ = try await stage.process(spans("first"), context: StageContext(appBundleID: "com.apple.mail"))
        _ = try await stage.process(spans("second"), context: StageContext(appBundleID: "com.tinyspeck.slackmacgap"))
        let model = WhyItWroteThatModel(recorder: rec)
        #expect(model.turns.map(\.input) == ["second", "first"])
        #expect(model.selected?.input == "second")
        #expect(WhyItWroteThatModel.label(for: model.turns[0]).contains("slackmacgap"))
        model.clear()
        #expect(model.turns.isEmpty)
        #expect(rec.recent.isEmpty)
    }

    @Test @MainActor func menuRowOnlyOnceATurnExists() async throws {
        let rec = TurnTraceRecorder()
        #expect(WhyItWroteThatMenu.item(recorder: rec) == nil)
        _ = try await TracedStage(StyleStage(), recorder: rec, opensTurn: true).process(spans("hi"), context: StageContext())
        let item = try #require(WhyItWroteThatMenu.item(recorder: rec))
        #expect(item.title == "Why did it write that?")
        #expect(item.identifier?.rawValue == WhyItWroteThatCopy.menuID)
    }

    @Test func reasonCopyNeverShowsText() {
        #expect(WhyItWroteThatCopy.reason("rejected:lengthRatio").contains("lengthRatio"))
        #expect(WhyItWroteThatCopy.reason("timeout").contains("kept"))
        #expect(WhyItWroteThatCopy.noChange(nil) == "No change")
    }
}
