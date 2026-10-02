import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// S5 (+S3/S10) — the review count, the rows' copy, the announcement and `TurnRecord.uncertainSpans`
/// all come from the marks `UncertaintyMarkMapper` draws on the final text, never from counting
/// low-confidence spans or searching for their words in order.
@Suite("S5 — review count from mapped marks")
@MainActor
struct ReviewCountMappingS5Tests {
    typealias Harness = TurnControllerTests.Harness

    private static func spans(_ words: [(String, Float)]) -> [TranscriptSpan] {
        words.enumerated().map { i, w in
            TranscriptSpan(text: w.0, confidence: w.1, audioRange: Double(i) * 0.3...(Double(i) * 0.3 + 0.3),
                           provenance: [.asr], stability: .final)
        }
    }

    /// One held turn whose formatter produced `text` from `source`; the payload is on screen.
    private func preview(_ source: [TranscriptSpan], formatted text: String) async throws -> (Harness, TurnID, FinalPreviewInfo) {
        let h = Harness()
        h.lander.textFinalizer = { _ in text }
        let id = try #require(await h.holdToPreview(source))
        let info = try #require(h.controller.previewInfo)
        return (h, id, info)
    }

    @Test("a T05 rewrite: the count is the marks drawn, and every row reads “Review this phrase”")
    func phraseRewrite() async throws {
        let source = Self.spans([("the", 0.9), ("quick", 0.9), ("brown", 0.3), ("fox", 0.9), ("jumps", 0.9)])
        let (h, id, info) = try await preview(source, formatted: "a fast auburn fox jumps")
        let spans = try #require(h.events.finalSpans.first)
        let mapping = UncertaintyMarkMapper.map(source: spans, finalText: info.text)
        #expect(mapping.needsPhraseReview && mapping.count == 1)

        // S3: the preview's count and flag, and the record Today / turn detail / Review read.
        #expect(info.uncertainCount == mapping.count)
        #expect(info.needsPhraseReview)
        #expect(info.reviewLine == RecoveryCatalog.entry(.T05).headline)
        #expect(h.store.record(id)?.uncertainSpans == mapping.uncertainRanges)
        #expect(!(h.store.record(id)?.uncertainSpans.isEmpty ?? true), "a reworded span keeps its (phrase) range")

        // S2: the pill draws exactly those marks and says so in the preview row …
        let pill = PillViewModel()
        pill.present(.listening(level: 0.2))                 // the turn began at key-down
        pill.present(.finishing(elapsedWarning: false))
        pill.setFinalSpans(spans, text: info.text)
        #expect(pill.turn.uncertainCount == mapping.count && pill.turn.needsPhraseReview)
        pill.present(.finalPreview(info))
        let row = pill.content()
        #expect(pill.marks(for: row.words).count == info.uncertainCount, "count == marks drawn")
        // N22 — no dwell: an automatic preview is the Inserting face; the marks stay on its words,
        // and the review line moves to the inserted row below.
        #expect(row.designKey == "inserting")
        #expect(!row.status.contains("word to review"))
        // … and in the inserted row.
        pill.present(.landed(LandedPillInfo(text: info.text, verified: true)))
        #expect(pill.content().helper == "Review this phrase in the field")

        // S10: VoiceOver hears the same line once.
        var announcer = PillAnnouncer()
        let said = announcer.next(.finalPreview(info), content: row, captureOpen: false)
        #expect(said?.text == PillAnnouncer.finalReady + PillCopy.statusSeparator + "Review this phrase")
    }

    @Test("a whole-result rewrite is marked, counted and recorded even though no word aligns")
    func wholeResult() async throws {
        let source = Self.spans([("gonna", 0.3), ("head", 0.9), ("out", 0.9)])
        let (h, id, info) = try await preview(source, formatted: "Leaving now.")
        let spans = try #require(h.events.finalSpans.first)
        let mapping = UncertaintyMarkMapper.map(source: spans, finalText: info.text)
        #expect(mapping.marks.first?.kind == .wholeResult)
        #expect(info.uncertainCount == 1 && info.needsPhraseReview)
        #expect(h.store.record(id)?.uncertainSpans == mapping.uncertainRanges)
        let pill = PillViewModel()
        pill.setFinalSpans(spans, text: info.text)
        pill.present(.finalPreview(info))
        #expect(pill.marks(for: pill.content().words).count == 1, "the payload's own spans mark it: no belongs guard")
    }

    @Test("a reworded word keeps its range for Today; a removed filler is neither marked nor counted")
    func rewordedAndRemoved() async throws {
        let source = Self.spans([("it", 0.9), ("costs", 0.9), ("twenty", 0.9), ("five", 0.3), ("dollars", 0.9), ("today", 0.9)])
        let (h, id, info) = try await preview(source, formatted: "It costs $25 today.")
        let ranges = try #require(h.store.record(id)?.uncertainSpans)
        #expect(ranges.count == 1 && info.uncertainCount == 1 && !info.needsPhraseReview)
        let marked = (info.text as NSString).substring(with: NSRange(location: ranges[0].lowerBound, length: ranges[0].count))
        #expect(marked == "25", "the naive in-order search found no “five” here and Today lost the mark")
        #expect(info.status == nil || info.status?.hasSuffix("1 word to review") == true)

        let (h2, id2, info2) = try await preview(Self.spans([("um", 0.2), ("send", 0.9), ("it", 0.9)]), formatted: "Send it.")
        #expect(info2.uncertainCount == 0 && !info2.needsReview, "the filler's mark went with it")
        #expect(h2.store.record(id2)?.uncertainSpans == [])
    }

    @Test("the lander's ranges are the mapper's (the naive substring search is gone)")
    func landerDelegates() {
        let spans = Self.spans([("the", 0.9), ("quick", 0.9), ("brown", 0.3), ("fox", 0.9), ("jumps", 0.9)])
        let text = "a fast auburn fox jumps"
        #expect(UtteranceLander.uncertainRanges(of: spans, in: text)
                == UncertaintyMarkMapper.map(source: spans, finalText: text).uncertainRanges)
        #expect(!UtteranceLander.uncertainRanges(of: spans, in: text).isEmpty)
    }

    @Test("without the payload text the pill counts the marks on the spans' own rendering")
    func spansOnly() {
        let pill = PillViewModel()
        pill.setFinalSpans(Self.spans([("meet", 0.9), ("mira", 0.3), ("and", 0.9), ("joaquin", 0.2)]))
        #expect(pill.turn.uncertainCount == 2 && !pill.turn.needsPhraseReview)
    }
}
