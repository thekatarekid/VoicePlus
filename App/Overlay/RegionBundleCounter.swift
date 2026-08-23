import Foundation
import CoreGraphics

/// A region the deixis resolver bound a word to (AX element frame, stroke bounds, or a point).
public struct BoundRegion: Equatable, Hashable, Sendable {
    public var frame: CGRect
    public var displayID: UInt32
    public var windowID: UInt32?
    public var pid: pid_t?

    public init(frame: CGRect, displayID: UInt32, windowID: UInt32? = nil, pid: pid_t? = nil) {
        self.frame = frame; self.displayID = displayID; self.windowID = windowID; self.pid = pid
    }
}

/// Counts distinct regions bound during one utterance for the pill ("3 regions") — shown only when
/// the utterance spans more than one window or display, per spec.
public struct RegionBundleCounter: Equatable, Sendable {
    public private(set) var regions: [BoundRegion] = []
    /// Two regions whose frames overlap by more than this IoU are the same region.
    public var mergeIoU: CGFloat = 0.6

    public init() {}

    public mutating func add(_ r: BoundRegion) {
        if regions.contains(where: { $0.displayID == r.displayID && Self.iou($0.frame, r.frame) >= mergeIoU }) { return }
        regions.append(r)
    }

    public mutating func reset() { regions.removeAll() }

    public var count: Int { regions.count }
    public var displayCount: Int { Set(regions.map(\.displayID)).count }
    public var windowCount: Int { Set(regions.compactMap(\.windowID)).count }
    public var spansWindows: Bool { displayCount > 1 || windowCount > 1 }

    /// Pill text; nil when a count would be noise (≤1 region or everything in one window).
    public var pillText: String? {
        guard count > 1, spansWindows else { return nil }
        return "\(count) regions"
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return a == b ? 1 : 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }
}
