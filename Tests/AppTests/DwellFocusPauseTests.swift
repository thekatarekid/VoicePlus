import Engine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// S3 — "Hover, focus, selection or Review freezes it" (build doc §2; design §5 step 4, §11 "Respect
/// focus and hover pause of preview dwell"). Keyboard / VoiceOver focus on the pill's final text or
/// its actions is reported by `PillFocusReport` into `PillViewModel.setFocus`, and
/// `TurnWiring.wireFocusPause` turns it into `pauseDwell(.focus)` / `resumeDwell(.focus)`. Driven on
/// the S3 harness (manual clock, `MockSystemAccess`); the SwiftUI focus system itself (VoiceOver
/// moving its cursor) is not driven here and needs a manual check.
@MainActor
@Suite("S3 — keyboard / VoiceOver focus pauses the final preview's dwell")
struct DwellFocusPauseTests {
    typealias Harness = TurnControllerTests.Harness

    @Test("focus freezes the dwell; focus moving inside the pill keeps it frozen; leaving resumes the rest")
    func focusFreezesAndResumes() async throws {
        let h = Harness()
        let pill = PillViewModel()
        let wiring = TurnWiring.wireFocusPause(pill: pill, controller: h.controller)
        defer { wiring.cancel() }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        h.clock.advance(0.5)

        pill.setFocus(true, element: "action.pill.action.insertNow")
        #expect(h.controller.previewInfo?.paused == true)
        let left = try #require(h.controller.previewInfo?.dwellRemaining)
        #expect(abs(left - 0.4) < 0.001)
        h.clock.advance(30)
        #expect(h.system.postCount == 0, "focused: nothing is written however long it stays")
        #expect(h.controller.previewInfo?.dwellRemaining == left, "frozen, not counting down")

        // Tab / the VoiceOver cursor moves from the button to the text: still inside, still frozen.
        pill.setFocus(true, element: "words.line.0")
        pill.setFocus(false, element: "action.pill.action.insertNow")
        h.clock.advance(30)
        #expect(h.system.postCount == 0)
        #expect(h.controller.previewInfo?.paused == true)

        pill.setFocus(false, element: "words.line.0")
        #expect(h.controller.previewInfo?.paused == false)
        h.clock.advance(0.399)
        #expect(h.system.postCount == 0, "resumes with the time that was left, not a fresh dwell")
        h.clock.advance(0.002)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.system.postCount == 1)
    }

    @Test("focus and hover are separate holds: either one keeps the dwell frozen")
    func focusAndHoverStack() async throws {
        let h = Harness()
        let pill = PillViewModel()
        let wiring = TurnWiring.wireFocusPause(pill: pill, controller: h.controller)
        defer { wiring.cancel() }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        pill.setFocus(true, element: "words.line.0")
        h.controller.pauseDwell(.hover)
        pill.setFocus(false, element: "words.line.0")
        h.clock.advance(30)
        #expect(h.system.postCount == 0, "hover still holds it")
        h.controller.resumeDwell(.hover)
        h.clock.advance(0.901)
        #expect(await h.wait { h.events.landed.count == 1 })
    }

    @Test("a preview that opens with focus already on the text lane starts frozen")
    func previewOpensUnderFocus() async throws {
        let h = Harness()
        let pill = PillViewModel()
        let wiring = TurnWiring.wireFocusPause(pill: pill, controller: h.controller)
        defer { wiring.cancel() }
        pill.setFocus(true, element: "words.line.0")   // the VoiceOver cursor was on the live words
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        #expect(h.controller.previewInfo?.paused == false, "no preview existed when focus arrived")
        let info = try #require(h.controller.previewInfo)
        pill.present(.finalPreview(info))   // what TurnWiring's onPresent does with the preview
        #expect(await h.wait { h.controller.previewInfo?.paused == true })
        h.controller.finalRendered(id)
        h.clock.advance(30)
        #expect(h.system.postCount == 0)
        pill.setFocus(false, element: "words.line.0")
        h.clock.advance(0.901)
        #expect(await h.wait { h.events.landed.count == 1 })
    }

    @Test("the pill reports focus once across its pieces, and a hidden pill holds no focus")
    func pillReportsFocus() {
        let pill = PillViewModel()
        var calls: [Bool] = []
        pill.onKeyboardFocusChange = { calls.append($0) }
        pill.setFocus(true, element: "action.a")
        pill.setFocus(true, element: "action.b")
        pill.setFocus(false, element: "action.a")
        #expect(calls == [true] && pill.focusInside)
        pill.setFocus(false, element: "action.b")
        #expect(calls == [true, false] && !pill.focusInside)
        pill.setFocus(false, element: "action.b")
        #expect(calls == [true, false], "a repeated loss is not a second change")

        pill.present(.listening(level: 0.2))
        pill.setFocus(true, element: "words.line.0")
        #expect(calls == [true, false, true])
        pill.hide()
        #expect(!pill.focusInside && calls == [true, false, true, false], "the pieces are gone with the pill")
        pill.setFocus(false, element: "words.line.0")
        #expect(calls.count == 4)
    }

    @Test("the text lane lines, the uncertain words and the action buttons report focus")
    func viewsReportFocus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("App/UI/PillView.swift"), encoding: .utf8)
        #expect(view.contains(".pillFocusReport(\"words.line."))
        #expect(view.contains(".pillFocusReport(\"words.mark."))
        #expect(view.contains(".pillFocusReport(\"action."))
        #expect(view.components(separatedBy: "onFocus: { model.setFocus($0, element: $1) }").count == 3,
                "the words lane and the action row both feed the model")
        let modifier = try String(contentsOf: root.appendingPathComponent("App/UI/PillFocusReport.swift"), encoding: .utf8)
        #expect(modifier.contains(".accessibilityFocused(") && modifier.contains(".focused("),
                "VoiceOver focus and keyboard focus both count")
    }
}
