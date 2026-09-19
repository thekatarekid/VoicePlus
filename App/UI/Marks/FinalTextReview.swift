import AppKit
import SwiftUI

// S5 — the Review surface the pill's "Review all" opens (design §4 "Transcript layout": a long final
// text shows its last two lines plus "N words · Review all"; §7: review keeps the marks). The whole
// final text, selectable, with its dotted marks; each mark opens word review; "Confidence unavailable"
// when the result carried none. Nothing here edits text. Closing it resumes the preview's dwell.

public struct FinalTextReviewModel: Equatable, Sendable {
    public static let eyebrow = "Final text"
    public static let closeLabel = "Done"

    public var mapping: MarkMapping

    public init(mapping: MarkMapping) { self.mapping = mapping }

    public var text: String { mapping.text }

    /// "42 words" · "1 word to review" · "Review this phrase" · "Confidence unavailable".
    public var subtitle: String {
        if !mapping.confidenceAvailable { return MarkCopy.confidenceUnavailable }
        if !mapping.isEmpty { return mapping.reviewLine }
        let words = MarkWords.words(in: mapping.text).count
        return "\(words) word\(words == 1 ? "" : "s")"
    }

    public struct MarkButton: Equatable, Identifiable, Sendable {
        public var id: Int
        public var label: String
    }

    /// One button per mark: "Review “Mira”".
    public var markButtons: [MarkButton] {
        mapping.marks.map { MarkButton(id: $0.id, label: $0.kind == .word ? "Review “\($0.text)”" : MarkCopy.reviewPhrase) }
    }

    public static func == (a: Self, b: Self) -> Bool { a.mapping == b.mapping }
}

final class FinalTextReviewState: ObservableObject {
    @Published var model: FinalTextReviewModel?
}

struct FinalTextReviewView: View {
    @ObservedObject var state: FinalTextReviewState
    var review: (Int) -> Void
    var close: () -> Void

    var body: some View {
        if let model = state.model {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(FinalTextReviewModel.eyebrow.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(attributed(model))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                if !model.markButtons.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(model.markButtons) { button in
                            Button(button.label) { review(button.id) }.controlSize(.small)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(FinalTextReviewModel.closeLabel, action: close).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.control + 4).fill(.regularMaterial))
            .onExitCommand(perform: close)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.mapping.accessibilityLabel)
            .accessibilityIdentifier("review.finalText")
        }
    }

    /// Marks as dotted underlines on whole grapheme clusters (S10).
    private func attributed(_ model: FinalTextReviewModel) -> AttributedString {
        var out = AttributedString(model.text)
        let ranges = GraphemeMarks.ranges(in: model.text, utf16Spans: model.mapping.uncertainRanges)
        for range in ranges {
            guard let r = Range(range, in: model.text), let marked = Range<AttributedString.Index>(r, in: out) else { continue }
            out[marked].underlineStyle = Text.LineStyle(pattern: .dot, color: Color(nsColor: Tokens.Colors.uncertainty))
        }
        return out
    }
}

final class FinalTextReviewPanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The Review surface's panel: under the pill, non-activating, closes on Escape or Done.
public final class FinalTextReviewPanel {
    private let panel: FinalTextReviewPanelWindow
    private let state = FinalTextReviewState()
    public var onReviewMark: ((Int) -> Void)?
    public var onClose: (() -> Void)?
    /// Escape closes this layer before it cancels the turn under it (S10).
    public var escapeLayers: EscapeLayerStack = .shared

    public init() {
        panel = FinalTextReviewPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.onEscape = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: FinalTextReviewView(
            state: state,
            review: { [weak self] in self?.onReviewMark?($0) },
            close: { [weak self] in self?.close() }))
    }

    public var isShown: Bool { state.model != nil }
    public var model: FinalTextReviewModel? { state.model }

    /// Opens under `anchor` (AppKit screen rect, the pill's "Review all").
    public func show(_ model: FinalTextReviewModel, below anchor: CGRect) {
        state.model = model
        let size = panel.contentView?.fittingSize ?? CGSize(width: 420, height: 200)
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrame(CorrectionPopoverLayout.frame(anchoredTo: anchor, size: size, in: screen), display: true)
        panel.makeKeyAndOrderFront(nil)
        escapeLayers.push(ObjectIdentifier(self)) { [weak self] in self?.close() }
    }

    /// Marks resolved while it is open.
    public func update(_ mapping: MarkMapping) {
        guard state.model != nil else { return }
        state.model = FinalTextReviewModel(mapping: mapping)
    }

    public func close() {
        guard state.model != nil else { return }
        state.model = nil
        panel.orderOut(nil)
        escapeLayers.remove(ObjectIdentifier(self))
        onClose?()
    }
}
