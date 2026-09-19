import AppKit
import Foundation
import Shared
import SwiftUI

// S5 — the correction popover (design §7 "Click uncertain word / Review", §8.8, prototype
// `#reviewDialog`): anchored to the word; at most three credible alternatives, the word itself to
// keep, Edit… for a spelling of one's own, "Remember this spelling in Dictionary" (unchecked); closes
// on Escape and gives focus back. It never edits anything itself: a decision goes to
// `WordCorrectionApplier`, which replaces only a range that still reads as landed (D10 otherwise).

/// What the user decided in the popover.
public enum WordReviewDecision: Equatable, Sendable {
    /// Replace the marked word with this spelling. `remember` adds it to the learned lexicon.
    case replace(String, remember: Bool)
    /// Keep the word as it is; its mark clears for this turn.
    case keep
    /// Closed (Escape, Cancel, ×): nothing changes.
    case dismiss
}

/// The popover as a value: copy, choices and the steps between them. Tests drive it without AppKit.
public struct CorrectionPopoverModel: Equatable, Sendable {
    /// Before insertion (the pill's final preview) or on the verified range in the destination.
    public enum Origin: String, Equatable, Sendable { case preview, destination }

    public enum Stage: Equatable, Sendable {
        /// Alternatives, Keep and Edit….
        case choosing
        /// The spelling field is open.
        case editing
        /// D10: the destination changed before the correction; nothing was replaced. `copied` once
        /// "Copy correction" put the spelling on the clipboard.
        case textChanged(replacement: String, copied: Bool)
    }

    // Copy (prototype `#reviewDialog`; design §7 ASCII; catalogue T05 / D10).
    public static let eyebrow = "Word review"
    public static let suggestionNote = "Suggested spelling, not certainty"
    public static let editLabel = "Edit…"
    public static let editPrompt = "Or enter a spelling"
    public static let editPlaceholder = "Your spelling"
    public static let useSpellingLabel = "Use spelling"
    public static let rememberLabel = "Remember this spelling in Dictionary"
    public static let cancelLabel = "Cancel"
    public static let closeLabel = "Close correction review"
    /// Before insertion a choice is applied to the verified range right after the text lands.
    public static let previewNote = "Your choice replaces the word once it is inserted, only if the text is unchanged."

    public var mark: UncertainMark
    public var origin: Origin
    public var confidenceAvailable: Bool
    public var stage: Stage = .choosing
    public var draft: String = ""
    /// "Remember this spelling in Dictionary" — unchecked unless the user ticks it.
    public var remember = false
    /// "2 of 3" when Review walks several marks.
    public var position: (index: Int, total: Int)?

    public init(mark: UncertainMark, origin: Origin, confidenceAvailable: Bool = true, position: (Int, Int)? = nil) {
        self.mark = mark
        self.origin = origin
        self.confidenceAvailable = confidenceAvailable
        self.position = position.map { (index: $0.0, total: $0.1) }
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.mark == b.mark && a.origin == b.origin && a.confidenceAvailable == b.confidenceAvailable && a.stage == b.stage
            && a.draft == b.draft && a.remember == b.remember && a.position?.index == b.position?.index
            && a.position?.total == b.position?.total
    }

    /// ≤ 3 credible alternatives, best first.
    public var alternatives: [String] { Array(mark.alternatives.prefix(UncertaintyMarkMapper.maxAlternatives)) }

    public var isPhrase: Bool { mark.kind != .word }

    /// "Did you mean “Meera”?" · "Review “Mira”" · "Review this phrase" (T05) · "The text has changed" (D10).
    public var title: String {
        if case .textChanged = stage { return RecoveryCatalog.entry(.D10).headline }
        if isPhrase { return MarkCopy.reviewPhrase }
        if let top = alternatives.first { return "Did you mean “\(top)”?" }
        return "Review “\(mark.text)”"
    }

    /// "“Mira” was uncertain. Choose a spelling or keep what you said." — or T05's / D10's consequence,
    /// or "Confidence unavailable" when the result carried none (nothing is claimed as checked).
    public var detail: String {
        if case .textChanged = stage { return RecoveryCatalog.entry(.D10).consequence }
        if !confidenceAvailable { return MarkCopy.confidenceUnavailable }
        if isPhrase { return RecoveryCatalog.entry(.T05).consequence }
        return "“\(mark.text)” was uncertain. Choose a spelling or keep what you said."
    }

    /// "Mira · keep".
    public var keepLabel: String { "\(mark.text) · keep" }

    /// D10's one action.
    public var copyCorrectionLabel: String { RecoveryCatalog.entry(.D10).action }

    /// Remembering applies to one word's spelling.
    public var offersRemember: Bool { !isPhrase }

    public var positionLabel: String? {
        guard let p = position, p.total > 1 else { return nil }
        return "\(p.index) of \(p.total)"
    }

    /// VoiceOver for the popover as a whole.
    public var accessibilityLabel: String { "\(Self.eyebrow). \(title). \(detail)" }

    // MARK: Steps

    public func choose(_ alternative: String) -> WordReviewDecision {
        .replace(alternative, remember: remember && offersRemember)
    }

    public func keep() -> WordReviewDecision { .keep }

    public mutating func startEditing() {
        stage = .editing
        if draft.isEmpty { draft = mark.text }
    }

    /// "Use spelling": nil while the field is blank; the word itself counts as keeping it.
    public func submitEdit() -> WordReviewDecision? {
        let spelling = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty else { return nil }
        if spelling == mark.text { return .keep }
        return .replace(spelling, remember: remember && offersRemember)
    }

    /// Escape, Cancel or ×.
    public func dismiss() -> WordReviewDecision { .dismiss }

    /// D10: show the changed-text notice with "Copy correction".
    public mutating func textChanged(replacement: String) {
        stage = .textChanged(replacement: replacement, copied: false)
    }

    /// "Copy correction" was pressed; returns the text to put on the clipboard.
    public mutating func copyCorrection() -> String? {
        guard case .textChanged(let replacement, _) = stage else { return nil }
        stage = .textChanged(replacement: replacement, copied: true)
        return replacement
    }
}

/// Placement of the popover next to its word: below it, above when there is no room, inside the
/// screen's visible frame. AppKit coordinates.
public enum CorrectionPopoverLayout {
    public static let size = CGSize(width: 300, height: 196)
    public static let gap: CGFloat = 6

    public static func frame(anchoredTo word: CGRect, size: CGSize = size, in screen: CGRect) -> CGRect {
        var origin = CGPoint(x: word.minX, y: word.minY - gap - size.height)
        if origin.y < screen.minY { origin.y = word.maxY + gap }
        origin.x = min(max(origin.x, screen.minX), max(screen.minX, screen.maxX - size.width))
        origin.y = min(max(origin.y, screen.minY), max(screen.minY, screen.maxY - size.height))
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - View

final class CorrectionPopoverState: ObservableObject {
    @Published var model: CorrectionPopoverModel?
}

struct CorrectionPopoverView: View {
    @ObservedObject var state: CorrectionPopoverState
    var decide: (WordReviewDecision) -> Void
    var copyCorrection: () -> Void
    var next: (() -> Void)?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if let model = state.model {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(CorrectionPopoverModel.eyebrow.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let position = model.positionLabel {
                        Text(position).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { decide(model.dismiss()) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(CorrectionPopoverModel.closeLabel)
                }
                Text(model.title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(model.detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content(model)
            }
            .padding(12)
            .frame(width: CorrectionPopoverLayout.size.width, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Tokens.Radius.control + 4).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control + 4).stroke(Color.primary.opacity(0.12)))
            .onExitCommand { decide(model.dismiss()) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityIdentifier("correction.popover")
        }
    }

    @ViewBuilder
    private func content(_ model: CorrectionPopoverModel) -> some View {
        switch model.stage {
        case .choosing:
            FlowRow {
                ForEach(Array(model.alternatives.enumerated()), id: \.offset) { index, alternative in
                    choice(alternative, primary: index == 0) { decide(model.choose(alternative)) }
                        .accessibilityIdentifier("correction.alternative.\(index)")
                }
                choice(model.keepLabel, primary: model.alternatives.isEmpty) { decide(model.keep()) }
                    .accessibilityIdentifier("correction.keep")
                choice(CorrectionPopoverModel.editLabel, primary: false) {
                    state.model?.startEditing()
                    fieldFocused = true
                }
                .accessibilityIdentifier("correction.edit")
            }
            if !model.alternatives.isEmpty {
                Text(CorrectionPopoverModel.suggestionNote).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            footer(model)
        case .editing:
            Text(CorrectionPopoverModel.editPrompt).font(.system(size: 11)).foregroundStyle(.secondary)
            TextField(CorrectionPopoverModel.editPlaceholder, text: Binding(
                get: { state.model?.draft ?? "" }, set: { state.model?.draft = $0 }))
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { if let d = state.model?.submitEdit() { decide(d) } }
                .accessibilityIdentifier("correction.field")
            HStack {
                Button(CorrectionPopoverModel.useSpellingLabel) { if let d = state.model?.submitEdit() { decide(d) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled((state.model?.submitEdit()) == nil)
                Button(CorrectionPopoverModel.cancelLabel) { decide(model.dismiss()) }
            }
            footer(model)
        case .textChanged(_, let copied):
            HStack {
                Button(copied ? "Copied" : model.copyCorrectionLabel) { copyCorrection() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(copied)
                    .accessibilityIdentifier("correction.copy")
                Button(CorrectionPopoverModel.cancelLabel) { decide(.dismiss) }
            }
        }
    }

    @ViewBuilder
    private func footer(_ model: CorrectionPopoverModel) -> some View {
        if model.offersRemember {
            Toggle(CorrectionPopoverModel.rememberLabel, isOn: Binding(
                get: { state.model?.remember ?? false }, set: { state.model?.remember = $0 }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .accessibilityIdentifier("correction.remember")
        }
        if model.origin == .preview {
            Text(CorrectionPopoverModel.previewNote).font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let next {
            Button("Next word", action: next).buttonStyle(.borderless).font(.system(size: 11))
        }
    }

    private func choice(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: primary ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(primary ? Color.white : Color.primary)
        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .fill(primary ? Color.accentColor : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control).stroke(Color.primary.opacity(primary ? 0 : 0.15)))
    }
}

/// Buttons in a row that wraps.
private struct FlowRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

// MARK: - Panel

/// A panel that takes keys (the spelling field, Escape) without activating VoicePlus, so the
/// destination app stays frontmost and gets its focus back when the popover closes.
final class CorrectionPopoverPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Shows one popover at a time, anchored to a word's screen rect.
public final class CorrectionPopoverController {
    private let panel: CorrectionPopoverPanel
    private let state = CorrectionPopoverState()
    private var previousKey: NSWindow?
    /// The user decided (replace, keep or dismiss) for the shown mark.
    public var onDecision: ((WordReviewDecision, CorrectionPopoverModel) -> Void)?
    /// "Copy correction" (D10): put the spelling on the clipboard.
    public var onCopy: ((String) -> Void)?
    /// "Next word" while reviewing several marks.
    public var onNext: (() -> Void)?
    /// The popover went away, whatever the reason.
    public var onClose: (() -> Void)?
    /// During a turn Escape is a global hot key: the open popover is a layer it closes first (S10).
    public var escapeLayers: EscapeLayerStack = .shared

    public init() {
        panel = CorrectionPopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar + 2
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.onEscape = { [weak self] in self?.decide(.dismiss) }
        rebuild()
    }

    public var model: CorrectionPopoverModel? { state.model }
    public var isShown: Bool { state.model != nil }

    /// Shows `model` next to `word` (AppKit screen rect) and takes key focus for Escape and the field.
    public func show(_ model: CorrectionPopoverModel, anchoredTo word: CGRect, hasNext: Bool = false) {
        state.model = model
        rebuild(hasNext: hasNext)
        let screen = (NSScreen.screens.first { $0.frame.intersects(word) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let fitting = panel.contentView?.fittingSize ?? CorrectionPopoverLayout.size
        let size = CGSize(width: CorrectionPopoverLayout.size.width, height: max(120, fitting.height))
        if !panel.isVisible { previousKey = NSApplication.shared.keyWindow }
        panel.setFrame(CorrectionPopoverLayout.frame(anchoredTo: word, size: size, in: screen), display: true)
        panel.makeKeyAndOrderFront(nil)
        // During a turn Escape is a global hot key: this layer takes the press before the turn does (S10).
        escapeLayers.push(ObjectIdentifier(self)) { [weak self] in self?.decide(.dismiss) }
        NSAccessibility.post(element: panel, notification: .focusedUIElementChanged)
    }

    /// D10 inside the open popover: "The text has changed" with "Copy correction".
    public func showTextChanged(replacement: String) {
        state.model?.textChanged(replacement: replacement)
    }

    public func close() {
        guard state.model != nil || panel.isVisible else { return }
        state.model = nil
        panel.orderOut(nil)
        escapeLayers.remove(ObjectIdentifier(self))
        // Focus goes back where it was: our own window if one was key, else the destination app,
        // which never stopped being frontmost (the panel does not activate VoicePlus).
        if let previousKey, previousKey.isVisible { previousKey.makeKey() }
        previousKey = nil
        onClose?()
    }

    private func decide(_ decision: WordReviewDecision) {
        guard let model = state.model else { return }
        onDecision?(decision, model)
        if decision == .dismiss { close() }
    }

    private func rebuild(hasNext: Bool = false) {
        panel.contentView = NSHostingView(rootView: CorrectionPopoverView(
            state: state,
            decide: { [weak self] in self?.decide($0) },
            copyCorrection: { [weak self] in
                guard let self, let text = self.state.model?.copyCorrection() else { return }
                self.onCopy?(text)
            },
            next: hasNext ? { [weak self] in self?.onNext?() } : nil))
    }
}
