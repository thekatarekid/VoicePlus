import Foundation
import Shared
import Testing
@testable import Pipeline

/// H19 — the context repair stage: only uncertain words, only with near-caret evidence, audio /
/// confidence / provenance kept. The phonetic encoder here is a tiny stub; the real Double Metaphone
/// replay of fixture 135111-082 lives in `TurnSurfaceContextH19Tests` (AppTests).
@Suite struct ContextRepairStageTests {
    /// Stub of Double Metaphone for the words used here (real codes); others: consonant skeleton.
    static let stub: ContextRepairStage.PhoneticEncoder = { w in
        let known = ["whole": "AL", "hold": "HLT", "talk": "TLK", "to": "T", "pile": "PL", "pill": "PL",
                     "hover": "HFR", "hoover": "HFR", "it": "AT", "tomorrow": "TMR", "send": "SNT"]
        let l = w.lowercased().filter(\.isLetter)
        if let k = known[l] { return [k] }
        return [l.uppercased().filter { !"AEIOU".contains($0) }]
    }

    static func spans(_ words: [(String, Float)], alts: [Int: [String]] = [:]) -> [TranscriptSpan] {
        words.enumerated().map { i, w in
            TranscriptSpan(text: w.0, confidence: w.1, audioRange: Double(i)...Double(i) + 0.9,
                           alternates: (alts[i] ?? []).map { Alternate(text: $0, score: 0.3, source: .beam) },
                           provenance: [.asr])
        }
    }

    static func ctx(_ terms: [ContextRepairEvidence.Term]) -> StageContext {
        var c = StageContext()
        ContextRepairEvidence(terms: terms).write(into: &c)
        return c
    }

    static let holdToTalk = ContextRepairEvidence.Term(text: "hold-to-talk", aliases: ["hold to talk"], distance: 20, kind: .entity)

    @Test func noEvidenceIsInert() async throws {
        let s = Self.spans([("whole", 0.3), ("to", 0.9), ("talk.", 0.4)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: StageContext())
        #expect(out.map(\.text) == s.map(\.text))
        #expect(out.allSatisfy { $0.provenance == [.asr, ContextRepairStage.stageID] })
    }

    @Test func uncertainSoundAlikeRunBecomesTheNearCaretTerm() async throws {
        let s = Self.spans([("In", 0.95), ("case", 0.9), ("of", 0.9), ("whole", 0.3), ("to", 0.9), ("talk.", 0.4)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([Self.holdToTalk]))
        #expect(out.map(\.text) == ["In", "case", "of", "hold-to-talk."])
        let m = out[3]
        #expect(m.audioRange == 3.0...5.9)
        #expect(m.confidence == 0.3)
        #expect(m.provenance == [.asr, ContextRepairStage.stageID])
        #expect(m.needsRepair)
        #expect(m.alternates.first == Alternate(text: "whole to talk.", score: 0, source: .repair))
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
    }

    @Test func confidentWordsAreNeverChanged() async throws {
        let s = Self.spans([("whole", 0.9), ("to", 0.9), ("talk", 0.4)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([Self.holdToTalk]))
        #expect(out.map(\.text) == ["whole", "to", "talk"])
    }

    @Test func noUncertainWordNoSwapEvenForAnExactAlias() async throws {
        let s = Self.spans([("hold", 0.9), ("to", 0.9), ("talk", 0.9)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([Self.holdToTalk]))
        #expect(out.map(\.text) == ["hold", "to", "talk"])
    }

    @Test func exactHeardAliasWithAnUncertainWordTakesTheWrittenForm() async throws {
        let s = Self.spans([("hold", 0.3), ("to", 0.9), ("talk", 0.9)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([Self.holdToTalk]))
        #expect(out.map(\.text) == ["hold-to-talk"])
    }

    @Test func topKAlternateIsEvidenceWithoutPhonetics() async throws {
        let s = Self.spans([("ping", 0.9), ("Kotary", 0.2)], alts: [1: ["Kothari"]])
        let term = ContextRepairEvidence.Term(text: "Kothari", distance: 10, kind: .entity)
        let out = try await ContextRepairStage(phonetic: nil).process(s, context: Self.ctx([term]))
        #expect(out.map(\.text) == ["ping", "Kothari"])
        #expect(out[1].needsRepair)
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
    }

    @Test func unrelatedUncertainWordIsLeftAlone() async throws {
        let s = Self.spans([("send", 0.9), ("it", 0.3), ("tomorrow", 0.4)])
        let terms = [Self.holdToTalk, .init(text: "Kubernetes", distance: 5, kind: .entity),
                     .init(text: "hover pill", distance: 30, kind: .phrase)]
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx(terms))
        #expect(out.map(\.text) == ["send", "it", "tomorrow"])
    }

    @Test func farTermsAreIgnored() async throws {
        let s = Self.spans([("whole", 0.3), ("to", 0.9), ("talk", 0.4)])
        var far = Self.holdToTalk; far.distance = 5000
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([far]))
        #expect(out.map(\.text) == ["whole", "to", "talk"])
    }

    @Test func ambiguousRunIsLeftAlone() async throws {
        let s = Self.spans([("ping", 0.9), ("Kotary", 0.2)], alts: [1: ["Kothari", "Kotari"]])
        let terms: [ContextRepairEvidence.Term] = [.init(text: "Kothari", distance: 10, kind: .entity),
                                                   .init(text: "Kotari", distance: 10, kind: .entity)]
        let out = try await ContextRepairStage(phonetic: nil).process(s, context: Self.ctx(terms))
        #expect(out.map(\.text) == ["ping", "Kotary"])
    }

    @Test func runNeverCrossesASentenceBreak() async throws {
        let s = Self.spans([("whole.", 0.3), ("To", 0.9), ("talk", 0.4)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([Self.holdToTalk]))
        #expect(out.map(\.text) == ["whole.", "To", "talk"])
    }

    @Test func phraseNeedsAnAnchorAndChangesOneWordAtMost() async throws {
        let phrase = ContextRepairEvidence.Term(text: "hover pill", distance: 10, kind: .phrase)
        let one = Self.spans([("hover", 0.9), ("pile", 0.3)])
        #expect(try await ContextRepairStage(phonetic: Self.stub).process(one, context: Self.ctx([phrase])).map(\.text) == ["hover pill"])
        let two = Self.spans([("hoover", 0.3), ("pile", 0.3)])
        #expect(try await ContextRepairStage(phonetic: Self.stub).process(two, context: Self.ctx([phrase])).map(\.text) == ["hoover", "pile"])
    }

    @Test func sentenceStartKeepsItsCapital() async throws {
        let s = Self.spans([("Whole", 0.3), ("to", 0.9), ("talk", 0.4), ("works.", 0.9)])
        let out = try await ContextRepairStage(phonetic: Self.stub).process(s, context: Self.ctx([Self.holdToTalk]))
        #expect(out.map(\.text) == ["Hold-to-talk", "works."])
    }

    @Test func evidenceRoundTripsThroughTheStageContext() {
        let e = ContextRepairEvidence(terms: [Self.holdToTalk])
        var c = StageContext()
        e.write(into: &c)
        #expect(ContextRepairEvidence.read(from: c) == e)
        var empty = StageContext()
        ContextRepairEvidence(terms: []).write(into: &empty)
        #expect(empty.extra[ContextRepairEvidence.extraKey] == nil)
    }

    @Test func registeredBeforeEveryFormatter() {
        let ids = StageRegistry.allStages().map(\.id)
        let at = try! #require(ids.firstIndex(of: ContextRepairStage.stageID))
        #expect(at == 1)
    }
}
