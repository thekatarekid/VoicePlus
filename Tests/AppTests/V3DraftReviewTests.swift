import Foundation
import Engine
import Shared
import Testing
@testable import VoicePlusApp

@Suite("V3 native draft review")
struct V3DraftReviewTests {
    @Test func fixedDelayRegardlessOfConfidenceOrLength() {
        #expect(PreviewDwell.standard.seconds(lowConfidence: false) == 0.6)
        #expect(PreviewDwell.standard.seconds(lowConfidence: true) == 0.6)
        #expect(PreviewDwell.long.seconds(lowConfidence: true) == 1.2)
        #expect(PreviewDwell.manual.seconds(lowConfidence: true) == nil)
    }

    @Test func editedPayloadIsTheOnlyInsertedRevision() async throws {
        let h = TurnControllerTests.Harness()
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("Hello Mira")))
        h.controller.finalRendered(id)
        h.controller.pauseDwell(.hover)
        let text = "Hello Meera"
        let mapping = MarkMapping(text: text, marks: [], confidenceAvailable: true)
        #expect(h.controller.revisePreview(text: text, mapping: mapping, spans: DraftRevision.spans(for: mapping)))
        h.controller.resumeDwell(.hover)
        h.clock.advance(0.601)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.field == TurnControllerTests.original + text)
        #expect(h.system.postCount == 1)
        #expect(h.store.entry(id)?.record.finalText == text)
        #expect(!h.controller.revisePreview(text: "late edit", mapping: mapping, spans: []))
    }

    @Test func compositionAndEmptyDraftBlockExplicitInsert() async throws {
        let h = TurnControllerTests.Harness()
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello")))
        h.controller.finalRendered(id)
        for reason in [DwellPause.editing, .composition, .emptyDraft, .hiddenApp] {
            h.controller.pauseDwell(reason)
            h.controller.insertNow()
            h.clock.advance(20)
            #expect(h.system.postCount == 0)
            h.controller.resumeDwell(reason)
        }
        h.controller.insertNow()
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.system.postCount == 1)
    }

    @MainActor @Test func activeEditorCannotInsertItsPreviousPayload() async throws {
        let h = TurnControllerTests.Harness()
        let pill = PillViewModel()
        h.controller.onPresent = { pill.present($0) }
        pill.onDraftPause = { reason, paused in
            if paused { h.controller.pauseDwell(reason) } else { h.controller.resumeDwell(reason) }
        }
        pill.onApplyDraft = { h.controller.revisePreview(text: $0, mapping: $1, spans: $2) }
        pill.onAction = { action, shown in _ = TurnWiring.route(action, shown: shown, to: h.controller, finishLatch: nil) }
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("previous draft")))
        h.controller.finalRendered(id)
        pill.beginEditingDraft()
        pill.draftText = "edited draft"
        h.controller.insertNow()  // A separate Insert control must not dispatch stale text.
        h.clock.advance(20)
        #expect(h.system.postCount == 0)
        #expect(pill.isEditingDraft)
        pill.draftText = ""
        pill.perform(.insert)
        #expect(h.system.postCount == 0 && pill.isEditingDraft)
        pill.draftText = "composed draft"
        pill.setCompositionActive(true)
        pill.perform(.insert)
        #expect(h.system.postCount == 0 && pill.isEditingDraft)
        pill.setCompositionActive(false)
        pill.perform(.insert)
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.field == TurnControllerTests.original + "composed draft")
        #expect(h.system.postCount == 1)
    }

    @MainActor @Test func keyboardReadingReacquiresFocusAfterMouseExit() {
        let pill = PillViewModel()
        pill.present(.finalPreview(FinalPreviewInfo(text: "a long transcript", dwellRemaining: 0.6)))
        pill.setPointerInside(true)
        pill.setFocus(true, element: "draft.editor")
        pill.setPointerInside(false)
        #expect(!pill.focusInside)
        pill.noteKeyboardInteraction()
        #expect(pill.focusInside && !pill.isEditingDraft)
        pill.setPointerInside(true)
        pill.setPointerInside(false)
        #expect(pill.focusInside)
        pill.setFocus(false, element: "draft.editor")
        #expect(!pill.focusInside)
    }

    @MainActor @Test func keyboardFocusDepartureAppliesButInternalTabDoesNot() async {
        let pill = PillViewModel()
        var accepted: [String] = []
        pill.present(.finalPreview(FinalPreviewInfo(text: "before", dwellRemaining: 0.6)))
        pill.onApplyDraft = { text, _, _ in accepted.append(text); return true }
        pill.beginEditingDraft()
        pill.draftText = "after"
        pill.setFocus(true, element: "draft.editor")
        pill.setFocus(false, element: "draft.editor")
        pill.setFocus(true, element: "draft.done")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(pill.isEditingDraft && accepted.isEmpty)
        pill.setFocus(false, element: "draft.done")
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!pill.isEditingDraft && accepted == ["after"])
    }

    @Test func revisedTargetStillRevalidatesBeforeWrite() async throws {
        let h = TurnControllerTests.Harness()
        let id = try #require(await h.holdToPreview(TurnControllerTests.words("hello")))
        h.controller.finalRendered(id)
        h.controller.pauseDwell(.review)
        let mapping = MarkMapping(text: "edited hello", marks: [], confidenceAvailable: true)
        #expect(h.controller.revisePreview(text: mapping.text, mapping: mapping, spans: DraftRevision.spans(for: mapping)))
        h.system.frontmost = TurnControllerTests.mail
        h.controller.resumeDwell(.review)
        h.clock.advance(0.601)
        #expect(await h.wait { h.store.entry(id)?.stage == .held })
        #expect(h.system.postCount == 0)
        let held = try #require(h.focusGuard.heldText(turn: id))
        #expect(held.text == mapping.text)
        let edited = "retained revision"
        let revised = MarkMapping(text: edited, marks: [], confidenceAvailable: true)
        #expect(h.controller.reviseRetainedDraft(shown: .held(HeldPillInfo(id: held.id, text: held.text, destination: "Mail", reason: held.reason)), original: held.text, edited: edited, mapping: revised))
        #expect(h.focusGuard.heldText(id: held.id)?.text == edited)
        #expect(h.store.entry(id)?.record.finalText == edited)
        h.clock.advance(100)
        #expect(h.system.postCount == 0)
    }

    @Test func uncertainWordsRebaseAcrossUnicodeEdits() {
        let old = "🙂 Mira met Rohan"
        let mapping = MarkMapping(text: old, marks: [
            UncertainMark(id: 0, kind: .word, range: 3..<7, text: "Mira", heard: "Mira", confidence: 0.2, alternatives: ["Meera"]),
            UncertainMark(id: 1, kind: .word, range: 12..<17, text: "Rohan", heard: "Rohan", confidence: 0.2)
        ], confidenceAvailable: true)
        let new = DraftRevision.mapping(mapping, edited: "🙂 Meera met Rohan")
        #expect(new.marks.count == 1)
        #expect(new.marks.first?.text == "Rohan")
        #expect(new.marks.first?.range == 13..<18)
    }

    @Test func repeatedEditsPreserveRemainingConfidenceEvidence() {
        let spans = [TranscriptSpan(text: "Mira", confidence: 0.2, audioRange: 0...0.3),
                     TranscriptSpan(text: "met", confidence: 0.9, audioRange: 0.3...0.5),
                     TranscriptSpan(text: "Rohan", confidence: 0.2, audioRange: 0.5...0.8)]
        let original = UncertaintyMarkMapper.map(source: spans, finalText: "Mira met Rohan")
        let edited = DraftRevision.mapping(original, edited: "Meera met Rohan")
        let firstSpans = DraftRevision.spans(for: edited, source: spans)
        let first = DraftRevision.indexing(edited, spans: firstSpans)
        #expect(UncertaintyMarkMapper.map(source: firstSpans, finalText: first.text).marks.map(\.text) == ["Rohan"])
        let second = DraftRevision.mapping(first, edited: "Today Meera met Rohan")
        let secondSpans = DraftRevision.spans(for: second, source: firstSpans)
        #expect(UncertaintyMarkMapper.map(source: secondSpans, finalText: second.text).marks.map(\.text) == ["Rohan"])
        let boundary = DraftRevision.mapping(original, edited: "Amira met Rohan")
        #expect(boundary.marks.map(\.text) == ["Rohan"])
    }

    @Test func learningIgnoresPunctuationAndPersistsManageableTerms() throws {
        #expect(DraftVocabularyLearner.addedTerms(original: "Hello Mira.", edited: "Hello, Mira!").isEmpty)
        let database = try AppDatabase.inMemory()
        let learner = DraftVocabularyLearner(database: database)
        #expect(learner.learn(original: "Hello Mira", edited: "Hello Meera"))
        #expect(try database.dictionaryTerms().map(\.term) == ["Meera"])
        #expect(try database.dictionaryTerms().first?.spokenForms == "")
        #expect(learner.learn(original: "Mira", edited: "Meera"))
        #expect(try database.dictionaryTerms().count == 1)
        let session = DraftVocabularyLearner(database: nil)
        #expect(!session.learn(original: "Mira", edited: "Meera"))
        #expect(session.sessionTerms == ["Meera"])
    }

    @MainActor @Test func pointerExitAppliesDraftAndClearsOnlyMouseFocus() {
        let pill = PillViewModel()
        var committed = ""
        var learned: [String] = []
        pill.present(.finalPreview(FinalPreviewInfo(text: "Hello Mira", dwellRemaining: 0.6)))
        pill.onApplyDraft = { text, _, _ in committed = text; return true }
        pill.onLearnDraft = { _, text in learned.append(text) }
        pill.setPointerInside(true)
        pill.setFocus(true, element: "editor")
        pill.beginEditingDraft()
        pill.draftText = "Hello Meera"
        pill.setPointerInside(false)
        #expect(committed == "Hello Meera")
        #expect(!pill.isEditingDraft && !pill.focusInside)
        #expect(learned == ["Hello Meera"])
        pill.beginEditingDraft()
        pill.draftText = "canceled"
        pill.cancelDraftEdits()
        #expect(learned.count == 1)
        pill.setFocus(true, element: "keyboard")
        pill.setPointerInside(true)
        pill.setPointerInside(false)
        #expect(pill.focusInside)
    }
}
