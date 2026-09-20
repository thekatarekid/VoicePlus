import CoreGraphics
import Foundation

/// Screen facts needed to place the pill, decoupled from `NSScreen` so tests can cover it.
public struct ScreenMetrics: Equatable, Sendable {
    /// Full screen frame in global (bottom-left origin) coordinates.
    public var frame: CGRect
    /// Height of the top safe-area inset (the notch) — 0 on notch-less displays.
    public var topInset: CGFloat
    /// Width of the notch cut-out if known (auxiliaryTopLeft/Right areas), else `nil`.
    public var notchWidth: CGFloat?
    /// Menu bar height (visibleFrame delta) for notch-less displays.
    public var menuBarHeight: CGFloat
    /// The screen's `visibleFrame` (menu bar, notch and Dock excluded) when known.
    public var visibleFrame: CGRect?

    public init(frame: CGRect, topInset: CGFloat = 0, notchWidth: CGFloat? = nil, menuBarHeight: CGFloat = 24,
                visibleFrame: CGRect? = nil) {
        self.frame = frame
        self.topInset = topInset
        self.notchWidth = notchWidth
        self.menuBarHeight = menuBarHeight
        self.visibleFrame = visibleFrame
    }

    public var hasNotch: Bool { topInset > 0 }

    /// S2 (design §4) — the pill hangs from the camera housing (upper corners square) on a notched
    /// display, and floats 8 pt below the menu-bar band with all four corners rounded everywhere else.
    public var isAttached: Bool { hasNotch }

    /// Area a regular window may occupy: the real `visibleFrame` when known, else the frame minus
    /// the forbidden top band (better than nothing — a window placed here still clears the notch).
    public var usableFrame: CGRect {
        visibleFrame ?? CGRect(x: frame.minX, y: frame.minY, width: frame.width,
                               height: max(0, frame.height - topBand))
    }

    /// Band at the top of the display nothing may be drawn into: the camera-housing safe area on a
    /// notched built-in display, the menu bar otherwise. `max` matters — with the menu bar auto-hidden
    /// (or in a full-screen space) the visibleFrame delta collapses to 0 while `safeAreaInsets.top`
    /// stays at the housing height, and on an external display there is no inset but there is a menu bar.
    public var topBand: CGFloat { max(max(topInset, menuBarHeight), 0) }

    /// The physical camera housing in global coordinates; `nil` on notch-less displays.
    /// Nothing drawn inside this rect is visible — there is no panel behind it.
    public var notchRect: CGRect? {
        guard hasNotch, let width = notchWidth, width > 0 else { return nil }
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - topInset, width: width, height: topInset)
    }
}

/// S2 — pure placement and size math for the Spool pill (design §4, DESIGN.md §8.3).
///
/// Every size is the verified design's: the idle chin 64 × 14, the hover hint 360 × 38 (text-sized,
/// never under 190), the active pill 560 × 164, the actionable pill 560 × 204, all bounded by the
/// compact ceiling `min(560, usable width − 32) × 204`. Below 460 pt the character bay shrinks from 132
/// to an 84 pt cameo bay. The ceiling replaces the old 560 × 96 `absoluteMaximumSize`: the pill's frame
/// is placement math, never content, so no message length can make it a slab (the 1.7.9 bug).
public enum NotchGeometry {
    public struct Layout: Equatable, Sendable {
        /// Pill frame when fully shown (global coordinates).
        public var shown: CGRect
        /// Pill frame when retracted (rolls up to the top edge).
        public var retracted: CGRect
        /// Corner radius (`Tokens.Radius.pill`). Lower corners always; upper corners only when floating.
        public var cornerRadius: CGFloat
        /// Hangs from the camera housing: upper corners square. False: floating, all corners rounded.
        public var attached: Bool
        /// Background-only extension above the safe content area.
        public var backgroundCap: CGFloat = 0
        public var contentFrame: CGRect { CGRect(x: shown.minX, y: shown.minY, width: shown.width, height: shown.height - backgroundCap) }

        public init(shown: CGRect, retracted: CGRect, cornerRadius: CGFloat, attached: Bool) {
            self.shown = shown
            self.retracted = retracted
            self.cornerRadius = cornerRadius
            self.attached = attached
        }
    }

    /// What the pill is drawing, as far as its frame is concerned.
    public enum Surface: Equatable, Sendable {
        case hidden
        /// I1 — the hover hint, sized to its measured text width.
        case hint(textWidth: CGFloat)
        /// Status, text lane, tape lane and helper row: 164 pt.
        case active
        /// The same plus a full-width action row below the character bay: 204 pt.
        case actionable
    }

    // MARK: - Sizes (design §4)

    public static let idleChinSize = CGSize(width: 64, height: 14)
    /// Nominal hover hint. The real width follows the text (`hintSize(textWidth:on:)`).
    public static let hintSize = CGSize(width: 360, height: 38)
    public static let hintMinimumWidth: CGFloat = 190
    /// Left + right padding inside the hint (prototype `.notch.ready { padding: 10px 12px }`).
    public static let hintHorizontalPadding: CGFloat = 24
    public static let activeSize = CGSize(width: 560, height: 160)
    public static let actionableSize = CGSize(width: 560, height: 160)
    /// Compact ceiling: `min(560, usable width − ceilingMargin) × 204`.
    public static let ceilingMargin: CGFloat = 32
    /// Narrowest a pill is ever made before the display clamp; below this nothing is legible.
    public static let minimumPillWidth: CGFloat = 240
    /// Below this width the review layout uses the 84 pt cameo bay and Spool at scale 0.69.
    public static let narrowBelow: CGFloat = 460
    public static let characterBay: CGFloat = 126
    public static let cameoBay: CGFloat = 84
    /// Floating pills sit this far below the menu-bar band (external displays).
    public static let floatingGap: CGFloat = 8
    /// `Tokens.Radius.pill`.
    public static let cornerRadius: CGFloat = 18
    /// Horizontal margin kept between any notch surface and the edges of a narrow display.
    static let edgeMargin: CGFloat = 8

    /// The compact ceiling on a display: `min(560, usable width − 32) × 204`, and never taller than the
    /// room below the pill's top edge.
    public static func ceiling(on metrics: ScreenMetrics) -> CGSize {
        let usable = metrics.usableFrame.width
        let width = min(actionableSize.width, max(minimumPillWidth, usable - ceilingMargin))
        let displayLimit = max(64, metrics.frame.width - 2 * edgeMargin)
        let room = max(1, pillTopEdge(on: metrics) - metrics.frame.minY - edgeMargin)
        return CGSize(width: min(width, displayLimit), height: min(actionableSize.height, room))
    }

    /// True when a pill this wide uses the narrow review layout (84 pt cameo bay, Spool at 0.69).
    public static func isNarrow(width: CGFloat) -> Bool { width < narrowBelow }

    /// The right-hand bay the character owns for a pill this wide; no text is ever laid out in it.
    public static func bayWidth(forPillWidth width: CGFloat) -> CGFloat {
        isNarrow(width: width) ? cameoBay : characterBay
    }

    /// Nominal size of a surface, before any display clamp.
    public static func nominalSize(for surface: Surface) -> CGSize {
        switch surface {
        case .hidden: return .zero
        case .hint(let textWidth): return CGSize(width: max(hintMinimumWidth, textWidth + hintHorizontalPadding),
                                                 height: hintSize.height)
        case .active: return activeSize
        case .actionable: return actionableSize
        }
    }

    /// A surface's size on a display: the hint follows its text (min 190), a turn state is the full
    /// ceiling width with stable height (164, or 204 with actions), all clamped to the ceiling.
    public static func size(for surface: Surface, on metrics: ScreenMetrics) -> CGSize {
        let ceiling = ceiling(on: metrics)
        switch surface {
        case .hidden: return .zero
        case .hint:
            let nominal = nominalSize(for: surface)
            let widest = max(64, metrics.frame.width - 2 * edgeMargin)
            return CGSize(width: min(nominal.width, widest), height: min(nominal.height, ceiling.height))
        case .active, .actionable:
            let nominal = nominalSize(for: surface)
            return CGSize(width: min(nominal.width, ceiling.width), height: min(nominal.height, ceiling.height))
        }
    }

    /// Nominal size of a pill state with the default turn context (no display): 164 or 204 by whether
    /// the state draws actions, the hint for `.ready`, zero when hidden.
    public static func size(for state: PillState) -> CGSize {
        nominalSize(for: PillContent.make(state, context: PillTurnContext()).surface(measure: { _ in 0 }))
    }

    /// A state's size on a display, measuring the hint text with `measure`.
    public static func size(for state: PillState, on metrics: ScreenMetrics, context: PillTurnContext = PillTurnContext(),
                            measure: (String) -> CGFloat) -> CGSize {
        size(for: PillContent.make(state, context: context).surface(measure: measure), on: metrics)
    }

    // MARK: - Placement

    /// The y of the pill's top edge: the bottom of the forbidden band when attached to the housing,
    /// `floatingGap` below it when floating. Shared with the presence chin so the two never drift.
    public static func pillTopEdge(on metrics: ScreenMetrics) -> CGFloat {
        metrics.frame.maxY - metrics.topBand - (metrics.isAttached ? 0 : floatingGap)
    }

    /// S2 — the pill: centred, hanging off the housing (attached, upper corners square) or floating 8 pt
    /// below the menu-bar band (all corners rounded). Clamped to the ceiling and the display, so no
    /// caller can produce a slab, and never drawn behind the camera housing.
    public static func pillLayout(for metrics: ScreenMetrics, size requested: CGSize = activeSize) -> Layout {
        let bounds = ceiling(on: metrics)
        var size = requested
        size.width = min(max(1, size.width), bounds.width)
        size.height = min(max(1, size.height), bounds.height)
        let top = pillTopEdge(on: metrics)
        let x = centredX(width: size.width, on: metrics)
        let cap = metrics.isAttached ? metrics.topBand : 0
        let shown = CGRect(x: x, y: top - size.height, width: size.width, height: size.height + cap)
        // Retract by rolling up to the top edge rather than translating off the top of the screen: a
        // retracted frame above the band would drag the pill through the camera housing.
        let retracted = CGRect(x: x, y: top - 1, width: size.width, height: 1)
        var result = Layout(shown: shown, retracted: retracted, cornerRadius: cornerRadius, attached: metrics.isAttached)
        result.backgroundCap = cap
        return result
    }

    /// Generic anchor for other notch surfaces (the meeting prompt): top edge at the bottom of the
    /// forbidden band, centred, at least as wide as the housing + 24 so it reads as attached, and
    /// clamped to the display and the compact ceiling.
    public static func layout(for metrics: ScreenMetrics, size requested: CGSize = activeSize) -> Layout {
        var size = requested
        if let notchWidth = metrics.notchWidth, metrics.hasNotch {
            size.width = max(size.width, notchWidth + 24)
        }
        size.width = min(size.width, actionableSize.width, max(64, metrics.frame.width - 2 * edgeMargin))
        size.height = min(size.height, actionableSize.height, max(1, metrics.frame.height - metrics.topBand - edgeMargin))
        let topBoundary = metrics.frame.maxY - metrics.topBand
        let x = centredX(width: size.width, on: metrics)
        let shown = CGRect(x: x, y: topBoundary - size.height, width: size.width, height: size.height)
        let retracted = CGRect(x: x, y: topBoundary - 1, width: size.width, height: 1)
        return Layout(shown: shown, retracted: retracted, cornerRadius: metrics.hasNotch ? cornerRadius : 12,
                      attached: metrics.hasNotch)
    }

    static func centredX(width: CGFloat, on metrics: ScreenMetrics) -> CGFloat {
        var x = metrics.frame.midX - width / 2
        let minX = metrics.frame.minX + edgeMargin
        let maxX = metrics.frame.maxX - width - edgeMargin
        if maxX >= minX { x = min(max(x, minX), maxX) }
        return x
    }

    /// True when `rect` is drawable: on the display, and not behind the camera housing.
    public static func clearsHousing(_ rect: CGRect, on metrics: ScreenMetrics) -> Bool {
        guard metrics.frame.contains(rect) else { return false }
        guard let housing = metrics.notchRect else { return true }
        return !rect.intersects(housing)
    }

    /// Pick the screen that should host the pill: the one containing the mouse, else the main screen.
    public static func hostScreen(screens: [ScreenMetrics], mouse: CGPoint, main: ScreenMetrics?) -> ScreenMetrics? {
        screens.first { $0.frame.contains(mouse) } ?? main ?? screens.first
    }
}

/// S2 — where each row of the pill sits inside a pill of a given size (design §4, DESIGN.md §8.3,
/// prototype `.notch` rules). Pure, so "never text under the face" and "the chip sits in the text lane
/// above the tape" are unit tests. Coordinates are the pill's own: origin top-left, y down.
public struct PillLaneLayout: Equatable, Sendable {
    public var size: CGSize
    /// The character bay on the right: 132 pt (84 pt narrow) plus the 16 pt inset, from the top down
    /// to the helper row (Spool is ~126 × 115 pt centred at y 80, design §4).
    public var bay: CGRect
    /// Status · destination / timer.
    public var statusRow: CGRect
    /// The newest transcript lines (two, or one when the deixis chip takes the second).
    public var wordsLane: CGRect
    /// The confidence-dots lane: the band right under the words where each uncertain word's 2 px
    /// dotted mark sits (3 px below its baseline, design §7). Reserved, so the chip row and the tape
    /// lane never draw over the marks.
    public var confidenceLane: CGRect
    /// Deixis chip row, under the transcript and above the tape lane; `nil` without a chip.
    public var chipRow: CGRect?
    /// Top of the tape's excursion band (the lane is at `tapeY`, bounded to ±12 pt, 8 pt ribbon).
    public var tapeTop: CGFloat
    public var tapeY: CGFloat
    /// Helper · key hint, full width below the character.
    public var helperRow: CGRect
    /// Full-width action row below the character bay; `nil` on a 164 pt pill.
    public var actionRow: CGRect?
    public var lineCount: Int

    public static let inset: CGFloat = 20
    public static let top: CGFloat = 16
    public static let statusHeight: CGFloat = 14
    public static let wordsGap: CGFloat = 4
    public static let lineHeight: CGFloat = 21
    public static let chipHeight: CGFloat = 18
    public static let chipGap: CGFloat = 4
    /// Height of the confidence-dots lane under the last word line (fits in `chipGap`).
    public static let confidenceHeight: CGFloat = 4
    /// `spool_spec.json` › `sceneGeometry` › `tapeStart.y`.
    public static let tapeY: CGFloat = 98
    /// Tape amplitude bound (design §11) plus half the 8 pt ribbon.
    public static let tapeExcursion: CGFloat = 12 + 3.2
    /// Prototype `.notch .helper { top: 139px }`.
    public static let helperY: CGFloat = 116
    public static let helperHeight: CGFloat = 32
    public static let sceneHeight: CGFloat = 160
    public static let actionHeight: CGFloat = 32
    /// Gap between the lane and the bay (prototype: 144 = 132 bay + 12; narrow 90 = 84 + 6).
    public static func laneGap(narrow: Bool) -> CGFloat { narrow ? 6 : 0 }

    public init(size: CGSize, hasChip: Bool, hasActions: Bool) {
        self.size = size
        let narrow = NotchGeometry.isNarrow(width: size.width)
        let bayWidth = NotchGeometry.bayWidth(forPillWidth: size.width)
        let inset = Self.inset
        bay = CGRect(x: size.width - inset - bayWidth, y: 0, width: bayWidth + inset, height: Self.helperY)
        let laneWidth = max(0, size.width - 2 * inset - bayWidth - Self.laneGap(narrow: narrow))
        statusRow = CGRect(x: inset, y: Self.top, width: laneWidth, height: Self.statusHeight)
        lineCount = hasChip ? 1 : 2
        let wordsY = Self.top + Self.statusHeight + Self.wordsGap
        wordsLane = CGRect(x: inset, y: wordsY, width: laneWidth, height: CGFloat(lineCount) * Self.lineHeight + 6)
        confidenceLane = CGRect(x: inset, y: wordsLane.maxY, width: laneWidth, height: Self.confidenceHeight)
        chipRow = hasChip
            ? CGRect(x: inset, y: wordsLane.maxY + Self.chipGap, width: laneWidth, height: Self.chipHeight)
            : nil
        tapeY = Self.tapeY
        tapeTop = Self.tapeY - Self.tapeExcursion
        helperRow = CGRect(x: inset, y: Self.helperY, width: max(0, size.width - 2 * inset), height: Self.helperHeight)
        actionRow = hasActions
            ? CGRect(x: inset, y: Self.helperY, width: max(0, size.width - 2 * inset), height: Self.actionHeight)
            : nil
    }

    /// Every rect that carries readable text or a control.
    public var textRects: [CGRect] { [statusRow, wordsLane, confidenceLane] + [chipRow].compactMap { $0 } }
}
