import SwiftUI

/// S7a — the design's tag (prototype `.tag`, `.tag.good`, `.tag.warn`): a short outcome word in the
/// `key` role inside a 4 pt-cornered outline — "Inserted", "Held", "Unconfirmed", "Local", "Ready".
/// Good and warn carry a glyph as well as a colour, so the state is never colour alone
/// (`DESIGN.md` §12.9); the word is the accessible label.
struct StatusTag: View {
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case good, warn, neutral

        var systemImage: String? {
            switch self {
            case .good: return "checkmark"
            case .warn: return "exclamationmark.triangle"
            case .neutral: return nil
            }
        }

        var role: Tokens.Role {
            switch self {
            case .good: return .ready
            case .warn: return .attention
            case .neutral: return .secondaryInk
            }
        }
    }

    var text: String
    var kind: Kind

    init(_ text: String, kind: Kind = .neutral) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let glyph = kind.systemImage {
                Image(systemName: glyph).imageScale(.small)
            }
            Text(text)
        }
        .windowFont(Tokens.Typography.key)
        .foregroundStyle(kind.role.color)
        .padding(.horizontal, Tokens.Spacing.s)
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.keyCap, style: .continuous)
                .strokeBorder(WindowColor.separator, lineWidth: 1)
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("tag.\(kind.rawValue)")
    }
}
