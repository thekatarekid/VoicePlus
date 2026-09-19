import SwiftUI

// S10 — the pill's accessibility pieces the pill view places: the VoiceOver announcement hook and the
// Reduce Motion level readout.

/// Attaches the pill model's `PillAnnouncementCenter` (once per model) wherever the pill is drawn.
struct PillAnnouncementsModifier: ViewModifier {
    let model: PillViewModel

    func body(content: Content) -> some View {
        PillAnnouncementCenter.attach(to: model)
        return content
    }
}

extension View {
    /// VoiceOver hears the pill's start, stop, final and delivery lines (`PillAnnouncer`).
    func pillAnnouncements(_ model: PillViewModel) -> some View {
        modifier(PillAnnouncementsModifier(model: model))
    }
}

/// "Level 40%" in the pill's tape lane while capture is live under Reduce Motion. Decoration for the
/// eye: VoiceOver is told the state, not a number that changes many times a second.
struct PillLevelReadout: View {
    var level: Double

    var body: some View {
        Text(LevelReadout.text(level: level))
            .font(Tokens.Typography.pillTimer.font())
            .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
            .lineLimit(1)
            .accessibilityHidden(true)
            .accessibilityIdentifier("pill.levelReadout")
    }
}
