import AppKit
import ApplicationServices
import Foundation
import Shared

/// Real AX / CGEvent / NSPasteboard implementation. Every AX call is guarded by `AXIsProcessTrusted()`.
public final class LiveSystemAccess: SystemAccess {
    public init() {}

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Focus

    public func frontmostApp() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        var token: String?
        if isAccessibilityTrusted, let element = try? focusedAXElement(pid: app.processIdentifier) {
            token = String(CFHash(element))
        }
        return FocusSnapshot(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "unknown",
                             appName: app.localizedName ?? "", elementToken: token)
    }

    public func focusedElement() throws -> FocusedElementInfo {
        let element = try focusedAXElement()
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? "unknown"
        let value = copyAttribute(element, kAXValueAttribute) as? String
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
                                  isSelectedTextSettable: isSettable(element, kAXSelectedTextAttribute))
    }

    // MARK: AX writes

    public func setFocusedValue(_ value: String) throws {
        try set(kAXValueAttribute, value as CFString)
    }

    public func setFocusedSelectedRange(_ range: Range<Int>) throws {
        var cfRange = CFRange(location: range.lowerBound, length: range.count)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { throw SystemAccessError.axError(-1) }
        try set(kAXSelectedTextRangeAttribute, axValue)
    }

    public func setFocusedSelectedText(_ text: String) throws {
        try set(kAXSelectedTextAttribute, text as CFString)
    }

    // MARK: CGEvent

    public func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { throw SystemAccessError.eventPostFailed }
        // CGEventKeyboardSetUnicodeString handles up to 20 UTF-16 units per event reliably.
        let units = Array(text.utf16)
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
            down.postToPid(pid)
            up.postToPid(pid)
        }
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
        return focused as! AXUIElement
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private func set(_ name: String, _ value: CFTypeRef) throws {
        let element = try focusedAXElement()
        guard isSettable(element, name) else { throw SystemAccessError.attributeNotSettable(name) }
        let err = AXUIElementSetAttributeValue(element, name as CFString, value)
        guard err == .success else { throw SystemAccessError.axError(err.rawValue) }
    }
}
