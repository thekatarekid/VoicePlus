import Foundation
@testable import Actions

/// 15 mock apps built from the catalogue's own control names (what a real AX tree of that app kind exposes).
enum DeterministicMockApps {
    static let apps: [(name: String, bundle: String, kind: ActionCategory)] = [
        ("Finder", "com.apple.finder", .files), ("Preview", "com.apple.Preview", .mac), ("System Settings", "com.apple.systempreferences", .mac),
        ("Safari", "com.apple.Safari", .browser), ("Google Chrome", "com.google.Chrome", .browser), ("Arc", "company.thebrowser.Browser", .browser),
        ("Visual Studio Code", "com.microsoft.VSCode", .editor), ("Xcode", "com.apple.dt.Xcode", .editor), ("Cursor", "com.todesktop.cursor", .editor),
        ("Slack", "com.tinyspeck.slackmacgap", .chat), ("Discord", "com.hnc.Discord", .chat), ("Messages", "com.apple.MobileSMS", .chat),
        ("Mail", "com.apple.mail", .mail), ("Microsoft Outlook", "com.microsoft.Outlook", .mail), ("Notes", "com.apple.Notes", .mac),
    ]

    /// Fresh desktop with every app running; `front` is frontmost with a focused body text area.
    static func desktop(catalog: ActionCatalog, front: String) -> MockActionSystem {
        let sys = MockActionSystem()
        var nextID = 1
        for (i, a) in apps.enumerated() {
            let w1 = 100 + i * 10, w2 = w1 + 1
            var els: [ElementRef] = []
            func add(_ role: String, _ title: String, selected: Bool = false) { els.append(ElementRef(id: nextID, windowID: w1, role: role, title: title, isSelected: selected)); nextID += 1 }
            add("AXTextArea", "Body")
            var tabs = ["Overview"]
            for e in catalog.entries where e.applies(to: a.kind) {
                switch e.kind {
                case .click: if let n = e.params["name"] { add("AXButton", n) }
                case .fillField: add("AXTextField", e.params["name"] ?? "Field")
                case .focusTab: if let t = e.params["target"], t != "next", t != "previous", !tabs.contains(t) { tabs.append(t) }
                default: break
                }
            }
            for n in ["OK", "Cancel", "Toolbar", "Merge pull request", "Zoom", "Sidebar"] where !els.contains(where: { $0.title == n }) { add("AXButton", n) }
            for (k, t) in tabs.enumerated() { add("AXTab", t, selected: k == 0) }
            let ref = AppRef(name: a.name, bundleID: a.bundle)
            sys.add(.init(ref: ref, kind: a.kind, windows: [WindowRef(id: w1, appBundleID: a.bundle, title: "\(a.name) — Main"), WindowRef(id: w2, appBundleID: a.bundle, title: "Second")],
                          elements: [w1: els, w2: [ElementRef(id: nextID, windowID: w2, role: "AXButton", title: "OK")]]))
            nextID += 1
        }
        sys.bringToFront(front)
        if let body = sys.snapshot().focusedWindow.flatMap({ sys.elements(in: $0).first { $0.title == "Body" } }) { try? sys.focus(body) }
        return sys
    }

    static func argument(for e: CatalogEntry) -> String {
        switch e.kind {
        case .focusApp: return "Preview"; case .focusWindow: return "Second"; case .click: return "Toolbar"; case .focusTab: return "Overview"
        case .openURL: return "github dot com slash pulls"; case .openFile: return "~/Documents"; default: return "hello world"
        }
    }
    static func phrase(for e: CatalogEntry) -> String { e.phrasings[0].replacingOccurrences(of: "{arg}", with: argument(for: e)) }
}
