import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// Context Writer §2.5 — `HeardWords.make`: the raw spans as per-word confidence + top-K alternates
// for `ContextPacket.Heard`.

private func span(_ text: String, _ confidence: Float, _ alternates: [(String, Float)] = [], at t: Double = 0) -> TranscriptSpan {
    TranscriptSpan(text: text, confidence: confidence, audioRange: t...(t + 0.3),
                   alternates: alternates.map { Alternate(text: $0.0, score: $0.1, source: .beam) }, provenance: [.asr])
}

@Suite("Context Writer — heard words for the packet")
struct HeardWordsTests {
    @Test("the owner's “Place two”: one word per span, its confidence, the decoder's alternates best first")
    func placeTwo() {
        let spans = [
            span("Place", 0.339, [("Rlace", 0.077), ("Facelace", 0.067), ("Prace", 0.063), ("Phlace", 0.021)]),
            span("two.", 0.627, [("to.", 0.146), ("T.", 0.013), ("do.", 0.006)], at: 0.3),
        ]
        let words = HeardWords.make(from: spans)
        #expect(words.map(\.text) == ["Place", "two."])
        #expect(words.map(\.isUncertain) == [true, false])
        #expect(words[0].confidence == spans[0].confidence)
        #expect(words[0].alternates == ["Rlace", "Facelace", "Prace"], "best score first, at most three")
        #expect(words[1].alternates == ["to.", "T.", "do."], "punctuation kept as the recogniser wrote it")
        #expect(ContextPacket.Heard(raw: spans.joinedText, words: words).marked == "⟦Place⟧ two.")
    }

    @Test("alternates are ranked by score, never the word itself, never twice")
    func dedupe() {
        let spans = [span("Mira", 0.3, [("mira", 0.9), ("Meera", 0.5), ("Myra", 0.6), ("Mira.", 0.4), ("meera", 0.2), (".", 0.1)])]
        #expect(HeardWords.make(from: spans).first?.alternates == ["Myra", "Meera"])
        #expect(HeardWords.make(from: spans, topK: 1).first?.alternates == ["Myra"])
    }

    @Test("a multi-word span attributes an alternate by position and drops one it cannot pin")
    func multiWordSpan() {
        let spans = [span("all right", 0.3, [("all write", 0.3), ("or right", 0.2), ("alright", 0.1)])]
        let words = HeardWords.make(from: spans)
        #expect(words.map(\.text) == ["all", "right"])
        #expect(words[0].alternates == ["or"])
        #expect(words[1].alternates == ["write"])
        #expect(words.allSatisfy { $0.confidence == 0.3 })
    }

    @Test("a single-word span keeps a multi-word alternate whole")
    func splitAlternate() {
        let spans = [span("sixtien", 0.43, [("six teen", 0.05), ("sixteen", 0.03)])]
        #expect(HeardWords.make(from: spans).first?.alternates == ["six teen", "sixteen"])
    }

    @Test("blank spans add no words; the order is the spans' order")
    func blanks() {
        let spans = [span("", 0.9), span("   ", 0.9), span("fan out", 0.9, at: 0.3), span("surveillance", 0.2, at: 0.9)]
        let words = HeardWords.make(from: spans)
        #expect(words.map(\.text) == ["fan", "out", "surveillance"])
        #expect(words.map(\.isUncertain) == [false, false, true])
        #expect(HeardWords.make(from: []).isEmpty)
    }

    @Test("a streaming placeholder (no audio, 0.5) passes through unflagged with no alternates")
    func placeholder() {
        let placeholder = TranscriptSpan(text: "use available text", confidence: 0.5, audioRange: 0...0,
                                         provenance: [.asr], stability: .committed)
        let words = HeardWords.make(from: [placeholder])
        #expect(words.count == 3 && words.allSatisfy { !$0.isUncertain && $0.alternates.isEmpty })
    }
}
