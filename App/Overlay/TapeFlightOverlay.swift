import Actions
import AppKit
import SwiftUI

/// S4 — the live flight surface: its own instance of the ink overlay's `OverlayWindow` (transparent,
/// click-through, never key, above the pill) on the display the flight runs on, drawing the ribbon with
/// the same `SpoolCanvas` renderer as the pill. The window covers the display so the ribbon can leave
/// the pill's bounds; it ignores the pointer, so it never traps a click or obscures a control for more
/// than the flight's second. Ordered out whenever nothing flies. Main thread.
final class TapeFlightOverlay: TapeFlightSurface {
    private var window: OverlayWindow?
    private let model = TapeFlightOverlayModel()

    init() {}

    func show(_ run: TapeFlightRun) {
        let window = window(for: run.path.display)
        model.run = run
        window.orderFrontRegardless()
    }

    func clear() {
        model.run = nil
        window?.orderOut(nil)
    }

    private func window(for display: DisplayFrame) -> OverlayWindow {
        if let window, window.display == display { return window }
        window?.orderOut(nil)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
