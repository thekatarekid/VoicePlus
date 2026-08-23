import Foundation
import Testing
import Shared
@testable import Engine

/// T6 — alternate usefulness on a synthetic mangled set.
///
/// Method: each case is (truth, mangled-as-ASR-heard, beam alternates the selective beam
/// would have produced). Manglings are the confusions Parakeet actually makes on the
/// fixtures (see Engine/Decoder/README.md: "Priya" → "Kriya") plus classic phonetic
/// substitutions (k/c, th/t, ph/f, dropped syllables, homophones). The mangled word is
/// landed at confidence 0.3 with the beam alternates; the enricher adds bias-vocabulary /
/// dictionary neighbours. We then ask: is the truth in the top-3? Target ≥ 60 %, kill < 40 %.
@Suite("P1.6 T6 — alternate usefulness")
struct RepairUsefulnessTests {
    static let bias = ["Kothari", "Priya", "TeamViewer", "kubectl", "Rishi", "Samantha", "Daniel", "Thursday", "Kubernetes",
                       "Anthropic", "Figma", "Bhattacharya", "Xcode", "Schmidt", "Catherine", "Stephen", "Zhang", "Nguyen",
                       "Lakshmi", "Parakeet", "Sparkle", "Homebrew", "GRDB", "Muesli", "Monday", "Friday", "quarterly", "invoice"]
    static let dictionary = ["Aditya", "VoicePlus", "FluidAudio"]

    /// (truth, mangled, beam alternates)
    static let cases: [(String, String, [String])] = [
        ("Kothari", "cotari", ["katari"]), ("Priya", "kriya", []), ("TeamViewer", "team fuel", []), ("kubectl", "cube cuttle", ["kubectl"]),
        ("Rishi", "rishy", []), ("Samantha", "semantha", ["samanta"]), ("Daniel", "daniyal", []), ("Thursday", "thirsday", ["thursday"]),
        ("Kubernetes", "cooper netties", []), ("Anthropic", "anthropik", []), ("Figma", "fig ma", ["figma"]), ("Bhattacharya", "batacharia", []),
        ("Xcode", "ex code", ["xcode"]), ("Schmidt", "shmit", []), ("Catherine", "katherine", []), ("Stephen", "steven", []),
        ("Zhang", "jang", []), ("Nguyen", "win", ["when"]), ("Lakshmi", "lakshme", []), ("Parakeet", "parakete", []),
        ("Sparkle", "sparkel", []), ("Homebrew", "home brew", []), ("Aditya", "aditia", []), ("VoicePlus", "voice plus", []),
        ("FluidAudio", "fluid audio", []), ("Monday", "munday", []), ("invoice", "in voice", []), ("quarterly", "quarterlee", []),
        // Honest misses: truth absent from every vocabulary and beam → cannot be recovered.
        ("Okonkwo", "a conquer", ["a conker"]), ("Wojciechowski", "voy chef ski", []),
    ]

    @Test func top3HitRateAtLeast60Percent() {
        let enricher = AlternateEnricher(biasVocabulary: Self.bias, userDictionary: Self.dictionary)
        var pairs: [(span: TranscriptSpan, truth: String)] = []
        var misses: [String] = []
        for (truth, mangled, beam) in Self.cases {
            let alts = beam.enumerated().map { Alternate(text: $0.element, score: 0.3 / Float($0.offset + 1), source: .beam) }
            let span = enricher.enrich(TranscriptSpan(text: mangled, confidence: 0.3, audioRange: 0...0.5, alternates: alts))
            pairs.append((span, truth))
            if !span.alternates.prefix(3).contains(where: { WordConfusionNetwork.normalize($0.text) == WordConfusionNetwork.normalize(truth) }) {
                misses.append("\(mangled) → \(span.alternates.prefix(3).map(\.text)) (truth \(truth))")
            }
        }
        let m = AlternateUsefulness.measure(pairs)
        #expect(m.evaluated == Self.cases.count)
        #expect(m.hitRate >= 0.6, "\(m.summary) misses: \(misses)")
        #expect(m.meetsTarget && !m.belowKill)
    }

    @Test func metricSkipsConfidentAndAlreadyCorrectSpans() {
        let right = TranscriptSpan(text: "Priya", confidence: 0.2, audioRange: 0...1)
        let confidentWrong = TranscriptSpan(text: "Kriya", confidence: 0.9, audioRange: 0...1, alternates: [Alternate(text: "Priya", score: 1, source: .beam)])
        let hit = TranscriptSpan(text: "kriya", confidence: 0.2, audioRange: 0...1, alternates: [Alternate(text: "priya", score: 1, source: .beam)])
        let miss = TranscriptSpan(text: "kriya", confidence: 0.2, audioRange: 0...1, alternates: [Alternate(text: "maria", score: 1, source: .beam)])
        let m = AlternateUsefulness.measure([(right, "Priya"), (confidentWrong, "Priya"), (hit, "Priya"), (miss, "Priya")])
        #expect(m.evaluated == 2 && m.hits == 1 && m.hitRate == 0.5 && !m.meetsTarget && !m.belowKill)
        #expect(AlternateUsefulness().hitRate == 0 && !AlternateUsefulness().belowKill)
    }

    @Test func enricherLeavesStrongBeamAndConfidentSpansAlone() {
        let enricher = AlternateEnricher(biasVocabulary: Self.bias)
        let strong = TranscriptSpan(text: "cotari", confidence: 0.3, audioRange: 0...1, alternates: [
            Alternate(text: "katari", score: 0.4, source: .beam), Alternate(text: "kotari", score: 0.3, source: .beam)])
        #expect(enricher.enrich(strong) == strong)
        let confident = TranscriptSpan(text: "cotari", confidence: 0.9, audioRange: 0...1)
        #expect(enricher.enrich(confident) == confident)
        #expect(enricher.enrich(confident, force: true).alternates.first?.text == "Kothari")
        let cands = enricher.candidates(for: "kriya")
        #expect(cands.first?.text == "Priya" && cands.first?.source == .biasing)
        #expect(cands.allSatisfy { $0.score > 0 && $0.score <= 1 })
        #expect(AlternateEnricher.levenshtein("kitten", "sitting") == 3)
    }
}
