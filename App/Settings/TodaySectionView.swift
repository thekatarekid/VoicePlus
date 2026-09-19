import SwiftUI
import Shared

// S7b — Today (design §8.1, prototype `case'today'`; `DESIGN.md` §9.1), drawn in S7a's `SectionPage`:
//
// - content: the Spool note ("Ready when you are", only while that is true — otherwise what needs
//   attention), the page header with Try dictation, every held / partial draft first ("Text waiting
//   for Mail", its text, what happened, Review text · Copy), then "Recent dictations" — time ·
//   destination · excerpt · Inserted / Held / Unconfirmed / "1 to review" — then the ambient
//   Timeline when ambient capture is on, and the hold hint with the configured key.
// - empty: "Nothing dictated yet" + the key + Try dictation; the history-off variant; "No matches for …"
// - loading: "Loading recent dictations…"; error: "History can't be read" + Try again.
// No vanity counters. Every decision is the view model's (`page`, `history`, `drafts`, `recent`).

struct TodaySectionView: View {
    @ObservedObject var model: TodaySectionViewModel
    @ObservedObject private var retry: ScopedRetry
    var hotkey: String
    /// Routing to another section (Settings › Shortcuts, Privacy, Voice…).
    var open: (WindowRoute) -> Void

    init(model: TodaySectionViewModel, hotkey: String, open: @escaping (WindowRoute) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _retry = ObservedObject(wrappedValue: model.historyRetry)
        self.hotkey = hotkey
        self.open = open
    }

    var body: some View {
        SectionPage(PageCopy.section(.today), state: model.page, banner: nil,
                    headerAction: PageAction(TodayCopy.tryDictation, identifier: "today.tryDictation") { perform(.tryDictation) },
                    onStateAction: { perform(model.stateAction(for: model.page)) },
                    isRetrying: retry.isRetrying,
                    spoolNote: model.spoolNote, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                if let notice = model.notice { TodayNoticeLine(notice: notice) }
                if !model.blockers.isEmpty { blockers }
                ForEach(model.drafts) { draft in
                    TodayDraftCard(draft: draft, notice: model.draftNotices[draft.id],
                                   review: { model.presentRecovery(draft) },
                                   copy: { model.copy(draft) })
                }
                recentGroup
                if model.ambientVisible { TodayAmbientTimelineView(model: model, open: open) }
                KeyHint(TodayCopy.holdHintBefore, key: hotkey, TodayCopy.holdHintAfter)
                    .accessibilityIdentifier("today.holdHint")
            }
        }
        .accessibilityIdentifier("today.page")
    }

    private func perform(_ action: TodayStateAction) {
        switch action {
        case .tryDictation: open(.settings(.shortcuts))
        case .reviewRetention: open(WindowRoute(.privacy))
        case .clearSearch: Task { await model.clearHistorySearch() }
        case .retry: Task { await model.retryHistory() }
        case .none: break
        }
    }

    // MARK: What needs attention (the readiness strip, only when something is not ready)

    private var blockers: some View {
        GroupBox(TodaySectionCopy.needsAttention, layout: .rows) {
            ForEach(model.blockers) { row in
                RowView(row.label, detail: row.detail) {
                    HStack(spacing: Tokens.Spacing.s) {
                        StatusTag(row.word, kind: .warn)
                        if let title = row.actionTitle {
                            Button(title) { open(TodaySectionCopy.route(forReadiness: row.id)) }
                                .accessibilityIdentifier("today.readiness.\(row.id).action")
                        }
                    }
                }
                .accessibilityIdentifier("today.readiness.\(row.id)")
            }
        }
    }

    // MARK: Recent dictations

    @ViewBuilder private var recentGroup: some View {
        if let banner = model.historyBanner {
            ScopedBanner(banner, isRetrying: retry.isRetrying) { Task { await model.retryHistory() } }
        }
        GroupBox(TodayCopy.recentHeading, layout: model.history.isContent ? .rows : .padded) {
            switch model.history.rendering {
            case .content:
                ForEach(model.recent) { row in recentRow(row) }
            case .loading:
                Text(model.history.headline)
                    .windowFont(Tokens.Typography.body)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .accessibilityIdentifier("today.recent.loading")
            case .empty, .error:
                inlineState(model.history)
            }
        }
        .accessibilityIdentifier("today.recent")
    }

    /// One row: excerpt over "12:42 · Mail", the tag at the trailing edge. The row opens the turn.
    private func recentRow(_ row: TodayTurnRow) -> some View {
        RowView(row.excerpt, detail: row.subtitle()) {
            if row.tag.opensTurn {
                Button(row.tag.label) { model.openTurn(row.id) }
                    .accessibilityIdentifier("today.recent.review")
            } else {
                StatusTag(row.tag)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openTurn(row.id) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(row.excerpt), \(row.subtitle()), \(row.tag.label)")
        .accessibilityAction { model.openTurn(row.id) }
        .accessibilityIdentifier("today.recent.row")
        // S10 — a keyboard stop in reading order that Return opens, and where focus comes back to
        // when its turn detail closes.
        .focusReturnTarget(TodayFocus.row(row.id), in: .today)
        .onKeyPress(.return) { model.openTurn(row.id); return .handled }
    }

    /// The recent group's empty or error when drafts keep the page as content.
    private func inlineState(_ state: SectionState) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label {
                Text(state.headline).fontWeight(.medium)
            } icon: {
                Image(systemName: state.rendering == .error ? "exclamationmark.triangle" : "text.bubble")
            }
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(state.rendering == .error ? WindowColor.attention : WindowColor.ink)
            if let detail = state.detail {
                Text(detail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            if let title = state.actionTitle {
                PageActionButton(action: PageAction(title, isPrimary: false,
                                                    isEnabled: !(state.rendering == .error && retry.isRetrying),
                                                    identifier: "today.recent.action") {
                    perform(model.stateAction(for: state))
                })
            }
        }
        .accessibilityIdentifier("today.recent.\(state.rendering.rawValue)")
    }
}

/// A held or partial draft (prototype Today `.banner`): ⚠ "Text waiting for Mail", the text with its
/// uncertain words marked, what happened, where it is kept, then Review text · Copy.
struct TodayDraftCard: View {
    var draft: TodayDraft
    var notice: TodayNotice?
    var review: () -> Void
    var copy: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Label {
                Text(draft.headline).fontWeight(.semibold)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(WindowColor.attention)
            .accessibilityIdentifier("today.draft.headline")
            TurnTextView(text: draft.text, uncertain: draft.uncertainSpans, accessibilityIdentifier: "today.draft.text")
            Text(draft.consequence)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            Text(draft.retention.label)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
                .accessibilityIdentifier("today.draft.retention")
            HStack(spacing: Tokens.Spacing.s) {
                PageActionButton(action: PageAction(TodayCopy.reviewText, identifier: "today.draft.review", perform: review))
                PageActionButton(action: PageAction(TodayCopy.copy, isPrimary: false, identifier: "today.draft.copy", perform: copy))
            }
            .padding(.top, Tokens.Spacing.xs)
            if let notice { TodayNoticeLine(notice: notice) }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(WindowColor.attention.opacity(ScopedBannerStyle.fillOpacity)))
        .overlay(shape.strokeBorder(contrast == .increased ? WindowColor.controlBorder
                                                            : WindowColor.attention.opacity(ScopedBannerStyle.outlineOpacity),
                                    lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.draft")
    }
}

enum TodaySectionCopy {
    static let needsAttention = "Needs attention"

    /// Where a readiness row's action goes: the key → Shortcuts, the microphone → Voice, the model
    /// → Models, mute → Privacy (hard mute lives there).
    static func route(forReadiness id: String) -> WindowRoute {
        switch id {
        case "key": return .settings(.shortcuts)
        case "microphone": return WindowRoute(.voice)
        case "model": return .settings(.models)
        case "mute": return WindowRoute(.privacy)
        default: return .settings(.general)
        }
    }
}
