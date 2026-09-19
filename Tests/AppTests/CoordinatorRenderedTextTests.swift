import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// D4 (V4.13) — text the coordinator shows or copies is `renderedText`, never the raw join: a
/// filler the formatter blanked leaves no leading or double space.
@Suite("D4 — DictationCoordinator uses rendered text")
@MainActor
struct CoordinatorRenderedTextTests {
    static func spans(_ words: [String]) -> [TranscriptSpan] {
        words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 0.95, audioRange: Double(i)...Double(i) + 0.4)
        }
    }

    @Test("onboarding's fallback text (no lander) has no leading space from a blanked first span")
    func guidedLandingWithoutLanderRendersText() async {
        let coordinator = DictationCoordinator(engine: StatusMenuControllerTests.CountingEngine(), database: nil,
                                               pill: PillPanelController())
        #expect(coordinator.lander == nil)
        let spans = Self.spans(["", "hello", "world"])
        #expect(spans.joinedText == " hello world", "the raw join the old path showed")
        let result = await coordinator.guidedLanding(spans)
        #expect(result == GuidedLanding(text: "hello world", injected: false))
    }

    @Test("blank spans in the middle and at the end leave single spaces")
    func guidedLandingCollapsesBlankSpans() async {
        let coordinator = DictationCoordinator(engine: StatusMenuControllerTests.CountingEngine(), database: nil,
                                               pill: PillPanelController())
        let result = await coordinator.guidedLanding(Self.spans(["so", " ", "we", "", "ship", ""]))
        #expect(result.text == "so we ship")
    }
}
