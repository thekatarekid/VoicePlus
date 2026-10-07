import Foundation
import Testing
import Shared
@testable import Pipeline
@testable import VoicePlusApp

// Context Writer — the per-change guard with the app's real ear (Double Metaphone) and the system
// word list, on the owner's real failures (replay 2026-10-07). Acoustics are the constraint, not
// spelling; a confident word changes its sound only with context (a screen / vocabulary term or a
// named entity that is not an ordinary word).
@Suite struct WriterGuardAcousticsTests {
    static let g = WriterGuard(phonetic: TurnSurfaceContext.phoneticCodes)

    static func tokens(_ text: String, uncertain: Set<Int> = []) -> [WriterGuard.HeardToken] {
        text.split(separator: " ").enumerated().map { i, w in
            WriterGuard.HeardToken(text: String(w), confidence: uncertain.contains(i) ? 0.3 : 0.9, span: i)
        }
    }

    static func accepted(_ v: WriterGuard.Verdict) -> String? { v.accepted?.text }

    @Test func anUncertainSoundAlikeIsAcceptedWhateverItsSpelling() {
        // "face" and "phase" both read FS; spelling 0.4 refused it before.
        let h = Self.tokens("Till face two.", uncertain: [1])
        #expect(Self.accepted(Self.g.check(heard: h, output: "Till phase two.")) == "Till phase two.")
        #expect(Self.accepted(Self.g.check(heard: h, output: "Till phase 2.")) == "Till phase 2.")
    }

    @Test func aConfidentOrdinaryWordNeedsScreenContextToChangeItsSound() {
        let h = Self.tokens("Till face two.")
        #expect(Self.g.check(heard: h, output: "Till phase two.").accepted?.text != "Till phase two.")
        let withScreen = Self.g.check(heard: h, output: "Till Phase 2.", screenTerms: ["Phase 1", "Phase 2"])
        #expect(Self.accepted(withScreen) == "Till Phase 2.")
        let finish = Self.g.check(heard: Self.tokens("Is Finnish dictation the only way to land the text"),
                                  output: "Is Finish dictation the only way to land the text",
                                  screenTerms: ["Finish dictation", "hands-free"])
        #expect(Self.accepted(finish) == "Is Finish dictation the only way to land the text")
    }

    @Test func aConfidentWordMayBecomeANamedEntityThatSoundsTheSame() {
        let h = Self.tokens("I just downloaded the Queen four B model as well as turned on the polishing mode as well.")
        let v = Self.g.check(heard: h, output: "I just downloaded the Qwen 4B model as well as turned on the polishing mode as well.")
        #expect(Self.accepted(v) == "I just downloaded the Qwen 4B model as well as turned on the polishing mode as well.")
    }

    @Test func aConfidentWordNeverBecomesAnotherOrdinaryWordOrANameThatSoundsDifferent() {
        // "night" → "knight": same sound, but an ordinary word with no context — reverted.
        let night = Self.g.check(heard: Self.tokens("see you tonight at the night market"), output: "see you tonight at the knight market")
        #expect(night.accepted?.text != "see you tonight at the knight market")
        // "Queen" → "Kevin": a name, but it does not sound the same — reverted.
        let kevin = Self.g.check(heard: Self.tokens("ask the Queen about it"), output: "ask the Kevin about it")
        #expect(kevin.accepted?.text != "ask the Kevin about it")
    }

    @Test func lettersAndDigitsAreReadPartByPart() {
        let live = Self.tokens("A sixtien z.", uncertain: [0, 1, 2])
        #expect(Self.accepted(Self.g.check(heard: live, output: "a16z.")) == "a16z.")
        let spelled = Self.tokens("deploy it on k eight s", uncertain: [3, 4, 5])
        #expect(Self.accepted(Self.g.check(heard: spelled, output: "deploy it on k8s")) == "deploy it on k8s")
        // The z is not in the audio of the replayed clip ("A sixti."): nothing justifies it.
        let clipped = Self.tokens("A sixti.", uncertain: [0, 1])
        #expect(Self.g.check(heard: clipped, output: "a16z.").accepted?.text != "a16z.")
    }

    @Test func aFalseStartTheSpeakerRestartsMayGo() {
        // The local model's real reply on the owner's sentence: the restart "turned on" stays.
        let h = Self.tokens("I just downloaded the Queen four B model as well as turned out the turned on the polishing mode as well.", uncertain: [4])
        let v = Self.g.check(heard: h, output: "I just downloaded the Queen four B model as well as turned on the polishing mode as well.")
        #expect(Self.accepted(v) == "I just downloaded the Queen four B model as well as turned on the polishing mode as well.")
        // Not a restart (different first word): dropping content words reverts.
        let drop = Self.g.check(heard: Self.tokens("send the red deck to Priya today"), output: "send the deck to Priya today")
        #expect(drop.accepted?.text != "send the deck to Priya today")
        // A repeated function word is not a restart: "cat and" is content.
        let dog = Self.g.check(heard: Self.tokens("I saw the cat and the dog"), output: "I saw the dog")
        #expect(dog.accepted?.text != "I saw the dog")
    }

    @Test func anAnswerIsStillRejected() {
        let h = Self.tokens("Can you also find out how Google News works?")
        let v = Self.g.check(heard: h, output: "Google News aggregates articles from many publishers using algorithms.")
        #expect(v.accepted == nil || v.accepted?.text == "Can you also find out how Google News works?")
    }
}
