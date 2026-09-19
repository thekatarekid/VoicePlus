import SwiftUI

/// S3 — keyboard or VoiceOver focus on the pill's text lane or its actions freezes the final
/// preview's dwell, the same way hover does (build doc §2 "Hover, focus, selection or Review freezes
/// it"; design §11 "Respect focus and hover pause of preview dwell").
///
/// Each focusable piece of the pill (a text-lane line, an uncertain-word target, an action button)
/// reports its own focus under a stable element name; `PillViewModel.setFocus(_:element:)` keeps the
/// set, so focus moving from one button to the next never looks like focus leaving the pill. The pill
/// panel is non-activating, so in practice this is the VoiceOver cursor (`accessibilityFocused`);
/// Tab focus (`focused`) is reported the same way wherever the panel can take it.
///
/// The final text is drawn as plain `Text` (not selectable), so there is no selection to report;
/// `DwellPause.selection` stays for a surface that makes it selectable.
struct PillFocusReport: ViewModifier {
    let element: String
    let report: ((Bool, String) -> Void)?
    @FocusState private var keyboard: Bool
    @AccessibilityFocusState private var voiceOver: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if let report {
            content
                .focused($keyboard)
                .accessibilityFocused($voiceOver)
                .onChange(of: keyboard || voiceOver) { _, focused in report(focused, element) }
                // A focused piece that goes away (the row changed) no longer holds the dwell.
                .onDisappear { report(false, element) }
        } else {
            content
        }
    }
}

extension View {
    /// Reports keyboard / VoiceOver focus on this piece of the pill (S3 dwell pause).
    func pillFocusReport(_ element: String, _ report: ((Bool, String) -> Void)?) -> some View {
        modifier(PillFocusReport(element: element, report: report))
    }
}
