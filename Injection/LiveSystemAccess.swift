import AppKit
import ApplicationServices
import Foundation
import Shared

/// Real AX / CGEvent / NSPasteboard implementation. Every AX call is guarded by `AXIsProcessTrusted()`.
///
/// FX1 — every AX call that could land in **this** process runs on the main thread (`onSafeThread`):
/// macOS runs an AX request aimed at ourselves in-process on the calling thread, and AppKit off the
/// main thread deadlocks TextKit 2 against the main thread's layout. Our own focused text view is
/// read and written directly (`InProcessTextDelivering`), never through AX.
public final class LiveSystemAccess: SystemAccess {
    public init() {}

    /// FX1 — the frontmost application. Live: `NSWorkspace`. A test points it at this process.
    public var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    /// FX1 — our own focused text (main thread only). Live: the key window's first responder,
    /// when it is text. A test points it at a view in an off-screen window.
    public var ownTextResponder: @MainActor () -> NSText? = { OwnTextResponder.keyWindowText() }
    /// FX1 — how long a read / a write aimed at our own process waits for the main thread to pick
    /// it up before giving up (`.mainThreadBusy`, nothing done). See `MainThreadHop`.
    public var mainThreadReadTimeout = MainThreadHop.readStartTimeout
    public var mainThreadWriteTimeout = MainThreadHop.writeStartTimeout

    /// FX1 — true when an AX request for "the focused element" would be answered by this process.
    /// No AX round trip: `NSRunningApplication` is thread-safe.
    func ownProcessHasFocus() -> Bool {
        frontmostApplication()?.processIdentifier == OwnProcess.pid || NSRunningApplication.current.isActive
    }

    /// FX1 — the guard every AX entry point goes through. Off the main thread, work that targets
    /// this process runs on the main thread (`MainThreadHop`, bounded: it never waits forever).
    /// Work that turns out to target us only once the element is resolved (a panel of ours holding
    /// AX focus while another app is frontmost) throws `.ownProcessOffMain` from
    /// `focusedAXElement` before touching it, and is retried on the main thread.
    func onSafeThread<T>(ownProcess: Bool, startTimeout: TimeInterval? = nil,
                         _ work: @escaping () throws -> T) throws -> T {
        if Thread.isMainThread { return try work() }
        let startTimeout = startTimeout ?? mainThreadReadTimeout
        if ownProcess { return try MainThreadHop.run(startTimeout: startTimeout, work) }
        do { return try work() } catch let error as SystemAccessError where error == .ownProcessOffMain {
            return try MainThreadHop.run(startTimeout: startTimeout, work)
        }
    }

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Q2 / N10 — turns on Electron's / Chromium's accessibility tree by trying (`AppAccessibilityEnabling`).
    public let appAccessibility = AppAccessibilityEnabler(
        lookup: { pid in
            NSRunningApplication(processIdentifier: pid).map {
                let info = $0.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
                let version = (info?["CFBundleVersion"] as? String) ?? (info?["CFBundleShortVersionString"] as? String)
                return AppAccessibilityEnabler.App(bundleID: $0.bundleIdentifier, bundleURL: $0.bundleURL, version: version)
            }
        },
        setAttribute: { pid, attribute in
            guard AXIsProcessTrusted() else { return false }
            let app = AXUIElementCreateApplication(pid)
            return AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue) == .success
        },
        probe: { pid in LiveSystemAccess.probeFocusedElement(pid: pid) })

    /// N10 — one bounded read of `pid`'s focused element: editable (self or ≤ 4 ancestors), and an
    /// `AXWebArea` ancestor (≤ 40 levels). Never called for our own process (the enabler skips it).
    static func probeFocusedElement(pid: Int32) -> AppAccessibilityProbe? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        func copy(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func parent(_ e: AXUIElement) -> AXUIElement? {
            guard let p = copy(e, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            return (p as! AXUIElement)   // swiftlint:disable:this force_cast
        }
        guard let f = copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let focused = f as! AXUIElement   // swiftlint:disable:this force_cast
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        var editable = false
        var node: AXUIElement? = focused
        var depth = 0
        while let n = node, depth <= 4, !editable {
            let role = copy(n, kAXRoleAttribute) as? String
            var settable = DarwinBoolean(false)
            let valueSettable = AXUIElementIsAttributeSettable(n, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
            editable = role.map(editableRoles.contains) == true || (valueSettable && role != "AXStaticText")
            node = parent(n); depth += 1
        }
        var inWeb = false
        node = focused; depth = 0
        while let n = node, depth < 40, !inWeb {
            inWeb = (copy(n, kAXRoleAttribute) as? String) == "AXWebArea"
            node = parent(n); depth += 1
        }
        return AppAccessibilityProbe(editable: editable, inWebArea: inWeb)
    }

    /// Every AX text write / keystroke / key combo that reached `postToPid`. See the protocol doc:
    /// the injector uses this to know whether a method posted before it threw.
    public private(set) var postCount = 0

    // MARK: Focus

    public func frontmostApp() -> FocusSnapshot? {
        guard let app = frontmostApplication() else { return nil }
        let pid = app.processIdentifier
        var token: String?
        if isAccessibilityTrusted {
            token = try? onSafeThread(ownProcess: pid == OwnProcess.pid) { [self] in
                String(CFHash(try focusedAXElement(pid: pid)))
            }
        }
        return FocusSnapshot(pid: pid, bundleID: app.bundleIdentifier ?? "unknown",
                             appName: app.localizedName ?? "", elementToken: token)
    }

    public func focusedElement() throws -> FocusedElementInfo {
        try onSafeThread(ownProcess: ownProcessHasFocus()) { [self] in try readFocusedElement() }
    }

    private func readFocusedElement() throws -> FocusedElementInfo {
        // FX1 — our own text view is read directly, on the main thread: no AX round trip into
        // ourselves, and no accessibility permission needed for it.
        if Thread.isMainThread, ownProcessHasFocus(), let own = ownFocusedText() { return own }
        let element = try focusedAXElement()
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? "unknown"
        let subrole = copyAttribute(element, kAXSubroleAttribute) as? String
        let value = copyAttribute(element, kAXValueAttribute) as? String
        let selectedText = copyAttribute(element, kAXSelectedTextAttribute) as? String
        var range: Range<Int>?
        if let rangeValue = copyAttribute(element, kAXSelectedTextRangeAttribute) {
            var cfRange = CFRange()
            // swiftlint:disable:next force_cast
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                range = cfRange.location..<(cfRange.location + cfRange.length)
            }
        }
        return FocusedElementInfo(role: role, value: value, selectedRange: range,
                                  isValueSettable: isSettable(element, kAXValueAttribute),
                                  isSelectedTextSettable: isSettable(element, kAXSelectedTextAttribute),
                                  subrole: subrole, selectedText: selectedText,
                                  hints: hints(of: element))
    }

    /// R4.2 — the four descriptive attributes, fetched in **one** batched request on the element
    /// this call already resolved. No second `kAXFocusedUIElement` traversal and no extra
    /// per-attribute round-trip: `focusedElement()` runs once per utterance and AX is slow.
    ///
    /// `AXUIElementCopyMultipleAttributeValues` puts an `AXValue` of type `.axError` in the slot of
    /// any attribute the element does not expose, which is the common case — most elements have
    /// only one or two of these. Those slots (and a wholesale failure of the batched call) come
    /// back as `nil` and are dropped, so hints degrade to `[]` rather than throwing.
    private func hints(of element: AXUIElement) -> [String] {
        let names = FocusedElementInfo.hintAttributes
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard err == .success, let raw = values as? [CFTypeRef], raw.count == names.count else { return [] }
        return FocusedElementInfo.hints(from: raw.map { $0 as? String })
    }

    // MARK: AX writes

    public func setFocusedValue(_ value: String) throws {
        try set(kAXValueAttribute, value as CFString, counts: true)
    }

    public func setFocusedSelectedRange(_ range: Range<Int>) throws {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { throw SystemAccessError.axError(-1) }
        try set(kAXSelectedTextRangeAttribute, axValue)   // caret only: never counts as a post
    }

    public func setFocusedSelectedText(_ text: String) throws {
        try set(kAXSelectedTextAttribute, text as CFString, counts: true)
    }

    // MARK: CGEvent

    /// Every event is built *before* the first one is posted, so a failure here throws with
    /// nothing posted — which is the only case the injector may fall through on (R2.3).
    public func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw SystemAccessError.eventPostFailed }
        // CGEventKeyboardSetUnicodeString handles up to 20 UTF-16 units per event reliably.
        let units = Array(text.utf16)
        var events: [CGEvent] = []
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            index += chunk.count
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw SystemAccessError.eventPostFailed
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            events.append(down)
            events.append(up)
        }
        guard !events.isEmpty else { return }
        postCount += 1
        for event in events { event.postToPid(pid) }
    }

    public func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: false) else {
            throw SystemAccessError.eventPostFailed
        }
        var flags: CGEventFlags = []
        if combo.command { flags.insert(.maskCommand) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.shift { flags.insert(.maskShift) }
        if combo.control { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        postCount += 1
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: Pasteboard

    public func readPasteboard() -> PasteboardSnapshot {
        let pb = NSPasteboard.general
        let items = (pb.pasteboardItems ?? []).map { item -> PasteboardItemSnapshot in
            var types: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { types[type.rawValue] = data }
            }
            return PasteboardItemSnapshot(types: types)
        }
        return PasteboardSnapshot(items: items, changeCount: pb.changeCount)
    }

    @discardableResult
    public func writePasteboard(string: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        return pb.changeCount
    }

    public func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = snapshot.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    public var pasteboardChangeCount: Int { NSPasteboard.general.changeCount }

    public func settle(milliseconds: Int) {
        Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
    }

    // MARK: AX plumbing

    private func focusedAXElement(pid: Int32? = nil) throws -> AXUIElement {
        guard isAccessibilityTrusted else { throw SystemAccessError.accessibilityNotTrusted }
        let root: AXUIElement = pid.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused else { throw SystemAccessError.noFocusedElement }
        // swiftlint:disable:next force_cast
        let element = focused as! AXUIElement
        // FX1 — every later read or write on this element would run our AppKit handlers on this
        // thread. Refuse before touching it; `onSafeThread` retries on the main thread.
        if !Thread.isMainThread, Self.pid(of: element) == OwnProcess.pid { throw SystemAccessError.ownProcessOffMain }
        return element
    }

    static func pid(of element: AXUIElement) -> Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    /// `counts: true` for the two attributes that can put text in the user's field. The count is
    /// bumped *before* the write, so a write that fails halfway still reads as "possibly posted".
    private func set(_ name: String, _ value: CFTypeRef, counts: Bool = false) throws {
        try onSafeThread(ownProcess: ownProcessHasFocus(), startTimeout: mainThreadWriteTimeout) { [self] in
            try setNow(name, value, counts: counts)
        }
    }

    private func setNow(_ name: String, _ value: CFTypeRef, counts: Bool) throws {
        let element = try focusedAXElement()
        guard isSettable(element, name) else { throw SystemAccessError.attributeNotSettable(name) }
        if counts { postCount += 1 }
        let err = AXUIElementSetAttributeValue(element, name as CFString, value)
        guard err == .success else { throw SystemAccessError.axError(err.rawValue) }
    }
}

// MARK: - Q2 — expose Electron / Chromium text fields

extension LiveSystemAccess: AppAccessibilityEnabling {
    @discardableResult
    public func enableAppAccessibility(pid: Int32) -> Bool { appAccessibility.enable(pid: pid) }
}

extension LiveSystemAccess: AppAccessibilityOutcomeReading {
    public func accessibilityOutcome(pid: Int32) -> AppAccessibilityOutcome? { appAccessibility.outcome(pid: pid) }
}

// MARK: - Q1 — the web document around the focused element

extension LiveSystemAccess: FocusedDocumentURLReading {
    /// Walks `AXParent` from the focused element (bounded) to the first ancestor exposing `AXURL`
    /// — Chromium's and WebKit's `AXWebArea`. `nil` on any failure or for native fields.
    public func focusedDocumentURL() -> String? {
        (try? onSafeThread(ownProcess: ownProcessHasFocus()) { [self] () -> String? in
            var element: AXUIElement? = try focusedAXElement()
            var depth = 0
            while let current = element, depth < 40 {
                if let url = copyAttribute(current, "AXURL") {
                    if let cfURL = url as? URL { return cfURL.absoluteString }
                    if let text = url as? String { return text }
                }
                // swiftlint:disable:next force_cast
                element = copyAttribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
                depth += 1
            }
            return nil
        }) ?? nil
    }
}

// MARK: - D1 — the caret through text markers (WebKit / Chromium)

extension LiveSystemAccess: TextMarkerCaretReading {
    /// The attribute names, spelled as literals: they are not in the public AX headers.
    enum MarkerAttribute {
        static let selectedRange = "AXSelectedTextMarkerRange"
        static let rangeForElement = "AXTextMarkerRangeForUIElement"
        static let startOfRange = "AXStartTextMarkerForTextMarkerRange"
        static let endOfRange = "AXEndTextMarkerForTextMarkerRange"
        static let rangeForMarkers = "AXTextMarkerRangeForUnorderedTextMarkers"
        static let string = "AXStringForTextMarkerRange"
    }

    /// Selection edges from `AXSelectedTextMarkerRange`; field edges from the element's own
    /// marker range (`AXTextMarkerRangeForUIElement`); then `AXTextMarkerRangeForUnorderedTextMarkers`
    /// builds field-start → selection-start and selection-end → field-end, and
    /// `AXStringForTextMarkerRange` reads each. Any missing piece answers `nil` — the caller falls
    /// through to `unknown`, never to "end".
    ///
    /// Deliberately no fallback to `AXStartTextMarker` / `AXEndTextMarker`: those are the
    /// *document's* edges, so "before" would carry the page's text above an empty input — the
    /// very "always starts with a space" bug this rung exists to remove (V4 §5).
    public func caretByTextMarkers() -> TextMarkerCaret? {
        (try? onSafeThread(ownProcess: ownProcessHasFocus()) { [self] in try readCaretByTextMarkers() }) ?? nil
    }

    private func readCaretByTextMarkers() throws -> TextMarkerCaret? {
        // FX1 — our own text view answers the first rung (value + selected range) directly.
        if Thread.isMainThread, ownProcessHasFocus(), ownFocusedText() != nil { return nil }
        let element = try focusedAXElement()
        guard let selection = copyAttribute(element, MarkerAttribute.selectedRange),
              let selectionStart = parameterized(element, MarkerAttribute.startOfRange, selection),
              let selectionEnd = parameterized(element, MarkerAttribute.endOfRange, selection),
              let whole = parameterized(element, MarkerAttribute.rangeForElement, element),
              let fieldStart = parameterized(element, MarkerAttribute.startOfRange, whole),
              let fieldEnd = parameterized(element, MarkerAttribute.endOfRange, whole),
              let beforeRange = parameterized(element, MarkerAttribute.rangeForMarkers, [fieldStart, selectionStart] as CFArray),
              let afterRange = parameterized(element, MarkerAttribute.rangeForMarkers, [selectionEnd, fieldEnd] as CFArray),
              let before = parameterized(element, MarkerAttribute.string, beforeRange) as? String,
              let after = parameterized(element, MarkerAttribute.string, afterRange) as? String else { return nil }
        return TextMarkerCaret(before: before, after: after)
    }

    private func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value)
        return err == .success ? value : nil
    }
}

// MARK: - FX1 — our own focused text, driven directly (never through AX)

extension LiveSystemAccess: InProcessTextDelivering {
    public func ownFocusedText() -> FocusedElementInfo? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { ownTextResponder().map { OwnTextResponder.element(of: $0) } }
    }

    public func insertIntoOwnFocusedText(_ text: String) throws -> Bool {
        guard Thread.isMainThread else { throw SystemAccessError.ownProcessOffMain }
        return MainActor.assumeIsolated { () -> Bool in
            guard let view = ownTextResponder(), view.isEditable else { return false }
            postCount += 1
            return OwnTextResponder.insert(text, into: view)
        }
    }
}

/// FX1 — VoicePlus's own focused text view (an `NSTextView`, or a text field's field editor),
/// read and written on the main thread with AppKit's own editing API.
@MainActor
public enum OwnTextResponder {
    /// The key (else main) window's first responder, when it is text.
    public static func keyWindowText() -> NSText? {
        guard let app = NSApp else { return nil }
        return (app.keyWindow ?? app.mainWindow)?.firstResponder as? NSText
    }

    /// What the injector's readback and the field-context reader need, as `focusedElement()` would
    /// report it. A secure text field's field editor reports the secure role and no value.
    public static func element(of view: NSText) -> FocusedElementInfo {
        let value = view.string as NSString
        let selection = view.selectedRange
        let lower = min(max(0, selection.location), value.length)
        let upper = min(lower + max(0, selection.length), value.length)
        let secure = isSecure(view)
        let role = secure ? FocusedElementInfo.secureRole : (view.isFieldEditor ? "AXTextField" : "AXTextArea")
        return FocusedElementInfo(role: role, value: secure ? nil : value as String, selectedRange: lower..<upper,
                                  isValueSettable: view.isEditable, isSelectedTextSettable: view.isEditable,
                                  selectedText: secure ? nil : value.substring(with: NSRange(location: lower, length: upper - lower)),
                                  hints: FocusedElementInfo.hints(from: [view.accessibilityIdentifier(), view.accessibilityLabel()]))
    }

    /// Inserts `text` at the selection exactly as typing does: `insertText(_:replacementRange:)`
    /// runs `shouldChangeText`, registers undo, updates the delegate — so a SwiftUI `TextEditor` /
    /// `TextField` binding sees the change. `false` when the view is not editable.
    public static func insert(_ text: String, into view: NSText) -> Bool {
        guard view.isEditable else { return false }
        let range = view.selectedRange
        if let textView = view as? NSTextView {
            textView.insertText(text, replacementRange: range)
        } else {
            view.replaceCharacters(in: range, with: text)
            view.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
        }
        return true
    }

    /// A secure text field's field editor: its delegate is the `NSSecureTextField` being edited.
    static func isSecure(_ view: NSText) -> Bool { view.delegate is NSSecureTextField }
}

// N4 — macOS secure event input, read live before a blind write.
extension LiveSystemAccess: SecureInputReading {
    public var isSecureEventInputEnabled: Bool { SecureInputGuard.isActive }
}

// N18 — dictation pastes are marked transient / auto-generated / concealed for clipboard managers.
extension LiveSystemAccess: TransientPasteboardWriting {
    @discardableResult
    public func writeTransientPasteboard(string: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        for marker in PasteboardMarkers.all { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
        pb.writeObjects([item])
        return pb.changeCount
    }
}

// N24 — rich paste: several representations in one marked item (TSV + HTML, Markdown).
extension LiveSystemAccess: RichPasteboardWriting {
    @discardableResult
    public func writeTransientPasteboard(types: [String: Data]) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        for marker in PasteboardMarkers.all { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
        pb.writeObjects([item])
        return pb.changeCount
    }
}

// MARK: - N5 — web area ancestor and runtime, by structure

extension LiveSystemAccess: WebAreaProbing {
    /// Walks `AXParent` (bounded) from the focused element looking for role `AXWebArea`.
    public func focusedIsInWebArea() -> Bool {
        (try? onSafeThread(ownProcess: ownProcessHasFocus()) { [self] () -> Bool in
            var element: AXUIElement? = try focusedAXElement()
            var depth = 0
            while let current = element, depth < 40 {
                if (copyAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea" { return true }
                // swiftlint:disable:next force_cast
                element = copyAttribute(current, kAXParentAttribute).map { $0 as! AXUIElement }
                depth += 1
            }
            return false
        }) ?? false
    }
}

extension LiveSystemAccess: AppRuntimeReading {
    public func appRuntime(pid: Int32) -> SurfaceRuntime {
        AppRuntimeSniffer.shared.runtime(bundleURL: NSRunningApplication(processIdentifier: pid)?.bundleURL)
    }
}

// MARK: - N3 — window identity for the delivery ladder

extension LiveSystemAccess: FocusedWindowReading {
    /// `CFHash` of the app's `AXFocusedWindow` (stable while the window lives; the AX reader uses
    /// the same identity).
    public func focusedWindowToken(pid: Int32) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success, let ref else { return nil }
        return String(CFHash(ref))
    }

    public func windowExists(pid: Int32, token: String) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AnyObject] else { return true }   // cannot tell → do not claim "gone"
        return windows.contains { String(CFHash($0)) == token }
    }
}
