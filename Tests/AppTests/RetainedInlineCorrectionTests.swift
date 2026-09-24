import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

@Suite("V3 retained inline corrections")
@MainActor
struct RetainedInlineCorrectionTests {
    private func makePill(error: Bool) -> PillViewModel {
        let pill = PillViewModel()
        pill.present(.finishing(elapsedWarning: false))
        pill.present(delivery: error ? .failed(reason: "delivery unavailable") : .held(reason: "destination changed"),
                     text: "Hello Mira", destination: "Mail")
        pill.setFinalSpans([
            TranscriptSpan(text: "Hello", confidence: 1, audioRange: 0...0.2),
            TranscriptSpan(text: "Mira", confidence: 0.2, audioRange: 0.2...0.5,
                           alternates: [Alternate(text: "Meera", score: 0.6, source: .beam)])
        ], text: "Hello Mira")
        return pill
    }

    @Test(arguments: [false, true])
    func acceptsSuggestionWithoutDeliveringOrDismissing(error: Bool) throws {
        let pill = makePill(error: error)
        let originalState = pill.state
        let mark = try #require(pill.markMapping(for: pill.actionText).marks.first)
        var revisions: [String] = []
        var deliveries = 0
        let database = try AppDatabase.inMemory()
        let learner = DraftVocabularyLearner(database: database)
        pill.onApplyRetainedDraft = { shown, original, edited, mapping in
            #expect(shown == originalState && original == "Hello Mira")
            #expect(mapping.text == edited && mapping.marks.isEmpty)
            revisions.append(edited)
            return true
        }
        pill.onApplyDraft = { _, _, _ in Issue.record("Retained text entered live preview"); return false }
        pill.onAction = { _, _ in deliveries += 1 }
        pill.onHeldAction = { _, _ in deliveries += 1 }
        pill.onLearnDraft = { original, edited in #expect(learner.learn(original: original, edited: edited)) }
        pill.setPointerInside(true)
        pill.acceptSuggestion(markID: mark.id, replacement: "Meera")
        pill.setPointerInside(false)
        #expect(revisions == ["Hello Meera"])
        #expect(pill.actionText == "Hello Meera" && !pill.isEditingDraft)
        #expect(deliveries == 0 && pill.laneNote == nil)
        #expect(try database.dictionaryTerms().map(\.term) == ["Meera"])
        if error { #expect(pill.state == originalState) }
        else {
            guard case .held(let before) = originalState, case .held(let after) = pill.state else {
                Issue.record("Retained correction stopped being held"); return
            }
            #expect(after.id == before.id && after.text == "Hello Meera" && after.reason == before.reason)
            pill.perform(.insert)
            #expect(deliveries == 1)
        }
    }

    @Test(arguments: [false, true])
    func originalWordEditsApplyOnExitAndRespectCancelEmptyAndComposition(error: Bool) throws {
        let pill = makePill(error: error)
        let mark = try #require(pill.markMapping(for: pill.actionText).marks.first)
        var revisions: [String] = []
        var learned: [String] = []
        pill.onApplyRetainedDraft = { _, _, edited, _ in revisions.append(edited); return true }
        pill.onLearnDraft = { _, edited in learned.append(edited) }
        pill.onReviewMark = { _, _, _ in Issue.record("Retained word opened destination review") }
        pill.setPointerInside(true)
        pill.reviewMark(mark.id)
        #expect(pill.isEditingDraft && pill.editingMarkID == mark.id)
        #expect(pill.draftText == "Hello Mira")
        pill.draftText = "cancel me"
        pill.cancelDraftEdits()
        #expect(revisions.isEmpty && learned.isEmpty && pill.actionText == "Hello Mira")
        pill.reviewMark(mark.id)
        pill.draftText = ""
        pill.setPointerInside(false)
        #expect(pill.isEditingDraft && revisions.isEmpty)
        pill.setPointerInside(true)
        pill.draftText = "Hello Meera"
        pill.setCompositionActive(true)
        pill.setPointerInside(false)
        #expect(pill.isEditingDraft && revisions.isEmpty && learned.isEmpty)
        pill.setCompositionActive(false)
        #expect(!pill.isEditingDraft && revisions == ["Hello Meera"] && learned == revisions)
        if error { guard case .error = pill.state else { Issue.record("Edited error draft was released"); return } }
        else { guard case .held = pill.state else { Issue.record("Edited draft was released"); return } }
    }

    @Test(arguments: [false, true])
    func refusedRetainedRevisionDoesNotLearnOrDiscardEdit(error: Bool) throws {
        let pill = makePill(error: error)
        let state = pill.state
        let mark = try #require(pill.markMapping(for: pill.actionText).marks.first)
        pill.onApplyRetainedDraft = { _, _, _, _ in false }
        pill.onLearnDraft = { _, _ in Issue.record("Uncommitted correction was learned") }
        pill.acceptSuggestion(markID: mark.id, replacement: "Meera")
        #expect(pill.state == state && pill.isEditingDraft && pill.draftText == "Hello Meera")
        pill.cancelDraftEdits()
        #expect(pill.actionText == "Hello Mira")
    }
}
