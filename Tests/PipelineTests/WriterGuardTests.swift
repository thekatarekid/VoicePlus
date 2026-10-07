import Foundation
import Shared
import Testing
@testable import Pipeline

// Context Writer — the per-change guard on its own: formatting and number changes pass on any
// word; swaps need an uncertain word plus evidence; new or dropped content words revert their
// region only; an answer, an empty or a runaway output rejects the whole thing.

@Suite struct WriterGuardTests {
    /// Stub of Double Metaphone for the words used here; others: the consonant skeleton.
    static let stub: WriterGuard.PhoneticEncoder = { w in
        let known = ["queen": "KN", "qwen": "KN", "gira": "JR", "jira": "JR", "desk": "TSK", "deck": "TK",
                     "polishing": "PLXNK", "polish": "PLX"]
        let l = w.lowercased().filter(\.isLetter)
        if let k = known[l] { return [k] }
        return [l.uppercased().filter { !"AEIOU".contains($0) }]
    }

    static func heard(_ words: [(String, Float)], alts: [Int: [String]] = [:]) -> [WriterGuard.HeardToken] {
        words.enumerated().map { i, w in
            WriterGuard.HeardToken(text: w.0, confidence: w.1, alternates: alts[i] ?? [], span: i)
        }
    }

    static func confident(_ text: String) -> [WriterGuard.HeardToken] {
        heard(text.split(separator: " ").map { (String($0), 0.9) })
    }

    static let g = WriterGuard(phonetic: stub)

    // MARK: Formatting

    @Test func caseAndPunctuationAreFormatting() throws {
        let v = Self.g.check(heard: Self.confident("see you friday"), output: "See you Friday.")
        let a = try #require(v.accepted)
        #expect(a.text == "See you Friday.")
        #expect(a.revertedCount == 0)
        #expect(a.regions.isEmpty)
    }

    @Test func numbersAreFormattingOnConfidentWords() {
        let cases: [(String, String)] = [
            ("twenty five people came", "25 people came"),
            ("it costs fifty dollars", "It costs $50."),
            ("see you march third", "See you March 3rd."),
            ("at five thirty", "At 5:30."),
            ("version three point five", "Version 3.5"),
            ("ten percent off", "10% off"),
            ("queen four b", "queen 4B"),
        ]
        for (input, output) in cases {
            let v = Self.g.check(heard: Self.confident(input), output: output)
            #expect(v.accepted?.text == output, "\(input) → \(output): \(v)")
            #expect(v.accepted?.revertedCount == 0, "\(input)")
        }
    }

    @Test func joinsAndSplitsAreFormatting() {
        #expect(Self.g.check(heard: Self.confident("the web site is up"), output: "The website is up.").accepted?.text == "The website is up.")
        #expect(Self.g.check(heard: Self.confident("hold to talk"), output: "hold-to-talk").accepted?.text == "hold-to-talk")
        #expect(Self.g.check(heard: Self.confident("run qwen4b"), output: "run Qwen 4B").accepted?.text == "run Qwen 4B")
    }

    @Test func fillersAndStuttersMayGo() {
        let v = Self.g.check(heard: Self.confident("um send the the file"), output: "Send the file.")
        #expect(v.accepted?.text == "Send the file.")
        #expect(v.accepted?.perToken == ["", "Send", "the", "", "file."])
        let v2 = Self.g.check(heard: Self.confident("I I think so"), output: "I think so.")
        #expect(v2.accepted?.text == "I think so.")
        let v3 = Self.g.check(heard: Self.confident("the pol polishing step"), output: "the polishing step")
        #expect(v3.accepted?.text == "the polishing step")
    }

    @Test func selfCorrectionsCollapse() {
        let cases: [(String, String)] = [
            ("let's meet thursday no friday at noon", "Let's meet Friday at noon."),
            ("meet at the cafe I mean the office", "Meet at the office."),
            ("the red or rather the blue one", "the blue one"),
            ("three tickets make that two tickets", "Two tickets."),
            ("send it to sam scratch that to priya", "Send it to Priya."),
        ]
        for (input, output) in cases {
            let v = Self.g.check(heard: Self.confident(input), output: output)
            #expect(v.accepted?.text == output, "\(input): \(v)")
            #expect(v.accepted?.revertedCount == 0, "\(input)")
        }
    }

    // MARK: Substitutions

    @Test func soundAlikeSwapOnAConfidentWordNeedsAnEntityOrContext() {
        let uncertain = Self.heard([("Queen", 0.3), ("four", 0.9), ("B", 0.9)])
        #expect(Self.g.check(heard: uncertain, output: "Qwen 4B").accepted?.text == "Qwen 4B")
        // Confident: "Qwen" is a named entity (capitalised, not an ordinary word) that sounds the same.
        let common = WordVocabulary(words: ["queen", "four", "send", "the", "desk", "deck", "open", "ticket"])
        let named = WriterGuard(phonetic: Self.stub, common: common)
        #expect(named.check(heard: Self.confident("Queen four B"), output: "Qwen 4B").accepted?.text == "Qwen 4B")
        // Without a word list nothing counts as a named entity: the confident swap reverts.
        let noLexicon = WriterGuard(phonetic: Self.stub, common: nil)
        #expect(noLexicon.check(heard: Self.confident("Queen four B"), output: "Qwen 4B").rejection == .everyChangeReverted)
    }

    @Test func alternatesAreEvidence() {
        let h = Self.heard([("send", 0.9), ("the", 0.9), ("desk", 0.3)], alts: [2: ["deck", "disk"]])
        #expect(Self.g.check(heard: h, output: "Send the deck.").accepted?.text == "Send the deck.")
        let confident = Self.heard([("send", 0.9), ("the", 0.9), ("desk", 0.9)], alts: [2: ["deck"]])
        let v = Self.g.check(heard: confident, output: "Send the deck.")
        #expect(v.accepted?.text == "Send the desk")
        #expect(v.accepted?.regions.map(\.reverted) == [.confidentChanged])
    }

    @Test func vocabularyTermThroughItsSpokenForm() {
        let h = Self.heard([("A", 0.9), ("sixtien", 0.3), ("z", 0.9), ("backed", 0.9), ("it", 0.9)])
        let vocab = [ContextPacket.VocabularyMatch(term: "a16z", spokenForm: "a sixteen z", heard: "sixtien", score: 0.8, source: "dictionary")]
        let v = Self.g.check(heard: h, output: "a16z backed it.", vocabulary: vocab)
        #expect(v.accepted?.text == "a16z backed it.", "\(v)")
        #expect(v.accepted?.perToken == ["a16z", "", "", "backed", "it."])
        // Without the vocabulary the token is read part by part: "a" + the uncertain "sixtien" as 16 + "z".
        let bare = Self.g.check(heard: h, output: "a16z backed it.")
        #expect(bare.accepted?.text == "a16z backed it.")
        #expect(bare.accepted?.revertedCount == 0)
        // A part that is not in the audio is not invented.
        let clipped = Self.heard([("A", 0.9), ("sixtien", 0.3), ("backed", 0.9), ("it", 0.9)])
        #expect(Self.g.check(heard: clipped, output: "a16z backed it.").accepted?.text != "a16z backed it.")
    }

    @Test func vocabularyExactHeardWordsIsFormattingOnAnyConfidence() {
        let vocab = [ContextPacket.VocabularyMatch(term: "hold-to-talk", spokenForm: "hold to talk", heard: "hold to talk", score: 1, source: "dictionary")]
        let v = Self.g.check(heard: Self.confident("use hold to talk here"), output: "use hold-to-talk here", vocabulary: vocab)
        #expect(v.accepted?.text == "use hold-to-talk here")
    }

    @Test func screenTermNeedsSound() {
        let uncertain = Self.heard([("open", 0.9), ("the", 0.9), ("gira", 0.3), ("ticket", 0.9)])
        let v = Self.g.check(heard: uncertain, output: "Open the Jira ticket.", screenTerms: ["Jira", "Backlog"])
        #expect(v.accepted?.text == "Open the Jira ticket.")
        // A confident word may take an on-screen term that sounds the same ("gira" JR = "Jira" JR)…
        let confident = Self.confident("open the gira ticket")
        let v2 = Self.g.check(heard: confident, output: "Open the Jira ticket.", screenTerms: ["Jira"])
        #expect(v2.accepted?.text == "Open the Jira ticket.")
        // …but not one that sounds different.
        let v2b = Self.g.check(heard: confident, output: "Open the Linear ticket.", screenTerms: ["Linear"])
        #expect(v2b.accepted?.text == "Open the gira ticket.")
        #expect(v2b.accepted?.regions.map(\.reverted) == [.confidentChanged])
        // A screen term is never a licence to insert what was not said: the region reverts whole.
        let v3 = Self.g.check(heard: uncertain, output: "Open the Jira Backlog ticket.", screenTerms: ["Jira", "Backlog"])
        #expect(v3.accepted?.text == "Open the gira ticket.")
        #expect(v3.accepted?.regions.map(\.reverted) == [.insertion])
    }

    @Test func unsupportedSwapOnUncertainWordReverts() throws {
        let h = Self.heard([("Queen", 0.3), ("four", 0.9), ("B", 0.9), ("in", 0.9), ("polishing", 0.3), ("mode", 0.9)])
        let v = Self.g.check(heard: h, output: "Qwen 4B in Polish in chosen apps")
        let a = try #require(v.accepted)
        #expect(a.text == "Qwen 4B in polishing mode")
        #expect(a.revertedCount == 1)
        #expect(a.regions.map(\.reverted) == [nil, .substitution])
    }

    // MARK: Insertions and deletions

    @Test func newContentWordsRevertTheirRegionOnly() throws {
        let v = Self.g.check(heard: Self.confident("send it friday"), output: "Please send it on Friday.")
        let a = try #require(v.accepted)
        #expect(a.text == "send it Friday.")
        #expect(a.revertedCount == 2)
        #expect(a.regions.map(\.reverted) == [.insertion, .insertion])
    }

    @Test func droppedContentWordsRevert() throws {
        let v = Self.g.check(heard: Self.confident("send the big file"), output: "Send the file.")
        let a = try #require(v.accepted)
        #expect(a.text == "Send the file.".replacingOccurrences(of: "the file", with: "the big file"))
        #expect(a.regions.first?.reverted == .deletion)
        // A dropped word mid-sentence with nothing retained after a "no" is not a self-correction.
        #expect(Self.g.check(heard: Self.confident("I said no"), output: "I said").rejection == .everyChangeReverted)
    }

    // MARK: Whole-output rejections

    @Test func answersPreamblesEmptyAndRunawayReject() {
        let h = Self.confident("what time is it")
        #expect(Self.g.check(heard: h, output: "Sure, here is the corrected text: What time is it?").rejection == .assistantPreamble)
        #expect(Self.g.check(heard: h, output: "   ").rejection == .empty)
        let runaway = Array(repeating: "lorem ipsum dolor sit amet", count: 4).joined(separator: " ")
        #expect(Self.g.check(heard: h, output: runaway).rejection == .runaway)
        // Shares "is" and "it" (50 % overlap) but nearly every word of it is new: not a transcript.
        let answer = "It is 3 pm right now, according to the clock on your screen and the calendar entry."
        #expect(Self.g.check(heard: h, output: answer).rejection == .mostlyReverted)
        #expect(Self.g.check(heard: h, output: "⟦What⟧ time is it?").accepted?.text == "What time is it?")
    }

    @Test func withoutAnEncoderOnlyNearSpellingsPass() {
        let plain = WriterGuard(phonetic: { _ in [] })
        // Falls back to the process-wide encoder: none in PipelineTests alone, Double Metaphone once an
        // AppTests suite installed it in a full run, so only assert what holds either way.
        let bare = WriterGuard(phonetic: nil)
        let h = Self.heard([("sixtien", 0.3), ("times", 0.9)])
        #expect(plain.check(heard: h, output: "sixteen times").accepted?.text == "sixteen times")
        #expect(bare.check(heard: h, output: "sixteen times").accepted?.text == "sixteen times")
        let far = Self.heard([("Queen", 0.3), ("four", 0.9)])
        #expect(plain.check(heard: far, output: "Qwen four").rejection == .everyChangeReverted)
    }
}

@Suite struct WriterSpokenNumbersTests {
    @Test func readings() {
        #expect(WriterSpokenNumbers.readings(["twenty", "five"]) == ["25"])
        #expect(WriterSpokenNumbers.readings(["two", "hundred", "and", "three"]) == ["203"])
        #expect(WriterSpokenNumbers.readings(["four", "one", "five"]).contains("415"))
        #expect(WriterSpokenNumbers.readings(["third"]) == ["3rd"])
        #expect(WriterSpokenNumbers.readings(["twenty", "third"]) == ["23rd"])
        #expect(WriterSpokenNumbers.readings(["five", "thirty"]).contains("5:30"))
        #expect(WriterSpokenNumbers.readings(["nine", "oh", "five"]).contains("9:05"))
        #expect(WriterSpokenNumbers.readings(["three", "point", "five"]) == ["3.5"])
        #expect(WriterSpokenNumbers.readings(["fifty", "dollars"]) == ["$50"])
        #expect(WriterSpokenNumbers.readings(["ten", "percent"]) == ["10%"])
        #expect(WriterSpokenNumbers.readings(["a", "hundred"]) == ["100"])
        #expect(WriterSpokenNumbers.readings(["a", "file"]).isEmpty)
        #expect(WriterSpokenNumbers.readings(["hundred"]).isEmpty)
    }

    @Test func writtenForms() {
        #expect(WriterSpokenNumbers.writtenNumber("25,000")! == ("25000", ""))
        #expect(WriterSpokenNumbers.writtenNumber("$50.")! == ("$50", ""))
        #expect(WriterSpokenNumbers.writtenNumber("4B")! == ("4", "b"))
        #expect(WriterSpokenNumbers.writtenNumber("3rd,")! == ("3", "rd"))
        #expect(WriterSpokenNumbers.writtenNumber("5:30")! == ("5:30", ""))
        #expect(WriterSpokenNumbers.writtenNumber("10%")! == ("10%", ""))
        #expect(WriterSpokenNumbers.writtenNumber("a16z") == nil)
        #expect(WriterSpokenNumbers.writtenNumber("file") == nil)
    }
}
