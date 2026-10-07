import Foundation
import Shared
import Testing
@testable import Engine

private func tk(_ id: Int, _ text: String, p: Float = 0.9, _ s: Double, _ e: Double) -> DecodedToken {
    DecodedToken(tokenId: id, text: text, logProb: log(p), startTime: s, endTime: e)
}

/// V5 B1 — model-free parts of CTC vocabulary boosting: the token re-alignment, the boost list,
/// the two-pass split (preview never boosted) and the catalog entry.
@Suite("Vocabulary boosting (V5 B1)")
struct VocabularyBoostingB1Tests {
    // "mister kotari will join" — "kotari" is two sub-word tokens.
    static let tokens = [tk(1, "▁mister", 0.0, 0.3), tk(2, "▁kot", p: 0.5, 0.3, 0.5), tk(3, "ari", p: 0.6, 0.5, 0.7),
                         tk(4, "▁will", 0.7, 0.9), tk(5, "▁join", 0.9, 1.2)]

    // MARK: alignment

    @Test func identicalTextKeepsTokensBitForBit() {
        #expect(BoostAlignment.apply(rescoredText: "mister kotari will join", to: Self.tokens) == Self.tokens)
    }

    @Test func aReplacedWordSpansTheAudioOfTheWordItReplaced() {
        let out = BoostAlignment.apply(rescoredText: "mister Kothari will join", to: Self.tokens)
        #expect(out.renderedText == "mister Kothari will join")
        #expect(out[0] == Self.tokens[0] && out[2] == Self.tokens[3] && out[3] == Self.tokens[4], "untouched words keep their tokens")
        let k = out[1]
        #expect(k.tokenId == BoostAlignment.replacementTokenId)
        #expect(k.startTime == 0.3 && k.endTime == 0.7)
        #expect(abs(k.logProb - log(Float(0.5))) < 1e-6, "N11: lowest of the replaced tokens")
        #expect(k.logProb <= 0)
    }

    @Test func multiWordTermsSplitTheReplacedSpan() {
        let toks = [tk(1, "▁sunder", p: 0.4, 0, 0.4), tk(2, "▁pitch", p: 0.5, 0.4, 0.6), tk(3, "ai", p: 0.5, 0.6, 0.8), tk(4, "▁spoke", 0.9, 1.1)]
        let out = BoostAlignment.apply(rescoredText: "Sundar Pichai spoke", to: toks)
        #expect(out.renderedText == "Sundar Pichai spoke")
        #expect(out.count == 3)
        #expect(out[0].startTime == 0 && abs(out[1].endTime - 0.8) < 1e-9 && out[2] == toks[3])
        #expect(out.map(\.startTime) == out.map(\.startTime).sorted(), "time order preserved")
    }

    @Test func aMergeOfTwoWordsIntoOneTermIsOneToken() {
        let toks = [tk(1, "▁team", p: 0.5, 0, 0.3), tk(2, "▁viewer", p: 0.6, 0.3, 0.6), tk(3, "▁reported", 0.6, 1.0)]
        let out = BoostAlignment.apply(rescoredText: "TeamViewer reported", to: toks)
        #expect(out.renderedText == "TeamViewer reported")
        #expect(out.count == 2 && out[0].startTime == 0 && out[0].endTime == 0.6)
    }

    @Test func spansStillCarryConfidenceAndAudioRangeAfterBoosting() {
        let out = BoostAlignment.apply(rescoredText: "mister Kothari will join", to: Self.tokens)
        let spans = WordConfidence.spans(from: out)
        #expect(spans.map(\.text) == ["mister", "Kothari", "will", "join"])
        #expect(spans.allSatisfy { $0.provenance == [.asr] && $0.audioRange.upperBound > $0.audioRange.lowerBound })
        #expect(abs(spans[1].confidence - 0.5) < 1e-4)
    }

    // MARK: the false-insertion guard

    @Test func guardRejectsAnOrdinaryWordSwappedForAnUnspokenTerm() {
        #expect(!BoostGuard.accepts(original: "stores", replacement: "Postgres"))
        #expect(!BoostGuard.accepts(original: "the", replacement: "Zephyr"))
        #expect(!BoostGuard.accepts(original: "store", replacement: "Shopify"))
        #expect(!BoostGuard.accepts(original: "", replacement: "Grafana"))
    }

    @Test func guardKeepsRealMishearingsOfTheTerm() {
        #expect(BoostGuard.accepts(original: "Sklite", replacement: "SQLite"))
        #expect(BoostGuard.accepts(original: "cubectel", replacement: "kubectl"))
        #expect(BoostGuard.accepts(original: "Team viewer", replacement: "TeamViewer"))
        #expect(BoostGuard.accepts(original: "Fluid Audio", replacement: "FluidAudio"))
        #expect(BoostGuard.accepts(original: "Sundar Pichi", replacement: "Sundar Pichai"))
        #expect(BoostGuard.accepts(original: "kotari", replacement: "Kothari"))
    }

    @Test func aRejectedRunKeepsItsOriginalTokensAndTheRestIsApplied() {
        let toks = [tk(1, "▁the", 0, 0.2), tk(2, "▁app", 0.2, 0.4), tk(3, "▁stores", 0.4, 0.8),
                    tk(4, "▁data", 0.8, 1.0), tk(5, "▁in", 1.0, 1.1), tk(6, "▁sk", p: 0.4, 1.1, 1.3), tk(7, "lite", p: 0.5, 1.3, 1.6)]
        let out = BoostAlignment.apply(rescoredText: "the app Postgres data in SQLite", to: toks,
                                       accept: BoostGuard.accepts(original:replacement:))
        #expect(out.renderedText == "the app stores data in SQLite")
        #expect(out[2] == toks[2], "rejected swap keeps the TDT token bit-for-bit")
        #expect(out.last?.tokenId == BoostAlignment.replacementTokenId)
    }

    // MARK: the boost list

    @Test func listIsDictionaryThenCorrectionEntitiesThenAuthoredTierOnly() {
        let ranked = ContextRanker().rank([
            ContextEntry(text: "Zephyr", source: .axTree),          // screen — never boosted
            ContextEntry(text: "Grafana", source: .recentWords),    // recent — never boosted
            ContextEntry(text: "a16z", source: .dictionary),        // authored, has a spoken form
            ContextEntry(text: "tomorrow", source: .corrections),   // authored but plain word — dropped
            ContextEntry(text: "Priya", source: .corrections),      // authored entity
        ])
        // Context Writer scope-down: a Dictionary term boosts only with a spoken form (typed or
        // verbalized), so "gpt-4o" / "TeamViewer AG" stay and a plain name would not (BoostScopeTests).
        let list = BoostVocabulary.build(dictionary: ["gpt-4o", "GPT-4o", "TeamViewer AG", "ok"],
                                         corrections: ["send it to Sundar tomorrow"], context: ranked)
        #expect(Array(list.prefix(3)) == ["gpt-4o", "TeamViewer AG", "Sundar"])
        #expect(Set(list.dropFirst(3)) == ["a16z", "Priya"])
        #expect(!list.contains("Zephyr") && !list.contains("Grafana") && !list.contains("tomorrow"))
    }

    @Test func listIsCappedAt100() {
        let many = (0..<1_000).map { "Term\($0)" }
        let list = BoostVocabulary.build(dictionary: many, corrections: [])
        #expect(list.count == 100 && BoostVocabulary.cap == 100, "Context Writer scope-down: cap 100")
        #expect(list.first == "Term0")
    }

    @Test func emptyInputsGiveNoBooster() {
        let c = BoostingController(makeBooster: { ScriptedVocabularyBooster(terms: $0, rewrites: [:]) })
        #expect(c.makeBoosterForUtterance() == nil)
        #expect(c.lastTerms.isEmpty)
    }

    // MARK: final pass boosted, preview not

    /// A decoder with both passes, scripted.
    final class TwoPassDecoder: Decoder, VocabularyBoostable, PreviewDecoding, @unchecked Sendable {
        let name = "two-pass"
        var biaser: LogitBiaser?
        var booster: VocabularyBooster?
        let script: [DecodedToken]
        init(_ script: [DecodedToken]) { self.script = script }
        func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult {
            guard let booster, let o = await booster.boost(tokens: script, samples: encoderFrames.values) else {
                return DecodeResult(tokens: script)
            }
            return DecodeResult(tokens: o.tokens)
        }
        func decodePreview(encoderFrames: EncoderFrames) async throws -> DecodeResult { DecodeResult(tokens: script) }
        func reset() async {}
    }

    @Test func finalPassIsBoostedAndThePollingPreviewIsNot() async throws {
        let decoder = TwoPassDecoder(Self.tokens)
        let final = DecoderFinalRecognizer(decoder: decoder)
        #expect(final.installBooster(ScriptedVocabularyBooster(terms: ["Kothari"], rewrites: ["kotari": "Kothari"])))
        let samples = [Float](repeating: 0, count: 16_000)
        #expect(try await final.recognize(samples).joinedText == "mister Kothari will join")
        #expect(try await final.recognizePreview(samples).joinedText == "mister kotari will join")

        let preview = PollingPreviewRecognizer(recognizer: final, interval: 0.5)
        #expect(try await preview.feed(samples) == "mister kotari will join", "the pill never shows an unconfirmed boost")
    }

    @Test func boosterOnlyRewritesTermsInItsVocabulary() async {
        let none = ScriptedVocabularyBooster(terms: [], rewrites: ["kotari": "Kothari"])
        #expect(await none.boost(tokens: Self.tokens, samples: []) == nil)
    }

    @Test func mockDecoderAppliesTheBoosterAndIgnoresTheLegacyBiaser() async throws {
        let d = MockDecoder(script: Self.tokens)
        d.booster = ScriptedVocabularyBooster(terms: ["Kothari"], rewrites: ["kotari": "Kothari"])
        let r = try await d.decode(encoderFrames: EncoderFrames(values: [], frameCount: 100, hiddenSize: 0))
        #expect(r.text == "mister Kothari will join")
    }

    // MARK: catalog

    @Test func ctcModelIsAnOnDemandCatalogEntry() {
        let d = ModelCatalog.descriptor(.parakeetCTC110m)
        #expect(d.hfRepo == "FluidInference/parakeet-ctc-110m-coreml")
        #expect(d.requiredPaths.contains("AudioEncoder.mlmodelc"))
        #expect(Set(CTCBoostingRuntime.requiredFiles).isSubset(of: Set(d.requiredPaths)))
        #expect(d.role == .onDemand)
        #expect(!ModelStack.models.contains(.parakeetCTC110m), "never part of the first-run stack")
        #expect(!ModelCatalog.userVisible(qwenRefinementEnabled: true).contains(.parakeetCTC110m))
        #expect(!BundledModel.finalModelsByQuality.contains(.parakeetCTC110m), "a keyword spotter, not a transcriber")
        #expect(d.folderName == ModelCatalog.fluidAudioFolderName(for: .parakeetCTC110m))
    }

    // MARK: the legacy path is gone

    @Test func legacyBiasingFilesAreDeleted() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for f in ["Engine/Biasing/ShallowFusionBiaser.swift", "Engine/Biasing/NarrowBeamDecoder.swift",
                  "Engine/Biasing/ScriptedLogitDecoder.swift", "Engine/Biasing/ContextRecallProbe.swift"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(f).path), "\(f)")
        }
        #expect(!FeatureFlag.all.map(\.id).contains("contextBiasing"))
    }
}
