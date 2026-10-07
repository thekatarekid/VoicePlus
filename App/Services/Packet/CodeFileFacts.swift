import Foundation

/// Context Writer §2.1 — the code editor's record: the file (from the window title the editor
/// already shows), its language (from the extension) and whether the caret sits in code, a
/// comment or a string (from the text before the caret). No file is opened; nothing is guessed
/// when the title names no file.
enum CodeFileFacts {
    enum Region: String { case code, comment, string }

    /// `● Foo.swift — VoiceInput`, `Foo.swift - proj - Visual Studio Code`, `VoiceInput — Foo.swift`
    /// → `Foo.swift`. The first title segment that is a single file-like token.
    static func filePath(fromTitle title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let segments = title.components(separatedBy: CharacterSet(charactersIn: "—–|"))
            .flatMap { $0.components(separatedBy: " - ") }
        for raw in segments {
            var s = raw.trimmingCharacters(in: .whitespaces)
            while let f = s.first, "●•*◦".contains(f) { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
            guard !s.isEmpty, !s.contains(" "), s.count <= 200, isFileLike(s) else { continue }
            return s
        }
        return nil
    }

    static func isFileLike(_ s: String) -> Bool {
        let name = (s as NSString).lastPathComponent
        if name == "COMMIT_EDITMSG" || name == "Makefile" || name == "Dockerfile" { return true }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...]
        return (1...6).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    static let languages: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "rb": "ruby", "go": "go", "rs": "rust", "java": "java", "kt": "kotlin",
        "kts": "kotlin", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "m": "objective-c", "mm": "objective-c",
        "cs": "csharp", "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell", "md": "markdown", "json": "json",
        "yaml": "yaml", "yml": "yaml", "toml": "toml", "html": "html", "css": "css", "scss": "scss", "sql": "sql", "php": "php",
        "scala": "scala", "lua": "lua", "ex": "elixir", "exs": "elixir", "hs": "haskell", "dart": "dart", "r": "r", "zig": "zig",
        "vue": "vue", "svelte": "svelte", "pl": "perl", "ps1": "powershell", "tf": "terraform", "proto": "protobuf",
        "xml": "xml", "plist": "xml", "txt": "text",
    ]

    static func language(forPath path: String?) -> String? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        if name == "Makefile" { return "make" }
        if name == "Dockerfile" { return "dockerfile" }
        if name == "COMMIT_EDITMSG" { return "git-commit" }
        return languages[(name as NSString).pathExtension.lowercased()]
    }

    /// Languages whose line comment is `#` (the rest use `//`, SQL / Lua / Haskell `--`).
    static let hashComment: Set<String> = ["python", "ruby", "shell", "yaml", "toml", "r", "perl", "make", "dockerfile", "terraform", "elixir", "powershell"]
    static let dashComment: Set<String> = ["sql", "lua", "haskell"]

    /// Where the caret is, from the text before it: inside an unclosed `/* … */` or docstring, after
    /// the language's line-comment marker on the current line (outside a string), or inside an
    /// unclosed quote on the current line.
    static func caretRegion(textBefore: String, language: String?) -> Region {
        let line = textBefore.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let lead = line.trimmingCharacters(in: .whitespaces)
        let hashLanguage = language.map { hashComment.contains($0) } ?? false
        let dashLanguage = language.map { dashComment.contains($0) } ?? false
        let marker: String
        if hashLanguage { marker = "#" } else if dashLanguage { marker = "--" } else { marker = "//" }
        if !hashLanguage, !dashLanguage {
            if let open = textBefore.range(of: "/*", options: .backwards),
               textBefore[open.upperBound...].range(of: "*/") == nil { return .comment }
            if lead.hasPrefix("*") { return .comment }
        }
        if language == "python", textBefore.components(separatedBy: "\"\"\"").count % 2 == 0 { return .string }
        if lead.hasPrefix("#!") { return .code }
        var inString: Character?
        var previous: Character?
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if let open = inString {
                if ch == open, previous != "\\" { inString = nil }
            } else if line[i...].hasPrefix(marker) {
                return .comment
            } else if ch == "\"" || ch == "'" || ch == "`" {
                inString = ch
            }
            previous = ch
            i = line.index(after: i)
        }
        return inString == nil ? .code : .string
    }
}
