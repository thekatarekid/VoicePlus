import AppKit
import SwiftUI

// S7b — the payload as selectable text (design §8.9 "complete text stays selectable"), with every
// uncertain word under the design's red dotted underline (design §7; `Tokens.Role.uncertainty`).
// Shared by the turn detail, Today's held cards and the recovery sheet.
//
// An `NSTextView` rather than `Text.textSelection`: D08 ("Couldn't copy your text" › Select text)
// has to select the whole payload for a manual copy, which only a real text view can do on request.

/// The marks, as data: each uncertain span clamped to the text and ordered. What the view underlines.
enum TurnTextMarks {
    /// UTF-16 spans → `NSRange`s inside `text`; empty, negative or out-of-range spans are dropped.
    /// S10: each mark covers whole grapheme clusters, so a span never splits an emoji, a flag or a
    /// letter from its combining marks (`GraphemeMarks`).
    static func ranges(in text: String, spans: [Range<Int>]) -> [NSRange] {
        GraphemeMarks.ranges(in: text, utf16Spans: spans)
    }

    static func attributed(_ text: String, spans: [Range<Int>], scale: CGFloat = 1) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: Tokens.Typography.body.nsFont(scale: scale),
            .foregroundColor: Tokens.Colors.ink,
        ])
        for range in ranges(in: text, spans: spans) {
            out.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: Tokens.Colors.uncertainty,
            ], range: range)
        }
        return out
    }
}

/// Read-only, selectable, wrapping text with the uncertainty marks. `selectAllRequest` changing
/// focuses the text and selects all of it.
struct TurnTextView: NSViewRepresentable {
    var text: String
    var uncertain: [Range<Int>] = []
    var selectAllRequest: Int = 0
    var accessibilityIdentifier: String = "turn.text"

    @Environment(\.windowTextScale) private var scale

    final class Coordinator {
        var lastSelectAll = 0
        var lastText: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.lastSelectAll = selectAllRequest
        return coordinator
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let attributed = TurnTextMarks.attributed(text, spans: uncertain, scale: scale)
        if context.coordinator.lastText != attributed {
            view.textStorage?.setAttributedString(attributed)
            context.coordinator.lastText = attributed
        }
        if context.coordinator.lastSelectAll != selectAllRequest {
            context.coordinator.lastSelectAll = selectAllRequest
            view.window?.makeFirstResponder(view)
            view.selectAll(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 480, 40)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

/// The prototype's `.paper`: the payload on the raised surface, 24 pt inset, 10 pt corners.
struct TurnPaper<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) { content }
            .padding(Tokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(WindowColor.surface))
            .overlay(shape.strokeBorder(WindowColor.separator, lineWidth: 1))
    }
}

/// One acknowledgement or problem line: a glyph and a word, never colour alone (`DESIGN.md` §12.9).
struct TodayNoticeLine: View {
    var notice: TodayNotice
    var action: PageAction?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Label {
                Text(notice.text).fontWeight(.medium)
            } icon: {
                Image(systemName: notice.tone == .good ? "checkmark" : "exclamationmark.triangle")
            }
            .windowFont(Tokens.Typography.body)
            .foregroundStyle(notice.tone == .good ? WindowColor.ready : WindowColor.attention)
            if let detail = notice.detail, !detail.isEmpty {
                Text(detail)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            if let action { PageActionButton(action: action) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today.notice")
    }
}

extension StatusTag {
    /// A Today tag as the design's tag: good / warn / neutral, word always present.
    init(_ tag: TodayTag) {
        switch tag.tone {
        case .good: self.init(tag.label, kind: .good)
        case .warn: self.init(tag.label, kind: .warn)
        case .neutral: self.init(tag.label, kind: .neutral)
        }
    }
}
