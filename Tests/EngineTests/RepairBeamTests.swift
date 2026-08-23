import Foundation
import Testing
import Shared
@testable import Engine

private func tok(_ id: Int, _ text: String, p: Float, _ s: TimeInterval, _ e: TimeInterval) -> DecodedToken {
    DecodedToken(tokenId: id, text: text, logProb: log(p), startTime: s, endTime: e)
}
private func hyp(_ pieces: [(String, Float)], at start: TimeInterval = 0.8) -> BeamHypothesis {
    var t: TimeInterval = start
    var out: [DecodedToken] = []
    for (i, (piece, p)) in pieces.enumerated() {
        out.append(tok(1000 + i, piece, p: p, t, t + 0.08)); t += 0.08
    }
    return BeamHypothesis(tokens: out)
}

@Suite("P1.6 T1 — selective beam + word confusion network")
struct RepairBeamTests {
    // "send it to kothari tomorrow" — "kothari" is shaky.
    static let script: [DecodedToken] = [
        tok(1, "▁send", p: 0.98, 0.0, 0.08), tok(2, "▁it", p: 0.97, 0.16, 0.24), tok(3, "▁to", p: 0.96, 0.32, 0.4),
        tok(4, "▁ko", p: 0.45, 0.8, 0.88), tok(5, "th", p: 0.4, 0.88, 0.96), tok(6, "ari", p: 0.7, 0.96, 1.04),
        tok(7, "▁tomorrow", p: 0.99, 1.2, 1.44),
    ]
    static let frames = EncoderFrames(values: [], frameCount: 25, hiddenSize: 0)

    @Test func confusionNetworkCollapsesSegmentationAndBlankVariants() {
        // Three raw beam paths render to "kothari", two to "cotari", one to "katari".
        let hyps = [
            hyp([("▁ko", 0.5), ("th", 0.5), ("ari", 0.8)]), hyp([("▁koth", 0.5), ("ari", 0.7)]), hyp([("▁ko", 0.5), ("thari", 0.6)]),
            hyp([("▁co", 0.45), ("tari", 0.6)]), hyp([("▁cot", 0.4), ("ari", 0.6)]),
            hyp([("▁ka", 0.2), ("tari", 0.5)]),
        ]
        let alts = WordConfusionNetwork.collapse(hyps)
        #expect(alts.map(\.text) == ["kothari", "cotari", "katari"])
        #expect(alts[0].source == .confusionNetwork && alts[2].source == .beam)
        #expect(abs(alts.map(\.score).reduce(0, +) - 1) < 1e-4)
        #expect(WordConfusionNetwork.collapse(hyps, excluding: "Kothari").map(\.text) == ["cotari", "katari"])
    }

    @Test func beamRunsOnlyOverLowConfidenceRegions() async throws {
        let backend = ScriptedBeamBackend(["kothari": [hyp([("▁co", 0.4), ("tari", 0.5)]), hyp([("▁ka", 0.3), ("tari", 0.4)])]])
        let decoder = SelectiveBeamDecoder(base: MockDecoder(script: Self.script), backend: backend, width: 4)
        let spans = try await decoder.decodeSpans(encoderFrames: Self.frames)
        #expect(spans.map(\.text) == ["send", "it", "to", "kothari", "tomorrow"])
        #expect(backend.calls.count == 1)
        #expect(backend.calls[0].greedyText == "kothari" && backend.calls[0].timeRange == 0.8...1.04)
        #expect(spans[3].alternates.map(\.text) == ["cotari", "katari"])
        #expect(spans[3].confidence == 0.4 && spans[3].isLowConfidence)   // greedy confidence untouched
        #expect(spans.filter { $0.text != "kothari" }.allSatisfy { $0.alternates.isEmpty })
        #expect(spans.allSatisfy { $0.provenance == [.asr] })
        let result = try await decoder.decode(encoderFrames: Self.frames)  // frozen path returns greedy tokens
        #expect(result.tokens.isEmpty) // MockDecoder emitted everything already; reset restores
        await decoder.reset()
        #expect(decoder.spansFromLastDecode.isEmpty)
    }

    @Test func weakBeamLeavesNoAlternates() async throws {
        let decoder = SelectiveBeamDecoder(base: MockDecoder(script: Self.script), backend: ScriptedBeamBackend())
        let spans = try await decoder.decodeSpans(encoderFrames: Self.frames)
        #expect(spans[3].alternates.isEmpty)
        #expect(decoder.regionsDecoded == 1)
    }

    @Test func adjacentLowConfidenceWordsMergeIntoOneRegion() async throws {
        let script = [tok(1, "▁team", p: 0.3, 0.0, 0.08), tok(2, "▁viewer", p: 0.35, 0.08, 0.16), tok(3, "▁ag", p: 0.2, 0.16, 0.24), tok(4, "▁call", p: 0.9, 0.5, 0.6)]
        let backend = ScriptedBeamBackend(["team viewer ag": [hyp([("▁team", 0.5), ("▁viewer", 0.5), ("▁ag", 0.5)]), hyp([("▁Team", 0.4), ("Viewer", 0.4), ("▁AG", 0.6)])]])
        let decoder = SelectiveBeamDecoder(base: MockDecoder(script: script), backend: backend)
        let spans = try await decoder.decodeSpans(encoderFrames: EncoderFrames(values: [], frameCount: 10, hiddenSize: 0))
        #expect(backend.calls.count == 1 && backend.calls[0].wordRange == 0...2)
        #expect(spans[0].alternates.first?.text == "TeamViewer AG") // phrase-level alternate on the region head
        #expect(spans.count == 4 && spans[3].alternates.isEmpty)
    }

    @Test func biaserPassesThroughToBase() {
        struct B: LogitBiaser { func boost(tokenIds: [Int], prefixState: PrefixState) -> [Int: Float] { [:] } }
        let base = MockDecoder(script: [])
        let decoder = SelectiveBeamDecoder(base: base, backend: ScriptedBeamBackend())
        decoder.biaser = B()
        #expect(base.biaser != nil && decoder.name.contains("mock"))
    }
}
