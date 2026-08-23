import Foundation
import Testing
@testable import Lab

@Suite struct ScoringTests {
    @Test func normaliserStripsPunctuationAndCase() {
        #expect(TextNormalizer.words("Hey, just checking-in. Don't!") == ["hey", "just", "checking", "in", "don't"])
        #expect(TextNormalizer.rawTokens("Run `kubectl get pods`, now (gpt-4o).") == ["Run", "`kubectl", "get", "pods`", "now", "gpt-4o"])
    }

    @Test(arguments: [
        ("the cat sat", "the cat sat", 0, 0, 0, 0.0),
        ("the cat sat", "the dog sat", 1, 0, 0, 1.0 / 3),
        ("the cat sat", "the sat", 0, 1, 0, 1.0 / 3),
        ("the cat sat", "the big cat sat", 0, 0, 1, 1.0 / 3),
        ("the cat sat", "", 0, 3, 0, 1.0),
        ("", "hello", 0, 0, 1, 1.0),
        ("", "", 0, 0, 0, 0.0),
        ("a b c d", "d c b a", 4, 0, 0, 1.0),
        ("Hello, World!", "hello world", 0, 0, 0, 0.0),
    ])
    func werVectors(ref: String, hyp: String, sub: Int, del: Int, ins: Int, wer: Double) {
        let r = WERScorer.score(reference: ref, hypothesis: hyp)
        #expect(r.substitutions == sub, "sub \(ref) / \(hyp)")
        #expect(r.deletions == del, "del \(ref) / \(hyp)")
        #expect(r.insertions == ins, "ins \(ref) / \(hyp)")
        #expect(abs(r.wer - wer) < 1e-9)
        #expect(r.errors == sub + del + ins)
    }

    @Test func werIsSymmetricInEditCount() {
        let a = "please find the updated quarterly report attached"
        let b = "please find updated quarterly reports attached today"
        #expect(WERScorer.score(reference: a, hypothesis: b).errors == WERScorer.score(reference: b, hypothesis: a).errors)
    }

    @Test func entityDetectionHeuristics() {
        let e = EntityScorer.detectEntities(in: "TeamViewer AG reported strong growth in the enterprise segment this year.")
        #expect(e == ["TeamViewer", "AG"])
        #expect(EntityScorer.detectEntities(in: "We switched the summarizer from gpt-4o to a smaller local model.") == ["gpt-4o"])
        #expect(EntityScorer.detectEntities(in: "Mister Kothari will join the call from the Mumbai office at four.") == ["Kothari", "Mumbai"])
        #expect(EntityScorer.detectEntities(in: "Hey, just checking in. Are we still on for lunch tomorrow at noon?") == [])
        #expect(EntityScorer.detectEntities(in: "I think Sundar Pichai uses camelCase.") == ["Sundar", "Pichai", "camelCase"])
    }

    @Test func entityRecallAndFalseEntities() {
        let r = EntityScorer.score(reference: "Run kubectl get pods to check Anthropic.", hypothesis: "Run cube cuttle get pods to check Anthropic and Google.")
        #expect(r.expected == ["kubectl", "Anthropic"])
        #expect(r.found == ["Anthropic"])
        #expect(r.recall == 0.5)
        #expect(r.falseEntities == ["Google"])
        #expect(r.falseEntityRate == 1.0 / 10)
        let curated = EntityScorer.score(reference: "x", hypothesis: "Foo bar", entities: ["Foo", "Baz"])
        #expect(curated.recall == 0.5)
        #expect(EntityScorer.score(reference: "plain words", hypothesis: "plain words").recall == nil)
    }

    @Test func percentiles() {
        let v: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        #expect(Percentile.value(v, p: 50) == 50)
        #expect(Percentile.value(v, p: 95) == 100)
        #expect(Percentile.value(v, p: 90) == 90)
        #expect(Percentile.value([], p: 50) == 0)
        #expect(Percentile.value([7], p: 95) == 7)
    }

    @Test func stableHashIsStable() {
        #expect(StableHash.fnv1a("clean_01_samantha.wav") == StableHash.fnv1a("clean_01_samantha.wav"))
        #expect(StableHash.fnv1a("a") != StableHash.fnv1a("b"))
        #expect(StableHash.fnv1a("") == 0xcbf29ce484222325)
    }
}
