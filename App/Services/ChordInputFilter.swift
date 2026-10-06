import CoreGraphics
import Foundation

/// Launch fix (RC5) — which events count as "Option + another input" (X1, owner round 4: any key,
/// click or scroll while Option is held cancels silently).
///
/// A *scroll the user makes* is a chord; the tail of one they already finished is not. Until now
/// every `scrollWheel` event counted — including the momentum events a trackpad keeps emitting for
/// a second or more after the fingers lift, the zero-delta "may begin" a resting finger sends, and
/// the "ended" marker — both in the active Option tap and in the passive key-up check
/// (`secondsSinceLastEventType(.scrollWheel)`). Scroll a Claude or Codex window, then hold Option to
/// dictate, and the press was cancelled silently 5–580 ms after key-down: 20 of 58 presses on
/// 2026-10-06, many of them 1–2.3 s holds that were meant as dictation.
public enum ChordInputFilter {
    /// `kCGScrollWheelEventScrollPhase` values (NSEvent.Phase raw values).
    enum ScrollPhase {
        static let none: Int64 = 0
        static let began: Int64 = 1
        static let changed: Int64 = 2
        static let ended: Int64 = 4
        static let cancelled: Int64 = 8
        static let mayBegin: Int64 = 128
    }

    /// Does a scroll event with these phase fields count as other input?
    /// A discrete mouse wheel (no phase) and a live trackpad gesture (began/changed) do; momentum,
    /// may-begin (finger resting), ended and cancelled do not.
    public static func scrollCounts(scrollPhase: Int64, momentumPhase: Int64) -> Bool {
        guard momentumPhase == 0 else { return false }
        return scrollPhase == ScrollPhase.none || scrollPhase == ScrollPhase.began || scrollPhase == ScrollPhase.changed
    }

    /// Does `event` (seen by the Option tap while the key may be held) count as other input?
    public static func counts(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .scrollWheel else { return true }
        return scrollCounts(scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
    }

    /// A short label for the log line, so a silent cancel says what caused it.
    public static func label(for type: CGEventType) -> String {
        switch type {
        case .keyDown: return "key"
        case .flagsChanged: return "modifier"
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return "click"
        case .scrollWheel: return "scroll"
        default: return "input"
        }
    }

    /// Event types the passive key-up check asks `CGEventSource` about. `secondsSinceLastEventType`
    /// carries no phase, so it cannot tell a momentum tail from a scroll: while the active tap feeds
    /// the service (it reports real scrolls itself, with their phases) scroll is left out here.
    public static func passiveTypes(includeScroll: Bool) -> [CGEventType] {
        let base: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return includeScroll ? base + [.scrollWheel] : base
    }
}
