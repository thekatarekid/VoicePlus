import AppKit
import SwiftUI

/// S4 — Spool's anchors on the screen: the tape flight's source (design §4 "Mouth-to-caret tape path":
/// "anchor its source to the transformed mouth slot").
///
/// `SpoolView` reports its anchors in window coordinates (SwiftUI's global space, top-left origin) every
/// frame it draws, and a probe view reports the window it is drawn in. The mouth is converted to AppKit
/// screen coordinates when it is read, against the window's frame at that moment, so a pill that moves
/// or resizes mid-flight is followed. Main thread only.
final class SpoolAnchorTracker {
    /// The last anchors drawn, in window coordinates. `nil` until the first frame, and once no view is
    /// in a window any more.
    private(set) var anchors: SpoolAnchors?
    /// Called each time a Spool view lands in a window (the pill's first frame after a hidden stretch).
    var onWindow: ((NSWindow) -> Void)?
    /// Whatever follows these anchors (the tape flight); kept alive with the tracker's owner.
    var subscriber: AnyObject?

    /// Probe views: a state change can build the new `SpoolView` before the old one leaves.
    private var probes: [WeakView] = []

    private struct WeakView {
        weak var view: NSView?
    }

    init(onWindow: ((NSWindow) -> Void)? = nil) {
        self.onWindow = onWindow
    }

    /// The window the view is drawn in.
    var window: NSWindow? {
        probes.lazy.compactMap { $0.view?.window }.first
    }

    func update(_ anchors: SpoolAnchors) {
        self.anchors = anchors
    }

    /// A probe moved into or out of a window.
    func probeMoved(_ probe: NSView) {
        probes.removeAll { $0.view == nil }
        if !probes.contains(where: { $0.view === probe }) { probes.append(WeakView(view: probe)) }
        if let window = probe.window {
            onWindow?(window)
        } else {
            probes.removeAll { $0.view === probe }
            if window == nil { anchors = nil }
        }
    }

    /// The mouth in AppKit screen coordinates (points, bottom-left origin of the primary display), or
    /// `nil` when nothing is drawn or the window is not on screen.
    var mouthOnScreen: CGPoint? {
        guard let anchors, let window, window.isVisible else { return nil }
        let content = window.contentView?.frame ?? CGRect(origin: .zero, size: window.frame.size)
        return SpoolScreenGeometry.screenPoint(anchors.mouthAnchor, windowFrame: window.frame, contentFrame: content)
    }
}

/// Pure conversion from a SwiftUI global point to the screen.
enum SpoolScreenGeometry {
    /// `point` is in the hosting view's space (top-left origin, y down: SwiftUI's `.global` inside an
    /// `NSHostingView` that is the window's content view). `contentFrame` is the content view's frame in
    /// the window (bottom-left origin); `windowFrame` is the window's frame on screen. Points throughout:
    /// the result does not depend on the display's backing scale.
    static func screenPoint(_ point: CGPoint, windowFrame: CGRect, contentFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + contentFrame.minX + point.x,
                y: windowFrame.minY + contentFrame.maxY - point.y)
    }
}

/// A zero-size, pointer-transparent view that tells a tracker which window Spool is drawn in.
struct SpoolWindowProbe: NSViewRepresentable {
    let tracker: SpoolAnchorTracker

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(tracker: tracker)
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        guard view.tracker !== tracker else { return }
        view.tracker = tracker
        tracker.probeMoved(view)
    }

    final class ProbeView: NSView {
        weak var tracker: SpoolAnchorTracker?

        init(tracker: SpoolAnchorTracker) {
            self.tracker = tracker
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tracker?.probeMoved(self)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
