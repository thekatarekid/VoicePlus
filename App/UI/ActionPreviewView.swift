import SwiftUI

/// S12 — the outbound action preview card (design_v1 §8.8): the proposed action and its destination
/// as the headline, what has not happened yet, and the two explicit controls. The primary button
/// names the action ("Send"); nothing is the default for Return, so a keystroke meant for the
/// destination can never confirm a send. Esc cancels.
struct ActionPreviewView: View {
    let preview: ActionPreview
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(preview.headline, systemImage: preview.isOutbound ? "paperplane" : "exclamationmark.triangle.fill")
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("actionPreview.headline")
            Text(preview.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("actionPreview.detail")
            HStack(spacing: 8) {
                Text(preview.footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(ActionPreview.cancelLabel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("consent.card.cancel")
                Button(preview.confirmLabel, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("consent.card.confirm")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(preview.headline)
        .accessibilityIdentifier("consent.card")
    }
}
