import Foundation
import Testing
import Shared
@testable import Engine

/// C2 (V4.22) — the hallucination guard's rule table, as a pure function.
@Suite("C2 hallucination guard")
struct HallucinationGuardTests {
    struct Row: CustomTestStringConvertible, Sendable {
        let text: String
        let speechRatio: Double
        let speechSeconds: Double
        let meanConfidence: Double
        let expected: HallucinationGuard.Verdict
        var testDescription: String { "\"\(text)\" ratio \(speechRatio) speech \(speechSeconds)s conf \(meanConfidence)" }
    }

    static let table: [Row] = [
        // The row the spec names: a real "Thank you." with plenty of speech stays.
        Row(text: "Thank you.", speechRatio: 0.6, speechSeconds: 1.2, meanConfidence: 0.9, expected: .keep),
        // Filler rule: text is a known room-tone closer and speech ratio is under 20 %.
        Row(text: "Thank you.", speechRatio: 0.1, speechSeconds: 0.3, meanConfidence: 0.9, expected: .drop(.fillerWithoutSpeech)),
        Row(text: "you", speechRatio: 0.05, speechSeconds: 0.3, meanConfidence: 0.8, expected: .drop(.fillerWithoutSpeech)),
        Row(text: "Thanks for watching!", speechRatio: 0.15, speechSeconds: 0.5, meanConfidence: 0.9, expected: .drop(.fillerWithoutSpeech)),
        Row(text: "Bye.", speechRatio: 0.19, speechSeconds: 0.4, meanConfidence: 0.9, expected: .drop(.fillerWithoutSpeech)),
        Row(text: "The End", speechRatio: 0, speechSeconds: 0, meanConfidence: 0.9, expected: .drop(.fillerWithoutSpeech)),
        Row(text: "Subtitles by", speechRatio: 0.1, speechSeconds: 0.5, meanConfidence: 0.9, expected: .drop(.fillerWithoutSpeech)),
        Row(text: "Okay.", speechRatio: 0.1, speechSeconds: 0.4, meanConfidence: 0.9, expected: .drop(.fillerWithoutSpeech)),
        // Boundary: 20 % is not *under* 20 %.
        Row(text: "Bye.", speechRatio: 0.2, speechSeconds: 0.4, meanConfidence: 0.9, expected: .keep),
        // Membership is the whole text, not a prefix.
        Row(text: "Okay, send it", speechRatio: 0.1, speechSeconds: 1.2, meanConfidence: 0.9, expected: .keep),
        Row(text: "Thank you for the update", speechRatio: 0.1, speechSeconds: 1.5, meanConfidence: 0.9, expected: .keep),
        // Repetition rule: one token four or more times in a row, whatever the speech.
        Row(text: "the the the the", speechRatio: 0.9, speechSeconds: 3, meanConfidence: 0.9, expected: .drop(.repeatedToken)),
        Row(text: "No, no. No! NO", speechRatio: 0.9, speechSeconds: 2, meanConfidence: 0.9, expected: .drop(.repeatedToken)),
        Row(text: "I said no no no no way", speechRatio: 0.9, speechSeconds: 2, meanConfidence: 0.9, expected: .drop(.repeatedToken)),
        Row(text: "no no no", speechRatio: 0.9, speechSeconds: 2, meanConfidence: 0.9, expected: .keep),
        Row(text: "go go go stop go", speechRatio: 0.9, speechSeconds: 2, meanConfidence: 0.9, expected: .keep),
        // Filler rule wins over repetition when both match; the verdict names the first rule.
        Row(text: "you", speechRatio: 0.0, speechSeconds: 0.0, meanConfidence: 0.1, expected: .drop(.fillerWithoutSpeech)),
        // Confidence rule: mean < 0.3 with under a second of speech.
        Row(text: "send the report", speechRatio: 0.5, speechSeconds: 0.5, meanConfidence: 0.2, expected: .drop(.lowConfidenceShortSpeech)),
        Row(text: "send the report", speechRatio: 0.5, speechSeconds: 1.0, meanConfidence: 0.2, expected: .keep),
        Row(text: "send the report", speechRatio: 0.5, speechSeconds: 0.5, meanConfidence: 0.3, expected: .keep),
        // Nothing to drop.
        Row(text: "", speechRatio: 0, speechSeconds: 0, meanConfidence: 0, expected: .keep),
        Row(text: " . ", speechRatio: 0, speechSeconds: 0, meanConfidence: 0, expected: .keep),
    ]

    @Test("verdict table", arguments: table)
    func verdictTable(_ row: Row) {
        let verdict = HallucinationGuard.verdict(
            text: row.text, speechRatio: row.speechRatio, speechSeconds: row.speechSeconds,
            meanConfidence: row.meanConfidence, tokens: HallucinationGuard.tokens(of: row.text))
        #expect(verdict == row.expected)
    }

    @Test func tableIsAtLeastTwelveRowsAndCoversEveryRule() {
        #expect(Self.table.count >= 12)
        let reasons = Set(Self.table.compactMap(\.expected.reason))
        #expect(reasons == Set(HallucinationGuard.Reason.allCases))
        #expect(Self.table.contains { $0.expected == .keep })
    }

    @Test func fillerSetIsTheSpecifiedOne() {
        #expect(HallucinationGuard.fillerPhrases == [
            "you", "thank you", "thanks for watching", "bye", "the end", "subtitles by", "okay",
        ])
    }

    @Test func normalizationFoldsCaseAndPunctuation() {
        #expect(HallucinationGuard.normalize("Thank you.") == "thank you")
        #expect(HallucinationGuard.normalize("  THANKS  for\twatching!! ") == "thanks for watching")
        #expect(HallucinationGuard.normalize("Bye-bye") == "bye bye")
        #expect(HallucinationGuard.normalize("It\u{2019}s 5 o'clock.") == "it's 5 o'clock")
        #expect(HallucinationGuard.normalize("…") == "")
    }

    @Test func longestRunSkipsBarePunctuation() {
        #expect(HallucinationGuard.longestRun(of: ["the", "—", "the", "The.", "THE"]) == 4)
        #expect(HallucinationGuard.longestRun(of: ["a", "b", "a", "b"]) == 1)
        #expect(HallucinationGuard.longestRun(of: []) == 0)
    }

    private func span(_ text: String, _ confidence: Float, refined: Bool = false) -> TranscriptSpan {
        TranscriptSpan(text: text, confidence: confidence, audioRange: 0...1,
                       provenance: refined ? [.asr, .refineQwen3] : [.asr])
    }

    /// Refinement reports no confidence (`Refinement.confidenceNotReported` = 0); counting it
    /// would drop every short refined segment.
    @Test func meanConfidenceIgnoresRefinedAndEmptySpans() {
        #expect(abs(HallucinationGuard.meanConfidence(of: [span("a", 0.8), span("b", 0.4)]) - 0.6) < 1e-6)
        #expect(HallucinationGuard.meanConfidence(of: [span("pass2", 0, refined: true)]) == 1)
        #expect(HallucinationGuard.meanConfidence(of: [span(" ", 0), span("x", 0.9)]) > 0.89)
        #expect(HallucinationGuard.meanConfidence(of: []) == 1)
    }

    /// Without a VAD the speech ratio is unknown, so the filler rule cannot fire on a guess; the
    /// confidence rule still can, because speech can never exceed the audio.
    @Test func spanVerdictWithoutVADNeverGuessesSpeech() {
        let thanks = [span("Thank", 0.9), span("you.", 0.9)]
        #expect(HallucinationGuard.verdict(for: thanks, speechSeconds: nil, audioSeconds: 2) == .keep)
        #expect(HallucinationGuard.verdict(for: thanks, speechSeconds: 0.2, audioSeconds: 2) == .drop(.fillerWithoutSpeech))
        #expect(HallucinationGuard.verdict(for: thanks, speechSeconds: 1.4, audioSeconds: 2) == .keep)
        let mumble = [span("send", 0.1), span("it", 0.2)]
        #expect(HallucinationGuard.verdict(for: mumble, speechSeconds: nil, audioSeconds: 0.8) == .drop(.lowConfidenceShortSpeech))
        #expect(HallucinationGuard.verdict(for: mumble, speechSeconds: nil, audioSeconds: 1.5) == .keep)
    }

    @Test func diagnosticsCountPerRuleAndBoundTheirMemory() {
        let d = EngineDiagnostics()
        for i in 0..<(EngineDiagnostics.recentLimit + 5) {
            d.record(.init(stamp: "s\(i)", segment: nil, kind: i.isMultiple(of: 2) ? .noSpeech : .hallucination(.repeatedToken),
                           speechSeconds: nil, audioSeconds: 1, tokenCount: 0))
        }
        #expect(d.noSpeechSkips == 28)
        #expect(d.hallucinationDrops == 27)
        #expect(d.hallucinationDrops(.repeatedToken) == 27)
        #expect(d.hallucinationDrops(.fillerWithoutSpeech) == 0)
        #expect(d.recentDrops.count == EngineDiagnostics.recentLimit)
        #expect(d.recentDrops.last?.stamp == "s54")
    }

    @Test func stopReasonMapsGuardOutcomesToA06() {
        #expect(EngineStopReason.noSpeech.recoveryID == "A06")
        #expect(EngineStopReason.hallucination(.fillerWithoutSpeech).recoveryID == "A06")
        #expect(EngineStopReason.decoded.recoveryID == nil)
        #expect(EngineStopReason.tooShort.recoveryID == nil)
        #expect(EngineStopReason.noSpeech.isQuietReturn)
        #expect(EngineStopReason.quietReturnFade == 1.2)
    }
}
