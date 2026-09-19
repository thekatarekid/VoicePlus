import SwiftUI

/// S7a — a key cap (prototype `kbd`): the configured key's label in the `key` role (11 pt mono) inside a
/// 1 pt outline in the text's own colour at 85 %, 4 pt corners. Always the configured key — "fn / 🌐"
/// by default (owner decision, build doc §0) — never a hard-coded name.
struct KeyCap: View {
    var label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .windowFont(Tokens.Typography.key)
            .padding(.horizontal, Tokens.Spacing.xs)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.keyCap, style: .continuous)
                    .strokeBorder(HierarchicalShapeStyle.primary, lineWidth: 1)
            )
            .opacity(KeyCapStyle.opacity)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(KeyCap.accessibilityLabel(for: label))
    }

    /// "fn / 🌐 key" — the word "key" so VoiceOver does not read the label as prose.
    static func accessibilityLabel(for label: String) -> String { "\(label) key" }
}

enum KeyCapStyle {
    /// Prototype `kbd { opacity: .85 }`.
    static let opacity: Double = 0.85
}

/// A sentence with the key in a cap: "Hold [fn / 🌐] to speak. Release to preview, then insert."
/// (Today's page foot, design §8). Read as one sentence by VoiceOver.
struct KeyHint: View {
    var before: String
    var key: String
    var after: String

    init(_ before: String, key: String, _ after: String) {
        self.before = before
        self.key = key
        self.after = after
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.xs) {
            Text(before)
            KeyCap(key)
            Text(after)
        }
        .windowFont(Tokens.Typography.meta)
        .foregroundStyle(WindowColor.secondaryInk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(before) \(key) \(after)")
    }
}
