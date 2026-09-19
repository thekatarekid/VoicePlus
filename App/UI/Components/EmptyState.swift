import SwiftUI

/// S7a — the design's empty state (prototype `.empty-state`): the still `ready` Spool cameo, one
/// headline, one sentence, one call to action, centred in at least 320 pt. The loading rendering uses
/// the same frame with "Loading <section>…" and no action — the words, and the page title above it,
/// are what keep loading from ever looking like empty (design §9).
///
/// Spool never moves here: the cameo is a still frame, so an empty or loading screen never spins
/// (design §8.9 "never spin for background history loading").
struct EmptyState: View {
    var pose: SpoolStateKey
    var headline: String
    var message: String?
    var action: PageAction?

    init(pose: SpoolStateKey = .ready, headline: String, message: String? = nil, action: PageAction? = nil) {
        self.pose = pose
        self.headline = headline
        self.message = message
        self.action = action
    }

    var body: some View {
        VStack(spacing: 0) {
            SpoolCameo(pose, size: .emptyState)
                .padding(.bottom, Tokens.Spacing.xl)
            Text(headline)
                .windowFont(Tokens.Typography.section)
                .foregroundStyle(WindowColor.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("section.state.headline")
                .padding(.bottom, Tokens.Spacing.m)
            if let message, !message.isEmpty {
                Text(message)
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: EmptyStateLayout.messageWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Tokens.Spacing.xl)
            }
            if let action { PageActionButton(action: action) }
        }
        .padding(Tokens.Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: EmptyStateLayout.minimumHeight)
        .accessibilityElement(children: .contain)
    }
}

enum EmptyStateLayout {
    /// Prototype `.empty-state { min-height: 320px }`.
    static let minimumHeight: CGFloat = 320
    /// Prototype `.empty-state p { max-width: 330px }`.
    static let messageWidth: CGFloat = 330
}
