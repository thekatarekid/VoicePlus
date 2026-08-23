import AppKit
import Combine
import Shared
import SwiftUI

/// Borderless, non-activating `NSPanel` that slides out from under the notch (T2).
/// Slide in/out ≤150 ms; every animation is interruptible (each transition cancels the previous).
public final class PillPanelController {
    public let model = PillViewModel()
    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private var lastState: PillState = .hidden

    public init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        cancellable = model.$state.receive(on: DispatchQueue.main).sink { [weak self] state in self?.render(state) }
    }

    /// Screen metrics for the screen under the mouse (falls back to main).
    public static func currentMetrics() -> ScreenMetrics? {
        let all = NSScreen.screens.map(metrics(for:))
        let main = NSScreen.main.map(metrics(for:))
        return NotchGeometry.hostScreen(screens: all, mouse: NSEvent.mouseLocation, main: main)
    }

    static func metrics(for screen: NSScreen) -> ScreenMetrics {
        var notchWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        }
        return ScreenMetrics(frame: screen.frame, topInset: screen.safeAreaInsets.top, notchWidth: notchWidth,
                             menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func render(_ state: PillState) {
        defer { lastState = state }
        guard let metrics = Self.currentMetrics() else { return }
        let layout = NotchGeometry.layout(for: metrics, size: NotchGeometry.size(for: state))
        if let host = panel.contentView as? NSHostingView<PillView> {
            host.rootView = PillView(model: model, cornerRadius: layout.cornerRadius)
        }
        switch (lastState.isVisible, state.isVisible) {
        case (false, true):
            panel.setFrame(layout.retracted, display: false)
            panel.orderFrontRegardless()
            animate(to: layout.shown)
        case (true, false):
            animate(to: layout.retracted) { [weak self] in
                if self?.model.state.isVisible == false { self?.panel.orderOut(nil) }
            }
        case (true, true):
            animate(to: layout.shown)
        case (false, false):
            break
        }
    }

    private func animate(to frame: NSRect, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }
}
