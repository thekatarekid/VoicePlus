import SwiftUI

/// P5 / S2 — the notch chin (design §4 "Hover presence", DESIGN.md §6.2, §8.4). Bodies at one anchor:
/// the 64 × 14 black chin with its 6 pt green dot at rest, the text-only hint "Hold or Double Tap <key>
/// to dictate" under the pointer, a level bar while another owner has the mic open, and a legible badge
/// when muted / paused / blocked. Nothing here is interactive except the whole-panel click, which the
/// controller handles.
struct PresenceIndicatorView: View {
    let state: PresenceState
    /// The pointer is on it (the hint for ready, the state's row otherwise).
    let hovered: Bool
    let cornerRadius: CGFloat
    /// "hold fn / 🌐" — for the non-ready rows.
    let hint: String
    /// Already fitted to the panel width, so the row never needs a tail ellipsis.
    let rowText: String
    /// Hangs from the housing (lower corners only) or floats below an external menu bar (all four).
    let attached: Bool
    /// The I1 hint for the configured key; also the chin's accessible description (design §4).
    let readyHint: String
    let backgroundCap: CGFloat
    /// N22 — held texts waiting; above zero the resting chin is the Needs you badge.
    let heldWaiting: Int
    /// S10 — Reduce Motion (system or Settings › Appearance).
    @ObservedObject private var motion = MotionPreference.shared

    init(state: PresenceState, hovered: Bool, cornerRadius: CGFloat, hint: String, rowText: String? = nil,
         attached: Bool = true, readyHint: String = HotkeyBinding.default.readyHint(), backgroundCap: CGFloat = 0,
         heldWaiting: Int = 0) {
        self.state = state
        self.hovered = hovered
        self.cornerRadius = cornerRadius
        self.hint = hint
        self.attached = attached
        self.readyHint = readyHint
        self.backgroundCap = backgroundCap
        let needsYou = PresenceFace.of(state, heldWaiting: heldWaiting) == .needsYou
        self.heldWaiting = needsYou ? heldWaiting : 0
        self.rowText = rowText
            ?? (needsYou ? PresenceFace.needsYouDetail(heldWaiting) : nil)
            ?? (state == .ready ? readyHint : nil)
            ?? PresenceRow.candidates(detail: state.detail, hint: PresenceRow.hint(hint, for: state)).first
            ?? state.detail
    }

    var body: some View {
        VStack(spacing: 0) {
            if backgroundCap > 0 { Color.clear.frame(height: backgroundCap) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .clipShape(UnevenRoundedRectangle(cornerRadii: corners))
            .foregroundStyle(Tokens.Pill.Token.ink.color)
            .animation(motion.policy.transition, value: hovered)   // S10: none under Reduce Motion
            .accessibilityIdentifier("presence.\(needsYou ? PresenceFace.needsYou.rawValue : state.caseName)")
            .accessibilityLabel(needsYou ? PresenceFace.needsYouDetail(heldWaiting)
                                         : state == .ready ? readyHint : state.detail)
    }

    /// FX6 — the seam the tests read: which body this view renders, and therefore whether a dot is
    /// in the presentation at all.
    var contentKind: PresenceContent { PresenceContent.kind(state: state, hovered: hovered, needsYou: needsYou) }

    /// N22 — the chin is the Needs you face.
    var needsYou: Bool { heldWaiting > 0 }
    private var symbol: String { needsYou ? PresenceFace.needsYouSymbol : state.symbol }
    private var badge: String? { needsYou ? PresenceFace.needsYouBadge : state.badge }

    private var corners: RectangleCornerRadii {
        attached && (hovered || state != .ready)
            ? RectangleCornerRadii(bottomLeading: cornerRadius, bottomTrailing: cornerRadius)
            : RectangleCornerRadii(topLeading: cornerRadius, bottomLeading: cornerRadius,
                                   bottomTrailing: cornerRadius, topTrailing: cornerRadius)
    }

    /// FX6 — the body is chosen by `PresenceContent`, and the chosen kind is the view's *identity*
    /// (`.id`). Without that, SwiftUI structurally matched the single content child across the
    /// `hovered` flip, so the line-49 container animation interpolated the **geometry** of the 6 pt
    /// dot leaf as the chin grew into the 360 × 38 hint box — the dot slid off to the box's top-left
    /// corner and only then faded. A distinct identity per kind makes the change an insert + remove,
    /// and `.transition(.opacity)` says the only thing that may animate is opacity: the dot
    /// cross-fades out where it stands and is genuinely absent from the hint layout.
    @ViewBuilder private var content: some View {
        let kind = PresenceContent.kind(state: state, hovered: hovered, needsYou: needsYou)
        ZStack {
            switch kind {
            case .empty:
                EmptyView()
            case .dot:
                ReadyDot()
            case .levelBar(let level):
                LevelBar(level: level)
            case .badge:
                badgeBody
            case .hint:
                // I1: text only — no dot, no brand prefix, no "Ready", no cassette.
                Text(rowText)
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("presence.hint")
            case .row:
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    // No `truncationMode`: the panel was sized to this exact string by `PresenceRow`.
                    Text(rowText).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 9)
            }
        }
        .id(kind.identity)
        // Opacity only, in both directions: never `.offset`, `.slide` or an implicit geometry match.
        .transition(.opacity)
    }

    private var badgeBody: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            if let badge {
                Text(badge).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Idle and the hint are the pill's own black (`Pill.background`); the badges keep their colours.
    private var background: some ShapeStyle {
        if needsYou { return AnyShapeStyle(Color.orange.opacity(0.9)) }
        switch state {
        case .off: return AnyShapeStyle(Color.clear)
        case .ready, .listening, .processing, .paused: return AnyShapeStyle(Tokens.Pill.Token.background.color)
        case .muted: return AnyShapeStyle(Color.red.opacity(0.88))
        case .blocked: return AnyShapeStyle(Color.orange.opacity(0.9))
        }
    }
}

/// FX6 — what the chin draws, as a pure decision, so "the I1 hint carries no dot" (DESIGN.md §8.3,
/// §8.4) is a unit test rather than a claim about a SwiftUI branch.
///
/// `identity` deliberately ignores the level payload: the level bar must keep one identity across
/// level ticks (it is the same bar getting wider), while the dot, the bar, the badge, the hint and
/// the state row are each a *different* view — so SwiftUI can never geometry-match one onto another
/// during the expand/collapse.
enum PresenceContent: Equatable {
    case empty
    case dot
    case levelBar(Float?)
    case badge
    case hint
    case row

    static func kind(state: PresenceState, hovered: Bool, needsYou: Bool = false) -> PresenceContent {
        guard state != .off else { return .empty }
        // N22 — Needs you is a badge at rest and its row on hover (never the ready dot or hint).
        if needsYou { return hovered ? .row : .badge }
        if hovered { return state == .ready ? .hint : .row }
        switch state {
        case .off: return .empty
        case .ready: return .dot
        case .listening(let level): return .levelBar(level)
        case .processing: return .levelBar(nil)
        case .muted, .paused, .blocked: return .badge
        }
    }

    /// The only presentation that carries the green dot is the resting `ready` chin (I0).
    var showsDot: Bool { self == .dot }

    var identity: String {
        switch self {
        case .empty: return "empty"
        case .dot: return "dot"
        case .levelBar: return "levelBar"
        case .badge: return "badge"
        case .hint: return "hint"
        case .row: return "row"
        }
    }
}

/// I0 — one 6 pt green dot, centred. Static: idle never animates (design §11).
private struct ReadyDot: View {
    var body: some View {
        Circle()
            .fill(Tokens.Pill.Token.ready.color)
            .frame(width: PresenceGeometry.dotDiameter, height: PresenceGeometry.dotDiameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// FX5 — the level bar's geometry, as pure functions of time and chin size, so "centred" is a
/// property of the arithmetic rather than of whatever animation happened to be running.
///
/// The 1.11.x bar was a `withAnimation(.repeatForever)` started in `onAppear`: SwiftUI's repeating
/// transaction also captured the layout change it was started during (the panel shrinking from the
/// hover row back to the chin), so the capsule's *position and size* swung forever between a stale
/// layout and the real one — off-centre to the left and narrower than the design allows. Here
/// nothing animates: the width is recomputed from the clock on every frame and the capsule is
/// placed at the chin's centre, so a layout change can only ever move the centre with the chin.
enum LevelBarPulse {
    /// Horizontal inset of the track inside the chin.
    static let inset: CGFloat = 4
    /// The indeterminate pulse's range, as a fraction of the track (unchanged from P5).
    static let minFraction: CGFloat = 0.25
    static let maxFraction: CGFloat = 0.85
    /// One full breath, narrow → wide → narrow (P5's 0.9 s ease each way).
    static let period: TimeInterval = 1.8
    /// Reduce Motion: the bar holds still here (P5's resting width).
    static let restingFraction: CGFloat = minFraction
    /// Lowest level drawn while listening, so a quiet room still shows a bar.
    static let levelFloor: Float = 0.06

    /// The indeterminate (processing) width at `time`, eased in and out at both ends; constant
    /// under Reduce Motion.
    static func pulseFraction(at time: TimeInterval, reduced: Bool) -> CGFloat {
        guard !reduced else { return restingFraction }
        let cycle = time.truncatingRemainder(dividingBy: period) / period
        let wave = CGFloat((1 - cos(2 * Double.pi * (cycle < 0 ? cycle + 1 : cycle))) / 2)
        return minFraction + (maxFraction - minFraction) * wave
    }

    /// The listening width for a microphone level.
    static func levelFraction(_ level: Float) -> CGFloat { CGFloat(min(max(level, levelFloor), 1)) }

    /// The capsule's rect in chin coordinates: centred on the chin in both axes, by construction.
    static func frame(fraction: CGFloat, in chin: CGSize) -> CGRect {
        let track = max(0, chin.width - 2 * inset)
        let width = min(max(4, track * min(max(fraction, 0), 1)), max(4, track))
        let height = max(2, chin.height - 6)
        return CGRect(x: (chin.width - width) / 2, y: (chin.height - height) / 2, width: width, height: height)
    }
}

/// A level-driven fill for the active chin. `nil` level = indeterminate (processing): a slow
/// pulse rather than a lie about the microphone. FX5: no `onAppear`, no `withAnimation`, no
/// `repeatForever` — the pulse is a `TimelineView` redraw and the capsule is positioned at the
/// chin's centre every frame, so neither its position nor the chin's layout can be animated.
private struct LevelBar: View {
    let level: Float?
    /// S10 — under Reduce Motion the processing bar holds still (no pulse) and levels step.
    @ObservedObject private var motion = MotionPreference.shared

    var body: some View {
        if let level {
            capsule(LevelBarPulse.levelFraction(level))
                // Only a level change animates (a short width ease); nothing inherited — the hover
                // transition, a panel resize — reaches the capsule.
                .animation(motion.reduced ? nil : .linear(duration: 0.08), value: level)
                .transaction { $0.animation = nil }
        } else if motion.reduced {
            capsule(LevelBarPulse.restingFraction)
                .transaction { $0.animation = nil }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                capsule(LevelBarPulse.pulseFraction(at: context.date.timeIntervalSinceReferenceDate, reduced: false))
            }
            .transaction { $0.animation = nil }
        }
    }

    private func capsule(_ fraction: CGFloat) -> some View {
        GeometryReader { geo in
            let rect = LevelBarPulse.frame(fraction: fraction, in: geo.size)
            Capsule()
                .fill(Tokens.Pill.Token.ink.color.opacity(0.85))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .accessibilityHidden(true)
    }
}
