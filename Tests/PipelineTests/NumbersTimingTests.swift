import Foundation
import Testing
import Shared
@testable import Pipeline

/// E1 (V4.11) punctuation-tolerant ITN and E2 (V4.12) digit sequences read by span timing, in
/// `ProseListFormatter`'s `Numbers` stage.
struct NumbersTimingTests {
    static let formatter = ProseListFormatter()

    /// One span per word, each 200 ms long, with `gaps[n]` seconds of silence between word n and
    /// n + 1 (the last value repeats). `<word>` is low confidence (0.3). Times are laid out in whole
    /// milliseconds so the table's gaps are exact.
    static func timed(_ text: String, gaps: [Double]) -> [TranscriptSpan] {
        let words = text.split(separator: " ").map(String.init)
        var startMs = 0
        return words.enumerated().map { i, word in
            let low = word.hasPrefix("<") && word.hasSuffix(">")
            let span = TranscriptSpan(text: low ? String(word.dropFirst().dropLast()) : word,
                                      confidence: low ? 0.3 : 0.95,
                                      audioRange: Double(startMs) / 1000...Double(startMs + 200) / 1000,
                                      provenance: [.asr])
            let gap = gaps.isEmpty ? 0 : gaps[min(i, gaps.count - 1)]
            startMs += 200 + Int((gap * 1000).rounded())
            return span
        }
    }

    static func timed(_ text: String, gap: Double) -> [TranscriptSpan] { timed(text, gaps: [gap]) }

    static func run(_ text: String, gap: Double = 0) -> String {
        formatter.format(timed(text, gap: gap)).renderedText
    }

    // MARK: - E1 · punctuation-tolerant ITN

    static let tolerant: [(String, String)] = [
        // The V4 symptom: the model's period on "fifty." used to stop the parse at 5100.
        ("five thousand one hundred and fifty.", "5150."),
        ("we sold one hundred and fifty, then stopped", "We sold 150, then stopped."),
        ("about one hundred and twenty.", "About 120."),
        ("it grew fifteen percent.", "It grew 15%."),
        ("that's five dollars.", "That's $5."),
        ("see you at three pm.", "See you at 3 pm."),
        ("the call is at nine thirty am.", "The call is at 9:30 am."),
        ("born in nineteen ninety five.", "Born in 1995."),
        ("due march fifth.", "Due March 5."),
        ("twenty five, thirty.", "25, 30."),
        // A mark ends the number: nothing after it binds to it.
        ("twenty, five", "20, five."),
        ("one hundred and fifteen", "115."),
        // No grouping separators (real-room script line 05 writes 2,340; `Numbers` never has grouped).
        ("two thousand three hundred forty rupees", "2340 rupees."),
        // Single small words stay words, marks and all.
        ("i have three, maybe four.", "I have three, maybe four."),
    ]

    @Test(arguments: tolerant)
    func punctuationTolerant(_ input: String, _ expected: String) {
        #expect(Self.run(input, gap: 0.4) == expected, "input: \(input)")
    }

    /// E1 alone leaves the model's comma-separated digits as they are; E2 decides them by timing.
    @Test func commaSeparatedDigitsUnchangedByE1Alone() {
        var toks = Tokenizer.tokens(from: Self.timed("one, two, three, four.", gap: 0.05))
        let before = toks.map(\.text)
        Numbers.normalize(&toks, spellOutSmall: true)            // no spans: E2 off
        #expect(toks.map(\.text) == before)
        // One multi-word span has no timing between its words either.
        let single = TranscriptSpan(text: "one, two, three, four.", confidence: 0.9, audioRange: 0...2, provenance: [.asr])
        #expect(Self.formatter.format([single]).renderedText == "One, two, three, four.")
    }

    @Test func andIsNeverSwallowedBeforeALowConfidenceWord() {
        let input = Self.timed("one hundred and <fifty>", gap: 0.05)
        let out = Self.formatter.format(input)
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        #expect(out.renderedText == "100 and fifty")
    }

    @Test func splitSeparatesTrailingMarks() {
        func parts(_ s: String) -> [String] { let p = Numbers.split(s); return [p.core, p.mark] }
        #expect(parts("fifty.") == ["fifty", "."])
        #expect(parts("a.m.,") == ["a.m", ".,"])
        #expect(parts("hello") == ["hello", ""])
        #expect(parts("?!") == ["", "?!"])
        #expect(parts("") == ["", ""])
        #expect(parts("2,340") == ["2,340", ""])
    }

    // MARK: - E2 · digit sequences by timing

    struct TimingRow: Sendable, CustomTestStringConvertible {
        let words: String
        let gap: Double           // seconds of silence between consecutive words
        let expected: String
        init(_ words: String, _ gap: Double, _ expected: String) { self.words = words; self.gap = gap; self.expected = expected }
        var testDescription: String { "\(words) @ \(Int(gap * 1000)) ms" }
    }

    static let timing: [TimingRow] = [
        .init("one two three four", 0.05, "1234."),
        .init("one two three four", 0.24, "1234."),                 // line 05's widest inter-digit gap
        .init("one two three four", 0.25, "1, 2, 3, 4."),           // ≥ 250 ms is a pause
        .init("one two three four", 0.40, "1, 2, 3, 4."),
        .init("one, two, three, four.", 0.10, "1234."),             // model commas do not split a number
        .init("one, two, three, four.", 0.40, "1, 2, 3, 4."),
        .init("one comma two comma three comma four", 0.05, "1, 2, 3, 4."),  // spoken commas always list
        .init("my pin is four four one two", 0.05, "My pin is 4412."),
        .init("call nine eight two oh one five", 0.05, "Call 982015."),
        .init("oh one two three", 0.05, "Oh 123."),                 // "oh" never starts a run
        .init("zero one two", 0.05, "012."),
        .init("one two", 0.05, "One two."),                         // fewer than three digits
        .init("one two three four hundred", 0.05, "123 400."),      // the last digit belongs to "hundred"
        .init("twenty twenty six", 0.05, "2026."),                  // years: the same timing rule
        .init("twenty twenty six", 0.40, "20 26."),
        .init("nineteen ninety five", 0.05, "1995."),
        .init("twenty oh five", 0.05, "2005."),
        .init("i was born in nineteen ninety five", 0.40, "I was born in 1995."),  // year context needs no timing
        .init("eleven forty five", 0.05, "11 45."),                 // not a year shape: unchanged
        .init("nineteen ninety nine dollars", 0.05, "19 $99."),     // a price is not a year: as before E2
    ]

    @Test(arguments: timing)
    func digitSequenceTiming(_ row: TimingRow) {
        #expect(Self.run(row.words, gap: row.gap) == row.expected, "\(row.testDescription)")
    }

    @Test func phoneNumberGroupedByPauses() {
        let spans = Self.timed("nine eight two three four five six seven eight nine",
                               gaps: [0.05, 0.05, 0.4, 0.05, 0.05, 0.4, 0.05, 0.05, 0.05])
        #expect(Self.formatter.format(spans).renderedText == "982 345 6789.")
    }

    @Test func spokenCommaSplitsGroups() {
        #expect(Self.run("one two three comma four five six", gap: 0.05) == "123, 456.")
        // A span an earlier stage marked `.spoken` counts as a spoken comma too.
        var spans = Self.timed("one, two three four", gap: 0.05)
        spans[0].punctuationOrigin = .spoken
        #expect(Self.formatter.format(spans).renderedText == "1, 234.")
    }

    /// The number lands in the first digit's span, the other spans are blanked, and `renderedText`
    /// (D4) joins the result without stray spaces.
    @Test func concatenationWritesOneSpanAndBlanksTheRest() {
        let input = Self.timed("the total is two three four zero rupees", gap: 0.05)
        let out = Self.formatter.format(input)
        #expect(out.map(\.text) == ["The", "total", "is", "2340", "", "", "", "rupees."])
        #expect(out.renderedText == "The total is 2340 rupees.")
        #expect(out.joinedText != out.renderedText)
        for (i, span) in out.enumerated() {
            #expect(span.audioRange == input[i].audioRange)
            #expect(span.confidence == input[i].confidence)
            #expect(span.provenance == [.asr, .formatterProse])
        }
    }

    @Test func listKeepsEachDigitInItsOwnSpan() {
        let out = Self.formatter.format(Self.timed("one two three", gap: 0.5))
        #expect(out.map(\.text) == ["1,", "2,", "3."])
    }

    @Test func digitsSharingASpanHaveNoTiming() {
        let single = TranscriptSpan(text: "one two three four", confidence: 0.9, audioRange: 0...1.2, provenance: [.asr])
        #expect(Self.formatter.format([single]).renderedText == "One two three four.")
    }

    /// Bet 9: a low-confidence digit that would have joined the run blocks the rewrite and is flagged.
    @Test func lowConfidenceDigitBlocksTheRunAndIsFlagged() {
        let trailing = Self.timed("one two three <four>", gap: 0.05)
        let out = Self.formatter.format(trailing)
        #expect(ConfidenceContract.verify(input: trailing, output: out).isEmpty)
        #expect(out.renderedText == "One two three four")
        #expect(out[3].needsRepair)
        #expect(out[3].text == "four")

        let leading = Self.timed("<nine> one two three", gap: 0.05)
        let out2 = Self.formatter.format(leading)
        #expect(ConfidenceContract.verify(input: leading, output: out2).isEmpty)
        #expect(out2[0].needsRepair)
        #expect(out2.renderedText == "nine one two three.")
    }

    /// A blocked run stays blocked as a whole: the tail that is still ≥ 3 digits long is not
    /// rewritten on its own ("nine one 234" would split the number the speaker said).
    @Test func blockedRunIsNeverRewrittenFromTheMiddle() {
        let leading = Self.timed("<nine> one two three four", gap: 0.05)
        let out = Self.formatter.format(leading)
        #expect(ConfidenceContract.verify(input: leading, output: out).isEmpty)
        #expect(out.renderedText == "nine one two three four.")
        #expect(out[0].needsRepair)
        #expect(out.dropFirst().allSatisfy { !$0.needsRepair })

        let trailing = Self.timed("one two three four <five>", gap: 0.05)
        let out2 = Self.formatter.format(trailing)
        #expect(ConfidenceContract.verify(input: trailing, output: out2).isEmpty)
        #expect(out2.renderedText == "One two three four five")
        #expect(out2[4].needsRepair)
    }

    /// A low-confidence digit whose own mark closes it ("nine.") would not have joined the run.
    @Test func lowConfidenceDigitBehindAStopDoesNotBlock() {
        let spans = Self.timed("<nine.> one two three", gap: 0.05)
        let out = Self.formatter.format(spans)
        #expect(ConfidenceContract.verify(input: spans, output: out).isEmpty)
        #expect(out.renderedText == "nine. 123.")
        #expect(!out[0].needsRepair)
    }

    /// Spans with no real timing — the `0...0` a typed or provider span carries, or ranges that run
    /// backwards — have no pause to read, so the digit rules leave them alone.
    @Test func spansWithoutTimingAreLeftAlone() {
        let words = ["call", "one", "two", "three", "four"]
        let flat = words.map { TranscriptSpan(text: $0, confidence: 0.9, audioRange: 0...0, provenance: [.asr]) }
        #expect(Self.formatter.format(flat).renderedText == "Call one two three four.")
        let backwards = words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 0.9, audioRange: Double(10 - i)...Double(10 - i) + 0.2, provenance: [.asr])
        }
        #expect(Self.formatter.format(backwards).renderedText == "Call one two three four.")
        let flatYear = ["twenty", "twenty", "six"].map {
            TranscriptSpan(text: $0, confidence: 0.9, audioRange: 0...0, provenance: [.asr])
        }
        #expect(Self.formatter.format(flatYear).renderedText == "20 26.")
    }

    @Test func poisonedTimingTable() {
        for row in Self.timing {
            let words = row.words
            var spans = Self.timed(words, gap: row.gap)
            let mid = spans.count / 2
            spans[mid].confidence = 0.1
            let out = Self.formatter.format(spans)
            #expect(ConfidenceContract.verify(input: spans, output: out).isEmpty, "\(words)")
            #expect(out.count == spans.count)
            #expect(out[mid].text == spans[mid].text)
        }
    }

    // MARK: - Preview agreement (V4.12 bullet 2)

    /// The same phrases and expectations as `Tests/EngineTests/PreviewNumbersTests.swift`
    /// (`PreviewFormatter`): the final pass writes the same digits, plus its terminal period.
    static let previewAgreement: [(String, String)] = [
        ("about one hundred and twenty guests", "About 120 guests"),
        ("five thousand one hundred and fifty", "5150"),
        ("one hundred and fifteen", "115"),
        ("twelve hundred and five", "1205"),
        ("twenty five hundred and six", "2506"),
        ("a hundred and fifty", "A hundred and 50"),
        ("one thousand and five", "1000 and five"),
        ("twenty and thirty", "20 and 30"),
        ("rock and roll", "Rock and roll"),
        ("the total is two thousand three hundred forty", "The total is 2340"),
    ]

    @Test(arguments: previewAgreement)
    func finalAgreesWithPreview(_ spoken: String, _ digits: String) {
        #expect(Self.run(spoken, gap: 0.4) == digits + ".")
    }

    // MARK: - Real-room corpus (fixture snapshot of the real model's spans)

    /// Script line 05 as the real model heard it ("two three four zero …"), formatted. The script
    /// line stays as written (`2,340`); scored the way `RealRoomCorpus` scores (digit grouping
    /// ignored) the formatted text now has no word errors against it.
    @Test func realRoomLine05() throws {
        let raw = Self.formatter.format(RealRoomNumberSnapshots.spans(RealRoomNumberSnapshots.line05Raw)).renderedText
        let processed = Self.formatter.format(RealRoomNumberSnapshots.spans(RealRoomNumberSnapshots.line05Processed)).renderedText
        #expect(raw == "The invoice total is 2340 rupees not 2430.")
        #expect(processed == "The invoice total is 2340 rupees, not 2430.")

        let reference = "The invoice total is 2,340 rupees, not 2,430."
        let script = try #require(AppPaths.fixturesDirectory()?.appendingPathComponent("real-room/script.md"))
        #expect(try String(contentsOf: script, encoding: .utf8).contains("05  " + reference))
        #expect(Self.scored(raw) == Self.scored(reference))
        #expect(Self.scored(processed) == Self.scored(reference))
    }

    /// The other number lines, formatted exactly as before E1/E2.
    @Test func realRoomNumberLinesUnchanged() {
        let cases: [([RealRoomNumberSnapshots.Row], String)] = [
            (RealRoomNumberSnapshots.line04Processed, "My flight lands at 11 forty-five, so let's meet at the gate around noon."),
            (RealRoomNumberSnapshots.line08Raw, "Order two of the large ones and one of the small ones."),
            (RealRoomNumberSnapshots.line11Processed, "Their new address is 14 Carter Road, Bandra, Mumbai 40050."),
            (RealRoomNumberSnapshots.line18Raw, "We have three options: ship now, ship next week, or do not ship at all."),
        ]
        for (rows, expected) in cases {
            #expect(Self.formatter.format(RealRoomNumberSnapshots.spans(rows)).renderedText == expected)
        }
    }

    /// `RealRoomCorpus.normalizedWords` (EngineTests): lowercase, letters/digits/apostrophes only,
    /// "2,340" read as one word.
    static func scored(_ text: String) -> [String] {
        var out: [String] = [], current = ""
        let chars = Array(text.lowercased())
        for (i, ch) in chars.enumerated() {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if ch == ",", i > 0, chars[i - 1].isNumber, i + 1 < chars.count, chars[i + 1].isNumber {
                continue
            } else if !current.isEmpty {
                out.append(current); current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
