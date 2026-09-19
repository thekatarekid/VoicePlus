import CoreGraphics
import Foundation

/// S5 — the drawn geometry of a mark (design §7): a 2 px red dotted underline 3 px below the word's
/// baseline, on every wrapped fragment. The dot pattern tells uncertainty apart without colour.
public enum MarkStyle {
    /// Underline thickness.
    public static let thickness: CGFloat = 2
    /// Gap between the baseline and the top of the underline.
    public static let baselineOffset: CGFloat = 3
    /// Dotted: 2 px dots, 2 px apart (the prototype's `border-bottom: 2px dotted`).
    public static let dash: [CGFloat] = [2, 2]
    /// Height of the click target around a fragment in a destination overlay (the mark plus padding).
    public static let hitHeight: CGFloat = 8
    /// Share of an AX line box below the baseline, for placing the mark under a word whose baseline
    /// AX does not report (`kAXBoundsForRangeParameterizedAttribute` returns the line box).
    public static let descentRatio: CGFloat = 0.22

    /// The underline under a word whose AX line box (AppKit coordinates, y up) is `box`.
    public static func underline(below box: CGRect) -> CGRect {
        let baseline = box.minY + box.height * descentRatio
        return CGRect(x: box.minX, y: baseline - baselineOffset - thickness, width: box.width, height: thickness)
    }
}

/// One drawn piece of a mark: the part of it on one line of the pill's text lane.
public struct MarkFragment: Equatable, Sendable {
    public var markID: Int
    /// Index into the drawn lines.
    public var line: Int
    /// From the line's leading edge.
    public var x: CGFloat
    public var width: CGFloat
}

public enum MarkFragments {
    /// Where the marks fall on the pill's drawn lines. `lines` are the newest lines of `text` wrapped by
    /// `PillTextLane` (whole words joined by one space, the last line ending with the last word);
    /// `measure` is the width of a string in the lane's font. A mark crossing a line break yields one
    /// fragment per line; marks on lines scrolled away are not drawn. Nothing when the lines are not
    /// `text`'s own.
    public static func layout(text: String, lines: [String], marks: [UncertainMark],
                              measure: (String) -> CGFloat) -> [MarkFragment] {
        guard !marks.isEmpty, !lines.isEmpty else { return [] }
        let words = MarkWords.words(in: text)
        let lineWords = lines.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        let drawn = lineWords.reduce(0) { $0 + $1.count }
        guard drawn <= words.count else { return [] }
        var index = words.count - drawn
        var out: [MarkFragment] = []
        for (li, parts) in lineWords.enumerated() {
            // UTF-16 offset of each word inside the drawn line ("w0 w1 w2").
            var offsets: [Int] = []
            var cursor = 0
            for part in parts {
                offsets.append(cursor)
                cursor += part.utf16.count + 1
            }
            let range = index..<(index + parts.count)
            guard zip(range, parts).allSatisfy({ words[$0].text == $1 }) else { return [] }
            for mark in marks {
                let hit = range.filter { words[$0].range.overlaps(mark.range) }
                guard let first = hit.first, let last = hit.last else { continue }
                let fw = words[first], lw = words[last]
                let rawStart = offsets[first - index] + max(0, mark.range.lowerBound - fw.range.lowerBound)
                let rawEnd = offsets[last - index] + min(lw.range.count, mark.range.upperBound - lw.range.lowerBound)
                guard rawEnd > rawStart else { continue }
                // Whole grapheme clusters only (S10): an emoji, a flag or a letter with its combining
                // marks is never cut by a mark's edge.
                let widened = (lines[li] as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: rawStart, length: rawEnd - rawStart))
                let start = widened.location, end = widened.location + widened.length
                let x = measure(prefix(lines[li], start))
                let w = measure(prefix(lines[li], end)) - x
                out.append(MarkFragment(markID: mark.id, line: li, x: x, width: max(0, w)))
            }
            index += parts.count
        }
        return out
    }

    static func prefix(_ line: String, _ utf16: Int) -> String {
        MarkWords.slice(line, 0..<min(utf16, line.utf16.count)) ?? line
    }
}
