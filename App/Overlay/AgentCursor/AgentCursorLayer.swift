import AppKit
import QuartzCore

/// Every deterministic/agentic action animates through this. Implementations draw the *agent's*
/// cursor on the overlay — they must never call `CGWarpMouseCursorPosition`/`NSCursor` on the
/// user's pointer. Points are Cocoa global.
@MainActor
public protocol ActionAnimating: AnyObject {
    func glide(to point: CGPoint, then: (@MainActor () -> Void)?)
    func click(at point: CGPoint)
    func typing(at point: CGPoint, characters: Int)
    func highlight(_ rect: CGRect)
    func dismiss()
}

/// CALayer tree for the agent cursor: tinted pointer dot + soft glow halo + wisp particle layers,
/// hosted on an `InkLayerView` of the existing overlay window. Drives `AgentCursorModel` on a
/// display-link-free 60 Hz timer (CA handles interpolation of the pointer itself; wisps are ours).
@MainActor
public final class AgentCursorLayer {
    public private(set) var model: AgentCursorModel
    public var tint = NSColor.systemTeal
    let root = CALayer()
    private let halo = CALayer()
    private let dot = CALayer()
    private let wispHost = CALayer()
    private var wispLayers: [CALayer] = []
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private(set) weak var host: CALayer?

    public init(model: AgentCursorModel = AgentCursorModel()) {
        self.model = model
        root.opacity = 0
        halo.bounds = CGRect(x: 0, y: 0, width: 44, height: 44); halo.cornerRadius = 22
        dot.bounds = CGRect(x: 0, y: 0, width: 14, height: 14); dot.cornerRadius = 7
        dot.borderWidth = 1.5; dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        applyTint()
        root.addSublayer(wispHost); root.addSublayer(halo); root.addSublayer(dot)
    }

    /// Attach to a layer-hosting view (the overlay's `InkLayerView`). Idempotent.
    public func attach(to hostLayer: CALayer) {
        guard host !== hostLayer else { return }
        root.removeFromSuperlayer(); hostLayer.addSublayer(root); host = hostLayer
        root.frame = hostLayer.bounds
    }

    public func detach() { stopTimer(); root.removeFromSuperlayer(); host = nil }

    private func applyTint() {
        halo.backgroundColor = tint.withAlphaComponent(0.35).cgColor
        dot.backgroundColor = tint.cgColor
        halo.shadowColor = tint.cgColor; halo.shadowOpacity = 0.9; halo.shadowRadius = 12
    }

    /// Run a keyframe list through CA (position/glow/scale) and mirror the end state into the model.
    public func play(_ frames: [AgentCursorModel.Keyframe], completion: (@MainActor () -> Void)? = nil) {
        guard let lastF = frames.last else { completion?(); return }
        show()
        let duration = max(lastF.time, 0.001)
        let times = frames.map { NSNumber(value: $0.time / duration) }
        func anim(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: key); a.values = values; a.keyTimes = times
            a.duration = duration; a.calculationMode = .cubic; return a
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { Task { @MainActor in completion?() } }
        for l in [halo, dot] {
            l.add(anim("position", frames.map { NSValue(point: $0.position) }), forKey: "pos")
            l.add(anim("transform.scale", frames.map { $0.scale }), forKey: "scale")
            l.position = lastF.position
        }
        halo.add(anim("opacity", frames.map { $0.glow }), forKey: "glow"); halo.opacity = Float(lastF.glow)
        CATransaction.commit()
        // Wisp trail follows the same path in model space.
        for f in frames { model.move(to: f.position) }
        model.glow = lastF.glow; model.scale = lastF.scale
    }

    func show() {
        guard !model.visible else { return }
        model.visible = true; root.opacity = 1; startTimer()
    }

    private func startTimer() {
        stopTimer(); last = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    func tick() {
        let now = CACurrentMediaTime(); model.tick(now - last); last = now
        renderWisps()
    }

    func renderWisps() {
        while wispLayers.count < model.wisps.count {
            let l = CALayer(); l.backgroundColor = tint.cgColor; wispHost.addSublayer(l); wispLayers.append(l)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, l) in wispLayers.enumerated() {
            if i < model.wisps.count {
                let w = model.wisps[i]
                l.isHidden = false; l.opacity = Float(w.alpha)
                l.bounds = CGRect(x: 0, y: 0, width: w.size, height: w.size); l.cornerRadius = w.size / 2
                l.position = w.position
            } else { l.isHidden = true }
        }
        CATransaction.commit()
    }
}

extension AgentCursorLayer: ActionAnimating {
    public func glide(to point: CGPoint, then: (@MainActor () -> Void)?) {
        play(model.glideKeyframes(to: point), completion: then)
    }
    public func click(at point: CGPoint) {
        glide(to: point) { [weak self] in self?.play(AgentCursorModel.clickKeyframes(at: point)) }
    }
    public func typing(at point: CGPoint, characters: Int) {
        glide(to: point) { [weak self] in self?.play(AgentCursorModel.typingKeyframes(at: point, chars: characters)) }
    }
    public func highlight(_ rect: CGRect) {
        let l = CALayer(); l.frame = rect.insetBy(dx: -4, dy: -4); l.cornerRadius = 6
        l.borderWidth = 2; l.borderColor = tint.cgColor; l.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        root.insertSublayer(l, below: wispHost)
        let a = CABasicAnimation(keyPath: "opacity"); a.fromValue = 1; a.toValue = 0; a.beginTime = CACurrentMediaTime() + 0.8
        a.duration = 0.5; a.fillMode = .both; a.isRemovedOnCompletion = false; l.add(a, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { l.removeFromSuperlayer() }
        glide(to: CGPoint(x: rect.midX, y: rect.midY), then: nil)
    }
    public func dismiss() {
        model.visible = false; model.wisps.removeAll(); renderWisps()
        root.removeAllAnimations(); root.opacity = 0; stopTimer()
    }
}

/// Routes global-coordinate actions to the right display's overlay window, one cursor layer per window.
@MainActor
public final class AgentCursorController: ActionAnimating {
    private var layers: [UInt32: AgentCursorLayer] = [:]
    private let overlay: InkOverlayController
    public init(overlay: InkOverlayController) { self.overlay = overlay }

    private func layer(for p: CGPoint) -> (AgentCursorLayer, CGPoint)? {
        overlay.show()
        guard let w = overlay.window(containing: p) else { return nil }
        let l = layers[w.display.id] ?? { let n = AgentCursorLayer(); layers[w.display.id] = n; return n }()
        if let host = w.inkView.layer { l.attach(to: host) }
        return (l, CGPoint(x: p.x - w.display.frame.minX, y: p.y - w.display.frame.minY))
    }
    public func glide(to point: CGPoint, then: (@MainActor () -> Void)?) {
        guard let (l, p) = layer(for: point) else { then?(); return }; l.glide(to: p, then: then)
    }
    public func click(at point: CGPoint) { if let (l, p) = layer(for: point) { l.click(at: p) } }
    public func typing(at point: CGPoint, characters: Int) { if let (l, p) = layer(for: point) { l.typing(at: p, characters: characters) } }
    public func highlight(_ rect: CGRect) {
        if let (l, p) = layer(for: CGPoint(x: rect.midX, y: rect.midY)) {
            l.highlight(CGRect(x: p.x - rect.width / 2, y: p.y - rect.height / 2, width: rect.width, height: rect.height))
        }
    }
    public func dismiss() { layers.values.forEach { $0.dismiss() } }
}

extension InkOverlayController {
    /// Window whose display contains the Cocoa-global point (falls back to the first window).
    func window(containing p: CGPoint) -> OverlayWindow? {
        if windows.isEmpty { rebuildWindows() }
        return windows.values.first { $0.display.frame.contains(p) } ?? windows.values.first
    }
}
