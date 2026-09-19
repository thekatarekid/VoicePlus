import SwiftUI

// S10 — Larger Text in the window (design §11: "Large text: window reflows; compact pill remains
// bounded and offers full review"). Settings › Appearance › Larger text scales every window type role
// (`windowTextScale`, applied at the window root) and, once text is larger than the default, rows and
// page headers put their trailing control under the text when the two no longer fit side by side.
// The pill keeps its sizes: its overflow goes to "N words · Review all", which opens the window.

public enum WindowReflow {
    /// Larger than the default size: rows may stack.
    public static func reflows(scale: CGFloat) -> Bool { scale > 1.001 }

    /// The scale the window root applies for a text-size choice.
    public static func scale(for size: WindowTextSize) -> CGFloat { size.scale }
}

/// Applies Settings › Appearance › Larger text to everything under it, following the setting live.
struct WindowTextScaleRoot: ViewModifier {
    @ObservedObject var general: GeneralSettingsViewModel

    func body(content: Content) -> some View {
        content.environment(\.windowTextScale, WindowReflow.scale(for: general.textSize))
    }
}

extension View {
    /// The window root's Larger Text.
    func windowTextScaleRoot(_ general: GeneralSettingsViewModel) -> some View {
        modifier(WindowTextScaleRoot(general: general))
    }
}

/// A leading block and a trailing control side by side; under Larger Text, the control goes under
/// the block when both no longer fit on one line (`ViewThatFits`). At the default size the layout is
/// always side by side, as designed.
struct ReflowingRow<Leading: View, Trailing: View>: View {
    var spacing: CGFloat
    var alignment: VerticalAlignment
    private let leading: Leading
    private let trailing: Trailing
    @Environment(\.windowTextScale) private var scale

    init(spacing: CGFloat, alignment: VerticalAlignment = .center,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.spacing = spacing
        self.alignment = alignment
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if WindowReflow.reflows(scale: scale) {
            ViewThatFits(in: .horizontal) {
                sideBySide
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    leading.frame(maxWidth: .infinity, alignment: .leading)
                    trailing.fixedSize()
                }
            }
        } else {
            sideBySide
        }
    }

    private var sideBySide: some View {
        HStack(alignment: alignment, spacing: spacing) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            trailing.fixedSize()
        }
    }
}
