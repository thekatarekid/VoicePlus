import Foundation
import Testing
import Shared
@testable import Pipeline

// V5 D3 — each rejection rule, and golden accept cases.

@Suite struct CleanupGuardTests {
    let g = CleanupGuard(entityGuard: nil)

    @Test func lengthRatioOutsideBoundsRejects() {
        #expect(g.check(input: "please send the report to the whole team today", output: "Send.").rejection == .lengthRatio)
        #expect(g.check(input: "hi there", output: "Hi there, how are you doing today my friend").rejection == .lengthRatio)
        #expect(g.check(input: "hello world", output: "").rejection == .lengthRatio)
    }

    @Test func lowWordOverlapRejects() {
        #expect(g.check(input: "the quick brown fox jumps", output: "a fast tan dog leaps up").rejection == .lowWordOverlap)
    }

    @Test func assistantPreambleRejects() {
        for out in ["Sure, meet at five tomorrow.", "Here's the text: meet at five", "Cleaned text: meet at five",
                    "As an AI, meet at five", "Meet at five.\nNote: I fixed the time."] {
            #expect(g.check(input: "meet at five tomorrow", output: out).rejection == .assistantPreamble, "\(out)")
        }
        // The speaker's own "sure" is not a preamble.
        #expect(g.check(input: "sure see you at five", output: "Sure, see you at five.").isAccepted)
    }

    @Test func droppedDictionaryTermRejects() {
        let v = g.check(input: "ask Priyanka about VoicePlus", output: "Ask Priyanka about the app.", dictionary: ["VoicePlus"])
        #expect(v.rejection == .dictionaryTermDropped)
        // A term not in the input cannot be dropped; a re-cased term is still there.
        #expect(g.check(input: "ask Priyanka", output: "Ask Priyanka.", dictionary: ["VoicePlus"]).isAccepted)
        #expect(g.check(input: "ask about voiceplus", output: "Ask about VoicePlus.", dictionary: ["VoicePlus"]).isAccepted)
    }

    @Test func changedLowConfidencePhraseRejects() {
        #expect(g.check(input: "call Kothari now", output: "Call Kotari now.", lockedPhrases: ["Kothari"]).rejection == .lowConfidenceChanged)
        #expect(g.check(input: "call Kothari now", output: "Call Kothari now.", lockedPhrases: ["Kothari"]).isAccepted)
        // Order matters.
        #expect(g.check(input: "A met B today", output: "B met A today.", lockedPhrases: ["A", "B"]).rejection == .lowConfidenceChanged)
    }

    @Test func entityCorrectionRejectsAndLowercasingIsRestored() {
        // P5's EntityGuard over a vocabulary where "kothari" is unknown (a likely entity).
        let vocab = WordVocabulary(words: ["call", "now", "please", "meet", "at", "five"])
        let guarded = CleanupGuard(entityGuard: EntityGuard(vocabulary: vocab, casing: nil))
        #expect(guarded.check(input: "please call Kothari now", output: "Please call Kotari now.").rejection == .entityCorrected)
        #expect(guarded.check(input: "please call Kothari now", output: "Please call kothari now.") == .accepted(text: "Please call Kothari now."))
    }

    @Test func goldenAccepts() {
        let cases: [(String, String)] = [
            ("let's ship it thursday, no, friday", "Let's ship it Friday."),
            ("email me at sam at example dot com", "Email me at sam@example.com"),
            ("thanks for the update. I'll review it tonight.", "thanks for the update. I'll review it tonight."),
            ("they was ready by five", "They were ready by five."),
            ("first buy milk second call mom", "First, buy milk. Second, call mom."),
        ]
        for (i, o) in cases {
            #expect(g.check(input: i, output: o) == .accepted(text: o), "\(i) -> \(o)")
        }
    }

    @Test func markersAreStripped() {
        #expect(g.check(input: "call Kothari now", output: "Call ⟦Kothari⟧ now.", lockedPhrases: ["Kothari"]) == .accepted(text: "Call Kothari now."))
    }
}
