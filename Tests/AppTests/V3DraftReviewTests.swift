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
        for reason in [DwellPause.composition, .emptyDraft, .hiddenApp] {
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
