import AppKit
import QuartzCore
import Actions

/// One transparent, click-through, full-screen window per display. Sits above the status bar so a
/// drawn box is visible over menus and the pill. Coordinates handed to it are display-local
/// (bottom-left). Ordered front only while the dictation key is down (V4.31).
final class OverlayWindow: NSWindow {
    let display: DisplayFrame
    /// The drawing surface: boxes, pulses, and the agent cursor's host layer.
    let inkView = RegionLayerView()

    init(display: DisplayFrame, screen: NSScreen?) {
        self.display = display
        // Four arguments, not five — and then place the window explicitly.
        //
        // This is the 1.6.6 "pressing the dictation key kills VoicePlus" crash. `OverlayWindow`
        // declares its own designated initializer and has stored properties with no defaults, so it
        // inherits none of `NSWindow`'s initializers; for the designated one it does not override,
        // the Swift compiler emits an @objc *trap stub*. Line 13 used to call the five-argument
        // `super.init(contentRect:styleMask:backing:defer:screen:)`, which is an ObjC convenience
        // initializer: AppKit re-dispatches it dynamically through `self` to
        // `initWithContentRect:styleMask:backing:defer:` — and landed on that stub. Every
        // `InkOverlayController.show()` therefore died with
        // "Fatal error: Use of unimplemented initializer" / EXC_BREAKPOINT, on every Mac, 100% of
        // the time, from the first keypress. `screen` was never the issue: the trap fires with a nil
        // screen and a single display too.
        //
        // `display.frame` is Cocoa global coordinates (`rebuildWindows` matches it against
        // `NSScreen.frame`), so `setFrame` places the window on the intended display without the
        // five-argument initializer's screen-relative interpretation.
        super.init(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(display.frame, display: false)
        _ = screen
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        inkView.frame = CGRect(origin: .zero, size: display.frame.size)
        contentView = inkView
    }

    /// The other half of the fix, and the durable half: overriding `NSWindow`'s designated
    /// initializer means the compiler emits no trap stub for it at all, so no AppKit path — present
    /// or future — can re-dispatch into one. Not called by our own code.
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        display = DisplayFrame(id: 0, frame: contentRect)
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        contentView = inkView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-hosting view: one `CAShapeLayer` per drawn box, one per pulse. Fades run as CA
/// animations scheduled by `FadeSchedule`.
final class RegionLayerView: NSView {
    var style = RegionStyle.crisp
    /// Orange on any content (V4.27).
    var boxColor = NSColor.systemOrange
    var pulseColor = NSColor.systemBlue
    /// The 1.5 s fade after the utterance.
    var fade = FadeSchedule(start: 0, hold: 0, duration: 1.5)
    private(set) var boxLayers: [UUID: CAShapeLayer] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// Draw (or redraw while dragging) a box at a display-local rect.
    func draw(region id: UUID, localRect: CGRect) {
        let layer = boxLayers[id] ?? makeBoxLayer(id: id)
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.lineWidth = style.lineWidth
        let rect = RegionGeometry.pixelAligned(localRect, scale: backingScale, lineWidth: style.lineWidth)
        layer.path = RegionGeometry.path(for: rect, style: style, seed: RegionGeometry.seed(for: id))
    }

    /// A drag too small to be a box: take it away at once.
    func discard(region id: UUID) {
        boxLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    }

    /// Fade every box over `fade.duration`, then remove it. Returns the seconds until all are gone.
    @discardableResult
    func fadeAll() -> TimeInterval {
        let schedule = fade.extended(from: CACurrentMediaTime())
        let layers = Array(boxLayers.values)
        boxLayers.removeAll()
        for layer in layers {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1; anim.toValue = 0
            anim.beginTime = schedule.fadeBegins
            anim.duration = schedule.duration
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "fade")
        }
        let total = schedule.end - schedule.start
        DispatchQueue.main.asyncAfter(deadline: .now() + total + 0.05) {
            layers.forEach { $0.removeFromSuperlayer() }
        }
        return total
    }

    func pulse(localRect: CGRect, spec: PulseSpec = PulseSpec()) {
        let l = CALayer()
        l.frame = spec.frame(for: localRect)
        l.cornerRadius = spec.cornerRadius
        l.borderWidth = 2
        l.borderColor = pulseColor.cgColor
        l.backgroundColor = pulseColor.withAlphaComponent(0.18).cgColor
        l.opacity = 0
        layer?.addSublayer(l)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1; scale.toValue = spec.scale
        let fadeA = CAKeyframeAnimation(keyPath: "opacity")
        fadeA.values = [0, spec.peakOpacity, 0]; fadeA.keyTimes = [0, 0.3, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fadeA]
        group.duration = spec.duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        l.add(group, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + spec.duration + 0.05) { l.removeFromSuperlayer() }
    }

    func clearAll() {
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        boxLayers.removeAll()
    }

    private func makeBoxLayer(id: UUID) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = nil
        l.strokeColor = boxColor.cgColor
        l.lineWidth = style.lineWidth
        l.lineCap = .round
        l.lineJoin = .miter
        l.contentsScale = backingScale
        layer?.addSublayer(l)
        boxLayers[id] = l
        return l
    }
}
