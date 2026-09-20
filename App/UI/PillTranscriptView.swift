import AppKit
import SwiftUI

/// The fixed two-line reading window. TextKit preserves native selection, keyboard scrolling,
/// input methods and grapheme boundaries while the rail remains visible independently of macOS's
/// auto-hiding scrollbar preference.
struct PillTranscriptView: NSViewRepresentable {
    @ObservedObject var model: PillViewModel
    let words: PillContent.Words
    let marks: MarkMapping

    func makeNSView(context: Context) -> PillTranscriptViewport { PillTranscriptViewport() }
    func updateNSView(_ view: PillTranscriptViewport, context: Context) {
        view.configure(model: model, words: words, marks: marks)
    }
}

final class PillTranscriptViewport: NSView, NSTextViewDelegate {
    let scroll = NSScrollView()
    let text = DraftTextView()
    private let up = NSButton()
    private let down = NSButton()
    private let track = TranscriptRail()
    private weak var model: PillViewModel?
    private var observed: NSObjectProtocol?
    private var editing = false
    private var selectedMark: Int?
    private var updating = false
    private var live = false
    private var lastSource = ""
    private var shownMarks: MarkMapping = .empty
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        text.focusRingType = .none
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.contentView.postsBoundsChangedNotifications = true
        text.drawsBackground = false
        text.isRichText = false
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.insertionPointColor = Tokens.Pill.primary
        text.selectedTextAttributes = [.backgroundColor: Tokens.Pill.control]
        text.linkTextAttributes = [:]
        text.delegate = self
        text.setAccessibilityIdentifier("pill.words")
        text.setAccessibilityLabel("Dictation text. Scroll to read the full text.")
        scroll.documentView = text
        addSubview(scroll)
        for (button, name, symbol, action) in [
            (up, "Scroll transcript up", "chevron.up", #selector(scrollUp)),
            (down, "Scroll transcript down", "chevron.down", #selector(scrollDown))
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = Tokens.Pill.secondaryInk
            button.target = self
            button.action = action
            button.setAccessibilityLabel(name)
            addSubview(button)
        }
        track.onFraction = { [weak self] fraction in
            guard let self else { return }
            self.scrollTo(fraction * self.maximumOffset)
        }
        addSubview(track)
        observed = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in self?.refreshRail() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observed { NotificationCenter.default.removeObserver(observed) } }

    func configure(model: PillViewModel, words: PillContent.Words, marks: MarkMapping) {
        self.model = model
        text.onKeyInteraction = { [weak model] in
            if let model, !model.pointerInside { model.noteKeyboardInteraction() }
        }
        text.onCompositionChange = { [weak self] in self?.publishEditorText() }
        let began = !editing && model.isEditingDraft
        let ended = editing && !model.isEditingDraft
        editing = model.isEditingDraft
        needsDisplay = true
        let wasLive = live
        if case .live = words { live = true } else { live = false }
        let source = editing ? model.draftText : words.text ?? ""
        let followsEnd = scroll.contentView.bounds.minY >= maximumOffset - 3
        let changed = source != lastSource || shownMarks != marks || began || ended || wasLive != live
        text.isEditable = editing
        if ended {
            model.setFocus(false, element: "draft.editor")
            if window?.firstResponder === text { window?.makeFirstResponder(nil) }
            window?.resignKey()
        }
        text.setAccessibilityLabel(editing ? "Edit dictation draft" : "Dictation text. Scroll to read the full text.")
        if changed && !text.hasMarkedText() {
            updating = true
            let selection = text.selectedRange()
            text.textStorage?.setAttributedString(attributed(source, words: words, marks: marks))
            text.setSelectedRange(NSRange(location: min(selection.location, text.string.utf16.count), length: 0))
            lastSource = source
            shownMarks = marks
            updating = false
            needsLayout = true
            layoutSubtreeIfNeeded()
            if live && followsEnd { scrollTo(maximumOffset) }
            if ended || (wasLive && !live) { scrollTo(0) }
        }
        if began || (editing && selectedMark != model.editingMarkID) {
            selectedMark = model.editingMarkID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editing else { return }
                self.window?.makeKey()
                self.window?.makeFirstResponder(self.text)
                if let id = self.selectedMark, let mark = marks.mark(id: id) {
                    let range = NSRange(location: mark.range.lowerBound, length: mark.range.count)
                    if NSMaxRange(range) <= self.text.string.utf16.count {
                        self.text.setSelectedRange(range)
                        self.text.scrollRangeToVisible(range)
                    }
                }
            }
        }
    }

    private func attributed(_ source: String, words: PillContent.Words, marks: MarkMapping) -> NSAttributedString {
        let ink: NSColor
        if case .fixed = words { ink = Tokens.Pill.secondaryInk } else { ink = Tokens.Pill.ink }
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: Tokens.Typography.pillTranscript.nsFont(), .foregroundColor: ink,
            .paragraphStyle: Tokens.Typography.pillTranscript.paragraphStyle()
        ])
        guard !editing else { return result }
        // Insert alternatives backwards so every original UTF-16 range stays valid.
        for mark in marks.marks.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let range = NSRange(location: mark.range.lowerBound, length: mark.range.count)
            guard range.location >= 0, NSMaxRange(range) <= source.utf16.count else { continue }
            result.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: Tokens.Pill.uncertainty,
                .link: "word:\(mark.id)"
            ], range: range)
            if let suggestion = model?.suggestion(for: mark) {
                let alternative = NSMutableAttributedString(string: " [\(suggestion)]", attributes: [
                    .font: Tokens.Typography.pillTranscript.nsFont(),
                    .foregroundColor: Tokens.Pill.uncertainty,
                    .paragraphStyle: Tokens.Typography.pillTranscript.paragraphStyle(),
                    .link: "suggest:\(mark.id)"
                ])
                result.insert(alternative, at: NSMaxRange(range))
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        guard editing else { return }
        Tokens.Pill.controlBorder.setFill()
        CGRect(x: 0, y: max(0, bounds.height - 1), width: scroll.frame.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        // The rail occupies the dedicated gap before the character bay.
        scroll.frame = CGRect(x: 0, y: 0, width: max(1, bounds.width - 30), height: bounds.height)
        text.frame.size.width = scroll.contentSize.width
        text.textContainer?.containerSize = CGSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 21
        let single = used <= 22 && !editing
        text.textContainerInset = CGSize(width: 0, height: single ? 13.5 : 3)
        text.frame.size.height = max(bounds.height, ceil(used) + (single ? 27 : 6))
        up.frame = CGRect(x: bounds.width - 16, y: 0, width: 16, height: 11)
        down.frame = CGRect(x: bounds.width - 16, y: bounds.height - 11, width: 16, height: 11)
        track.frame = CGRect(x: bounds.width - 12, y: 12, width: 8, height: max(1, bounds.height - 24))
        refreshRail()
    }
    private var maximumOffset: CGFloat { max(0, text.frame.height - scroll.contentSize.height) }
    private func scrollTo(_ y: CGFloat) {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, y), maximumOffset)))
        scroll.reflectScrolledClipView(scroll.contentView)
        refreshRail()
    }
    private func refreshRail() {
        let maximum = maximumOffset
        let y = scroll.contentView.bounds.minY
        track.isHidden = maximum < 1
        up.isHidden = maximum < 1 || y < 1
        down.isHidden = maximum < 1 || y >= maximum - 1
        track.fraction = maximum > 0 ? y / maximum : 0
        track.visibleFraction = min(1, scroll.contentSize.height / max(1, text.frame.height))
        track.needsDisplay = true
    }
    @objc private func scrollUp() { scrollTo(scroll.contentView.bounds.minY - 21) }
    @objc private func scrollDown() { scrollTo(scroll.contentView.bounds.minY + 21) }
    func textDidChange(_ notification: Notification) {
        guard !updating, editing else { return }
        publishEditorText()
    }
    private func publishEditorText() {
        guard !updating, editing else { return }
        model?.draftText = text.string
        lastSource = text.string
        model?.setCompositionActive(text.hasMarkedText())
        needsLayout = true
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let link = (link as? URL)?.absoluteString ?? (link as? String), let id = Int(link.split(separator: ":").last ?? "") else { return false }
        if link.hasPrefix("suggest:"), let mark = shownMarks.mark(id: id), let suggestion = model?.suggestion(for: mark) {
            model?.acceptSuggestion(markID: id, replacement: suggestion)
        } else { model?.reviewMark(id) }
        return true
    }
    func textDidBeginEditing(_ notification: Notification) { model?.setFocus(true, element: "draft.editor") }
    func textDidEndEditing(_ notification: Notification) {
        model?.setCompositionActive(text.hasMarkedText())
        model?.setFocus(false, element: "draft.editor")
    }
}

private final class TranscriptRail: NSView {
    var fraction: CGFloat = 0
    var visibleFraction: CGFloat = 1
    var onFraction: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel("Transcript position")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.09, green: 0.067, blue: 0.05, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let height = max(8, bounds.height * visibleFraction)
        NSColor(srgbRed: 0.67, green: 0.47, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 2, y: (bounds.height - height) * fraction, width: max(2, bounds.width - 4), height: height), xRadius: 2, yRadius: 2).fill()
    }
    override func mouseDown(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    private func move(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let height = max(8, bounds.height * visibleFraction)
        onFraction?(min(1, max(0, (point.y - height / 2) / max(1, bounds.height - height))))
    }
    override func accessibilityValue() -> Any? { Int(fraction * 100) }
    override func accessibilityPerformIncrement() -> Bool { onFraction?(min(1, fraction + 0.1)); return true }
    override func accessibilityPerformDecrement() -> Bool { onFraction?(max(0, fraction - 0.1)); return true }
}


final class DraftTextView: NSTextView {
    var onKeyInteraction: (() -> Void)?
    var onCompositionChange: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }
    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }
    override func keyDown(with event: NSEvent) {
        onKeyInteraction?()
        super.keyDown(with: event)
    }
}
