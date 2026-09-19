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
    /// S10 — Reduce Motion (system or Settings › Appearance).
    @ObservedObject private var motion = MotionPreference.shared

    init(state: PresenceState, hovered: Bool, cornerRadius: CGFloat, hint: String, rowText: String? = nil,
         attached: Bool = true, readyHint: String = HotkeyBinding.default.readyHint()) {
        self.state = state
        self.hovered = hovered
        self.cornerRadius = cornerRadius
        self.hint = hint
        self.attached = attached
        self.readyHint = readyHint
        self.rowText = rowText
            ?? (state == .ready ? readyHint : nil)
            ?? PresenceRow.candidates(detail: state.detail, hint: PresenceRow.hint(hint, for: state)).first
            ?? state.detail
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .clipShape(UnevenRoundedRectangle(cornerRadii: corners))
            .foregroundStyle(Tokens.Pill.Token.ink.color)
            .animation(motion.policy.transition, value: hovered)   // S10: none under Reduce Motion
            .accessibilityIdentifier("presence.\(state.caseName)")
            .accessibilityLabel(state == .ready ? readyHint : state.detail)
    }

    private var corners: RectangleCornerRadii {
        attached
            ? RectangleCornerRadii(bottomLeading: cornerRadius, bottomTrailing: cornerRadius)
            : RectangleCornerRadii(topLeading: cornerRadius, bottomLeading: cornerRadius,
                                   bottomTrailing: cornerRadius, topTrailing: cornerRadius)
    }

    @ViewBuilder private var content: some View {
        if hovered, state == .ready {
            // I1: text only — no dot, no brand prefix, no "Ready", no cassette.
            Text(rowText)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("presence.hint")
        } else if hovered {
            HStack(spacing: 6) {
                Image(systemName: state.symbol).font(.system(size: 10, weight: .semibold))
                // No `truncationMode`: the panel was sized to this exact string by `PresenceRow`.
                Text(rowText).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
        } else {
            switch state {
            case .off: EmptyView()
            case .ready: ReadyDot()
            case .listening(let level): LevelBar(level: level)
            case .processing: LevelBar(level: nil)
            case .muted, .paused, .blocked: badgeBody
            }
        }
    }

    private var badgeBody: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol).font(.system(size: 9, weight: .bold))
            if let badge = state.badge {
                Text(badge).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 6)
    }

    /// Idle and the hint are the pill's own black (`Pill.background`); the badges keep their colours.
    private var background: some ShapeStyle {
        switch state {
        case .off: return AnyShapeStyle(Color.clear)
        case .ready, .listening, .processing, .paused: return AnyShapeStyle(Tokens.Pill.Token.background.color)
        case .muted: return AnyShapeStyle(Color.red.opacity(0.88))
        case .blocked: return AnyShapeStyle(Color.orange.opacity(0.9))
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

/// A level-driven fill for the active chin. `nil` level = indeterminate (processing): a slow
/// shimmer rather than a lie about the microphone.
private struct LevelBar: View {
    let level: Float?
    @State private var phase: CGFloat = 0.25
    /// S10 — under Reduce Motion the processing bar holds still (no shimmer) and levels step.
    @ObservedObject private var motion = MotionPreference.shared

    var body: some View {
        GeometryReader { geo in
            let width = level.map { CGFloat(min(max($0, 0.06), 1)) } ?? phase
            Capsule()
                .fill(Tokens.Pill.Token.ink.color.opacity(0.85))
                .frame(width: max(4, geo.size.width * width), height: max(2, geo.size.height - 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(.horizontal, 4)
        .animation(motion.reduced ? nil : .linear(duration: 0.08), value: level)
        .onAppear {
            guard level == nil, !motion.reduced else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 0.85 }
        }
    }
}
