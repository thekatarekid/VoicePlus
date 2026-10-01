import Foundation
import ApplicationServices
import AppKit
import Contacts

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
