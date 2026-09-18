import Foundation
import Testing
@testable import Engine

/// E2 (V4.12, second bullet) — the preview digitizer takes `hundred` and `and` where the final pass
/// (`ProseListFormatter`'s `Numbers`) does, and tolerates the marks E1 strips, so what the pill shows
/// and what lands agree on the common cases. Full unification is V4.14 (Wave 2).
@Suite("Preview numbers agree with the final pass")
struct PreviewNumbersTests {

    /// The same phrases and expectations as `Tests/PipelineTests/NumbersTimingTests.swift`
    /// (`previewAgreement`), where the final pass writes these digits plus its terminal period.
    static let agreement: [(String, String)] = [
        ("about one hundred and twenty guests", "About 120 guests"),
        ("five thousand one hundred and fifty", "5150"),
        ("one hundred and fifteen", "115"),
        ("twelve hundred and five", "1205"),
        ("twenty five hundred and six", "2506"),
        ("a hundred and fifty", "A hundred and 50"),       // a bare "hundred" is not counted, so no bridge
        ("one thousand and five", "1000 and five"),        // `and` only bridges after a hundred
        ("twenty and thirty", "20 and 30"),
        ("rock and roll", "Rock and roll"),
        ("the total is two thousand three hundred forty", "The total is 2340"),
    ]

    @Test(arguments: agreement)
    func agreesWithTheFinalPass(_ spoken: String, _ expected: String) {
        #expect(PreviewFormatter.format(spoken) == expected)
    }

    @Test func hundredScaleAndBridge() {
        #expect(PreviewFormatter.format("one hundred") == "100")
        #expect(PreviewFormatter.format("five hundred people") == "500 people")
        #expect(PreviewFormatter.format("two hundred and five") == "205")
        #expect(PreviewFormatter.format("three hundred and ninety nine") == "399")
        #expect(PreviewFormatter.format("one hundred and eleven") == "111")
        // A trailing `and` with nothing after it stays a word.
        #expect(PreviewFormatter.format("one hundred and") == "100 and")
        #expect(PreviewFormatter.format("one hundred and oh") == "100 and oh")
        #expect(PreviewFormatter.format("one hundred and then some") == "100 and then some")
        // A hundred the preview does not count ("twenty" does not multiply it) never bridges, so
        // no number is invented out of the remainder ("20 105").
        #expect(PreviewFormatter.format("twenty hundred and five") == "20 hundred and five")
    }

    /// E1's tolerance, preview side: the mark is kept on the number, never added or dropped.
    @Test func trailingMarksAreKeptOnTheNumber() {
        #expect(PreviewFormatter.format("five thousand one hundred and fifty.") == "5150.")
        #expect(PreviewFormatter.format("we sold one hundred and fifty, then stopped")
                == "We sold 150, then stopped")
        #expect(PreviewFormatter.format("twenty five, thirty") == "25, 30")
        // The mark ends the number: "twenty," does not absorb "five".
        #expect(PreviewFormatter.format("twenty, five") == "20, five")
        // Small numbers stay words, marks included.
        #expect(PreviewFormatter.format("i have three, maybe four.") == "I have three, maybe four.")
    }

    @Test func stillNeverClaimsPunctuationAndIsIdempotent() {
        let inputs = [
            "five thousand one hundred and fifty.",
            "one hundred and twenty, then",
            "the invoice total is two three four zero rupees, not two four three zero.",
            "a hundred and fifty",
            "and",
            "one hundred and",
        ]
        for input in inputs {
            let once = PreviewFormatter.format(input)
            #expect(PreviewFormatter.addsNoPunctuation(input: input, output: once), "'\(input)' → '\(once)'")
            #expect(PreviewFormatter.format(once) == once, "not idempotent for '\(input)'")
        }
    }
}
