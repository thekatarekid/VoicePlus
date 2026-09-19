import SwiftUI

/// Where Spool's tape leaves the mouth slot and where the pill's tape lane meets the cassette inlet,
/// in window coordinates (SwiftUI's global space: points from the top-left of the hosting window's
/// content). S4 converts them to screen coordinates for the tape flight.
struct SpoolAnchors: Equatable, Sendable {
    /// Centre of the mouth slot (`data-spool-mouth`): where the tape flight leaves Spool.
    var mouthAnchor: CGPoint
    /// The cassette's tape inlet: where the pill's tape lane ends.
    var inletAnchor: CGPoint

    /// Maps a frame's viewBox points into a view of `size` whose top-left sits at `origin`.
    init(frame: SpoolScene.Frame, size: CGSize, origin: CGPoint) {
        let viewport = SpoolViewport(viewBox: frame.drawing.viewBox, size: size)
        let mouth = viewport.map(frame.mouth), inlet = viewport.map(frame.inlet)
        mouthAnchor = CGPoint(x: origin.x + mouth.x, y: origin.y + mouth.y)
        inletAnchor = CGPoint(x: origin.x + inlet.x, y: origin.y + inlet.y)
    }

    init(mouthAnchor: CGPoint, inletAnchor: CGPoint) {
        self.mouthAnchor = mouthAnchor
        self.inletAnchor = inletAnchor
    }
}

struct SpoolAnchorsPreferenceKey: PreferenceKey {
    static var defaultValue: SpoolAnchors? { nil }
    static func reduce(value: inout SpoolAnchors?, nextValue: () -> SpoolAnchors?) {
        value = nextValue() ?? value
    }
}

/// Frames for Spool's loop: every display frame from `from` until `end`, then one last frame at `end`;
/// a single frame when `end` is `nil` (Reduce Motion, hidden, cameo) or the system asks for low
/// frequency updates. `end == .distantFuture` runs until the state changes (build doc S1.5).
struct SpoolFrameSchedule: TimelineSchedule {
    var end: Date?
    var interval: TimeInterval = 1.0 / 60

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(next: startDate, end: mode == .lowFrequency ? nil : end, interval: interval)
    }

    struct Entries: Sequence, IteratorProtocol {
        private var upcoming: Date?
        private let end: Date?
        private let interval: TimeInterval

        init(next: Date, end: Date?, interval: TimeInterval) {
            upcoming = next
            self.end = end
            self.interval = interval
        }

        /// The first date always draws. With no end, or once `end` is reached, that frame is the last.
        mutating func next() -> Date? {
            guard let date = upcoming else { return nil }
            guard let end, date < end else {
                upcoming = nil
                return date
            }
            let following = date.addingTimeInterval(interval)
            upcoming = following < end ? following : end
            return date
        }
    }
}

/// Per-view motion state: the reel angle and the capture-level follower, advanced once per frame.
final class SpoolAnimator {
    private(set) var reel = SpoolReelIntegrator()
    private(set) var smoother = SpoolLevelSmoother()
    private var lastFrame: Date?
    private var lastState: (key: SpoolStateKey, start: Date)?

    init() {}

    /// One frame at `date`. The first frame after a state change advances nothing (`dt = 0`), as the
    /// prototype's `syncAnimation()` does; the angle itself carries over.
    func frame(_ key: SpoolStateKey, stateStartedAt start: Date, level: Double, at date: Date,
               reduceMotion: Bool, width: Double) -> SpoolScene.Frame {
        let sameState = lastState.map { $0.key == key && $0.start == start } ?? false
        let dt = sameState ? Swift.max(0, lastFrame.map { date.timeIntervalSince($0) } ?? 0) : 0
        lastState = (key, start)
        lastFrame = date
        let t = Swift.max(0, date.timeIntervalSince(start))
        let smoothed = smoother.advance(toward: level, dt: dt)
        reel.advance(key, t: t, dt: dt, level: smoothed, reduceMotion: reduceMotion)
        return SpoolScene.frame(key, t: t, width: width, still: reduceMotion, angle: reel.angle,
                                drive: .capture(level: smoothed))
    }
}

/// S1 — Spool, drawn with SwiftUI `Canvas` from the same `SpoolDrawing` the parity tests pin.
///
/// `.pill` draws the whole 164 pt-high pill scene (tape lane plus character on the right) at the view's
/// width; `.cameo` draws the still character for window surfaces. A `TimelineView` drives `t` and the
/// reel angle per S1.4; the loop stops per S1.5 (never when hidden or under Reduce Motion, where the
/// still frame is drawn). The tape follows the real capture `level` (S1.6): silence draws a flat tape.
/// The artwork is decoration and hidden from accessibility; hosts announce the semantic state.
struct SpoolView: View {
    enum Style: Equatable, Sendable {
        case pill
        case cameo
    }

    var key: SpoolStateKey
    var stateStartedAt: Date
    /// Raw capture level, 0…1; smoothed here (40 ms attack, 250 ms release).
    var level: Double = 0
    var style: Style = .pill
    var hidden: Bool = false
    /// Overrides the Reduce Motion preference (`nil` follows it: macOS or Settings › Appearance, S10).
    var reduceMotion: Bool?
    var onAnchorsChange: ((SpoolAnchors) -> Void)?
    /// S4 — follows the anchors on screen (the pill's tape flight source); `nil` on window surfaces.
    var anchorTracker: SpoolAnchorTracker?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// S10 — the app's own Reduce Motion switch joins the system's.
    @ObservedObject private var motion = MotionPreference.shared
    @State private var animator = SpoolAnimator()

    init(key: SpoolStateKey, stateStartedAt: Date, level: Double = 0, style: Style = .pill, hidden: Bool = false,
         reduceMotion: Bool? = nil, onAnchorsChange: ((SpoolAnchors) -> Void)? = nil,
         anchorTracker: SpoolAnchorTracker? = nil) {
        self.key = key
        self.stateStartedAt = stateStartedAt
        self.level = level
        self.style = style
        self.hidden = hidden
        self.reduceMotion = reduceMotion
        self.onAnchorsChange = onAnchorsChange
        self.anchorTracker = anchorTracker
    }

    var body: some View {
        let reduced = Self.reducesMotion(explicit: reduceMotion, system: systemReduceMotion, policy: motion.policy)
        GeometryReader { proxy in
            TimelineView(schedule(reduced: reduced)) { context in
                let frame = self.frame(at: context.date, reduced: reduced, size: proxy.size)
                Canvas { ctx, size in SpoolCanvas.draw(frame.drawing, in: &ctx, size: size) }
                    .preference(key: SpoolAnchorsPreferenceKey.self,
                                value: SpoolAnchors(frame: frame, size: proxy.size, origin: proxy.frame(in: .global).origin))
            }
        }
        .onPreferenceChange(SpoolAnchorsPreferenceKey.self) { anchors in
            guard let anchors else { return }
            onAnchorsChange?(anchors)
            anchorTracker?.update(anchors)
        }
        .background {
            if let anchorTracker { SpoolWindowProbe(tracker: anchorTracker) }
        }
        .accessibilityHidden(true)
    }

    private func schedule(reduced: Bool) -> SpoolFrameSchedule {
        guard style == .pill else { return SpoolFrameSchedule(end: nil) }
        return SpoolFrameSchedule(end: SpoolPoseTable.loopEnd(key, start: stateStartedAt, hidden: hidden, reduceMotion: reduced))
    }

    private func frame(at date: Date, reduced: Bool, size: CGSize) -> SpoolScene.Frame {
        switch style {
        case .cameo:
            return SpoolScene.cameo(key)
        case .pill:
            return animator.frame(key, stateStartedAt: stateStartedAt, level: level, at: date,
                                  reduceMotion: reduced, width: Self.sceneWidth(for: size))
        }
    }

    /// The scene's viewBox width for a view of `size`: the scene is always 164 units high, so a view
    /// 164 pt high draws 1:1 (`width` pt wide), and any other height keeps the aspect.
    static func sceneWidth(for size: CGSize) -> Double {
        guard size.height > 0, size.width > 0 else { return 560 }
        return Double(size.width) * SpoolScene.height / Double(size.height)
    }
}
