import SwiftUI

// S10 — reading and keyboard order in the pill (design §11: "Tab reaches actions in reading order").
// The pill's rows are pinned into a ZStack by rect, so their order in the view tree is not a promise
// of the order assistive technology walks them in. These priorities make it one: status row, words,
// chip row, level readout, helper row (with "N words · Review all"), then the action row left to
// right — the primary recovery first, exactly as drawn. Held and error rows are where it matters.

public enum PillReadingOrder {
    public enum Region: Int, CaseIterable, Sendable {
        case status, words, chips, levelReadout, helper, actions
    }

    /// `accessibilitySortPriority` of a region: higher is read first.
    public static func priority(_ region: Region) -> Double {
        Double(Region.allCases.count - region.rawValue) * 100
    }

    /// Priority of the `index`th of `count` buttons in the action row, inside the row: left first.
    public static func actionPriority(index: Int, count: Int) -> Double {
        Double(max(0, count - index))
    }

    /// One stop of the keyboard / VoiceOver focus chain.
    public struct Stop: Equatable, Sendable {
        public var label: String
        public var identifier: String
        public var action: PillActionKind
        public var primary: Bool
    }

    /// The controls a keyboard or VoiceOver user reaches in `content`, in order: the helper row's
    /// "N words · Review all" (when the final text overflows), then the action row's buttons left to
    /// right. Nothing else in the pill takes focus.
    public static func focusChain(_ content: PillContent, overflowLabel: String? = nil) -> [Stop] {
        var stops: [Stop] = []
        if let overflowLabel, !content.escapeHint {
            stops.append(Stop(label: overflowLabel, identifier: "pill.action.reviewAll", action: .reviewAll, primary: false))
        }
        stops += content.buttons.map { Stop(label: $0.label, identifier: $0.identifier, action: $0.action, primary: $0.primary) }
        return stops
    }

    /// The priority each stop of `focusChain` gets, in the same order (strictly decreasing).
    public static func chainPriorities(_ content: PillContent, overflowLabel: String? = nil) -> [Double] {
        var out: [Double] = []
        if overflowLabel != nil, !content.escapeHint { out.append(priority(.helper)) }
        let count = content.buttons.count
        out += (0..<count).map { priority(.actions) + actionPriority(index: $0, count: count) / Double(count + 1) }
        return out
    }
}
