import AppKit
import QuartzCore
import Actions

/// One transparent, click-through, full-screen window per display. Sits above the status bar so ink
/// is visible over menus and the pill. Coordinates handed to it are display-local (bottom-left).
final class OverlayWindow: NSWindow {
    let display: DisplayFrame
    let inkView = InkLayerView()

    init(display: DisplayFrame, screen: NSScreen?) {
        self.display = display
        super.init(contentRect: display.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-hosting view: one `CAShapeLayer` per stroke, one per pulse. Fades run as CA animations
/// scheduled by `FadeSchedule`.
final class InkLayerView: NSView {
    var style = StrokeStyle()
    var inkColor = NSColor.systemOrange
    var pulseColor = NSColor.systemBlue
    var fade = FadeSchedule(start: 0, hold: 0.2, duration: 1.5)
    private var strokeLayers: [UUID: CAShapeLayer] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func draw(stroke id: UUID, localPoints: [CGPoint], pressures: [CGFloat]) {
        let layer = strokeLayers[id] ?? makeStrokeLayer(id: id)
        layer.removeAllAnimations()
        layer.opacity = 1
        let outline = StrokeGeometry.outline(points: localPoints, pressures: pressures, style: style,
                                             seed: StrokeGeometry.seed(for: id))
        layer.path = StrokeGeometry.path(outline: outline)
    }

    func finish(stroke id: UUID) {
        guard let layer = strokeLayers[id] else { return }
        let schedule = fade.extended(from: CACurrentMediaTime())
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1; anim.toValue = 0
        anim.beginTime = schedule.fadeBegins
        anim.duration = schedule.duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "fade")
        strokeLayers[id] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + schedule.end - schedule.start + 0.05) {
            layer.removeFromSuperlayer()
        }
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
        strokeLayers.removeAll()
    }

    private func makeStrokeLayer(id: UUID) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.fillColor = inkColor.cgColor
        l.strokeColor = nil
        l.lineJoin = .round
        layer?.addSublayer(l)
        strokeLayers[id] = l
        return l
    }
}
