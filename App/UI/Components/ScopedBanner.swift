import SwiftUI

/// S7a — the scoped banner (prototype `.banner`): a failure that sits beside content instead of
/// replacing it — the partial rendering's banner and the error rendering's recovery. Amber glyph and
/// headline, the consequence in secondary ink, one recovery action, and Copy diagnostics when there is
/// raw detail (which never goes in the sentence, `DESIGN.md` §7.1).
///
/// The action is scoped to the failed part and is disabled while that scope retries (design §9);
/// pass `isRetrying` from the scope's `ScopedRetry`. Under Increase Contrast the outline is a real
/// `controlBorder` line (`DESIGN.md` §6.3).
struct ScopedBanner: View {
    var banner: SectionBanner
    var isRetrying: Bool
    var onAction: (() -> Void)?

    @Environment(\.colorSchemeContrast) private var contrast

    init(_ banner: SectionBanner, isRetrying: Bool = false, onAction: (() -> Void)? = nil) {
        self.banner = banner
        self.isRetrying = isRetrying
        self.onAction = onAction
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label {
                Text(banner.headline).fontWeight(.semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(WindowColor.attention)
            .accessibilityIdentifier("section.banner.headline")
            if let body = banner.body, !body.isEmpty {
                Text(body)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasActions {
                HStack(spacing: Tokens.Spacing.s) {
                    if let title = banner.actionTitle, let onAction {
                        PageActionButton(action: PageAction(title, isEnabled: !isRetrying,
                                                            identifier: "section.banner.action", perform: onAction))
                    }
                    if let diagnostics = banner.diagnostics {
                        Button(SectionCopy.copyDiagnostics) { Pasteboard.copy(diagnostics) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("section.banner.copyDiagnostics")
                    }
                }
                .padding(.top, Tokens.Spacing.xs)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WindowColor.attention.opacity(ScopedBannerStyle.fillOpacity)))
        .overlay(shape.strokeBorder(outline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("section.banner")
    }

    private var hasActions: Bool {
        (banner.actionTitle != nil && onAction != nil) || banner.diagnostics != nil
    }

    private var outline: Color {
        contrast == .increased ? WindowColor.controlBorder : WindowColor.attention.opacity(ScopedBannerStyle.outlineOpacity)
    }
}

/// The prototype's `.banner` tint: an amber fill at alpha 0x10 and an amber outline at alpha 0x55 —
/// here the attention token at the same alphas, so no hex colour leaves `DesignTokens.swift`.
enum ScopedBannerStyle {
    static let fillOpacity: Double = 0x10 / 255
    static let outlineOpacity: Double = 0x55 / 255
}
