import Foundation
import Testing
@testable import Engine

@Suite("Biasing: vocabulary + prefix tree (T2)")
struct BiasingPrefixTreeTests {
    let vocab = BiasVocabulary.synthetic()

    @Test func greedyLongestMatchEncoding() throws {
        let ids = try #require(vocab.encode("kubectl"))
        #expect(ids.map { vocab.pieces[$0] } == ["▁kube", "ctl"])
        let multi = try #require(vocab.encode("TeamViewer AG"))
        #expect(multi.map { vocab.pieces[$0] } == ["▁Team", "Viewer", "▁AG"])
        #expect(vocab.encode("Ω") == nil)
    }

    @Test func treeMatchesFullAndPartialPaths() throws {
        let tree = BiasPrefixTree(entries: [BiasEntry(text: "kubectl", weight: 1), BiasEntry(text: "Kothari", weight: 0.5)], vocabulary: vocab)
        #expect(tree.entryCount == 2)
        let kube = vocab.ids["▁kube"]!, ctl = vocab.ids["ctl"]!, the = vocab.ids["▁the"]!
        let n1 = try #require(tree.child(of: BiasPrefixTree.root, token: kube))
        #expect(tree.depth(of: n1) == 1 && !tree.isTerminal(n1) && tree.weight(of: n1) == 1)
        let n2 = try #require(tree.child(of: n1, token: ctl))
        #expect(tree.isTerminal(n2))
        #expect(tree.child(of: n1, token: the) == nil)
        // Divergence and completion both return to root; a new entity can start right after.
        #expect(tree.state(after: [kube, the]) == BiasPrefixTree.root)
        #expect(tree.state(after: [kube, ctl, kube]) == n1)
    }

    @Test func loadsParakeetJSONAndSentencePieceTSV() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("p15-vocab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("parakeet_vocab.json")
        try #"{"0":"<unk>","2":"ctl","1":"▁kube"}"#.write(to: json, atomically: true, encoding: .utf8)
        let v1 = try BiasVocabulary.load(from: json)
        #expect(v1.pieces == ["<unk>", "▁kube", "ctl"])
        #expect(v1.encode("kubectl") == [1, 2])
        let tsv = dir.appendingPathComponent("sp.vocab")
        try "<unk>\t0\n▁kube\t-1.5\nctl\t-2\n".write(to: tsv, atomically: true, encoding: .utf8)
        let v2 = try BiasVocabulary.load(from: tsv)
        #expect(v2.pieces == ["<unk>", "▁kube", "ctl"])
        // Real Parakeet vocab if FluidAudio's cache is on this machine (skips silently otherwise).
        if let real = BiasVocabulary.discoverParakeet() {
            #expect(real.pieces.count == 8192)
            #expect(real.encode("kubectl") != nil)
        }
    }
}
