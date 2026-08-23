import Foundation
import ApplicationServices
import AppKit
import Contacts

/// Reads the focused window's AX tree (no screenshots — Build doc §1 Privacy). Returns []
/// when Accessibility is not trusted, so it is always safe to install.
public struct LiveAXFocusedWindowText: FocusedWindowTextProvider {
    public var maxNodes: Int
    public init(maxNodes: Int = 1_500) { self.maxNodes = maxNodes }

    public func visibleStrings() -> [(String, Double)] {
        guard AXIsProcessTrusted() else { return [] }
        let system = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp else { return [] }
        let appEl = app as! AXUIElement
        var win: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return [] }
        var out: [(String, Double)] = []
        var budget = maxNodes
        walk(w as! AXUIElement, depth: 0, budget: &budget, out: &out)
        return out
    }

    private func walk(_ el: AXUIElement, depth: Int, budget: inout Int, out: inout [(String, Double)]) {
        guard budget > 0, depth < 12 else { return }
        budget -= 1
        let salience = depth <= 1 ? 1.0 : max(0.4, 1.0 - Double(depth) * 0.08)
        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            var v: AnyObject?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty, s.count < 20_000 {
                out.append((s, salience))
            }
        }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for k in kids { walk(k, depth: depth + 1, budget: &budget, out: &out) }
    }
}

/// Open document names via AXDocument / window titles of the focused app.
public struct LiveAXOpenDocuments: OpenDocumentProvider {
    public init() {}
    public func openDocumentNames() -> [String] {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return [] }
        let appEl = AXUIElementCreateApplication(pid)
        var wins: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &wins) == .success,
              let windows = wins as? [AXUIElement] else { return [] }
        var names: [String] = []
        for w in windows.prefix(20) {
            var doc: AnyObject?
            if AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &doc) == .success, let s = doc as? String {
                names.append(URL(string: s)?.path ?? s)
            }
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title) == .success, let s = title as? String,
               s.contains(".") { names.append(s.split(separator: " ").first.map(String.init) ?? s) }
        }
        return names
    }
}

/// Contacts names; reads only when authorization was already granted elsewhere (onboarding).
public struct LiveContacts: ContactsProvider {
    public init() {}
    public func contactNames() -> [String] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let req = CNContactFetchRequest(keysToFetch: keys)
        var names: [String] = []
        try? store.enumerateContacts(with: req) { c, stop in
            for n in [c.givenName, c.familyName, c.organizationName] where n.count >= 2 { names.append(n) }
            if names.count > 5_000 { stop.pointee = true }
        }
        return names
    }
}
