import Foundation
import Pipeline
import SwiftUI

// MARK: - H10 · Settings › Edit commands
//
// Everything you can say over selected text, generated from `EditCommandCatalog` — the same data
// file the edit parser and the menu bar's "Edit commands" submenu read — so the list shown is
// exactly what works. Commands that need the on-device model say so. Read-only: nothing here is a
// setting.

public enum EditCommandsCopy {
    public static let title = "Edit commands"
    public static let subtitle = "Select text, hold Option and say one of these. Instant ones run on this Mac with no model."
    public static let needsModel = "Needs on-device model"
    public static let instant = "Instant"
    public static let footnote = "Each command also works with “it”, “that”, “the selection” or “the text”. Without a selection, speech is dictation as usual."

    /// The row detail: every example, then what it needs.
    public static func detail(_ entry: EditCommandEntry) -> String {
        let examples = entry.examples.map { "“\($0)”" }.joined(separator: ", ")
        var tags = [entry.kind == .llm ? needsModel : instant]
        if entry.markdownOnly { tags.append("Markdown fields only") }
        return examples.isEmpty ? tags.joined(separator: " · ") : examples + " · " + tags.joined(separator: " · ")
    }
}

/// The page's content, separate from the view so a test can prove it lists exactly the catalogue.
public struct EditCommandsPageContent: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var detail: String
        public var needsModel: Bool
    }
    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var rows: [Row]
    }

    public var sections: [Section]

    /// From the catalogue, in its display order (groups in `EditCommandGroup` order).
    public static func fromCatalog(_ grouped: [(group: EditCommandGroup, entries: [EditCommandEntry])] = EditCommandCatalog.grouped)
        -> EditCommandsPageContent {
        EditCommandsPageContent(sections: grouped.map { g in
            Section(id: g.group.rawValue, title: g.group.title, rows: g.entries.map {
                Row(id: $0.id, title: $0.title, detail: EditCommandsCopy.detail($0), needsModel: $0.kind == .llm)
            })
        })
    }

    public var rowIDs: [String] { sections.flatMap { $0.rows.map(\.id) } }
}

struct EditCommandsPage: View {
    var hotkey: String
    var content: EditCommandsPageContent = .fromCatalog()

    var body: some View {
        SectionPage(.settings(.editCommands), state: .content, hotkey: hotkey) {
            VStack(alignment: .leading, spacing: MainWindowLayout.sectionGap) {
                ForEach(content.sections) { section in
                    GroupBox(section.title, layout: .rows) {
                        ForEach(section.rows) { row in
                            RowView(row.title, detail: row.detail) {
                                if row.needsModel {
                                    Image(systemName: "cpu")
                                        .foregroundStyle(.secondary)
                                        .help(EditCommandsCopy.needsModel)
                                        .accessibilityLabel(EditCommandsCopy.needsModel)
                                }
                            }
                            .accessibilityIdentifier("editCommands.\(row.id)")
                        }
                    }
                }
                Text(EditCommandsCopy.footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
