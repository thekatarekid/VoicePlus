import Foundation
import Pipeline

/// H10 — the "Edit commands" submenu, generated from `EditCommandCatalog` (the one data file the
/// Settings page also reads), so the menu can never list a command the executor does not know or
/// miss one it does. Groups in catalogue order, each under a section header; every row is one
/// catalogue entry: its title, its first example as the helper line, all examples as the tooltip.
/// L entries (model rewrites) say "needs on-device model". Choosing a row opens the Edit commands
/// page in Settings; nothing here edits text, reads the selection or starts a capture.
public enum EditCommandsMenu {
    public static let title = "Edit commands"
    public static let needsModel = "needs on-device model"

    public static func headerID(_ group: EditCommandGroup) -> String { "menu.editCommands.group.\(group.rawValue)" }
    public static func rowID(_ entry: EditCommandEntry) -> String { "menu.editCommands.\(entry.id)" }

    /// The submenu's rows: a header per group, then that group's entries.
    public static func entries(_ grouped: [(group: EditCommandGroup, entries: [EditCommandEntry])]
                                = EditCommandCatalog.grouped) -> [MenuEntry] {
        var rows: [MenuEntry] = []
        for (group, items) in grouped {
            var header = MenuEntry.info(headerID(group), group.title)
            header.isHeader = true
            rows.append(header)
            rows += items.map(row)
        }
        return rows
    }

    static func row(_ entry: EditCommandEntry) -> MenuEntry {
        var detail = entry.examples.first.map { "“\($0)”" }
        if entry.kind == .llm { detail = [detail, needsModel].compactMap { $0 }.joined(separator: " · ") }
        var row = MenuEntry(id: rowID(entry), title: entry.title, detail: detail, action: .openEditCommands)
        row.toolTip = entry.examples.isEmpty ? nil : entry.examples.map { "“\($0)”" }.joined(separator: "\n")
        return row
    }

    /// The parent row in the main menu.
    public static func parent() -> MenuEntry {
        var parent = MenuEntry(id: StatusMenuSpec.ID.editCommands, title: title)
        parent.submenu = entries()
        return parent
    }

    /// The catalogue ids the submenu lists, in order (spec tests compare against the catalogue).
    public static func listedCommandIDs(_ rows: [MenuEntry] = entries()) -> [String] {
        rows.filter { !$0.isHeader }.map { String($0.id.dropFirst("menu.editCommands.".count)) }
    }
}
