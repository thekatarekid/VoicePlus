import AppKit
import Foundation
import Shared

/// "Show what changed" submenu for the status-item dropdown: recent silent corrections (newest
/// first, revert on click while still revertable) and the per-app off switch.
public enum CorrectionMenuBuilder {
    public static let maxRows = 8

    /// Pure: the rows the submenu shows (tests check these without AppKit).
    public static func rows(ledger: CorrectionLedger, limit: Int = maxRows) -> [CorrectionEntry] { Array(ledger.recent.prefix(limit)) }

    public static func appToggleTitle(bundleID: String?, settings: SettingsStore?) -> String? {
        guard let bundleID, let settings else { return nil }
        let name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return CorrectionSettings.isEnabled(for: bundleID, store: settings) ? "Turn off silent corrections in \(name)" : "Turn on silent corrections in \(name)"
    }

    public static func item(ledger: CorrectionLedger, settings: SettingsStore?, bundleID: String?, target: AnyObject,
                            revert: Selector, toggleApp: Selector) -> NSMenuItem {
        let sub = NSMenu()
        let entries = rows(ledger: ledger)
        if entries.isEmpty {
            let none = NSMenuItem(title: "No silent corrections yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for e in entries {
            let row = NSMenuItem(title: e.menuLine, action: e.isRevertable ? revert : nil, keyEquivalent: "")
            row.target = target
            row.representedObject = e.id.uuidString
            row.toolTip = e.isRevertable ? "Click to put “\(e.was)” back" : nil
            row.isEnabled = e.isRevertable
            sub.addItem(row)
        }
        if let title = appToggleTitle(bundleID: bundleID, settings: settings) {
            sub.addItem(.separator())
            let t = NSMenuItem(title: title, action: toggleApp, keyEquivalent: "")
            t.target = target
            t.representedObject = bundleID
            sub.addItem(t)
        }
        let item = NSMenuItem(title: "Show what changed", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }
}
