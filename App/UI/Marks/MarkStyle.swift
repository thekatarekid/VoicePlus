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
