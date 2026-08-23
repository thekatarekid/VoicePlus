import Foundation
import Testing
import Shared
@testable import Engine

@Suite("P1.6 T3/T5 — repair session semantics")
struct RepairSessionTests {
    struct Clock: Sendable { let box = Box(); final class Box: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) } }

    static func landed(prefix: String = "") -> (RepairSession, InMemoryReplaceRangeSink, InMemoryCorrectionSink, InMemoryZeroEditSink, Clock) {
        let clock = Clock()
        let sink = InMemoryReplaceRangeSink(document: prefix + "send it to kothari tomorrow")
        let corrections = InMemoryCorrectionSink()
        let zero = InMemoryZeroEditSink()
        let session = RepairSession(replaceSink: sink, correctionSink: corrections, zeroEditSink: zero, now: { clock.box.now })
        let u = Utterance(spans: [
            TranscriptSpan(text: "send", confidence: 0.98, audioRange: 0...0.1, provenance: [.asr]),
            TranscriptSpan(text: "it", confidence: 0.97, audioRange: 0.1...0.2, provenance: [.asr]),
            TranscriptSpan(text: "to", confidence: 0.96, audioRange: 0.3...0.4, provenance: [.asr]),
            TranscriptSpan(text: "kothari", confidence: 0.4, audioRange: 0.8...1.04, alternates: [
                Alternate(text: "Cotari", score: 0.5, source: .beam), Alternate(text: "Kothari", score: 0.3, source: .biasing), Alternate(text: "Katari", score: 0.2, source: .beam),
            ], provenance: [.asr]),
            TranscriptSpan(text: "tomorrow", confidence: 0.99, audioRange: 1.2...1.44, provenance: [.asr]),
        ])
        session.land(u, fieldOffset: prefix.utf16.count)
        return (session, sink, corrections, zero, clock)
    }

    @Test func snapToBestMatchingAlternateUpdatesDocumentSpanAndProvenance() {
        let (session, sink, corrections, zero, _) = Self.landed(prefix: "Hi. ")
        let r = session.apply(.snap("Kothari"))
        #expect(r == .replaced(spanIndex: 3, from: "kothari", to: "Kothari"))
        #expect(sink.document == "Hi. send it to Kothari tomorrow")
        #expect(sink.requests.last == RepairReplaceRequest(range: 15..<22, expected: "kothari", replacement: "Kothari", utteranceID: session.current!.id, spanIndex: 3))
        let span = session.current!.spans[3]
        #expect(span.text == "Kothari" && span.provenance == [.asr, .repair] && span.confidence == 0.4 && span.audioRange == 0.8...1.04)
        #expect(corrections.records.count == 1 && corrections.records[0].original == "kothari" && corrections.records[0].corrected == "Kothari"
                && corrections.records[0].source == "voiceRepair" && corrections.records[0].audioStart == 0.8)
        #expect(zero.events == [.init(utteranceID: session.current!.id, wordsEdited: 1, source: "voiceRepair")])
    }

    @Test func snapPhoneticallyAndWithUnknownWordTargetsWeakestSpan() {
        let (session, sink, _, _, _) = Self.landed()
        #expect(session.apply(.snap("cotary")) == .replaced(spanIndex: 3, from: "kothari", to: "Cotari")) // phonetic hit on alternate
        let (s2, sink2, _, _, _) = Self.landed()
        #expect(s2.apply(.snap("Bhattacharya")) == .replaced(spanIndex: 3, from: "kothari", to: "Bhattacharya")) // keeps spoken word
        #expect(sink2.document == "send it to Bhattacharya tomorrow")
        #expect(sink.document == "send it to Cotari tomorrow")
    }

    @Test func cycleWalksRingAndUndoRestores() {
        let (session, sink, _, zero, _) = Self.landed()
        #expect(session.apply(.cycle) == .replaced(spanIndex: 3, from: "kothari", to: "Cotari"))
        #expect(session.apply(.cycle) == .replaced(spanIndex: 3, from: "Cotari", to: "Kothari"))
        #expect(session.apply(.cycle) == .replaced(spanIndex: 3, from: "Kothari", to: "Katari"))
        #expect(session.apply(.cycle) == .replaced(spanIndex: 3, from: "Katari", to: "kothari")) // wraps to original
        #expect(sink.document == "send it to kothari tomorrow")
        #expect(session.apply(.undo) == .undone(spanIndex: 3, restored: "Katari"))
        #expect(session.apply(.undo) == .undone(spanIndex: 3, restored: "Kothari"))
        #expect(sink.document == "send it to Kothari tomorrow")
        #expect(zero.events.count == 4)
        _ = session.apply(.undo); _ = session.apply(.undo)
        #expect(session.apply(.undo) == .noop(reason: "nothing to undo"))
        #expect(sink.document == "send it to kothari tomorrow")
    }

    @Test func scratchDropsPhraseAndPutItBackRestoresIt() {
        let (session, sink, _, zero, _) = Self.landed(prefix: "Hi. ")
        #expect(session.apply(.scratch) == .scratched(text: "send it to kothari tomorrow"))
        #expect(sink.document == "Hi. " && session.landedText == "")
        #expect(session.apply(.cycle) == .noop(reason: "nothing landed"))
        #expect(session.apply(.undo) == .undone(spanIndex: nil, restored: "send it to kothari tomorrow"))
        #expect(sink.document == "Hi. send it to kothari tomorrow")
        #expect(zero.events.first?.wordsEdited == 5)
    }

    @Test func pickByNumberAndChoose() {
        let (session, sink, _, _, _) = Self.landed()
        #expect(session.apply(.pick(3)) == .replaced(spanIndex: 3, from: "kothari", to: "Katari"))
        #expect(session.apply(.pick(9)) == .noop(reason: "no alternate 9"))
        #expect(session.choose(alternate: 0, of: 3) == .replaced(spanIndex: 3, from: "Katari", to: "Cotari"))
        #expect(sink.document == "send it to Cotari tomorrow")
        #expect(session.current!.spans[3].alternates.map(\.text).contains("kothari")) // original stays reachable
    }

    @Test func tenSecondWindowAndReArm() {
        let (session, _, _, _, clock) = Self.landed()
        clock.box.now += 9
        #expect(session.isActive())
        #expect(session.apply(.cycle) == .replaced(spanIndex: 3, from: "kothari", to: "Cotari"))
        clock.box.now += 9 // 18 s after landing but 9 s after last command → still active
        #expect(session.isActive())
        clock.box.now += 10.5
        #expect(!session.isActive())
        #expect(session.apply(.cycle) == .inactive)
        #expect(!RepairResult.inactive.consumedUtterance)
    }

    @Test func documentMismatchLeavesEverythingUntouched() {
        let (session, sink, corrections, zero, _) = Self.landed()
        sink.failNext = .mismatch(actual: "kothary")
        #expect(session.apply(.snap("Kothari")) == .failed(.mismatch(actual: "kothary")))
        #expect(session.current!.spans[3].text == "kothari" && corrections.records.isEmpty && zero.events.isEmpty)
        #expect(session.apply(.undo) == .noop(reason: "nothing to undo"))
        let (s2, _, _, _, _) = Self.landed()
        s2.replaceSink = nil
        #expect(s2.apply(.scratch) == .failed(.unavailable(reason: "no sink")))
    }

    @Test func landingWithEnricherFillsWeakAlternates() {
        let enricher = AlternateEnricher(biasVocabulary: ["Kothari", "Priya", "TeamViewer"])
        let session = RepairSession(replaceSink: InMemoryReplaceRangeSink(document: "call cotari"), enricher: enricher)
        session.land(Utterance(spans: [TranscriptSpan(text: "call", confidence: 0.9, audioRange: 0...0.1), TranscriptSpan(text: "cotari", confidence: 0.3, audioRange: 0.2...0.5)]), fieldOffset: 0)
        #expect(session.current!.spans[1].alternates.first?.text == "Kothari")
        #expect(session.apply(.snap("Kothari")) == .replaced(spanIndex: 1, from: "cotari", to: "Kothari"))
    }
}
