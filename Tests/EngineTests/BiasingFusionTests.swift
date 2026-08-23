import Foundation
import Testing
import Shared
@testable import Engine

/// Synthetic entity-recall suite (P1.5 tests): scripted top-K logits where the acoustics
/// prefer a confusable spelling; biasing must flip the entity path without touching clean words.
@Suite("Biasing: shallow fusion on a scripted decoder (T3/T4)")
struct BiasingFusionTests {
    let vocab = BiasVocabulary.synthetic()
    let frames = EncoderFrames(values: [], frameCount: 0, hiddenSize: 1)
    func id(_ p: String) -> Int { vocab.ids[p]! }

    struct Case { let reference: String; let entities: [String]; let steps: [StepCandidates] }

    /// Four utterances with confusable entities + one clean utterance (so the baseline recall is > 0).
    var suite: [Case] {
        [
            Case(reference: "run kubectl get pods", entities: ["kubectl", "pods"],
                 steps: ScriptedLogitDecoder.script(truth: [id("▁run"), id("▁kube"), id("ctl"), id("▁get"), id("▁pods")],
                                                    confusions: [1: (id("▁cube"), 1.5)], distractors: [id("▁the")])),
            Case(reference: "meeting with Kothari", entities: ["Kothari"],
                 steps: ScriptedLogitDecoder.script(truth: [id("▁meeting"), id("▁with"), id("▁Kot"), id("hari")],
                                                    confusions: [2: (id("▁Ko"), 1.0), 3: (id("tari"), 1.0)], distractors: [id("▁the")])),
            Case(reference: "call TeamViewer AG", entities: ["TeamViewer AG"],
                 steps: ScriptedLogitDecoder.script(truth: [id("▁call"), id("▁Team"), id("Viewer"), id("▁AG")],
                                                    confusions: [1: (id("▁team"), 1.0), 2: (id("▁viewer"), 1.2)], distractors: [id("▁the")])),
            Case(reference: "please run gpt-4o", entities: ["gpt-4o"],
                 steps: ScriptedLogitDecoder.script(truth: [id("▁please"), id("▁run"), id("▁gpt"), id("-"), id("4"), id("o")],
                                                    confusions: [3: (id("_"), 1.0), 5: (id("0"), 0.8)], distractors: [id("▁the")])),
            Case(reference: "get pods", entities: ["pods"],
                 steps: ScriptedLogitDecoder.script(truth: [id("▁get"), id("▁pods")], confusions: [:], distractors: [id("▁the")])),
        ]
    }

    var biasList: [BiasEntry] {
        ["kubectl", "Kothari", "TeamViewer AG", "gpt-4o", "pods", "Aditya", "Viewer"].map { BiasEntry(text: $0, weight: 1) }
    }

    func run(_ cases: [Case], biaser: LogitBiaser?, beam: Int? = nil) async throws -> (BiasingMetrics, [String]) {
        var m = BiasingMetrics()
        var hyps: [String] = []
        for c in cases {
            let scripted = ScriptedLogitDecoder(steps: c.steps, vocabulary: vocab)
            let dec: Decoder = beam.map { NarrowBeamBiasedDecoder(inner: scripted, width: $0) } ?? scripted
            let t0 = DispatchTime.now().uptimeNanoseconds
            dec.biaser = biaser
            let r = try await dec.decode(encoderFrames: frames)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            hyps.append(r.text)
            m.record(reference: c.reference, hypothesis: r.text, entities: c.entities, biasList: biasList.map(\.text), addedLatencyMs: ms)
            // Bet 9: confidence stays the *unbiased* probability.
            #expect(r.tokens.allSatisfy { $0.logProb <= 0 })
        }
        return (m, hyps)
    }

    @Test func biasingLiftsEntityRecallBy30PercentRelative() async throws {
        let (base, baseHyps) = try await run(suite, biaser: nil)
        #expect(baseHyps[0] == "run cubectl get pods")
        #expect(base.entityRecall < 0.5)
        let biaser = ShallowFusionBiaser(entries: biasList, vocabulary: vocab)
        let (biased, hyps) = try await run(suite, biaser: biaser)
        #expect(hyps == ["run kubectl get pods", "meeting with Kothari", "call TeamViewer AG", "please run gpt-4o", "get pods"])
        #expect(biased.entityRecall == 1.0)
        #expect(biased.relativeRecallGain(over: base) >= 0.30)
        #expect(biased.falseInsertionRate == 0)
        #expect(biaser.callCount == suite.reduce(0) { $0 + $1.steps.count })
    }

    @Test func falseInsertionGuardNeverOverturnsConfidentAcoustics() async throws {
        // "the cube control": the decoder is sure (gap 4.5 logits); kubectl is on the bias list.
        let steps = ScriptedLogitDecoder.script(truth: [id("▁the"), id("▁cube"), id("▁control")],
                                                confusions: [1: (id("▁kube"), -4.5)], distractors: [id("ctl")])
        let c = Case(reference: "the cube control", entities: [], steps: steps)
        let biaser = ShallowFusionBiaser(entries: biasList, vocabulary: vocab)
        let (m, hyps) = try await run([c], biaser: biaser)
        #expect(hyps == ["the cube control"])
        #expect(m.falseInsertions == 0)
        // Every bonus is clamped to ±maxBoost.
        let big = ShallowFusionBiaser(entries: biasList, vocabulary: vocab, config: { var c = BiasingConfig(); c.boostPerToken = 50; return c }())
        let b = big.boost(tokenIds: [id("▁kube"), id("ctl")], prefixState: PrefixState(tokenIds: [id("▁kube")]))
        #expect(b.values.allSatisfy { abs($0) <= big.config.maxBoost })
    }

    @Test func partialMatchIsUnbiasedOnDivergence() {
        let biaser = ShallowFusionBiaser(entries: [BiasEntry(text: "kubectl", weight: 1)], vocabulary: vocab)
        let cfg = biaser.config
        let start = biaser.boost(tokenIds: [id("▁kube"), id("▁the")], prefixState: PrefixState())
        #expect(start[id("▁kube")] == cfg.boostPerToken)
        #expect(start[id("▁the")] == nil)
        let mid = biaser.boost(tokenIds: [id("ctl"), id("▁the")], prefixState: PrefixState(tokenIds: [id("▁kube")]))
        #expect(mid[id("ctl")] == cfg.boostPerToken + cfg.completionBonus)
        #expect(mid[id("▁the")] == -cfg.unboostFactor * cfg.boostPerToken)   // depth 1 taken back
        // After a completed entry nothing is penalised and a new one may start.
        let after = biaser.boost(tokenIds: [id("▁the"), id("▁kube")], prefixState: PrefixState(tokenIds: [id("▁kube"), id("ctl")]))
        #expect(after[id("▁the")] == nil)
        #expect(after[id("▁kube")] == cfg.boostPerToken)
    }

    @Test func latencyUnder60msWith400Entries() {
        let entries = (0..<400).map { BiasEntry(text: "Entity\($0)x\(($0 * 7919) % 1000)", weight: Float($0 % 10 + 1) / 10) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let biaser = ShallowFusionBiaser(entries: entries, vocabulary: vocab)
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        #expect(biaser.tree.entryCount == 400)
        #expect(biaser.tree.skipped.isEmpty)
        // A long utterance: 600 emission steps × 8 candidates, prefix grows each step.
        var prefix: [Int] = []
        let cands = ["▁E", "n", "t", "i", "▁the", "x", "1", "▁a"].map(id)
        let t1 = DispatchTime.now().uptimeNanoseconds
        for step in 0..<600 {
            _ = biaser.boost(tokenIds: cands, prefixState: PrefixState(tokenIds: prefix, frameIndex: step))
            prefix.append(cands[step % cands.count])
        }
        let decodeMs = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6
        #expect(buildMs < 60, "tree build took \(buildMs) ms")
        #expect(decodeMs < 60, "600 boost calls took \(decodeMs) ms")
        #expect(biaser.meanMicrosPerCall < 100)
    }

    @Test func narrowBeamAlsoRecoversEntitiesAndKeepsUnbiasedScore() async throws {
        let biaser = ShallowFusionBiaser(entries: biasList, vocabulary: vocab)
        let (m, hyps) = try await run(suite, biaser: biaser, beam: 3)
        #expect(hyps[1] == "meeting with Kothari" && hyps[2] == "call TeamViewer AG")
        #expect(m.entityRecall == 1.0)
        let (baseline, _) = try await run(suite, biaser: nil, beam: 4)
        #expect(baseline.entityRecall < 0.5)
        #expect(NarrowBeamBiasedDecoder(inner: ScriptedLogitDecoder(steps: [], vocabulary: vocab), width: 9).width == 4)
    }

    @Test func featureFlagGatesTheBiaser() {
        let h = ContextHarvester(sources: [AXTreeSource(provider: MockFocusedWindowText(["kubectl Kothari"]))])
        let off = BiasingController(harvester: h, vocabulary: vocab, flags: .inMemory(["contextBiasing": false]))
        #expect(off.makeBiaser() == nil)
        let on = BiasingController(harvester: h, vocabulary: vocab, flags: .inMemory(["contextBiasing": true]))
        let b = on.makeBiaser()
        #expect(b?.tree.entryCount == 2)
        #expect(on.lastEntries.map(\.text).sorted() == ["Kothari", "kubectl"])
        #expect(on.lastBuildMs < 60)
        let noVocab = BiasingController(harvester: h, flags: .inMemory(["contextBiasing": true]))
        #expect(noVocab.makeBiaser() == nil)
    }

    @Test func metricsCountFalseInsertionsAndRecall() {
        var m = BiasingMetrics()
        m.record(reference: "send it to priya", hypothesis: "send it to Kothari", entities: ["priya"], biasList: ["Kothari", "priya"])
        #expect(m.entityRecall == 0 && m.falseInsertions == 1)
        m.record(reference: "ping Kothari", hypothesis: "ping Kothari", entities: ["Kothari"], biasList: ["Kothari"])
        #expect(m.entitiesRecalled == 1 && m.falseInsertions == 1 && m.hypothesisWords == 6)
        #expect(abs(m.falseInsertionRate - 1.0 / 6.0) < 1e-9)
    }
}
