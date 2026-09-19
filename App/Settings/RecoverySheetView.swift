import AppKit
import SwiftUI

// S7b — the recovery sheet (design §8.1, prototype `case'recovery'`): the still held-tape Spool and
// its note, "Your text is still here." over "Destination changed · held for Mail", the banner, the
// complete payload (selectable, uncertain words marked), the current destination preview, then
// Insert here · Copy text · Discard…, the outcome line, and the retention footnote. Closing keeps the
// draft. Everything it says is `RecoverySheetModel`'s.

struct RecoverySheetView: View {
    @ObservedObject var model: RecoverySheetModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
            if model.state.isContent, let draft = model.draft {
                content(draft)
            } else {
                EmptyState(pose: .ready, headline: model.state.headline, message: model.state.detail,
                           action: model.state.actionTitle.map { PageAction($0, identifier: "recovery.state.action", perform: close) })
                    .accessibilityIdentifier("recovery.state.\(model.state.rendering.rawValue)")
            }
            HStack {
                Spacer()
                Button(model.isResolved ? RecoverySheetCopy.done : RecoverySheetCopy.close, action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("recovery.close")
            }
        }
        .padding(MainWindowLayout.outerPadding)
        .frame(width: RecoverySheetCopy.width)
        .background(WindowColor.canvas)
        .onAppear { model.load() }
        // Back from picking a field in another app: re-read the destination preview and the draft.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshTarget()
            model.refreshDraft()
        }
        .onChange(of: model.phase) { _, phase in
            if phase == .discarded { close() }
        }
        .confirmationDialog(RecoverySheetModel.discardHeadline,
                            isPresented: Binding(get: { model.confirmingDiscard }, set: { if !$0 { model.cancelDiscard() } }),
                            titleVisibility: .visible) {
            Button(RecoverySheetModel.discardConfirm, role: .destructive) { model.confirmDiscard() }
                .accessibilityIdentifier("recovery.confirmDiscard")
            Button(SectionCopy.cancel, role: .cancel) { model.cancelDiscard() }
        } message: {
            Text(RecoverySheetModel.discardDetail)
        }
        .accessibilityIdentifier("recovery.sheet")
    }

    @ViewBuilder private func content(_ draft: TodayDraft) -> some View {
        SpoolNote(SpoolSurfacePolicy.appearance(on: .recoverySheet)?.key ?? .held, SpoolSurfacePolicy.heldNote)
        PageHeader(model.title, subtitle: model.subtitle)
        if let banner = model.banner {
            ScopedBanner(banner, onAction: banner.recoveryID == .S03 ? { model.copy() } : nil)
        }
        TurnPaper {
            ScrollView {
                TurnTextView(text: draft.text, uncertain: draft.uncertainSpans, selectAllRequest: model.selectAllRequest,
                             accessibilityIdentifier: "recovery.text")
            }
            .frame(maxHeight: RecoverySheetCopy.textMaxHeight)
        }
        Label(model.destinationLine, systemImage: "text.cursor")
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(WindowColor.secondaryInk)
            .accessibilityIdentifier("recovery.destination")
        HStack(spacing: Tokens.Spacing.s) {
            PageActionButton(action: PageAction(HeldAction.insertHere.label, isPrimary: !model.copyIsPrimary,
                                                isEnabled: model.canAct, identifier: "recovery.insertHere") {
                Task { await model.insertHere() }
            })
            PageActionButton(action: PageAction(TodayCopy.copyText, isPrimary: model.copyIsPrimary,
                                                isEnabled: model.canAct, identifier: "recovery.copy") { model.copy() })
            PageActionButton(action: PageAction(RecoverySheetCopy.discard, isPrimary: false,
                                                isEnabled: model.canAct, identifier: "recovery.discard") { model.requestDiscard() })
            if model.phase == .inserting {
                ProgressView().controlSize(.small)
                Text(RecoverySheetCopy.checkingField)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
        if let notice = model.outcomeNotice {
            TodayNoticeLine(notice: notice,
                            action: model.problemAction.map { PageAction($0, isPrimary: false, identifier: "recovery.problem.action",
                                                                         perform: model.performProblemAction) })
        }
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ForEach(model.retentionLines, id: \.self) { line in
                Text(line)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recovery.retention")
    }
}

enum RecoverySheetCopy {
    /// Pill held row's third button (fixture `pill.held.buttons`).
    static let discard = "Discard…"
    static let close = "Close"
    static let done = "Done"
    static let checkingField = "Checking the field…"
    static let width: CGFloat = 560
    static let textMaxHeight: CGFloat = 220
}
