import AppKit
import Foundation

// Context Writer (plan §4 "visible, undoable changes") — the second kind of word mark the pill
// draws. An *uncertain* mark (S5) asks for review: a red dotted underline that stays. A *corrected*
// mark says the writer changed this word: the word's own ink takes a subtle tint that shimmers for
// ~3 s and then settles back to plain ink. No underline, no glyph, nothing to click: the landed
// row's "Polished N words" and its Undo carry the meaning in words. Under Reduce Motion the tint is
// static for the same ~3 s (no shimmer).

/// The kinds of word marks in the pill's text lane.
public enum WordMarkKind: String, CaseIterable, Equatable, Sendable {
    /// S5 — the recogniser was unsure: red dotted underline (`MarkStyle`), review on click.
    case uncertain
    /// Context Writer — the writer changed the word: a brief tint shimmer (`CorrectedMarkStyle`).
    case corrected
}

/// The changed words drawn in one final text, and when they were first drawn.
public struct CorrectedMarks: Equatable, Sendable {
    public var text: String
    public var changes: [LocatedWriterChange]
    /// The shimmer's clock.
    public var shownAt: Date?

    public init(text: String, changes: [LocatedWriterChange], shownAt: Date?) {
        self.text = text
        self.changes = changes
        self.shownAt = shownAt
    }

    public static let empty = CorrectedMarks(text: "", changes: [], shownAt: nil)
    public var kind: WordMarkKind { .corrected }
    public var isEmpty: Bool { changes.isEmpty }
    public var ranges: [Range<Int>] { changes.map(\.range) }

    /// How the marks look at `date`.
    public func appearance(at date: Date, reduceMotion: Bool) -> CorrectedMarkStyle.Appearance {
        guard !isEmpty, let shownAt else { return .plain }
        return CorrectedMarkStyle.appearance(elapsed: date.timeIntervalSince(shownAt), reduceMotion: reduceMotion)
    }
}

/// The corrected mark's look and motion, as data.
public enum CorrectedMarkStyle {
    public enum Appearance: Equatable, Sendable {
        /// A highlight band sweeping across the tinted word; `phase` 0…1 within one sweep.
        case shimmer(phase: Double)
        /// Reduce Motion: the tint alone, still.
        case tint
        /// Settled: the word's normal ink.
        case plain
    }

    /// The whole shimmer (or still tint) lasts this long from the first drawn frame.
    public static let duration: TimeInterval = WriterLandingTiming.shimmerDuration
    /// One sweep of the highlight band across a word.
    public static let sweep: TimeInterval = 1.0
    /// The band's half-width, as a share of the word.
    public static let bandHalfWidth: Double = 0.35
    /// Redraw rate while shimmering (the text lane recolours only the marked characters).
    public static let frameInterval: TimeInterval = 1.0 / 30.0

    public static func appearance(elapsed: TimeInterval, reduceMotion: Bool) -> Appearance {
        guard elapsed.isFinite, elapsed >= 0, elapsed < duration else { return .plain }
        if reduceMotion { return .tint }
        let phase = (elapsed / sweep).truncatingRemainder(dividingBy: 1)
        return .shimmer(phase: phase)
    }

    /// 0…1 — how much of the highlight a character at `position` (0…1 across its word) gets at
    /// `phase`. The band enters before the word's start and leaves after its end, so every sweep
    /// starts and ends on the plain tint (no pop).
    public static func highlight(phase: Double, position: Double) -> Double {
        let span = 1 + 2 * bandHalfWidth
        let center = -bandHalfWidth + phase * span
        let distance = abs(position - center)
        return max(0, 1 - distance / bandHalfWidth)
    }

    /// The tint: the pill's primary (peach) ink, ≥ 7 : 1 on the pill (`DesignTokenTests`).
    static var tint: NSColor { Tokens.Pill.primary }
    /// The band's crest: the pill's ink.
    static var crest: NSColor { Tokens.Pill.ink }

    /// The colour of a character at `position` across its word.
    static func color(_ appearance: Appearance, position: Double, base: NSColor) -> NSColor {
        switch appearance {
        case .plain: return base
        case .tint: return tint
        case .shimmer(let phase):
            let amount = CGFloat(highlight(phase: phase, position: position))
            return tint.usingColorSpace(.sRGB)?.blended(withFraction: amount, of: crest.usingColorSpace(.sRGB) ?? crest) ?? tint
        }
    }
}

extension NSAttributedString.Key {
    /// Marks the characters of a corrected word (value: the change's index), so the text lane can
    /// recolour them for the shimmer after uncertainty suggestions shifted the storage.
    static let transcriptCorrected = NSAttributedString.Key("VoicePlus.transcriptCorrected")
}
