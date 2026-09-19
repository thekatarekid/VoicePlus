import SwiftUI

// S7b — turn detail (design §8.1, prototype `case'turn'`), drawn in S7a's `SectionPage`: the still
// held-tape Spool beside the delivery status, the turn's title and "Mail · Today, 12:42 · 9 words",
// Copy text; Final text / Original transcript; the selectable text with its uncertain words marked
// and counted; Delivery (method, verified or not), Destination, Recovery for held text; Review and
// Delete…. Every rendering (loading, empty, error, S03 partial) is `TurnDetailModel.state`/`banner`.

struct TurnDetailView: View {
    @ObservedObject var model: TurnDetailModel
    @ObservedObject private var retry: ScopedRetry
    var hotkey: String
    var back: () -> Void

    init(model: TurnDetailModel, hotkey: String, back: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _retry = ObservedObject(wrappedValue: model.retry)
        self.hotkey = hotkey
        self.back = back
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                Label(TodayCopy.backToToday, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .windowFont(Tokens.Typography.body)
            .padding(.horizontal, MainWindowLayout.outerPadding)
            .padding(.top, Tokens.Spacing.l)
            .accessibilityIdentifier("turn.back")
            SectionPage(PageCopy(.turn, title: model.title, subtitle: model.subtitle),
                        state: model.state, banner: model.banner,
                        headerAction: PageAction(TodayCopy.copyText, isPrimary: model.banner != nil,
                                                 identifier: "turn.copy") { model.copy() },
                        onStateAction: stateAction,
                        onBannerAction: { model.copy() },
                        isRetrying: retry.isRetrying,
                        spoolNote: (SpoolSurfacePolicy.appearance(on: .turnDetail)?.key ?? .held, model.statusLine),
                        hotkey: hotkey) {
                content
            }
        }
        .onExitCommand(perform: back)
        .confirmationDialog(TurnDetailModel.deleteHeadline,
                            isPresented: Binding(get: { model.confirmingDelete }, set: { if !$0 { model.cancelDelete() } }),
                            titleVisibility: .visible) {
            Button(SectionCopy.confirmDelete, role: .destructive) { model.confirmDelete() }
                .accessibilityIdentifier("turn.confirmDelete")
            Button(SectionCopy.cancel, role: .cancel) { model.cancelDelete() }
        } message: {
            Text(model.draft != nil ? TurnDetailModel.deleteHeldDetail : TurnDetailModel.deleteDetail)
        }
        .accessibilityIdentifier("turn.detail")
    }

    /// Empty (the fixture's "Open Today") goes back; error retries the read.
    private func stateAction() {
        switch model.state.rendering {
        case .empty: back()
        case .error: Task { await model.retryLoad() }
        case .content, .loading: break
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            if model.hasOriginal {
                SegmentedControl("Text", options: TurnDetailModel.TextView.allCases, selection: $model.textView,
                                 identifier: "turn.textView") { $0.title }
                    .frame(maxWidth: 320)
            }
            TurnPaper {
                TurnTextView(text: model.displayedText, uncertain: model.displayedSpans)
                Text(model.uncertaintyLine)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("turn.uncertainty")
            }
            if model.reviewing, !model.uncertainWords.isEmpty {
                GroupBox("Words to review", layout: .rows) {
                    ForEach(Array(model.uncertainWords.enumerated()), id: \.offset) { _, word in
                        RowView("“\(word)”", detail: TurnDetailCopy.reviewDetail)
                    }
                }
                .accessibilityIdentifier("turn.review.words")
            }
            if let notice = model.notice { TodayNoticeLine(notice: notice) }
            GroupBox(layout: .rows) {
                RowView("Delivery", detail: model.deliveryDetail) {
                    if let tag = model.tag { StatusTag(tag) }
                }
                .accessibilityIdentifier("turn.delivery")
                RowView("Destination", detail: model.destinationLine)
                if let draft = model.draft {
                    RowView("Recovery", detail: draft.retention.label) {
                        Button(TurnDetailCopy.openRecovery) { model.review() }
                            .accessibilityIdentifier("turn.openRecovery")
                    }
                }
            }
            HStack(spacing: Tokens.Spacing.s) {
                if model.canReview {
                    PageActionButton(action: PageAction(TurnDetailCopy.review, isPrimary: false,
                                                        identifier: "turn.review") { model.review() })
                }
                PageActionButton(action: PageAction(TurnDetailCopy.delete, isPrimary: false,
                                                    identifier: "turn.delete") { model.askDelete() })
            }
        }
    }
}

enum TurnDetailCopy {
    static let review = "Review"
    static let delete = "Delete…"
    static let openRecovery = "Open recovery"
    static let reviewDetail = "Heard with low confidence. Check it where it landed — VoicePlus never changes inserted text on its own."
}
