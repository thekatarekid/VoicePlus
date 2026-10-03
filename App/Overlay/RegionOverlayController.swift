import AppKit
import Shared
import Actions

/// What the key controller needs from the overlay: front while the key is down, gone after.
@MainActor
public protocol DeixisOverlaying: AnyObject {
    /// Order the overlay front (the dictation key went down).
    func show()
    /// Take it away: boxes fade over 1.5 s first when `fading`, otherwise they go at once.
    func hide(fading: Bool)
}

/// Owns one `OverlayWindow` per display, draws the box being dragged (G1, from `RegionCapture`),
/// and pulses bound regions. The windows are ordered front only while the dictation key is down
/// (V4.31); boxes fade 1.5 s after the utterance. Main-thread only for AppKit calls; the sink
/// callbacks hop to main.
@MainActor
public final class RegionOverlayController: DeixisOverlaying {
    var windows: [UInt32: OverlayWindow] = [:]
    private(set) var normalizer: DisplayNormalizer
    public private(set) var bundle = RegionBundleCounter()
    /// Called whenever the bundle counter changes so the pill can show "3 regions".
    public var onBundleChanged: ((String?) -> Void)?
    /// Whether the windows are ordered front.
    public private(set) var isShown = false
    /// Shown because the key is down (as opposed to a box drawn without the key in latch).
    private var shownByKey = false
    private var hideGeneration = 0

    public init(normalizer: DisplayNormalizer = .current()) {
        self.normalizer = normalizer
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildWindows() }
        }
    }

    public func show() {
        shownByKey = true
        orderFront()
    }

    /// Key up, cancel, entering latch. `fading`: the utterance's boxes fade over 1.5 s and the
    /// windows go when the fade ends (unless the key went down again first).
    public func hide(fading: Bool) {
        shownByKey = false
        bundle.reset()
        onBundleChanged?(nil)
        takeAway(fading: fading)
    }

    /// Clear or fade the boxes, then order the windows out — unless something draws or the key
    /// goes down again first.
    private func takeAway(fading: Bool) {
        hideGeneration += 1
        guard fading else {
            windows.values.forEach { $0.inkView.clearAll(); $0.orderOut(nil) }
            isShown = false
            return
        }
        let generation = hideGeneration
        let wait = windows.values.map { $0.inkView.fadeAll() }.max() ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.05) { [weak self] in
            guard let self, self.hideGeneration == generation, !self.shownByKey else { return }
            self.windows.values.forEach { $0.orderOut(nil) }
            self.isShown = false
        }
    }

    /// The act key's release (P4): fade like the dictation key.
    public func hide() { hide(fading: true) }

    /// Region pulse for a resolved deictic binding. `region.frame` is Cocoa global.
    public func pulse(_ region: BoundRegion) {
        orderFront()
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
        if isShown { windows.values.forEach { SpaceMembership.orderIn([$0]) } }
    }

    private func orderFront() {
        hideGeneration += 1
        if windows.isEmpty { rebuildWindows() }
        // Fix notch — rejoin every Space before ordering in; a window macOS left on no Space is
        // rebuilt, because a new window joins every Space when it is first ordered in.
        let outcomes = windows.values.map { SpaceMembership.orderIn([$0]) }
        isShown = true
        if outcomes.contains(.offActiveSpace) {
            Log.app.warning("ink overlay: ordered in but not on the active Space — rebuilding its windows")
            rebuildWindows()
        }
    }

    fileprivate func render(_ region: DrawnRegion) {
        // Drawing cancels a pending order-out (a box started while the last one was fading).
        if isShown { hideGeneration += 1 } else { orderFront() }
        windows[region.displayID]?.inkView.draw(region: region.id, localRect: region.displayRect)
    }

    fileprivate func finish(_ region: DrawnRegion) {
        render(region)
        noteBox(region)
        // A box drawn without the key (latch, "draw without a key") has no key-up to fade it; the
        // utterance's bundle stays until the key or the turn takes the overlay away.
        if !shownByKey { takeAway(fading: true) }
    }

    fileprivate func discard(_ region: DrawnRegion) {
        windows[region.displayID]?.inkView.discard(region: region.id)
        if !shownByKey, isShown { takeAway(fading: true) }
    }

    /// V4.27 — several boxes in one utterance bundle like any bound region ("3 regions" when they
    /// span displays or windows).
    func noteBox(_ region: DrawnRegion) {
        bundle.add(BoundRegion(frame: region.rect, displayID: region.displayID))
        onBundleChanged?(bundle.pillText)
    }
}

/// The name the composition root has always used for the overlay.
public typealias InkOverlayController = RegionOverlayController

extension RegionOverlayController: RegionSink {
    nonisolated public func regionBegan(_ region: DrawnRegion) { Task { @MainActor in self.render(region) } }
    nonisolated public func regionChanged(_ region: DrawnRegion) { Task { @MainActor in self.render(region) } }
    nonisolated public func regionEnded(_ region: DrawnRegion) { Task { @MainActor in self.finish(region) } }
    nonisolated public func regionDiscarded(_ region: DrawnRegion) { Task { @MainActor in self.discard(region) } }
}
