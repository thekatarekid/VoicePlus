import Engine
import Testing

/// S5 — `WordAligner`'s text-only alignment (additive): the words a recogniser produced against the
/// words formatting left, for moving uncertainty marks without reusing character offsets.
@Suite("S5 — WordAligner text alignment")
struct WordAlignerTextS5Tests {
    @Test("equal words match whatever their case and punctuation")
    func matches() {
        let pairs = WordAligner.align(source: ["can", "we", "meet", "mira"], target: ["Can", "we", "meet", "Mira?"])
        #expect(pairs.map(\.op) == [.match, .match, .match, .match])
        #expect(pairs.map(\.preview) == [0, 1, 2, 3] && pairs.map(\.final) == [0, 1, 2, 3])
        #expect(WordAligner.regions(of: pairs).isEmpty)
    }

    @Test("a removed word is a deletion region with no target words")
    func deletion() {
        let pairs = WordAligner.align(source: ["um", "send", "it"], target: ["Send", "it."])
        #expect(pairs.first?.op == .delete)
        #expect(WordAligner.regions(of: pairs) == [WordAligner.Region(source: 0..<1, target: 0..<0)])
    }

    @Test("an inserted word is an insertion region at its place in the source")
    func insertion() {
        let pairs = WordAligner.align(source: ["meet", "friday"], target: ["meet", "on", "Friday"])
        #expect(WordAligner.regions(of: pairs) == [WordAligner.Region(source: 1..<1, target: 1..<2)])
    }

    @Test("a rewrite of several words into one is one region")
    func rewrite() {
        let pairs = WordAligner.align(source: ["costs", "twenty", "five", "dollars", "today"], target: ["costs", "$25", "today."])
        #expect(WordAligner.regions(of: pairs) == [WordAligner.Region(source: 1..<4, target: 1..<2)])
    }

    @Test("separate rewrites stay separate regions between matched anchors")
    func separateRegions() {
        let pairs = WordAligner.align(source: ["the", "quick", "brown", "fox", "jumped", "over"],
                                      target: ["a", "quick", "brown", "fox", "leapt", "over"])
        #expect(WordAligner.regions(of: pairs) == [WordAligner.Region(source: 0..<1, target: 0..<1),
                                                   WordAligner.Region(source: 4..<5, target: 4..<5)])
    }

    @Test("nothing in common: one region over both texts; empty sides")
    func nothingInCommon() {
        let pairs = WordAligner.align(source: ["gonna", "head", "out"], target: ["Leaving", "now."])
        #expect(WordAligner.regions(of: pairs) == [WordAligner.Region(source: 0..<3, target: 0..<2)])
        #expect(WordAligner.align(source: [], target: []).isEmpty)
        #expect(WordAligner.regions(of: WordAligner.align(source: [], target: ["hi"])) == [WordAligner.Region(source: 0..<0, target: 0..<1)])
    }
}
