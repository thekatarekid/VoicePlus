import Foundation
import Shared
import Testing
@testable import Pipeline

/// V5 K8 — pause / pitch punctuation, its F1 metric and the gate.
@Suite struct ProsodyPunctuationTests {
    /// Words with explicit gaps: `("word", gapAfter)`.
    static func spans(_ words: [(String, Double)], confidence: Float = 0.9) -> [TranscriptSpan] {
        var t = 0.0
        return words.map { w, gap in
            let s = TranscriptSpan(text: w, confidence: confidence, audioRange: t...(t + 0.3), provenance: [.asr])
            t += 0.3 + gap
            return s
        }
    }

    static let on = StageContext(register: .prose, flags: [ProsodyPunctuationStage.flag.id: true])

    static func text(_ s: [TranscriptSpan]) -> String { s.map(\.text).joined(separator: " ") }

    @Test func longPauseIsASentenceShortPauseIsAComma() async throws {
        let input = Self.spans([("so", 0.05), ("I", 0.05), ("went", 0.05), ("home", 0.8), ("then", 0.05), ("after", 0.05),
                                ("lunch", 0.35), ("we", 0.05), ("talked", 0.05), ("more", 0)])
        let out = try await ProsodyPunctuationStage().process(input, context: Self.on)
        #expect(Self.text(out) == "so I went home. Then after lunch, we talked more")
        #expect(out[3].punctuationOrigin == .stage && out[6].punctuationOrigin == .stage)
        #expect(out.allSatisfy { $0.provenance.last == ProsodyPunctuationStage.stageID })
        #expect(out.map(\.audioRange) == input.map(\.audioRange) && out.map(\.confidence) == input.map(\.confidence))
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
    }

    @Test func modelPunctuationAndSpokenPunctuationWin() async throws {
        var input = Self.spans([("well,", 0.9), ("that's", 0.05), ("it", 0.7), ("okay", 0)])
        input[2].punctuationOrigin = .spoken
        let out = try await ProsodyPunctuationStage().process(input, context: Self.on)
        #expect(Self.text(out) == "well, that's it okay", "the model's comma stands over a long pause; a spoken-origin span is untouched")
    }

    @Test func lowConfidenceWordsAreNotRewritten() async throws {
        let input = Self.spans([("one", 0.05), ("two", 0.9), ("three", 0)], confidence: 0.3)
        let out = try await ProsodyPunctuationStage().process(input, context: Self.on)
        #expect(Self.text(out) == "one two three")
    }

    @Test func offByDefaultAndNeverInCode() async throws {
        let input = Self.spans([("let", 0.05), ("x", 0.9), ("equal", 0)])
        let off = try await ProsodyPunctuationStage().process(input, context: StageContext(register: .prose))
        #expect(Self.text(off) == "let x equal")
        let code = try await ProsodyPunctuationStage().process(
            input, context: StageContext(register: .code, flags: [ProsodyPunctuationStage.flag.id: true]))
        #expect(Self.text(code) == "let x equal")
    }

    @Test func noCommaChainsOrCommaBeforeTheLastWord() async throws {
        let input = Self.spans([("yes", 0.3), ("ok", 0.3), ("fine", 0)])
        let out = try await ProsodyPunctuationStage().process(input, context: Self.on)
        #expect(Self.text(out) == "yes ok fine")
    }

    // MARK: phase 2

    @Test func risingEndWithACueBecomesAQuestion() async throws {
        let input = Self.spans([("are", 0.05), ("you", 0.05), ("coming.", 0.8), ("we", 0.05), ("leave", 0.05), ("at", 0.05), ("six", 0)])
        var ctx = Self.on
        ctx.extra[ProsodyCues.extraKey] = ProsodyCues(risingEnds: [input[2].audioRange.upperBound, input[6].audioRange.upperBound]).encoded
        let out = try await ProsodyPunctuationStage().process(input, context: ctx)
        #expect(Self.text(out) == "are you coming? We leave at six", "rise + cue → ?; rise without a cue stays a statement")
    }

    @Test func cueWithoutARiseStaysAStatement() async throws {
        let input = Self.spans([("is", 0.05), ("it", 0.05), ("ready", 0)])
        var ctx = Self.on
        ctx.extra[ProsodyCues.extraKey] = ProsodyCues(risingEnds: []).encoded
        #expect(Self.text(try await ProsodyPunctuationStage().process(input, context: ctx)) == "is it ready")
        ctx.extra[ProsodyCues.extraKey] = ProsodyCues(risingEnds: [input[2].audioRange.upperBound]).encoded
        #expect(Self.text(try await ProsodyPunctuationStage().process(input, context: ctx)) == "is it ready?")
    }

    @Test func lexicalCues() {
        #expect(ProsodyPunctuationStage.isQuestion(["What", "time"]))
        #expect(ProsodyPunctuationStage.isQuestion(["Don't", "you", "think"]))
        #expect(ProsodyPunctuationStage.isQuestion(["we", "ship", "today,", "right"]))
        #expect(!ProsodyPunctuationStage.isQuestion(["we", "ship", "today"]))
    }

    static func tone(_ f0: (Double) -> Double, seconds: Double, rate: Double = 16_000) -> [Float] {
        var phase = 0.0
        return (0..<Int(seconds * rate)).map { i in
            phase += 2 * .pi * f0(Double(i) / rate) / rate
            return Float(0.3 * sin(phase) + 0.15 * sin(2 * phase))
        }
    }

    @Test func pitchTrackerFindsF0AndTheTerminalRise() throws {
        let flat = Self.tone({ _ in 150 }, seconds: 0.5)
        let f0 = PitchTracker.track(flat).compactMap { $0 }
        #expect(!f0.isEmpty)
        let median = try #require(PitchTracker.median(f0))
        #expect(abs(median - 150) < 3)
        #expect(abs(try #require(PitchTracker.terminalSlope(flat))) < 0.5)
        let rising = Self.tone({ t in t < 0.2 ? 150 : 150 + (t - 0.2) * 400 }, seconds: 0.4)
        #expect(try #require(PitchTracker.terminalSlope(rising)) >= ProsodyCues.riseSemitones)
        let falling = Self.tone({ t in t < 0.2 ? 200 : 200 - (t - 0.2) * 300 }, seconds: 0.4)
        #expect(try #require(PitchTracker.terminalSlope(falling)) < 0)
        #expect(PitchTracker.terminalSlope([Float](repeating: 0, count: 6400)) == nil, "silence has no pitch")
    }

    @Test func cuesFromAudio() {
        // "is it ready" then a pause then "yes": the first sentence rises, the second falls.
        let rate = 16_000.0
        var audio = Self.tone({ t in t < 0.6 ? 140 : 140 + (t - 0.6) * 300 }, seconds: 0.9)
        audio += [Float](repeating: 0, count: Int(0.8 * rate))
        audio += Self.tone({ t in 180 - t * 120 }, seconds: 0.5)
        let words: [(text: String, range: ClosedRange<TimeInterval>)] = [
            ("is", 0...0.3), ("it", 0.3...0.6), ("ready", 0.6...0.9), ("yes", 1.7...2.2),
        ]
        let cues = ProsodyCues.analyze(samples: audio, sampleRate: rate, spans: words)
        #expect(cues.rises(at: 0.9) && !cues.rises(at: 2.2))
        #expect(ProsodyCues(encoded: cues.encoded) == cues)
    }

    // MARK: metric + gate

    @Test func punctuationF1AndGate() {
        let ref = "So I went home. Then, after lunch, we talked. Are you coming?"
        let base = PunctuationF1.score(reference: ref, hypothesis: "so I went home then after lunch we talked are you coming")
        #expect(base.tp == 0 && base.fn == 4)
        let cand = PunctuationF1.score(reference: ref, hypothesis: "so I went home. Then after lunch, we talked. Are you coming?")
        #expect(cand.tp == 3 && cand.fp == 0 && cand.fn == 1)
        let wordsSame = PunctuationF1.words(ref) == PunctuationF1.words("so I went home. Then after lunch, we talked. Are you coming?")
        #expect(wordsSame)
        #expect(PunctuationF1.gatePasses(baseline: base, candidate: cand, wordsUnchanged: wordsSame))
        #expect(!PunctuationF1.gatePasses(baseline: cand, candidate: base, wordsUnchanged: true))
        #expect(!PunctuationF1.gatePasses(baseline: base, candidate: cand, wordsUnchanged: false))
    }

    @Test func theStageNeverChangesTheWords() async throws {
        let input = Self.spans([("so", 0.05), ("I", 0.05), ("went", 0.05), ("home", 0.8), ("then", 0.3), ("we", 0.05), ("talked", 0)])
        let out = try await ProsodyPunctuationStage().process(input, context: Self.on)
        #expect(PunctuationF1.words(Self.text(out)) == PunctuationF1.words(Self.text(input)), "WER unchanged by construction")
    }

    @Test func registeredBeforeTheFormatters() {
        let ids = StageRegistry.allStages().map(\.id)
        let k8 = try? #require(ids.firstIndex(of: ProsodyPunctuationStage.stageID))
        let prose = ids.firstIndex(of: .formatterProse)
        #expect(k8 != nil && prose != nil && k8! < prose!)
    }
}
