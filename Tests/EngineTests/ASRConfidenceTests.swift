import Foundation
import Testing
import Shared
@testable import Engine

private func tok(_ id: Int, _ text: String, p: Float, _ s: TimeInterval, _ e: TimeInterval) -> DecodedToken {
    DecodedToken(tokenId: id, text: text, logProb: log(p), startTime: s, endTime: e)
}

@Suite("ASR confidence aggregation (T5)")
struct ASRConfidenceTests {
    @Test func minProbRuleAcrossSubwords() {
        let tokens = [tok(1, "▁kube", p: 0.9, 0.0, 0.08), tok(2, "ctl", p: 0.3, 0.08, 0.16), tok(3, "▁get", p: 0.95, 0.24, 0.32)]
        let words = WordConfidence.aggregate(tokens)
        #expect(words.map(\.text) == ["kubectl", "get"])
        #expect(abs(words[0].confidence - 0.3) < 1e-5)
        #expect(abs(words[1].confidence - 0.95) < 1e-5)
        #expect(words[0].startTime == 0.0 && words[0].endTime == 0.16)
    }

    @Test func spansCarryTimestampsAndProvenance() {
        let tokens = [tok(1, "▁hello", p: 0.8, 0.16, 0.4), tok(2, "▁world", p: 0.6, 0.48, 0.8)]
        let spans = WordConfidence.spans(from: tokens, timeOffset: 1.0)
        #expect(spans.count == 2)
        #expect(spans[0].audioRange == 1.16...1.4)
        #expect(spans[1].audioRange == 1.48...1.8)
        #expect(spans.allSatisfy { $0.provenance == [.asr] })
        #expect(abs(WordConfidence.utteranceConfidence(spans) - 0.7) < 1e-5)
    }

    @Test func leadingContinuationTokensFormOneWord() {
        // Model can emit a continuation piece first (no ▁) — it must still become a word.
        let tokens = [tok(5, "ing", p: 0.5, 0, 0.08), tok(1, "▁ok", p: 0.9, 0.08, 0.16)]
        #expect(WordConfidence.aggregate(tokens).map(\.text) == ["ing", "ok"])
    }

    @Test func emptyAndMarkerOnlyTokens() {
        #expect(WordConfidence.aggregate([]).isEmpty)
        let tokens = [tok(1, "▁", p: 0.2, 0, 0.08), tok(2, "a", p: 0.9, 0.08, 0.16)]
        let w = WordConfidence.aggregate(tokens)
        #expect(w.count == 1 && w[0].text == "a")
        #expect(abs(w[0].confidence - 0.2) < 1e-5)   // marker's low prob still counts
    }

    @Test func renderedTextAndProbabilityClamp() {
        let tokens = [tok(1, "▁foo", p: 1.0, 0, 0.1), tok(2, "bar", p: 0.5, 0.1, 0.2), tok(3, "▁baz", p: 0.1, 0.2, 0.3)]
        #expect(tokens.renderedText == "foobar baz")
        #expect(DecodeResult(tokens: tokens).text == "foobar baz")
        #expect(DecodedToken(tokenId: 0, text: "x", logProb: 1, startTime: 0, endTime: 0).probability == 1)
        #expect(DecodedToken(tokenId: 0, text: "x", logProb: 0, startTime: 1, endTime: 0.5).endTime == 1)
    }

    @Test func mangledWordsScoreLowerStatistically() {
        // Confidence sanity: words with a sub-0.5 piece must land below threshold; clean ones above.
        var rng = SystemRandomNumberGenerator()
        var low = 0, high = 0
        for i in 0..<200 {
            let mangled = i % 2 == 0
            let p1 = Float.random(in: 0.85...1.0, using: &rng)
            let p2 = mangled ? Float.random(in: 0.05...0.45, using: &rng) : Float.random(in: 0.85...1.0, using: &rng)
            let w = WordConfidence.aggregate([tok(1, "▁ab", p: p1, 0, 0.1), tok(2, "cd", p: p2, 0.1, 0.2)])[0]
            if mangled { #expect(w.confidence < TranscriptSpan.lowConfidenceThreshold); low += 1 }
            else { #expect(w.confidence >= TranscriptSpan.lowConfidenceThreshold); high += 1 }
        }
        #expect(low == 100 && high == 100)
    }
}

@Suite("Decoder protocol (T1)")
struct ASRDecoderTests {
    struct Boost: LogitBiaser {
        let bonus: [Int: Float]
        func boost(tokenIds: [Int], prefixState: PrefixState) -> [Int: Float] { bonus.filter { tokenIds.contains($0.key) } }
    }

    @Test func mockDecoderChunksByTimeAndResets() async throws {
        let script = [tok(1, "▁a", p: 0.9, 0.0, 0.08), tok(2, "▁b", p: 0.9, 1.0, 1.08), tok(3, "▁c", p: 0.9, 2.0, 2.08)]
        let d = MockDecoder(script: script)
        let r1 = try await d.decode(encoderFrames: EncoderFrames(values: [], frameCount: 20, hiddenSize: 0, frameDuration: 0.08, timeOffset: 0))
        #expect(r1.text == "a b")
        let r2 = try await d.decode(encoderFrames: EncoderFrames(values: [], frameCount: 20, hiddenSize: 0, frameDuration: 0.08, timeOffset: 1.6))
        #expect(r2.text == "c")
        await d.reset()
        let r3 = try await d.decode(encoderFrames: EncoderFrames(values: [], frameCount: 100, hiddenSize: 0, frameDuration: 0.08))
        #expect(r3.tokens.count == 3 && d.decodeCalls == 3)
    }

    /// V5 A1: the decode-time `LogitBiaser` is accepted but no longer applied (it could only
    /// re-score the chosen token and never changed a word). Boosting is the final-pass booster.
    @Test func biaserIsAcceptedButInert() async throws {
        let script = [tok(7, "▁team", p: 0.4, 0, 0.1), tok(8, "viewer", p: 0.9, 0.1, 0.2)]
        let d = MockDecoder(script: script)
        d.biaser = Boost(bonus: [7: 0.5, 8: 5.0])
        let r = try await d.decode(encoderFrames: EncoderFrames(values: [], frameCount: 10, hiddenSize: 0))
        #expect(r.tokens == script)
    }
}
