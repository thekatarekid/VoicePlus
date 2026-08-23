import Foundation

/// In-memory `SystemAccess`. Simulates one focused text field per frontmost app and a pasteboard.
/// Behaviour knobs (`axWriteWorks`, `keystrokesWork`, `pasteWorks`, `axReadable`) let tests model
/// hostile apps (Electron ignoring AX writes, Figma swallowing keystrokes, etc.).
open class MockSystemAccess: SystemAccess {
    public struct Field: Equatable {
        public var role: String = "AXTextArea"
        public var value: String = ""
        public var selection: Range<Int> = 0..<0
        public init(role: String = "AXTextArea", value: String = "", selection: Range<Int>? = nil) {
            self.role = role
            self.value = value
            self.selection = selection ?? value.utf16.count..<value.utf16.count
        }
    }

    public var isAccessibilityTrusted = true
    public var frontmost: FocusSnapshot?
    public var field = Field()
    public var hasFocusedElement = true

    /// Whether AX exposes the field's value for reading (false models Electron/Figma canvases).
    public var axReadable = true
    public var axWriteWorks = true
    public var keystrokesWork = true
    public var pasteWorks = true
    /// Simulates a user or clipboard manager touching the pasteboard between our write and our restore.
    public var externalPasteboardWriteAfterOurWrite: String?

    public private(set) var pasteboardItems: [PasteboardItemSnapshot] = []
    public private(set) var changeCount = 0
    public private(set) var journal: [String] = []
    /// Called before every keystroke/AX write; tests use it to change focus mid-injection.
    public var beforeSideEffect: (() -> Void)?

    public init(frontmost: FocusSnapshot? = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-1")) {
        self.frontmost = frontmost
    }

    // MARK: Focus

    public func frontmostApp() -> FocusSnapshot? { frontmost }

    public func focusedElement() throws -> FocusedElementInfo {
        guard isAccessibilityTrusted else { throw SystemAccessError.accessibilityNotTrusted }
        guard hasFocusedElement else { throw SystemAccessError.noFocusedElement }
        return FocusedElementInfo(role: field.role,
                                  value: axReadable ? field.value : nil,
                                  selectedRange: axReadable ? field.selection : nil,
                                  isValueSettable: axWriteWorks,
                                  isSelectedTextSettable: axWriteWorks)
    }

    // MARK: AX writes

    open func setFocusedValue(_ value: String) throws {
        beforeSideEffect?()
        journal.append("ax.setValue")
        guard axWriteWorks else { throw SystemAccessError.attributeNotSettable("AXValue") }
        field.value = value
        let end = value.utf16.count
        field.selection = end..<end
    }

    open func setFocusedSelectedRange(_ range: Range<Int>) throws {
        journal.append("ax.setSelectedRange(\(range.lowerBound),\(range.count))")
        guard axWriteWorks else { throw SystemAccessError.attributeNotSettable("AXSelectedTextRange") }
        field.selection = range
    }

    open func setFocusedSelectedText(_ text: String) throws {
        beforeSideEffect?()
        journal.append("ax.setSelectedText")
        guard axWriteWorks else { throw SystemAccessError.attributeNotSettable("AXSelectedText") }
        insertAtSelection(text)
    }

    // MARK: CGEvent

    open func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws {
        beforeSideEffect?()
        journal.append("key.unicode(\(pid)):\(text)")
        guard keystrokesWork, pid == frontmost?.pid else { return }   // events go nowhere useful
        insertAtSelection(text)
    }

    open func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws {
        journal.append("key.combo(\(pid)):\(combo.keyCode)\(combo.command ? "+cmd" : "")\(combo.option ? "+opt" : "")")
        guard pid == frontmost?.pid else { return }
        if combo == .paste {
            guard pasteWorks, let string = pasteboardString else { return }
            insertAtSelection(string)
        } else if combo == .optionReturn || combo == .returnKey {
            if keystrokesWork { insertAtSelection("\n") }
        }
    }

    // MARK: Pasteboard

    public func readPasteboard() -> PasteboardSnapshot {
        PasteboardSnapshot(items: pasteboardItems, changeCount: changeCount)
    }

    @discardableResult
    public func writePasteboard(string: String) -> Int {
        setPasteboard([PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data(string.utf8)])])
        let ours = changeCount
        if let external = externalPasteboardWriteAfterOurWrite {
            setPasteboard([PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data(external.utf8)])])
            externalPasteboardWriteAfterOurWrite = nil
        }
        return ours
    }

    public func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        journal.append("pasteboard.restore")
        setPasteboard(snapshot.items)
    }

    public var pasteboardChangeCount: Int { changeCount }

    public func settle(milliseconds: Int) {}

    // MARK: Test helpers

    /// Seeds the pasteboard as if the user had copied something (any types, e.g. an image).
    public func setPasteboard(_ items: [PasteboardItemSnapshot]) {
        pasteboardItems = items
        changeCount += 1
    }

    public var pasteboardString: String? {
        guard let data = pasteboardItems.first?.types["public.utf8-plain-text"] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func insertAtSelection(_ text: String) {
        var utf16 = Array(field.value.utf16)
        let lower = max(0, min(field.selection.lowerBound, utf16.count))
        let sel = lower..<max(lower, min(field.selection.upperBound, utf16.count))
        utf16.replaceSubrange(sel, with: Array(text.utf16))
        field.value = String(decoding: utf16, as: UTF16.self)
        let caret = sel.lowerBound + text.utf16.count
        field.selection = caret..<caret
    }
}
