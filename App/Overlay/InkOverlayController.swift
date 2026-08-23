import AppKit
import Actions

/// Owns one `OverlayWindow` per display, mirrors live strokes from `InkStrokeCapture`, and pulses
/// bound regions. Main-thread only for AppKit calls; the sink callbacks hop to main.
@MainActor
public final class InkOverlayController {
    var windows: [UInt32: OverlayWindow] = [:]
    private(set) var normalizer: DisplayNormalizer
    public private(set) var bundle = RegionBundleCounter()
    /// Called whenever the bundle counter changes so the pill can show "3 regions".
    public var onBundleChanged: ((String?) -> Void)?

    public init(normalizer: DisplayNormalizer = .current()) {
        self.normalizer = normalizer
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildWindows() }
        }
    }

    public func show() {
        if windows.isEmpty { rebuildWindows() }
        windows.values.forEach { $0.orderFrontRegardless() }
    }

    public func hide() {
        windows.values.forEach { $0.inkView.clearAll(); $0.orderOut(nil) }
        bundle.reset()
        onBundleChanged?(nil)
    }

    /// Region pulse for a resolved deictic binding. `region.frame` is Cocoa global.
    public func pulse(_ region: BoundRegion) {
        show()
        bundle.add(region)
        onBundleChanged?(bundle.pillText)
        guard let w = windows[region.displayID] else { return }
        let local = region.frame.offsetBy(dx: -w.display.frame.minX, dy: -w.display.frame.minY)
        w.inkView.pulse(localRect: local)
    }

    func rebuildWindows() {
        normalizer = .current()
        windows.values.forEach { $0.orderOut(nil) }
        windows.removeAll()
        for d in normalizer.displays {
            let screen = NSScreen.screens.first { $0.frame == d.frame }
            windows[d.id] = OverlayWindow(display: d, screen: screen)
        }
    }

    private func render(_ stroke: InkStroke) {
        show()
        // A stroke that crosses displays is drawn per display with that display's local coordinates.
        for id in stroke.displayIDs {
            guard let w = windows[id] else { continue }
            let pts = stroke.points.filter { $0.point.displayID == id }
            w.inkView.draw(stroke: stroke.id, localPoints: pts.map { normalizer.local($0.point) },
                           pressures: pts.map { CGFloat($0.pressure) })
        }
    }
}

extension InkOverlayController: InkStrokeSink {
    nonisolated public func strokeBegan(_ stroke: InkStroke) { Task { @MainActor in self.render(stroke) } }
    nonisolated public func strokeChanged(_ stroke: InkStroke) { Task { @MainActor in self.render(stroke) } }
    nonisolated public func strokeEnded(_ stroke: InkStroke) {
        Task { @MainActor in
            self.render(stroke)
            self.windows.values.forEach { $0.inkView.finish(stroke: stroke.id) }
        }
    }
}
