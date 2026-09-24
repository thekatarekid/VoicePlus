import AppKit
import SwiftUI
import Testing
@testable import VoicePlusApp

@Suite("V3 native keyboard traversal")
@MainActor
struct V3KeyboardTraversalTests {
    @Test func transcriptRailAndEveryFooterActionShareOneKeyLoop() throws {
        _ = NSApplication.shared
        let model = PillViewModel()
        model.present(.finalPreview(FinalPreviewInfo(
            text: String(repeating: "A readable long transcript. ", count: 30),
            dwellRemaining: 0.6, manual: true)))
        let size = NotchGeometry.activeSize
        let host = NSHostingView(rootView: PillView(model: model, size: size, attached: false))
        host.sizingOptions = []
        let panel = KeyboardTestPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        panel.recalculateKeyViewLoop()
        let views = descendants(host)
        let viewport = try #require(views.compactMap { $0 as? PillTranscriptViewport }.first)
        viewport.layout()
        viewport.track.onFraction?(0.5) // both arrows are visible in the middle of a long draft
        let buttons = views.compactMap { $0 as? PillFooterButton }.sorted {
            $0.convert(NSPoint.zero, to: host).x < $1.convert(NSPoint.zero, to: host).x
        }
        #expect(buttons.map { $0.accessibilityLabel() } == model.content().buttons.map(\.label))
        #expect(!buttons.isEmpty)
        let loop: [NSView] = [viewport.text, viewport.up, viewport.track, viewport.down] + buttons
        #expect(panel.makeFirstResponder(viewport.text))
        for target in Array(loop.dropFirst()) + [viewport.text] {
            panel.selectNextKeyView(nil)
            #expect(panel.firstResponder === target)
            #expect(model.focusInside)
        }
        for target in Array(loop.dropFirst().reversed()) + [viewport.text] {
            panel.selectPreviousKeyView(nil)
            #expect(panel.firstResponder === target)
        }
        #expect(model.focusInside)
        panel.makeFirstResponder(nil)
        #expect(!model.focusInside)
    }

    @Test func footerSupportsSpaceAndAccessibilityActivationAndSkipsUnavailableControls() throws {
        _ = NSApplication.shared
        let button = PillFooterButton(frame: CGRect(x: 0, y: 0, width: 90, height: 30))
        let panel = KeyboardTestPanel(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = button
        var presses = 0
        var focus: [Bool] = []
        button.onPress = { presses += 1 }
        button.onFocusChange = { focus.append($0) }
        #expect(button.canBecomeKeyView)
        #expect(panel.makeFirstResponder(button))
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        button.keyDown(with: space)
        #expect(presses == 1)
        _ = button.accessibilityPerformPress()
        #expect(presses == 2)
        panel.makeFirstResponder(nil)
        #expect(focus == [true, false])
        button.isEnabled = false
        #expect(!button.canBecomeKeyView)
        button.isEnabled = true
        button.isHidden = true
        #expect(!button.canBecomeKeyView)
    }

    @Test func voiceOverOwnershipSurvivesPointerExitAndKeyboardBlur() {
        let model = PillViewModel()
        model.setPointerInside(true)
        model.setFocus(true, element: "action.insertNow")
        model.setFocus(true, element: "voiceOver.insertNow", tracksPointer: false)
        model.setPointerInside(false)
        #expect(model.focusInside)
        model.setFocus(false, element: "action.insertNow")
        #expect(model.focusInside)
        model.setFocus(false, element: "voiceOver.insertNow", tracksPointer: false)
        #expect(!model.focusInside)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private final class KeyboardTestPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
}
