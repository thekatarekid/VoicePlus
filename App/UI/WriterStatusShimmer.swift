import SwiftUI

/// Context Writer (plan §4: "the animation *is* the wait") — the "Writing…" status line carries a
/// slow highlight that sweeps across the words, masked to the glyphs. It is decoration only: hidden
/// from VoiceOver, never hit-testable, and absent under Reduce Motion (the line is then still,
/// like the Spool's still finishing pose).
struct WriterStatusShimmer: ViewModifier {
    let active: Bool

    /// One sweep; slow and even, so it reads as "working", never as an alert.
    static let period: TimeInterval = 1.6
    /// The highlight band's width as a share of the line.
    static let band: CGFloat = 0.45

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let width = max(1, geometry.size.width)
                        let band = width * Self.band
                        let phase = Self.phase(at: timeline.date)
                        LinearGradient(colors: [.clear, Tokens.Pill.Token.ink.color.opacity(0.9), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band, height: geometry.size.height)
                            .offset(x: -band + CGFloat(phase) * (width + band))
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            content
        }
    }

    /// 0…1 within the current sweep.
    static func phase(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
    }
}
