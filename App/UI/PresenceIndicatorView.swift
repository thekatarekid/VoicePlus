import SwiftUI

/// P5 — the notch chin. Four bodies at one anchor: a hairline at rest, a level bar while the mic is
/// open, a legible badge when muted / paused / blocked, and a one-line row while the pointer is on
/// it. Nothing here is interactive except the whole-panel click, which the controller handles.
struct PresenceIndicatorView: View {
    let state: PresenceState
    let hovered: Bool
    let cornerRadius: CGFloat
    /// "hold Right ⌥" — supplied by the controller so the pure state model stays free of bindings.
    let hint: String

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius))
            .foregroundStyle(.white)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .accessibilityIdentifier("presence.\(state.caseName)")
            .accessibilityLabel(state.detail)
    }

    @ViewBuilder private var content: some View {
        if hovered {
            HStack(spacing: 6) {
                Image(systemName: state.symbol).font(.system(size: 10, weight: .semibold))
                Text(hoverText).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 9)
        } else {
            switch state {
            case .off: EmptyView()
            case .ready: EmptyView()                       // the chin itself is the whole idle body
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

    private var hoverText: String {
        if case .ready = state, !hint.isEmpty { return "\(state.detail) — \(hint)" }
        return state.detail
    }

    /// Idle is deliberately faint — it should read as a shadow under the bezel, not as chrome.
    private var background: some ShapeStyle {
        switch state {
        case .off: return AnyShapeStyle(Color.clear)
        case .ready: return AnyShapeStyle(Color.black.opacity(hovered ? 0.9 : 0.35))
        case .listening, .processing: return AnyShapeStyle(Color.black.opacity(0.9))
        case .muted: return AnyShapeStyle(Color.red.opacity(0.88))
        case .paused: return AnyShapeStyle(Color.black.opacity(0.75))
        case .blocked: return AnyShapeStyle(Color.orange.opacity(0.9))
        }
    }
}

/// A level-driven fill for the 10 pt active chin. `nil` level = indeterminate (processing): a slow
/// shimmer rather than a lie about the microphone.
private struct LevelBar: View {
    let level: Float?
    @State private var phase: CGFloat = 0.25

    var body: some View {
        GeometryReader { geo in
            let width = level.map { CGFloat(min(max($0, 0.06), 1)) } ?? phase
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: max(4, geo.size.width * width), height: max(2, geo.size.height - 4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .padding(.horizontal, 4)
        .animation(.linear(duration: 0.08), value: level)
        .onAppear {
            guard level == nil else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = 0.85 }
        }
    }
}
