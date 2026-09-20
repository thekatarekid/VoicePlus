import CoreGraphics
import Foundation

/// P5 / S2 — pure placement math for the persistent presence indicator ("the notch chin").
///
/// ONE RULE, shared verbatim with the pill: the indicator's top edge is the pill's top edge
/// (`NotchGeometry.pillTopEdge`) — the bottom of the display's forbidden band on a notched display,
/// 8 pt below the menu-bar band on an external one. That keeps it out from under the camera housing
/// (there is no panel behind the housing, so anything drawn there is never seen), and
/// `NotchPresenceTests.sharesTheTopBoundaryWithThePill` asserts the two surfaces cannot drift apart.
///
/// Sizes are the verified design's (design §4): the idle chin is 64 × 14 with a 6 pt green dot, the
/// hover hint 360 × 38, text-sized and never under 190.
public enum PresenceGeometry {
    public struct Layout: Equatable, Sendable {
        /// Where the panel goes (global, bottom-left origin coordinates).
        public var frame: CGRect
        /// Pointer inside this rect counts as hovering (see `PresenceInteraction`).
        public var hoverRect: CGRect
        /// Lower corners when attached; all four when floating (external display).
        public var cornerRadius: CGFloat
        /// False when the state is `.off` — nothing is ordered in at all.
        public var visible: Bool
        /// Hangs from the camera housing (upper corners square). False: floats 8 pt below the band.
        public var attached: Bool
    }

    // MARK: - Sizes (design §4, DESIGN.md §8.3–§8.4)

    /// I0 — idle: a 64 × 14 black chin carrying one 6 pt green dot. The green dot never means the
    /// microphone is open.
    public static let restSize = NotchGeometry.idleChinSize
    /// The idle dot's diameter.
    public static let dotDiameter: CGFloat = 6
    /// Mic open by another owner (meeting, the onboarding meter): a level bar in the same chin height.
    public static let activeSize = CGSize(width: 120, height: 14)
    /// Muted: a persistent, legible badge. A hidden hot mic is the one thing that must never ship,
    /// so this state is never shrunk and never suppressed.
    public static let mutedSize = CGSize(width: 84, height: 16)
    /// Blocked: room for a short reason — "Mic off", "Relaunch", "42%".
    public static let blockedSize = CGSize(width: 132, height: 16)
    /// I1 — the hover hint's nominal size. The row is sized to its text (`rowSize(width:on:)`), never
    /// narrower than `NotchGeometry.hintMinimumWidth` (190).
    public static let hoverSize = NotchGeometry.hintSize

    /// Widest a row may ever be on this display: the full width minus the edge margins.
    public static func maxRowWidth(on metrics: ScreenMetrics) -> CGFloat {
        max(64, metrics.frame.width - 2 * edgeMargin)
    }

    /// The expanded row's size for a measured text width (padding included by the caller): text-sized,
    /// never under 190, never off the display.
    public static func rowSize(width: CGFloat, on metrics: ScreenMetrics) -> CGSize {
        CGSize(width: min(max(width, NotchGeometry.hintMinimumWidth), maxRowWidth(on: metrics)), height: hoverSize.height)
    }

    /// Horizontal margin kept from the edges of a narrow display (same value as the pill's).
    static let edgeMargin: CGFloat = 8
    /// Slop around the resting chin that still counts as "pointing at it".
    public static let hoverSlop: CGFloat = 8

    public static func size(for state: PresenceState, hovered: Bool = false) -> CGSize {
        if hovered, state != .off { return hoverSize }
        switch state {
        case .off: return .zero
        case .ready: return restSize
        case .listening, .processing: return activeSize
        case .muted: return mutedSize
        case .paused, .blocked: return blockedSize
        }
    }

    /// The one rule, shared with the pill (`NotchGeometry.pillTopEdge`): centred, hanging off the
    /// housing on a notched display, 8 pt below the menu-bar band elsewhere, clamped to the display.
    public static func frame(size requested: CGSize, on metrics: ScreenMetrics) -> CGRect {
        var size = requested
        size.width = min(size.width, max(16, metrics.frame.width - 2 * edgeMargin))
        let top = NotchGeometry.pillTopEdge(on: metrics)
        size.height = min(size.height, max(1, top - metrics.frame.minY - edgeMargin))
        let x = NotchGeometry.centredX(width: size.width, on: metrics)
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    /// Hover target: the resting chin unioned with the expanded row (so the pointer does not fall
    /// out of the region the instant the panel grows and start a collapse/expand flicker), inflated
    /// by `hoverSlop`, unioned with the camera housing itself — pointing at the notch reveals it.
    public static func hoverRect(on metrics: ScreenMetrics, rowWidth: CGFloat? = nil) -> CGRect {
        var rect = frame(size: restSize, on: metrics)
            .union(frame(size: rowSize(width: 0, on: metrics), on: metrics))
        if let rowWidth { rect = rect.union(frame(size: rowSize(width: rowWidth, on: metrics), on: metrics)) }
        rect = rect.insetBy(dx: -hoverSlop, dy: -hoverSlop)
        if let notch = metrics.notchRect { rect = rect.union(notch) }
        return rect
    }

    /// `hovered` = the pointer is on it. `rowWidth` — measured — sizes the expanded row to its text.
    public static func layout(for metrics: ScreenMetrics, state: PresenceState, hovered: Bool = false,
                              rowWidth: CGFloat? = nil) -> Layout {
        guard state != .off else {
            return Layout(frame: .zero, hoverRect: hoverRect(on: metrics), cornerRadius: 0, visible: false,
                          attached: metrics.isAttached)
        }
        var size = size(for: state, hovered: hovered)
        if hovered, let rowWidth { size = rowSize(width: rowWidth, on: metrics) }
        let radius = hovered ? 10 : min(6, size.height / 2)   // Tokens.Radius.presenceHint / presenceChin
        return Layout(frame: frame(size: size, on: metrics),
                      hoverRect: hoverRect(on: metrics, rowWidth: hovered ? rowWidth : nil),
                      cornerRadius: radius, visible: true, attached: metrics.isAttached)
    }

    /// True when `rect` is drawable: on the display, and not behind the camera housing.
    public static func clearsHousing(_ rect: CGRect, on metrics: ScreenMetrics) -> Bool {
        NotchGeometry.clearsHousing(rect, on: metrics)
    }

    /// Every frame the indicator can ever occupy on this display — what the startup diagnostic logs
    /// and what the housing guard checks.
    public static func allFrames(on metrics: ScreenMetrics) -> [(name: String, rect: CGRect)] {
        [("rest", frame(size: restSize, on: metrics)),
         ("active", frame(size: activeSize, on: metrics)),
         ("muted", frame(size: mutedSize, on: metrics)),
         ("blocked", frame(size: blockedSize, on: metrics)),
         ("hover", frame(size: hoverSize, on: metrics))]
    }
}

/// S2 — what the chin shows under the pointer (design §4 "Hover presence", DESIGN.md §8.4).
///
/// * Idle (`ready`) with the pointer on it → the text-only hint "Hold or Double Tap <key> to dictate":
///   no dot, no Spool, no brand prefix, no "Ready".
/// * Any other visible state with the pointer on it → that state's own row (muted, paused, blocked…).
/// * No pointer → the chin (or its badge). Keyboard focus never opens the hover presentation, and
///   nothing expands unprompted: the hint is only ever a hover.
/// * Capture, errors and held text take priority over hover: the pill is showing them, and the
///   reducer has already turned the indicator off (`PresenceState.off`).
public enum PresenceHover {
    public enum Presentation: Equatable, Sendable {
        case none
        case chin
        /// The ready hint, exactly this text.
        case hint(String)
        /// A non-ready state's row (`PresenceRow`).
        case row
    }

    public static func presentation(state: PresenceState, pointerOn: Bool, keyboardFocus: Bool = false,
                                    readyHint: String) -> Presentation {
        guard state.isVisible else { return .none }
        // Only the pointer expands it. Keyboard focus alone never does (`keyboardFocus` is accepted so
        // callers state it, and ignored): the chin's accessible description carries the same hint.
        _ = keyboardFocus
        guard pointerOn else { return .chin }
        return state == .ready ? .hint(readyHint) : .row
    }

    /// The key hint a non-ready row carries ("hold fn / 🌐", "press ⌃⌥D"): the configured key by the
    /// label hints use (`HotkeyBinding.label`, I1), never the older display name ("Right ⌥").
    public static func keyHint(for binding: HotkeyBinding) -> String {
        switch binding.style {
        case .bareModifier: return "hold \(binding.label)"
        case .chord: return "press \(binding.label)"
        }
    }

    /// The width the hint row needs for `hint` (12 pt padding each side, min 190), measured by `measure`.
    public static func hintWidth(_ hint: String, on metrics: ScreenMetrics, measure: (String) -> CGFloat) -> CGFloat {
        PresenceGeometry.rowSize(width: max(NotchGeometry.hintSize.width, measure(hint) + NotchGeometry.hintHorizontalPadding), on: metrics).width
    }
}

/// Click/focus policy, pulled out as pure logic so the "it can never swallow a click" guarantee is
/// a unit test rather than a claim in a comment.
public enum PresenceInteraction {
    /// The panel ignores the mouse at all times except while the pointer is actually on it.
    public static func ignoresMouse(hovering: Bool) -> Bool { !hovering }

    public static func isHovering(mouse: CGPoint, on metrics: ScreenMetrics, rowWidth: CGFloat? = nil) -> Bool {
        PresenceGeometry.hoverRect(on: metrics, rowWidth: rowWidth).contains(mouse)
    }

    /// Full-screen detection with no private API: the menu bar's `visibleFrame` delta collapses to
    /// 0 in a full-screen Space. A display that has *never* shown a menu bar (a secondary display
    /// with "Displays have separate Spaces" off) is not full screen — it simply has no menu bar, so
    /// a zero delta there means nothing and must not be read as one.
    public static func menuBarPresent(current: CGFloat, everObserved: CGFloat) -> Bool {
        current > 0 || everObserved <= 0
    }
}
