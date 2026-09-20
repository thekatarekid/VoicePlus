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
        #expect(view.text.string == "Hello Mira [or did you mean Meera]")
        #expect(model.actionText == source)
        model.beginEditingDraft()
        view.configure(model: model, words: .final(source), marks: marks)
        #expect(view.text.isEditable)
        #expect(view.text.string == source)
        #expect(model.draftText == source)
        model.cancelDraftEdits()
    }

    @Test func liveTranscriptScrollsWithoutAcquiringKeyboardFocus() {
        let model = PillViewModel()
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 414, height: 48))
        let source = String(repeating: "Live words ", count: 50)
        view.configure(model: model, words: .live(source), marks: .empty)
        view.layout()
        #expect(view.text.frame.height > view.scroll.contentSize.height)
        #expect(!view.text.acceptsFirstResponder)
        #expect(!view.text.isEditable)
        #expect(!model.focusInside)
        view.configure(model: model, words: .final(source), marks: .empty)
        #expect(view.text.acceptsFirstResponder)
        #expect(view.text.isSelectable)
        #expect(!model.focusInside) // becoming reviewable does not itself focus the panel
    }

    @Test func copyExcludesOnlyDecoratedSuggestionsIncludingPartialSelections() throws {
        let model = PillViewModel()
        let source = "Hello Mira [team]."
        let marks = MarkMapping(text: source, marks: [
            UncertainMark(id: 0, kind: .word, range: 6..<10, text: "Mira", heard: "Mira", confidence: 0.2,
                          alternatives: ["Meera"])
        ], confidenceAvailable: true)
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 414, height: 48))
        view.configure(model: model, words: .final(source), marks: marks)
        let display = view.text.string as NSString
        let suggestion = display.range(of: " [or did you mean Meera]")
        #expect(suggestion.location != NSNotFound)
        let font = try #require(view.text.textStorage?.attribute(.font, at: suggestion.location, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - 11.34) < 0.001)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("VoicePlus.copy-test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        view.text.setSelectedRange(NSRange(location: 0, length: display.length))
        #expect(view.text.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == source)
        view.text.setSelectedRange(NSRange(location: 8, length: display.length - 8))
        #expect(view.text.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "ra [team].")
        view.text.setSelectedRange(NSRange(location: suggestion.location + 2, length: 5))
        #expect(view.text.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.string(forType: .string) == "")
        #expect(!view.text.writeSelection(to: pasteboard, type: .rtf))
    }

    @Test func returnShortcutsApplyEditsAndCompositionRetainsEnter() throws {
        let model = PillViewModel()
        let source = "Hello Mira"
        model.present(.finalPreview(FinalPreviewInfo(text: source, dwellRemaining: 0.6)))
        model.setPointerInside(true)
        var applied: [String] = []
        model.onApplyDraft = { text, _, _ in applied.append(text); return true }
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 414, height: 48))
        func start() {
            model.beginEditingDraft()
            view.configure(model: model, words: .final(source), marks: .empty)
            view.text.string = "Hello Meera"
        }
        start()
        #expect(!view.text.handleDraftReturn(try key(36))) // whole-draft Enter remains a newline
        #expect(model.isEditingDraft)
        #expect(view.text.performKeyEquivalent(with: try key(36, flags: .command)))
        #expect(applied == ["Hello Meera"])
        #expect(!model.isEditingDraft)
        start()
        #expect(view.text.handleDraftReturn(try key(36, flags: .control)))
        #expect(applied.count == 2)
        start()
        view.text.editsWord = true
        #expect(view.text.handleDraftReturn(try key(36)))
        #expect(applied.count == 3)
        start()
        view.text.editsWord = true
        view.text.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(view.text.hasMarkedText())
        #expect(!view.text.handleDraftReturn(try key(36)))
        #expect(!view.text.handleDraftReturn(try key(36, flags: .command)))
        #expect(applied.count == 3)
        view.text.unmarkText()
        model.cancelDraftEdits()
    }

    @Test func scrollbarKeyboardMovesByLinePageAndBoundaryAndPausesThePreview() throws {
        let model = PillViewModel()
        model.present(.finalPreview(FinalPreviewInfo(text: "long", dwellRemaining: 0.6)))
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 414, height: 48))
        view.configure(model: model, words: .final(String(repeating: "Readable words ", count: 50)), marks: .empty)
        view.layout()
        #expect(view.track.acceptsFirstResponder)
        #expect(view.track.becomeFirstResponder())
        #expect(model.focusInside)
        view.track.keyDown(with: try key(125))
        #expect(view.scroll.contentView.bounds.minY == 21)
        view.track.keyDown(with: try key(121))
        #expect(view.scroll.contentView.bounds.minY == 63)
        view.track.keyDown(with: try key(119))
        #expect(view.scroll.contentView.bounds.minY == view.text.frame.height - 48)
        view.track.keyDown(with: try key(115))
        #expect(view.scroll.contentView.bounds.minY == 0)
        model.setPointerInside(true)
        model.setFocus(true, element: "transcript.scroll")
        view.track.keyDown(with: try key(125))
        model.setPointerInside(false)
        #expect(model.focusInside) // keyboard ownership survives pointer exit
        #expect(view.track.resignFirstResponder())
        #expect(!model.focusInside)
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: "",
                                     isARepeat: false, keyCode: code))
    }

}
