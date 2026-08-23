import Foundation
import Testing
import Shared
@testable import Engine

func sp(_ text: String, _ r: ClosedRange<TimeInterval>, _ c: Float = 0.9) -> TranscriptSpan {
    TranscriptSpan(text: text, confidence: c, audioRange: r, provenance: [.asr])
}

@Suite("P1.5.1 T1 — word alignment vectors")
struct ReconcileAlignerTests {
    @Test func identicalHypothesesAlignAsMatches() {
        let a = [sp("send", 0...0.2), sp("it", 0.2...0.4), sp("now", 0.4...0.6)]
        let pairs = WordAligner.align(preview: a, final: a)
        #expect(pairs.map(\.op) == [.match, .match, .match])
        #expect(WordAligner.disagreements(preview: a, final: a).isEmpty)
    }

    @Test func substitutionWithOverlappingAudio() {
        let p = [sp("send", 0...0.2), sp("cotari", 0.3...0.6), sp("now", 0.7...0.9)]
        let f = [sp("send", 0...0.2), sp("Kothari", 0.28...0.62), sp("now", 0.7...0.9)]
        let d = WordAligner.disagreements(preview: p, final: f)
        #expect(d.count == 1 && d[0].previewRange == 1..<2 && d[0].finalRange == 1..<2)
        #expect(d[0].previewText == "cotari" && d[0].finalText == "Kothari")
        #expect(d[0].audioRange == 0.28...0.62)
    }

    @Test func insertionAndDeletionVectors() {
        let p = [sp("send", 0...0.2), sp("now", 0.5...0.7)]
        let f = [sp("send", 0...0.2), sp("it", 0.2...0.4), sp("now", 0.5...0.7)]
        let ins = WordAligner.align(preview: p, final: f).map(\.op)
        #expect(ins == [.match, .insert, .match])
        let di = WordAligner.disagreements(preview: p, final: f)
        #expect(di.count == 1 && di[0].previewRange == 1..<1 && di[0].finalText == "it")
        let del = WordAligner.align(preview: f, final: p).map(\.op)
        #expect(del == [.match, .delete, .match])
    }

    @Test func mergeSplitBecomesOneRegion() {
        let p = [sp("the", 0...0.1), sp("data", 0.1...0.3), sp("base", 0.3...0.5), sp("is", 0.5...0.6)]
        let f = [sp("the", 0...0.1), sp("database", 0.1...0.5), sp("is", 0.5...0.6)]
        let d = WordAligner.disagreements(preview: p, final: f)
        #expect(d.count == 1 && d[0].previewRange == 1..<3 && d[0].previewText == "data base" && d[0].finalText == "database")
    }

    @Test func casePunctuationOnlyIsAMatch() {
        let p = [sp("hello", 0...0.2), sp("world", 0.2...0.4)]
        let f = [sp("Hello,", 0...0.2), sp("world.", 0.2...0.4)]
        #expect(WordAligner.align(preview: p, final: f).map(\.op) == [.match, .match])
        #expect(WordAligner.normalize("Hello, World!") == "hello world")
    }

    @Test func audioOverlapDisambiguatesShiftedWords() {
        // Preview dropped a word; aligner must pair by audio, not drift into two substitutions.
        let p = [sp("meet", 0...0.2), sp("tomorrow", 0.6...0.9)]
        let f = [sp("meet", 0...0.2), sp("Raj", 0.25...0.5), sp("tomorrow", 0.6...0.9)]
        #expect(WordAligner.align(preview: p, final: f).map(\.op) == [.match, .insert, .match])
    }

    @Test func previewTimelineAssignsAudioRangesAndHandlesRewrites() {
        let spans = PreviewTimeline.spans(from: [
            .init(audioSeconds: 0.16, text: "send"), .init(audioSeconds: 0.32, text: "send it"),
            .init(audioSeconds: 0.48, text: "send it to"), .init(audioSeconds: 0.64, text: "send it to cotari"),
            .init(audioSeconds: 0.80, text: "send it to kothari"),
        ])
        #expect(spans.map(\.text) == ["send", "it", "to", "kothari"])
        #expect(spans[3].audioRange == 0.48...0.64 && spans[0].audioRange == 0...0.16)
        #expect(spans.allSatisfy { $0.confidence == 0.5 && $0.provenance == [.asr] })
    }
}
