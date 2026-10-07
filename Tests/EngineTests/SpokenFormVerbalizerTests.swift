import Foundation
import Testing
@testable import Engine

/// Context Writer §2.4 / A1 — principled spoken forms: digits as number words and digit sequences,
/// letters as letter names, "point", plus the H18 separator / camelCase splits. Deterministic.
@Suite("Context Writer — SpokenFormVerbalizer")
struct SpokenFormVerbalizerTests {
    static let vectors: [(term: String, forms: [String])] = [
        ("a16z", ["a sixteen z", "a one six z"]),
        ("k8s", ["k eight s"]),
        ("GPT-4o", ["g p t four o", "gpt four o"]),
        ("S3", ["s three"]),
        ("YC", ["y c"]),
        ("3.5", ["three point five"]),
        ("hold-to-talk", ["hold to talk"]),
        ("TeamViewer", ["team viewer"]),
    ]

    @Test(arguments: vectors) func verbalizesExactly(_ v: (term: String, forms: [String])) {
        #expect(SpokenFormVerbalizer.forms(for: v.term) == v.forms, "\(v.term)")
    }

    @Test func i18nReadsTheNumberFirstThenTheDigits() {
        let forms = SpokenFormVerbalizer.forms(for: "i18n")
        #expect(forms.first == "i eighteen n")
        #expect(forms.contains("i one eight n"))
    }

    @Test func plainWordsHaveNoVerbalizedForm() {
        for term in ["Kothari", "Qwen", "ok", "Muesli", "Sundar Pichai", "nvidia", "NVIDIA"] {
            #expect(SpokenFormVerbalizer.forms(for: term).isEmpty, "\(term)")
            #expect(!SpokenFormVerbalizer.hasSpokenForm(term), "\(term)")
        }
        #expect(SpokenFormVerbalizer.hasSpokenForm("Qwen", typed: ["queen"]))
        #expect(!SpokenFormVerbalizer.hasSpokenForm("Qwen", typed: ["  "]))
        #expect(SpokenFormVerbalizer.hasSpokenForm("a16z"))
    }

    @Test func numbersAreReadInAmericanEnglish() {
        #expect(SpokenFormVerbalizer.numberWords(0) == "zero")
        #expect(SpokenFormVerbalizer.numberWords(16) == "sixteen")
        #expect(SpokenFormVerbalizer.numberWords(40) == "forty")
        #expect(SpokenFormVerbalizer.numberWords(123) == "one hundred twenty three")
        #expect(SpokenFormVerbalizer.numberWords(2024) == "two thousand twenty four")
        #expect(SpokenFormVerbalizer.forms(for: "2024") == ["two thousand twenty four", "two zero two four", "twenty twenty four"])
        #expect(SpokenFormVerbalizer.forms(for: "1905") == ["one thousand nine hundred five", "one nine zero five", "nineteen oh five"])
    }

    @Test func leadingZerosAndLongRunsAreDigitByDigit() {
        #expect(SpokenFormVerbalizer.forms(for: "007") == ["zero zero seven"])
        #expect(SpokenFormVerbalizer.forms(for: "98765") == ["nine eight seven six five"])
        #expect(SpokenFormVerbalizer.forms(for: "3.14") == ["three point one four"])
    }

    @Test func dotsBetweenLettersAreSaidAndSymbolsAreBoundaries() {
        #expect(SpokenFormVerbalizer.forms(for: "node.js") == ["node dot js"])
        #expect(SpokenFormVerbalizer.forms(for: "snake_case_name") == ["snake case name"])
        #expect(SpokenFormVerbalizer.forms(for: "O'Brien") == ["o brien"])
    }

    /// A symbol that is said aloud but that the verbalizer does not read gives no form at all
    /// (never "c" for C++); only a typed form voices such a term.
    @Test func unsayableSymbolsGiveNoForm() {
        for term in ["C++", "C#", "F#", "AT&T", "R&D", "me@home", "100%", "Notepad++"] {
            #expect(SpokenFormVerbalizer.forms(for: term).isEmpty, "\(term)")
            #expect(!SpokenFormVerbalizer.hasSpokenForm(term), "\(term)")
        }
        #expect(SpokenFormVerbalizer.hasSpokenForm("C++", typed: ["c plus plus"]))
    }

    /// A dotted abbreviation is spelled, not read with "dot".
    @Test func dottedAbbreviationsAreSpelled() {
        #expect(SpokenFormVerbalizer.forms(for: "U.S.") == ["u s"])
        #expect(SpokenFormVerbalizer.forms(for: "U.S.A") == ["u s a"])
        #expect(SpokenFormVerbalizer.forms(for: "Ph.D.") == ["p h d"])
        #expect(SpokenFormVerbalizer.forms(for: "e.g.") == ["e g"])
        #expect(SpokenFormVerbalizer.forms(for: "U.S.-based") == ["u s based"])
        #expect(SpokenFormVerbalizer.spelledAbbreviation("u.s") == ["u", "s"])
        #expect(SpokenFormVerbalizer.spelledAbbreviation("node.js") == nil)
        #expect(SpokenFormVerbalizer.spelledAbbreviation("ok") == nil)
        #expect(PhoneticEncoder.spokenWords("the U.S. team") == ["the", "u", "s", "team"])
    }

    /// A typed form that holds no letter or digit says nothing.
    @Test func punctuationOnlyTypedFormsDoNotCount() {
        #expect(!SpokenFormVerbalizer.hasSpokenForm("Kothari", typed: ["-"]))
        #expect(!SpokenFormVerbalizer.hasSpokenForm("Kothari", typed: [" . ", "--"]))
        #expect(SpokenFormVerbalizer.hasSpokenForm("Kothari", typed: ["-", "ko thari"]))
    }

    @Test func longInitialismsAreReadAsWords() {
        // A short initialism is spelled and also read as a word; the word reading is kept even
        // though it spells the term itself, because it says *how* the term is pronounced.
        #expect(SpokenFormVerbalizer.forms(for: "NASA") == ["n a s a", "nasa"])
        #expect(SpokenFormVerbalizer.forms(for: "GPT") == ["g p t", "gpt"])
        #expect(SpokenFormVerbalizer.forms(for: "YC") == ["y c"], "two letters are only spelled")
        #expect(SpokenFormVerbalizer.forms(for: "nasa").isEmpty, "a lower-case word is just a word")
        #expect(SpokenFormVerbalizer.forms(for: "UNESCO2") == ["unesco two"])
    }

    /// A spoken form is words only: "GPT 4o" (the hyphen split) still carries a digit, so it is a
    /// written variant, not a spoken form — the digit is spoken in "g p t four o" / "gpt four o".
    @Test func separatorSplitsThatKeepDigitsAreNotSpokenForms() {
        #expect(!SpokenFormVerbalizer.forms(for: "GPT-4o").contains { $0.contains(where: \.isNumber) })
        #expect(!SpokenFormVerbalizer.forms(for: "GPT-4o-mini-2024").contains { $0.contains(where: \.isNumber) })
        #expect(SpokenFormVerbalizer.forms(for: "hold-to-talk") == ["hold to talk"], "digit-free splits stay")
    }

    /// The matcher reads heard digits the way the forms were verbalized (first reading only).
    @Test func heardTokensWithDigitsReadAsWords() {
        #expect(SpokenFormVerbalizer.reading(of: "4o") == "four o")
        #expect(SpokenFormVerbalizer.reading(of: "a16z") == "a sixteen z")
        #expect(SpokenFormVerbalizer.reading(of: "gpt-4o") == "gpt four o")
        #expect(SpokenFormVerbalizer.reading(of: "3.5") == "three point five")
        #expect(SpokenFormVerbalizer.reading(of: "kothari") == nil)
    }

    @Test func outputIsDeterministicAndCapped() {
        let a = SpokenFormVerbalizer.forms(for: "GPT-4o-mini-2024")
        let b = SpokenFormVerbalizer.forms(for: "GPT-4o-mini-2024")
        #expect(a == b)
        #expect(a.count <= SpokenFormVerbalizer.maxForms + 2, "product cap plus heard aliases")
        #expect(a.first == "g p t four o mini two thousand twenty four")
        #expect(Set(a.map { $0.lowercased() }).count == a.count, "case-insensitively distinct")
    }
}
