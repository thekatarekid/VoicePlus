import AppKit
import Testing
@testable import VoicePlusApp

@Suite("V3 transcript viewport")
@MainActor
struct V3TranscriptViewportTests {
    @Test func longTranscriptScrollsWithoutResizingTheReadingWindow() {
        let model = PillViewModel()
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 394, height: 48))
        view.configure(model: model, words: .live("One short line"), marks: .empty)
        view.layout()
        #expect(view.text.textContainerInset.height == 13.5)
        #expect(view.text.frame.height == 48)
        let long = String(repeating: "Readable words stay at their original size. ", count: 30)
        view.configure(model: model, words: .live(long), marks: .empty)
        view.layout()
        #expect(view.frame.height == 48)
        #expect(view.text.frame.height > 48)
        #expect(view.text.string == long)
        #expect(view.text.textContainerInset.height == 3)
        #expect(!view.scroll.hasVerticalScroller)
    }

    @Test func bracketAlternativesAreDisplayOnlyAndEditingUsesThePlainDraft() {
        let model = PillViewModel()
        let source = "Hello Mira"
        model.present(.finalPreview(FinalPreviewInfo(text: source, dwellRemaining: 0.6)))
        let marks = MarkMapping(text: source, marks: [
            UncertainMark(id: 0, kind: .word, range: 6..<10, text: "Mira", heard: "Mira", confidence: 0.2,
                          alternatives: ["Meera"])
        ], confidenceAvailable: true)
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 394, height: 48))
        view.configure(model: model, words: .final(source), marks: marks)
        #expect(view.text.string == "Hello Mira [Meera]")
        #expect(model.actionText == source)
        model.beginEditingDraft()
        view.configure(model: model, words: .final(source), marks: marks)
        #expect(view.text.isEditable)
        #expect(view.text.string == source)
        #expect(model.draftText == source)
        model.cancelDraftEdits()
    }
}
