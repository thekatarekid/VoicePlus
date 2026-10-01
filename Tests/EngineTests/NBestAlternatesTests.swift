import Foundation
import Shared
import Testing
@testable import Engine

/// V5 B3 — real N-best alternates: joint top-K per token → word alternates on `TranscriptSpan`,
/// dictionary variants added second.
@Suite("Real N-best alternates (V5 B3)")
struct NBestAlternatesTests {
    static func tok(_ id: Int, _ text: String, p: Float, at t: TimeInterval, alts: [(Int, String, Float)] = []) -> DecodedToken {
        DecodedToken(tokenId: id, text: text, logProb: log(p), startTime: t, endTime: t + 0.08,
                     alternatives: alts.map { TokenAlternative(tokenId: $0.0, text: $0.1, logProb: log($0.2)) })
    }

    struct MockProvider: TokenAlternativesProviding {
        var table: [Int: [TokenAlternative]]
        func alternatives(for tokens: [DecodedToken], samples: [Float], k: Int) async throws -> [[TokenAlternative]] {
            tokens.map { Array((table[$0.tokenId] ?? []).prefix(k)) }
        }
    }

    struct FailingProvider: TokenAlternativesProviding {
        func alternatives(for tokens: [DecodedToken], samples: [Float], k: Int) async throws -> [[TokenAlternative]] {
            throw CancellationError()
        }
    }

    @Test func wordAlternatesDifferFromTopAndCarryLogProbs() throws {
        // "cotari" = ▁co + tari; joint offered ▁ko / ▁ka at the first piece, ri / tar at the second.
        let word = [
            Self.tok(1, "\u{2581}co", p: 0.5, at: 0, alts: [(2, "\u{2581}ko", 0.3), (3, "\u{2581}ka", 0.1), (4, "ta", 0.05), (9, "\u{2581}Co", 0.04)]),
            Self.tok(5, "tari", p: 0.6, at: 0.08, alts: [(6, "thari", 0.3), (7, "\u{2581}tari", 0.05)]),
        ]
        let alts = WordAlternates.alternates(for: word)
        #expect(!alts.isEmpty && alts.count <= WordAlternates.defaultLimit)
        let texts = alts.map(\.text)
        #expect(!texts.contains { WordConfusionNetwork.normalize($0) == "cotari" }, "never repeats the top word: \(texts)")
        #expect(texts.contains("kotari") && texts.contains("cothari") && texts.contains("katari"))
        // A continuation piece never replaces a word start, and a word start never lands mid-word.
        #expect(!texts.contains("tatari") && !texts.contains("co tari") && !texts.contains("cotari"))
        for a in alts {
            let lp = try #require(a.logProb)
            #expect(lp <= 0 && a.source == .beam && abs(a.score - exp(lp)) < 1e-5)
        }
        #expect(zip(alts, alts.dropFirst()).allSatisfy { ($0.logProb ?? 0) >= ($1.logProb ?? 0) }, "best first")
        // logProb is the word's summed logProb with one piece swapped.
        let kotari = try #require(alts.first { $0.text == "kotari" })
        #expect(abs((kotari.logProb ?? 0) - (log(0.3) + log(0.6))) < 1e-4)
        #expect(WordAlternates.alternates(for: [Self.tok(1, "\u{2581}hi", p: 0.9, at: 0)]).isEmpty)
        let noise = [Self.tok(1, "\u{2581}hi", p: 0.9, at: 0, alts: [(2, "\u{2581}ho", 0.0005)])]
        #expect(WordAlternates.alternates(for: noise).isEmpty, "below the logProb floor")
    }

    @Test func jointCandidatesBecomeFullVocabularyLogProbs() throws {
        let vocab = [10: "\u{2581}the", 11: "\u{2581}a", 12: "\u{2581}this", 13: "\u{2581}that"]
        let pairs: [(Int, Float)] = [(11, 6.0), (10, 8.0), (8192, 7.0), (12, 5.0), (99, 4.9), (13, 3.0)]
        let c = JointTopKReplayer.candidates(pairs: pairs, argmaxProbability: 0.7, chosen: 10, blankId: 8192,
                                             vocabulary: vocab, k: 2)
        #expect(c.map(\.tokenId) == [11, 12], "chosen, blank and out-of-vocab ids dropped; best first; at most k")
        let first = try #require(c.first)
        #expect(abs(first.logProb - (log(0.7) + 6 - 8)) < 1e-5)
        #expect(c.allSatisfy { $0.logProb <= log(0.7) })
        #expect(JointTopKReplayer.candidates(pairs: [], argmaxProbability: 1, chosen: 0, blankId: 1, vocabulary: vocab, k: 4).isEmpty)
    }

    @Test func finalPassAttachesAlternativesOnlyWhenUncertain() async {
        let tokens = [Self.tok(1, "\u{2581}send", p: 0.95, at: 1.0), Self.tok(2, "\u{2581}cotari", p: 0.4, at: 1.2)]
        let provider = MockProvider(table: [
            1: [TokenAlternative(tokenId: 1, text: "\u{2581}send", logProb: -1), TokenAlternative(tokenId: 3, text: "\u{2581}sent", logProb: -2)],
            2: [TokenAlternative(tokenId: 4, text: "\u{2581}kothari", logProb: -1.2)],
        ])
        let out = await FluidAudioTDTDecoder.attachAlternatives(tokens, samples: [0, 0], timeOffset: 1.0, provider: provider,
                                                                k: 4, belowProbability: 0.9)
        #expect(out[0].alternatives.map(\.tokenId) == [3], "the chosen token is never its own alternative")
        #expect(out[1].alternatives.map(\.text) == ["\u{2581}kothari"])
        #expect(out.map(\.startTime) == tokens.map(\.startTime))

        let confident = await FluidAudioTDTDecoder.attachAlternatives([tokens[0]], samples: [0], timeOffset: 0, provider: provider,
                                                                      k: 4, belowProbability: 0.9)
        #expect(confident[0].alternatives.isEmpty, "confident utterances skip the replay")
        let failed = await FluidAudioTDTDecoder.attachAlternatives(tokens, samples: [0], timeOffset: 0, provider: FailingProvider(),
                                                                   k: 4, belowProbability: 0.9)
        #expect(failed == tokens, "a provider failure never blocks the transcript")

        // Spans built from the tokens carry the word alternates with logProbs.
        let spans = WordConfidence.spans(from: out)
        #expect(spans[1].alternates.map(\.text) == ["kothari"])
        #expect(spans[1].alternates.first?.logProb != nil && spans[1].alternates.first?.text != spans[1].text)
    }

    @Test func boostKeepsAlternativesOfUnchangedTokens() {
        let before = [Self.tok(1, "\u{2581}use", p: 0.5, at: 0, alts: [(5, "\u{2581}used", 0.2)]),
                      Self.tok(2, "\u{2581}stores", p: 0.4, at: 0.4, alts: [(6, "\u{2581}store", 0.3)])]
        let after = [Self.tok(1, "\u{2581}use", p: 0.5, at: 0), Self.tok(77, "\u{2581}Postgres", p: 0.4, at: 0.4)]
        let carried = FluidAudioTDTDecoder.carryAlternatives(from: before, to: after)
        #expect(carried[0].alternatives.map(\.tokenId) == [5])
        #expect(carried[1].alternatives.isEmpty, "a swapped-in token does not inherit the replaced piece's candidates")
    }

    @Test func decodedTokenCodableStaysBackwardCompatible() throws {
        let old = #"{"tokenId":3,"text":"▁hi","logProb":-0.1,"startTime":0,"endTime":0.08}"#
        let t = try JSONDecoder().decode(DecodedToken.self, from: Data(old.utf8))
        #expect(t.alternatives.isEmpty && t.tokenId == 3)
        let rich = Self.tok(1, "\u{2581}a", p: 0.5, at: 0, alts: [(2, "\u{2581}the", 0.2)])
        #expect(try JSONDecoder().decode(DecodedToken.self, from: JSONEncoder().encode(rich)) == rich)
        let alt = try JSONDecoder().decode(Alternate.self, from: Data(#"{"text":"x","score":0.5,"source":"beam"}"#.utf8))
        #expect(alt.logProb == nil)
    }

    @Test func enricherAddsDictionaryVariantsSecondNotFirst() {
        let enricher = AlternateEnricher(biasVocabulary: ["Kothari"], userDictionary: ["Kotari Labs"], limit: 5)
        let real = [Alternate(text: "katari", score: 0.05, source: .beam, logProb: log(0.05)),
                    Alternate(text: "cotary", score: 0.02, source: .beam, logProb: log(0.02))]
        let span = TranscriptSpan(text: "cotari", confidence: 0.3, audioRange: 0...1, alternates: real)
        let out = enricher.enrich(span).alternates
        #expect(Array(out.prefix(2)) == real, "real candidates keep their place and order")
        #expect(out.dropFirst(2).contains { $0.text == "Kothari" && $0.source == .biasing })

        // Real candidates filling the list still leave the last slot to the best dictionary variant.
        let full = (0..<4).map { Alternate(text: "alt\($0)", score: 0.01, source: .beam, logProb: -4) }
        let small = AlternateEnricher(biasVocabulary: ["Kothari"], limit: 4)
        let merged = small.merge(existing: full, generated: small.candidates(for: "cotari"))
        #expect(merged.count == 4 && Array(merged.prefix(3)) == Array(full.prefix(3)) && merged.last?.text == "Kothari")
    }
}

/// V5 B3 on the real model: the joint replay over Parakeet TDT v3 gives alternates that differ from
/// the top hypothesis and carry logProbs. Skipped unless v3 is on disk.
@Suite("Real N-best alternates (V5 B3, real model)", .serialized)
struct NBestAlternatesLiveTests {
    @Test(.timeLimit(.minutes(10)))
    func v3JointReplayFillsAlternates() async throws {
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetTDTv3) else { print("SKIPPED: parakeet-tdt-0.6b-v3 not on disk."); return }
        let fixtures = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/entity")
        let models = try #require(try await manager.load(.parakeetTDTv3).asrModels)
        let decoder = try await FluidAudioTDTDecoder(models: models, name: "fluidaudio.tdt.v3")
        #expect(decoder.alternativesProvider != nil, "v3's JointDecisionv3 exposes top-K")
        decoder.alternativesBelowProbability = 1.01   // force the replay so every utterance is checked
        let recognizer = DecoderFinalRecognizer(decoder: decoder)
        let plain = DecoderFinalRecognizer(decoder: try await FluidAudioTDTDecoder(models: models, alternatives: false))
        var spansWithAlts = 0, total = 0, replayMs = 0.0, plainMs = 0.0
        for file in ["entity_02_daniel.wav", "entity_06_rishi.wav", "entity_07_samantha.wav"] {
            let samples = try SampleAudioSource.load16k(url: fixtures.appendingPathComponent(file))
            let tp = Date()
            let base = try await plain.recognize(samples)
            plainMs += Date().timeIntervalSince(tp) * 1000
            let t0 = Date()
            let spans = try await recognizer.recognize(samples)
            replayMs += Date().timeIntervalSince(t0) * 1000
            #expect(spans.map(\.text) == base.map(\.text), "alternates never change the transcript")
            for s in spans {
                total += 1
                guard !s.alternates.isEmpty else { continue }
                spansWithAlts += 1
                for a in s.alternates {
                    #expect(WordConfusionNetwork.normalize(a.text) != WordConfusionNetwork.normalize(s.text))
                    let lp = try #require(a.logProb)
                    #expect(lp <= 0 && lp >= WordAlternates.defaultMinLogProb)
                }
            }
            let low = spans.sorted { $0.confidence < $1.confidence }.prefix(3)
            print("B3 \(file): \(spans.map(\.text).joined(separator: " "))")
            for s in low { print("  \(s.text) (\(String(format: "%.2f", s.confidence))) → \(s.alternates.map { "\($0.text) \(String(format: "%.2f", $0.logProb ?? 0))" })") }
        }
        print("B3 spans with alternates: \(spansWithAlts)/\(total); final pass \(Int(plainMs)) ms plain vs \(Int(replayMs)) ms with replay")
        #expect(spansWithAlts > 0)
    }
}
