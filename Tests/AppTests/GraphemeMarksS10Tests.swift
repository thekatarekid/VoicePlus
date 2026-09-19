import Foundation
import SwiftUI
import Testing
@testable import VoicePlusApp

/// S10 — grapheme-safe mark placement (design §11: "Mixed scripts, CJK, RTL, emoji and long
/// identifiers must not split graphemes or detach marks"). Marks cover whole grapheme clusters, in the
/// pill (words) and in the window (UTF-16 spans from the turn record).
@Suite("S10 — grapheme-safe uncertainty marks")
struct GraphemeMarksS10Tests {

    /// The marked text of each range.
    private func marked(_ line: String, _ words: Set<String>) -> [String] {
        GraphemeMarks.wordRanges(of: words, in: line).map { String(line[$0]) }
    }

    /// Every range starts and ends on a `Character` boundary of `line`.
    private func onClusterBoundaries(_ line: String, _ ranges: [Range<String.Index>]) -> Bool {
        let boundaries = Set(Array(line.indices) + [line.endIndex])
        return ranges.allSatisfy { boundaries.contains($0.lowerBound) && boundaries.contains($0.upperBound) }
    }

    // MARK: - Words in the pill's lines

    @Test("CJK: a word is found inside an unspaced run")
    func cjk() {
        #expect(marked("我们明天见面", ["明天"]) == ["明天"])
        #expect(marked("明日は晴れです", ["晴れ"]) == ["晴れ"])
        #expect(marked("東京で会いましょう", ["東京"]) == ["東京"])
        #expect(marked("会议在明天下午三点", ["明天", "三点"]) == ["明天", "三点"])
        // Mixed script: a Latin name inside Chinese text.
        #expect(marked("我和Mira明天见", ["mira"]) == ["Mira"])
    }

    @Test("Korean is written with spaces: only whole words are marked")
    func korean() {
        #expect(marked("안녕하세요 여러분", ["여러분"]) == ["여러분"])
        #expect(marked("여러분들", ["여러분"]).isEmpty, "not part of a longer word")
    }

    @Test("RTL: Hebrew and Arabic words keep their letters and their combining marks")
    func rtl() {
        #expect(marked("שלום עולם", ["עולם"]) == ["עולם"])
        #expect(marked("قال مرحبا للجميع", ["مرحبا"]) == ["مرحبا"])
        let voweled = "قال مَرْحَبًا للجميع"
        let ranges = GraphemeMarks.wordRanges(of: ["مَرْحَبًا"], in: voweled)
        #expect(ranges.map { String(voweled[$0]) } == ["مَرْحَبًا"], "the harakat stay with their letters")
        #expect(onClusterBoundaries(voweled, ranges))
        // Mixed direction: an English word inside an Arabic sentence.
        #expect(marked("أرسل Mira الملف", ["mira"]) == ["Mira"])
    }

    @Test("emoji: skin tones, ZWJ families, flags and keycaps are never split; a word beside one is marked alone")
    func emoji() {
        let line = "great👍🏽 meet 👨‍👩‍👧 in 🇮🇳 at 5️⃣ with Mira"
        let ranges = GraphemeMarks.wordRanges(of: ["great", "mira", "meet"], in: line)
        #expect(ranges.map { String(line[$0]) } == ["great", "meet", "Mira"])
        #expect(onClusterBoundaries(line, ranges))
        // A normalised word never matches half an emoji (emoji are symbols, never marks on their own).
        #expect(GraphemeMarks.wordRanges(of: ["👍"], in: "👍🏽 ok").isEmpty)
        #expect(GraphemeMarks.wordRanges(of: ["👨"], in: "👨‍👩‍👧").isEmpty)
    }

    @Test("Devanagari: matras and conjuncts stay with their word")
    func devanagari() {
        let line = "कल नमस्ते कहना"
        let ranges = GraphemeMarks.wordRanges(of: ["नमस्ते"], in: line)
        #expect(ranges.map { String(line[$0]) } == ["नमस्ते"])
        #expect(onClusterBoundaries(line, ranges))
    }

    @Test("Latin: whole words only, case-insensitive, trailing punctuation stays unmarked")
    func latin() {
        #expect(marked("Can we meet with Mira on Friday?", ["mira"]) == ["Mira"])
        #expect(marked("Mira, can we meet?", ["mira"]) == ["Mira"])
        #expect(marked("concatenate", ["cat"]).isEmpty)
        #expect(marked("Mira's desk", ["mira"]).isEmpty, "not the possessive's stem")
        #expect(marked("MIRA and mira", ["mira"]) == ["MIRA", "mira"])
        #expect(marked("\u{130}stanbul trip", ["istanbul", "\u{69}\u{307}stanbul"]) == ["\u{130}stanbul"],
                "İ lower-cases to i + combining dot, one cluster")
        // A long identifier is one word.
        #expect(marked("call parse_transcript_span_v2 now", ["parse_transcript_span_v2"]) == ["parse_transcript_span_v2"])
    }

    @Test("the pill's attributed line keeps its text and underlines only the marked clusters")
    func attributedLine() {
        let line = "我们明天 meet Mira👍🏽"
        let out = GraphemeMarks.attributed(line, uncertain: ["明天", "mira"], color: .red)
        #expect(String(out.characters) == line)
        var underlined: [String] = []
        for run in out.runs where run[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] != nil {
            underlined.append(String(out[run.range].characters))
        }
        #expect(underlined == ["明天", "Mira"])
        let plain = GraphemeMarks.attributed("nothing here", uncertain: ["mira"], color: .red)
        #expect(plain.runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] == nil })
    }

    // MARK: - UTF-16 spans in the window

    @Test("a UTF-16 span inside a cluster is widened to the whole cluster")
    func spansWidened() {
        let family = "hi 👨‍👩‍👧 there"
        let start = ("hi " as NSString).length
        // Only the first scalar's surrogate half of the family emoji.
        let widened = GraphemeMarks.ranges(in: family, utf16Spans: [start..<(start + 1)])
        #expect(widened.count == 1)
        #expect((family as NSString).substring(with: widened[0]) == "👨‍👩‍👧")

        let flag = "in 🇮🇳 today"
        let at = ("in " as NSString).length
        let flagRange = GraphemeMarks.ranges(in: flag, utf16Spans: [(at + 2)..<(at + 3)])
        #expect((flag as NSString).substring(with: flagRange[0]) == "🇮🇳", "never half a flag")

        let arabic = "قال مَرْحَبًا"
        let letter = ("قال " as NSString).length
        let harakat = GraphemeMarks.ranges(in: arabic, utf16Spans: [letter..<(letter + 1)])
        #expect((arabic as NSString).substring(with: harakat[0]) == "مَ", "the letter with its vowel mark")

        let skin = "ok 👍🏽"
        let thumb = ("ok " as NSString).length
        let tone = GraphemeMarks.ranges(in: skin, utf16Spans: [thumb..<(thumb + 2)])
        #expect((skin as NSString).substring(with: tone[0]) == "👍🏽", "the skin tone stays attached")
    }

    @Test("stale spans are dropped, never clamped onto other words; overlapping ones merge")
    func spansDroppedAndMerged() {
        let text = "Can we meet with Mira"
        #expect(GraphemeMarks.ranges(in: text, utf16Spans: [17..<21, -1..<2, 3..<3, 19..<99])
                == [NSRange(location: 17, length: 4)])
        #expect(GraphemeMarks.ranges(in: text, utf16Spans: [12..<16, 14..<21]) == [NSRange(location: 12, length: 9)])
        #expect(GraphemeMarks.ranges(in: text, utf16Spans: [17..<21, 0..<3]).map(\.location) == [0, 17], "in order")
    }

    @Test("the turn detail's marks are the grapheme-safe ones")
    func turnDetailUsesThem() {
        let text = "Meet 👨‍👩‍👧 Mira"
        let start = ("Meet " as NSString).length
        #expect(TurnTextMarks.ranges(in: text, spans: [(start + 2)..<(start + 4)])
                == GraphemeMarks.ranges(in: text, utf16Spans: [(start + 2)..<(start + 4)]))
        let attributed = TurnTextMarks.attributed(text, spans: [(start + 2)..<(start + 4)])
        var underlined = NSRange(location: NSNotFound, length: 0)
        _ = attributed.attribute(.underlineStyle, at: start, effectiveRange: &underlined)
        #expect((text as NSString).substring(with: underlined) == "👨‍👩‍👧")
    }
}
