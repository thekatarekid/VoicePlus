import Foundation
import Shared

/// In-memory `SystemAccess`. Simulates one focused text field per frontmost app and a pasteboard.
/// Behaviour knobs (`axWriteWorks`, `keystrokesWork`, `pasteWorks`, `axReadable`) let tests model
/// hostile apps (Electron ignoring AX writes, Figma swallowing keystrokes, etc.).
open class MockSystemAccess: SystemAccess {
    public struct Field: Equatable {
        public var role: String = "AXTextArea"
        /// `AXSubroleAttribute`. Set it to `FocusedElementInfo.secureRole` to model a web password
        /// field, which keeps `AXTextField` as its role.
        public var subrole: String?
        public var value: String = ""
        public var selection: Range<Int> = 0..<0
        /// R4.2 — `AXIdentifier` / `AXDescription` / `AXTitle` / `AXRoleDescription` as the live
        /// tree would report them. Set it to `["Terminal input"]` to model VS Code's integrated
        /// terminal, or `["Monaco editor"]` for its editor pane: same role, same bundle ID.
        public var hints: [String] = []
        public init(role: String = "AXTextArea", value: String = "", selection: Range<Int>? = nil,
                    subrole: String? = nil, hints: [String] = []) {
            self.role = role
            self.subrole = subrole
            self.value = value
            self.selection = selection ?? value.utf16.count..<value.utf16.count
            self.hints = hints
        }

        /// A password field, by role (native) or by subrole (web).
        public static func secure(webStyle: Bool = false) -> Field {
            webStyle ? Field(role: "AXTextField", subrole: FocusedElementInfo.secureRole)
                     : Field(role: FocusedElementInfo.secureRole)
        }
    }

    public var isAccessibilityTrusted = true
    public var frontmost: FocusSnapshot?
    public var field = Field()
    public var hasFocusedElement = true
    /// Q2 — model an Electron app that builds no AX tree until `enableAppAccessibility` is called
    /// for its pid: until then the field exposes no value, no caret and no selection.
    public var requiresAccessibilityEnable = false
    public private(set) var accessibilityEnabledPIDs: Set<Int32> = []
    /// Q2 — `enable(pid)` / `read(tree|no tree)` in call order, so a test can prove enable → read.
    /// Kept out of `journal`, whose exact contents other suites assert.
    public private(set) var accessibilityEvents: [String] = []
    /// Q1 — `AXURL` of the web area around the field (`FocusedDocumentURLReading`).
    public var documentURL: String?
    /// N5 — the focused element has an `AXWebArea` ancestor.
    public var inWebArea = false
    /// N5 — the runtime each pid reports (`.native` when absent).
    public var runtimeByPID: [Int32: SurfaceRuntime] = [:]

    /// Whether AX exposes the field's value for reading (false models Electron/Figma canvases).
    public var axReadable = true
    /// N4 — models macOS secure event input (`IsSecureEventInputEnabled`).
    public var secureEventInput = false
    /// Whether AX exposes the caret (`AXSelectedTextRange`) and `AXSelectedText` for reading.
    /// Defaults to `axReadable`; set it explicitly to model a Chromium field whose value is
    /// unreadable but whose caret is not (or the other way round).
    public var axCaretReadable: Bool?
    /// Every keystroke, key combo and AX text write that "reached the OS" — including the ones a
    /// hostile app then ignored. See `SystemAccess.postCount`.
    public private(set) var postCount = 0
    public var axWriteWorks = true
    public var keystrokesWork = true
    public var pasteWorks = true

    /// One OS touch-point that can fail. Distinguishing *how* it fails is the whole point of the
    /// readback rule (R2.3): `keystrokesWork = false` means the event was posted and the app
    /// swallowed it, which is *possibly landed*; `throwsBeforePosting` means the call failed with
    /// nothing on the wire, which is the only case the injector may fall through to another method.
    public enum PostSite: String, Sendable, CaseIterable {
        case axValue, axSelectedText, keystrokes, keyCombo
    }

    /// Sites that throw *before* incrementing `postCount`.
    public var throwsBeforePosting: Set<PostSite> = []

    private func failBeforePosting(_ site: PostSite) throws {
        guard throwsBeforePosting.contains(site) else { return }
        journal.append("throwBeforePosting.\(site.rawValue)")
        throw SystemAccessError.eventPostFailed
    }

    /// Simulates a user or clipboard manager touching the pasteboard between our write and our restore.
    public var externalPasteboardWriteAfterOurWrite: String?

    public private(set) var pasteboardItems: [PasteboardItemSnapshot] = []
    public private(set) var changeCount = 0
    public private(set) var journal: [String] = []
    /// Called before every keystroke/AX write; tests use it to change focus mid-injection.
    public var beforeSideEffect: (() -> Void)?
    /// Q3 — the app applies a write only after this many further `focusedElement()` reads: until
    /// then reads show the field as it was before the write (Electron/Chromium apply keystrokes
    /// asynchronously). 0 = applied at once.
    public var readbackLagReads = 0
    /// Q3 — every `focusedElement()` call so far.
    public private(set) var focusedReadCount = 0
    private var staleField: Field?
    private var staleReadsRemaining = 0

    public init(frontmost: FocusSnapshot? = FocusSnapshot(pid: 100, bundleID: "com.apple.TextEdit", appName: "TextEdit", elementToken: "el-1")) {
        self.frontmost = frontmost
    }

    // MARK: Focus

    public func frontmostApp() -> FocusSnapshot? { frontmost }

    public func focusedElement() throws -> FocusedElementInfo {
        guard isAccessibilityTrusted else { throw SystemAccessError.accessibilityNotTrusted }
        guard hasFocusedElement else { throw SystemAccessError.noFocusedElement }
        let exposed = !requiresAccessibilityEnable || frontmost.map { accessibilityEnabledPIDs.contains($0.pid) } == true
        accessibilityEvents.append(exposed ? "read(tree)" : "read(no tree)")
        focusedReadCount += 1
        var field = self.field
        if staleReadsRemaining > 0, let stale = staleField {
            staleReadsRemaining -= 1
            field = stale
            if staleReadsRemaining == 0 { staleField = nil }
        }
        let readable = axReadable && exposed
        let caretReadable = (axCaretReadable ?? axReadable) && exposed
        return FocusedElementInfo(role: field.role,
                                  value: readable ? field.value : nil,
                                  selectedRange: caretReadable ? field.selection : nil,
                                  isValueSettable: axWriteWorks,
                                  isSelectedTextSettable: axWriteWorks,
                                  subrole: field.subrole,
                                  selectedText: caretReadable ? Self.slice(of: field) : nil,
                                  hints: FocusedElementInfo.hints(from: field.hints.map { $0 }))
    }

    // MARK: AX writes

    open func setFocusedValue(_ value: String) throws {
        try failBeforePosting(.axValue)
        beforeSideEffect?()
        journal.append("ax.setValue")
        postCount += 1
        guard axWriteWorks else { throw SystemAccessError.attributeNotSettable("AXValue") }
        beginReadbackLag()
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
        try failBeforePosting(.axSelectedText)
        beforeSideEffect?()
        journal.append("ax.setSelectedText")
        postCount += 1
        guard axWriteWorks else { throw SystemAccessError.attributeNotSettable("AXSelectedText") }
        insertAtSelection(text)
    }

    // MARK: CGEvent

    open func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws {
        try failBeforePosting(.keystrokes)
        beforeSideEffect?()
        journal.append("key.unicode(\(pid)):\(text)")
        postCount += 1
        guard keystrokesWork, pid == frontmost?.pid else { return }   // events go nowhere useful
        insertAtSelection(text)
    }

    open func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws {
        try failBeforePosting(.keyCombo)
        journal.append("key.combo(\(pid)):\(combo.keyCode)\(combo.command ? "+cmd" : "")\(combo.option ? "+opt" : "")\(combo.shift ? "+shift" : "")")
        postCount += 1
        guard pid == frontmost?.pid else { return }
        if combo == .paste {
            guard pasteWorks, let string = pasteboardString else { return }
            insertAtSelection(string)
        } else if combo == .optionReturn || combo == .returnKey || combo == .shiftReturn {
            if keystrokesWork { insertAtSelection("\n") }
        }
    }

    // MARK: Pasteboard

    public func readPasteboard() -> PasteboardSnapshot {
        PasteboardSnapshot(items: pasteboardItems, changeCount: changeCount)
    }

    @discardableResult
    public func writePasteboard(string: String) -> Int {
        writeOurs(PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data(string.utf8)]))
    }

    private func writeOurs(_ item: PasteboardItemSnapshot) -> Int {
        pasteboardWrites.append(item)
        setPasteboard([item])
        let ours = changeCount
        if let external = externalPasteboardWriteAfterOurWrite {
            setPasteboard([PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data(external.utf8)])])
            externalPasteboardWriteAfterOurWrite = nil
        }
        return ours
    }

    /// N18 — every pasteboard write so far, as written (before any simulated external write).
    public private(set) var pasteboardWrites: [PasteboardItemSnapshot] = []

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

    /// `AXSelectedText`: the slice the selection covers — "" for a bare caret.
    public var selectedTextSlice: String {
        let utf16 = Array(field.value.utf16)
        let lower = max(0, min(field.selection.lowerBound, utf16.count))
        let upper = max(lower, min(field.selection.upperBound, utf16.count))
        return String(decoding: utf16[lower..<upper], as: UTF16.self)
    }

    public var pasteboardString: String? {
        guard let data = pasteboardItems.first?.types["public.utf8-plain-text"] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Q3 — a write starts the lag window (reads keep showing the pre-write field).
    private func beginReadbackLag() {
        guard readbackLagReads > 0 else { return }
        if staleReadsRemaining == 0 { staleField = field }
        staleReadsRemaining = readbackLagReads
    }

    private static func slice(of field: Field) -> String {
        let utf16 = Array(field.value.utf16)
        let lower = max(0, min(field.selection.lowerBound, utf16.count))
        let upper = max(lower, min(field.selection.upperBound, utf16.count))
        return String(decoding: utf16[lower..<upper], as: UTF16.self)
    }

    private func insertAtSelection(_ text: String) {
        beginReadbackLag()
        var utf16 = Array(field.value.utf16)
        let lower = max(0, min(field.selection.lowerBound, utf16.count))
        let sel = lower..<max(lower, min(field.selection.upperBound, utf16.count))
        utf16.replaceSubrange(sel, with: Array(text.utf16))
        field.value = String(decoding: utf16, as: UTF16.self)
        let caret = sel.lowerBound + text.utf16.count
        field.selection = caret..<caret
    }
}

extension MockSystemAccess: FocusedDocumentURLReading {
    public func focusedDocumentURL() -> String? { documentURL }
}

extension MockSystemAccess: AppAccessibilityEnabling {
    @discardableResult
    public func enableAppAccessibility(pid: Int32) -> Bool {
        accessibilityEvents.append("enable(\(pid))")
        accessibilityEnabledPIDs.insert(pid)
        return requiresAccessibilityEnable
    }
}

/// N4 — the fake secure-input flag (`secureEventInput`).
extension MockSystemAccess: SecureInputReading {
    public var isSecureEventInputEnabled: Bool { secureEventInput }
}

/// N18 — the marked write the paste path uses.
extension MockSystemAccess: TransientPasteboardWriting {
    @discardableResult
    public func writeTransientPasteboard(string: String) -> Int {
        var types = ["public.utf8-plain-text": Data(string.utf8)]
        for marker in PasteboardMarkers.all { types[marker] = Data() }
        return writeOurs(PasteboardItemSnapshot(types: types))
    }
}

extension MockSystemAccess: WebAreaProbing {
    public func focusedIsInWebArea() -> Bool { inWebArea }
}

extension MockSystemAccess: AppRuntimeReading {
    public func appRuntime(pid: Int32) -> SurfaceRuntime { runtimeByPID[pid] ?? .native }
}
