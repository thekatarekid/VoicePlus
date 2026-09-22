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

    @Test func contextHeaderLeavesTwoCompleteLinesAndBothScrollArrowsVisible() {
        let model = PillViewModel()
        for width: CGFloat in [560, 399, 300] {
            let lanes = PillLaneLayout(size: CGSize(width: width, height: 160), hasChip: true, hasActions: true)
            let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0,
                width: lanes.wordsLane.width + 20, height: lanes.wordsLane.height))
            view.configure(model: model, words: .final("First line\nSecond line"), marks: .empty)
            view.layout()
            #expect(view.scroll.contentSize.height == 48)
            #expect(view.text.frame.height == 48)
            #expect(view.text.textContainerInset.height == 3)
            let long = String(repeating: "More readable words. ", count: 40)
            view.configure(model: model, words: .final(long), marks: .empty)
            view.layout()
            #expect(view.bounds.contains(view.up.frame))
            #expect(view.bounds.contains(view.down.frame))
            #expect(view.track.frame.height == 24)
            #expect(!view.track.isHidden)
            #expect(!view.down.isHidden)
        }
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

    @Test func commandASelectsTheFocusedDraftWithoutAnEditMenu() throws {
        _ = NSApplication.shared
        let text = DraftTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 48))
        let window = NSWindow(contentRect: text.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = text
        text.isEditable = true
        text.string = "Original draft"
        #expect(window.makeFirstResponder(text))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(text.performKeyEquivalent(with: event))
        #expect(text.selectedRange() == NSRange(location: 0, length: text.string.utf16.count))
        text.insertText("Replacement", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(text.string == "Replacement")
        #expect(window.makeFirstResponder(nil))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!text.performKeyEquivalent(with: event))
        #expect(text.selectedRange().length == 0, "an unfocused transcript must not take another field's shortcut")
    }

    @Test func localEscapeRestoresDraftWithoutCancellingThePreview() {
        let model = PillViewModel()
        let original = "Original draft"
        model.present(.finalPreview(FinalPreviewInfo(text: original, dwellRemaining: 0.6)))
        model.setPointerInside(true)
        model.beginEditingDraft()
        let view = PillTranscriptViewport(frame: CGRect(x: 0, y: 0, width: 414, height: 48))
        view.configure(model: model, words: .final(original), marks: .empty)
        view.text.string = "Uncommitted edit"
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.text))
        #expect(model.draftText == "Uncommitted edit")
        let parent = CancelProbe()
        view.text.nextResponder = parent
        view.text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!model.isEditingDraft)
        #expect(model.draftText == original)
        #expect(model.actionText == original)
        #expect(parent.cancellations == 0, "the editor must consume this command without bubbling")
        if case .finalPreview = model.state {} else { Issue.record("Escape cancelled the parent preview") }
    }

    @Test func localCompositionDoesNotCancelTheDraft() {
        let text = DraftTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 48))
        text.isEditable = true
        text.string = "Draft"
        var cancelled = false
        text.onCancelDraft = { cancelled = true }
        text.setMarkedText("候補", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: 0, length: 0))
        #expect(text.hasMarkedText())
        text.cancelOperation(nil)
        #expect(!cancelled)
        text.unmarkText()
    }

    @Test func editingShortcutsRouteToNativeCommandsAndUndoRedo() throws {
        _ = NSApplication.shared
        let text = ClipboardCommandProbe(frame: CGRect(x: 0, y: 0, width: 300, height: 48))
        let window = NSWindow(contentRect: text.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = text
        text.isEditable = true
        text.allowsUndo = true
        text.string = "Original draft"
        #expect(window.makeFirstResponder(text))
        func command(_ character: String, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
        }
        for character in ["c", "x", "v"] {
            #expect(text.performKeyEquivalent(with: try command(character)))
        }
        #expect(text.commands == ["copy", "cut", "paste"])
        #expect(text.string == "Original draft", "spies must not touch the user's general pasteboard")

        let undo = try #require(text.undoManager)
        #expect(undo !== window.undoManager, "draft session history must not be shared with the window")
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        text.selectAll(nil)
        text.insertText("Replacement", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        #expect(text.performKeyEquivalent(with: try command("z")))
        #expect(text.string == "Original draft")
        #expect(text.performKeyEquivalent(with: try command("z", flags: [.command, .shift])))
        #expect(text.string == "Replacement")
    }

    private final class ClipboardCommandProbe: DraftTextView {
        var commands: [String] = []
        override func copy(_ sender: Any?) { commands.append("copy") }
        override func cut(_ sender: Any?) { commands.append("cut") }
        override func paste(_ sender: Any?) { commands.append("paste") }
    }

    private final class CancelProbe: NSResponder {
        var cancellations = 0
        override func cancelOperation(_ sender: Any?) { cancellations += 1 }
    }

}
