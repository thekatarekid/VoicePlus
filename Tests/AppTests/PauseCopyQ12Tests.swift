import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 Q12 — "Pause states — simplified": each pause reason names itself in one line, selection /
/// Review say nothing, and an empty draft left in the editor cancels with "Nothing was typed.".
@Suite("Pause copy (V5 Q12)")
@MainActor
struct PauseCopyQ12Tests {
    static let t0 = Date(timeIntervalSince1970: 90_000)

    private func info(_ reason: PreviewPauseReason?, manual: Bool = false) -> FinalPreviewInfo {
        FinalPreviewInfo(text: "Can we meet?", dwellRemaining: 1, paused: reason != nil, manual: manual,
                         destination: "Mail", pauseReason: reason)
    }

    @Test func eachReasonHasItsOwnLine() {
        let lines: [PreviewPauseReason: String] = [
            .hover: "Paused · move away to insert",
            .editing: "Editing · leave the pill to apply",
            .keyboardFocus: "Paused · Insert now when ready",
            .quiet: "",
        ]
        for (reason, line) in lines {
            // One source: the preview info's helper and the rendered row read the same line.
            #expect(info(reason).helper == line)
            #expect(PillContent.make(.finalPreview(info(reason)), context: PillTurnContext(destination: "Mail")).helper == line)
        }
        #expect(Set(lines.values).count == lines.count)
    }

    @Test func notPausedAndManualKeepTheirHelpers() {
        #expect(info(nil).helper == PillCopy.previewHelperAuto)
        #expect(info(.hover, manual: true).helper == PillCopy.previewHelperManual)
        // A paused flag with no named reason is the original hover line.
        #expect(FinalPreviewInfo(text: "x", dwellRemaining: 1, paused: true).helper == PillCopy.pausedHover)
    }

    @Test func pauseSetMapsToOneReasonByPriority() {
        #expect(DwellPause.pauseReason(for: []) == nil)
        #expect(DwellPause.pauseReason(for: [.hover]) == .hover)
        #expect(DwellPause.pauseReason(for: [.focus]) == .keyboardFocus)
        #expect(DwellPause.pauseReason(for: [.hover, .focus]) == .keyboardFocus)
        #expect(DwellPause.pauseReason(for: [.editing, .review, .hover]) == .editing)
        #expect(DwellPause.pauseReason(for: [.composition]) == .editing)
        #expect(DwellPause.pauseReason(for: [.selection]) == .quiet)
        #expect(DwellPause.pauseReason(for: [.review]) == .quiet)
    }

    @Test func controllerPublishesTheReasonAndRedrawsWhenItChanges() async throws {
        let h = TurnControllerTests.Harness()
        var shown: [FinalPreviewInfo] = []
        let previous = h.controller.onPresent
        h.controller.onPresent = { state in
            previous?(state)
            if case .finalPreview(let i) = state { shown.append(i) }
        }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello there")))
        h.controller.finalRendered(id)
        h.controller.pauseDwell(.hover)
        #expect(h.controller.previewInfo?.pauseReason == .hover)
        #expect(shown.last?.pauseReason == .hover)
        h.controller.pauseDwell(.focus)
        #expect(shown.last?.pauseReason == .keyboardFocus)
        #expect(shown.last?.helper == "Paused · Insert now when ready")
        h.controller.resumeDwell(.focus)
        #expect(shown.last?.pauseReason == .hover)
        h.controller.resumeDwell(.hover)
        #expect(shown.last?.pauseReason == nil)
        #expect(h.controller.previewInfo?.paused == false)
    }

    @Test func emptyDraftLeftInTheEditorCancelsWithNothingWasTyped() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        var cancelled = 0
        model.onEmptyDraftLeft = { cancelled += 1; model.present(.cancelled) }
        model.apply(.starting)
        model.present(.finalPreview(info(nil)))
        model.perform(.editDraft)
        model.setPointerInside(true)
        model.draftText = "   "
        #expect(model.leavingCancelsEmptyDraft)
        model.setPointerInside(false)
        #expect(cancelled == 1)
        #expect(!model.isEditingDraft)
        #expect(model.state == .cancelled)
        #expect(model.content().helper == "Nothing was typed.")
    }

    @Test func aNonEmptyDraftLeftInTheEditorDoesNotCancel() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        var cancelled = 0
        model.onEmptyDraftLeft = { cancelled += 1 }
        model.apply(.starting)
        model.present(.finalPreview(info(nil)))
        model.perform(.editDraft)
        model.setPointerInside(true)
        model.setPointerInside(false)
        #expect(cancelled == 0)
        #expect(!model.isEditingDraft)
    }

    @Test func anOrdinaryCancelKeepsTheStandardHelper() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.apply(.starting)
        model.present(.cancelled)
        #expect(model.content().helper == PillCopy.cancelledHelper)
    }
}
