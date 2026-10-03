import Actions
import AppKit
import Shared
import SwiftUI

/// S4 — the live flight surface: its own instance of the ink overlay's `OverlayWindow` (transparent,
/// click-through, never key, above the pill) on the display the flight runs on, drawing the ribbon with
/// the same `SpoolCanvas` renderer as the pill. The window covers the display so the ribbon can leave
/// the pill's bounds; it ignores the pointer, so it never traps a click or obscures a control for more
/// than the flight's second. Ordered out whenever nothing flies. Main thread.
final class TapeFlightOverlay: TapeFlightSurface {
    private var window: OverlayWindow?
    private let model = TapeFlightOverlayModel()
    /// Fix notch — whether the last `show` left the window on the active Space.
    private(set) var lastShowVisible: Bool?

    init() {}

    func show(_ run: TapeFlightRun) {
        model.run = run
        lastShowVisible = orderIn(display: run.path.display)
    }

    func clear() {
        model.run = nil
        orderOutIfEmpty()
    }

    /// The destination tape cue, in the same click-through window (design §13 scenario 4).
    func showCue(_ cue: TapeFieldCue) {
        model.cue = cue
        orderIn(display: cue.display)
    }

    /// Fix notch — orders the overlay in on the active Space. A window that macOS left on no Space
    /// (WindowServer "none→hidden") is rebuilt once, because a new window joins every Space.
    @discardableResult
    private func orderIn(display: DisplayFrame) -> Bool {
        if SpaceMembership.orderIn([window(for: display)]) != .offActiveSpace { return true }
        Log.app.warning("ribbon: overlay ordered in but not on the active Space — rebuilding its window")
        discardWindow()
        return SpaceMembership.orderIn([window(for: display)]) != .offActiveSpace
    }

    private func discardWindow() {
        window?.orderOut(nil)
        window?.inkView.subviews.forEach { $0.removeFromSuperview() }
        window = nil
    }

    func clearCue() {
        model.cue = nil
        orderOutIfEmpty()
    }

    private func orderOutIfEmpty() {
        guard model.run == nil, model.cue == nil else { return }
        window?.orderOut(nil)
    }

    private func window(for display: DisplayFrame) -> OverlayWindow {
        if let window, window.display == display { return window }
        discardWindow()
        let screen = NSScreen.screens.first { $0.frame == display.frame }
        let window = OverlayWindow(display: display, screen: screen)
        // Placement is the display's frame, never content: no minimum size may leak into the window.
        let host = NSHostingView(rootView: TapeFlightCanvas(model: model))
        host.sizingOptions = []
        host.frame = window.inkView.bounds
        host.autoresizingMask = [.width, .height]
        window.inkView.addSubview(host)
        self.window = window
        return window
    }
}

final class TapeFlightOverlayModel: ObservableObject {
    @Published var run: TapeFlightRun?
    @Published var cue: TapeFieldCue?
}

/// The ribbon, frame by frame from the flight's start to its end (`SpoolFrameSchedule`, S1), in the
/// display's overlay space: the drawing's viewBox is the display's size, so it maps 1:1 onto the window.
struct TapeFlightCanvas: View {
    @ObservedObject var model: TapeFlightOverlayModel

    var body: some View {
        ZStack {
            if let run = model.run {
                TimelineView(SpoolFrameSchedule(end: run.end)) { context in
                    Canvas { ctx, size in
                        guard let frame = run.frame(at: context.date) else { return }
                        SpoolCanvas.draw(frame.drawing, in: &ctx, size: size)
                    }
                }
                .id(run.id)
            }
            if let cue = model.cue {
                TimelineView(SpoolFrameSchedule(end: cue.end)) { context in
                    Canvas { ctx, _ in TapeFieldCueDrawing.draw(cue, at: context.date, in: &ctx) }
                }
                .id(cue.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The prototype's `.field-line`: tape-face fill, a 1 pt tape-edge top border, `linefade` opacity.
enum TapeFieldCueDrawing {
    static func draw(_ cue: TapeFieldCue, at date: Date, in ctx: inout GraphicsContext) {
        let opacity = cue.opacity(at: date)
        guard opacity > 0 else { return }
        ctx.opacity = opacity
        for rect in cue.rects {
            ctx.fill(Path(rect), with: .color(Tokens.SpoolMaterial.tapeFace.color))
            let edge = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: TapeFieldCue.edge)
            ctx.fill(Path(edge), with: .color(Tokens.SpoolMaterial.tapeEdge.color))
        }
    }
}
