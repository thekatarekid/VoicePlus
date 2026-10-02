import Foundation

// N11 — the collision rule (Investigation R3 §E3).
//
// A context term that is also an ordinary English word ("Bucket", "Cab", "Code", "Cleaning",
// "Comp") rewrites what the user actually said when it is boosted. Such a term only enters the
// boost layers with strong evidence (it is on screen right now, or the user corrected to it).
// The word list is the system dictionary (`/usr/share/dict/web2`, present on every Mac, read once
// and lazily) plus a built-in floor, so the rule still holds when the file is missing.

/// Is a term also a common word?
public enum CollisionLexicon {
    /// Built-in floor: very common words plus the words today's Contacts damage came from.
    static let builtIn: Set<String> = BoostGuard.commonWords.union([
        "bucket", "cab", "code", "cleaning", "comp", "apple", "bill", "bob", "cam", "carol", "chase",
        "dash", "dawn", "drew", "grace", "hope", "jack", "joy", "lane", "mark", "may", "page", "pat",
        "ray", "rose", "sky", "summer", "will", "max", "rob", "sue", "victor", "frank", "faith",
        "note", "notes", "file", "files", "folder", "mail", "message", "slack", "zoom", "notion",
        "docs", "sheet", "sheets", "terminal", "chrome", "safari", "finder", "word", "excel",
    ])

    /// Lower-cased entries of the system word list (lower-case lines only: proper names in web2 are
    /// capitalised, and a capitalised-only entry is a name, not a collision).
    private static let systemWords: Set<String> = {
        guard let data = FileManager.default.contents(atPath: "/usr/share/dict/web2"),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out = Set<String>()
        out.reserveCapacity(240_000)
        for line in text.split(separator: "\n") where line.first?.isLowercase == true {
            out.insert(String(line))
        }
        return out
    }()

    /// True when `term` is a single ordinary word (case-insensitive). Multi-word terms, terms with
    /// digits or inner capitals (`TeamViewer`, `gpt-4o`) never collide.
    public static func isCommonWord(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: { $0.isWhitespace || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" }) else {
            return false
        }
        if t.dropFirst().contains(where: \.isUppercase), t.contains(where: \.isLowercase) { return false } // camelCase
        let key = t.lowercased()
        return builtIn.contains(key) || systemWords.contains(key)
    }
}
