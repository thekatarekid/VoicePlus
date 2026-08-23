import Foundation

/// Personas shown in the keyboard strip. Pure selection/cycling; storage is the App Group
/// defaults (the companion app writes, the extension reads).
public struct PersonaPicker: Equatable, Sendable, Codable {
    public struct Entry: Equatable, Sendable, Codable, Identifiable {
        public var id: String
        public var title: String
        public var text: String
        public init(id: String, title: String, text: String) { self.id = id; self.title = title; self.text = text }
    }

    public static let none = Entry(id: "none", title: "Plain", text: "")
    public private(set) var entries: [Entry]
    public private(set) var selectedID: String

    public init(entries: [Entry] = [], selectedID: String? = nil) {
        let all = [Self.none] + entries.filter { $0.id != Self.none.id }
        self.entries = all
        self.selectedID = all.first { $0.id == selectedID }?.id ?? Self.none.id
    }

    public var selected: Entry { entries.first { $0.id == selectedID } ?? Self.none }
    /// Persona instruction for the pipeline, nil for "Plain".
    public var personaText: String? { selected.text.isEmpty ? nil : selected.text }

    public mutating func select(_ id: String) { if entries.contains(where: { $0.id == id }) { selectedID = id } }
    public mutating func cycle() {
        guard let i = entries.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = entries[(i + 1) % entries.count].id
    }
}
