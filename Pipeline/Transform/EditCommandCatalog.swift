import Foundation
import Shared

/// H7 (Follow-up §5) — the edit-command catalogue: the single data file behind the edit parser,
/// the "Edit commands" Settings page and the menu bar submenu (H10), so what is listed is exactly
/// what works.
///
/// - `.deterministic` (D) entries run instantly with no model (`EditCommandRules`).
/// - `.llm` (L) entries need the on-device model; anything that matches no entry is a free-form
///   LLM edit (`EditCommandCatalog.freeForm`).
///
/// Every phrase accepts "this", "it", "that", "the selection", "the text" as its object.
public enum EditCommandKind: String, Codable, Sendable, CaseIterable {
    case deterministic, llm
}

public enum EditCommandGroup: String, Codable, Sendable, CaseIterable {
    case replace, findReplace, deleteCutCopy, insertAround, textCase, listsLines, tidy, markdown, undo
    case tone, quality, length, explain, translate, reshape, ask, other

    public var title: String {
        switch self {
        case .replace: return "Replace"
        case .findReplace: return "Find and replace inside"
        case .deleteCutCopy: return "Delete, cut, copy"
        case .insertAround: return "Insert around"
        case .textCase: return "Case"
        case .listsLines: return "Lists and lines"
        case .tidy: return "Tidy"
        case .markdown: return "Markdown"
        case .undo: return "Undo"
        case .tone: return "Tone"
        case .quality: return "Quality"
        case .length: return "Length"
        case .explain: return "Explain and simplify"
        case .translate: return "Translate"
        case .reshape: return "Reshape"
        case .ask: return "Ask (no edit)"
        case .other: return "Anything else"
        }
    }
}

/// What running a matched command does to the selection.
public enum EditCommandAction: Equatable, Sendable {
    /// The selection becomes this text (may equal the selection: "no change").
    case rewrite(String)
    /// The selection is removed (output is empty on purpose).
    case delete
    /// Copy the selection (verified by read-back), then remove it.
    case cut
    /// Copy the selection (verified by read-back); the text is untouched.
    case copy
    /// Put back the text before the last applied edit.
    case undo
    /// "replace with …" — the spoken words replace the selection via the normal injector (H6).
    case replaceSelection
    /// Needs the on-device model.
    case model
}

public struct EditCommandEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var group: EditCommandGroup
    public var kind: EditCommandKind
    /// Short label for the Settings page / submenu.
    public var title: String
    /// What to say, as shown to the user.
    public var examples: [String]
    /// D: normalised core phrases (object words, politeness and "make/turn/convert … into" removed).
    /// L: cue words/phrases used only to name the command (diagnostics); the model gets the words.
    public var phrases: [String]
    /// Markdown syntax: only on Markdown surfaces.
    public var markdownOnly: Bool

    public init(_ id: String, _ group: EditCommandGroup, _ kind: EditCommandKind, _ title: String, examples: [String],
                phrases: [String] = [], markdownOnly: Bool = false) {
        self.id = id; self.group = group; self.kind = kind; self.title = title
        self.examples = examples; self.phrases = phrases; self.markdownOnly = markdownOnly
    }
}

/// A parsed command: the entry it matched and what it does to this selection.
public struct EditCommandMatch: Equatable, Sendable {
    public var entry: EditCommandEntry
    public var action: EditCommandAction
}

public enum EditCommandCatalog {
    /// Every command, in display order (groups in `EditCommandGroup` order).
    public static let entries: [EditCommandEntry] = [
        // Replace (D) — parsed by `SelectionReplaceCommand` (H6).
        .init("replace.with", .replace, .deterministic, "Replace with new text",
              examples: ["replace with …", "replace this with …", "overwrite with …", "change this to …"]),
        .init("replace.ask", .replace, .deterministic, "Replace (then say the new text)",
              examples: ["replace", "replace this text"]),
        // Find and replace inside (D)
        .init("find.replace", .findReplace, .deterministic, "Replace a word inside",
              examples: ["replace A with B", "change A to B"]),
        .init("find.swap", .findReplace, .deterministic, "Swap two words",
              examples: ["swap A and B"]),
        // Delete / cut / copy (D)
        .init("delete", .deleteCutCopy, .deterministic, "Delete",
              examples: ["delete this", "remove this", "erase this"],
              phrases: ["delete", "remove", "erase", "clear", "get rid", "delete all", "remove all", "scratch", "scratch that"]),
        .init("cut", .deleteCutCopy, .deterministic, "Cut",
              examples: ["cut this"], phrases: ["cut", "cut out"]),
        .init("copy", .deleteCutCopy, .deterministic, "Copy",
              examples: ["copy this"], phrases: ["copy", "copy to clipboard", "copy to the clipboard"]),
        // Insert around (D)
        .init("insert.before", .insertAround, .deterministic, "Add before",
              examples: ["add … before this", "prepend …"]),
        .init("insert.after", .insertAround, .deterministic, "Add after",
              examples: ["add … after this", "append …"]),
        .init("wrap.quotes", .insertAround, .deterministic, "Put in quotes",
              examples: ["put this in quotes"], phrases: ["quotes", "quote", "quotation marks", "double quotes", "quote marks"]),
        .init("wrap.singleQuotes", .insertAround, .deterministic, "Put in single quotes",
              examples: ["put this in single quotes"], phrases: ["single quotes", "single quote marks"]),
        .init("wrap.brackets", .insertAround, .deterministic, "Put in brackets",
              examples: ["put this in brackets"], phrases: ["brackets", "square brackets", "bracket"]),
        .init("wrap.parentheses", .insertAround, .deterministic, "Put in parentheses",
              examples: ["put this in parentheses"], phrases: ["parentheses", "parenthesis", "parens", "round brackets"]),
        .init("wrap.braces", .insertAround, .deterministic, "Put in curly braces",
              examples: ["put this in curly braces"], phrases: ["curly braces", "braces", "curly brackets"]),
        .init("wrap.backticks", .insertAround, .deterministic, "Wrap in backticks",
              examples: ["wrap in backticks"], phrases: ["backticks", "backtick", "back ticks", "inline code"]),
        // Case (D)
        .init("case.upper", .textCase, .deterministic, "Uppercase",
              examples: ["uppercase", "all caps"],
              phrases: ["uppercase", "upper case", "all caps", "caps", "all uppercase", "all capitals", "capitals", "capital letters", "all capital letters"]),
        .init("case.lower", .textCase, .deterministic, "Lowercase",
              examples: ["lowercase"], phrases: ["lowercase", "lower case", "all lowercase", "all lower case", "small letters", "no caps"]),
        .init("case.title", .textCase, .deterministic, "Title case",
              examples: ["title case", "capitalize each word"],
              phrases: ["title case", "capitalize each word", "capitalize every word", "capitalise each word", "capitalise every word",
                        "capitalize", "capitalise", "capitalize the words", "initial caps"]),
        .init("case.sentence", .textCase, .deterministic, "Sentence case",
              examples: ["sentence case"], phrases: ["sentence case"]),
        .init("case.firstLetter", .textCase, .deterministic, "Capitalize the first letter",
              examples: ["capitalize the first letter"],
              phrases: ["capitalize the first letter", "capitalise the first letter", "capitalize first letter", "capitalise first letter",
                        "capital first letter", "uppercase the first letter"]),
        // Lists and lines (D)
        .init("list.bullets", .listsLines, .deterministic, "Bulleted list",
              examples: ["make this a bulleted list", "bullet points"],
              phrases: ["bulleted list", "bullet list", "bullet points", "bullet point list", "bullets", "bulleted", "list", "bullet point"]),
        .init("list.numbered", .listsLines, .deterministic, "Numbered list",
              examples: ["numbered list"], phrases: ["numbered list", "numbered", "number list", "numbered points", "numbered steps", "number"]),
        .init("lines.join", .listsLines, .deterministic, "One paragraph",
              examples: ["make this one paragraph", "join the lines"],
              phrases: ["one paragraph", "single paragraph", "a single paragraph", "join the lines", "join lines", "join",
                        "merge the lines", "merge lines"]),
        .init("lines.split", .listsLines, .deterministic, "One per line",
              examples: ["one per line", "split into lines"],
              phrases: ["one per line", "one sentence per line", "split into lines", "split lines", "separate lines", "split"]),
        .init("lines.removeBreaks", .listsLines, .deterministic, "Remove line breaks",
              examples: ["remove line breaks"],
              phrases: ["remove line breaks", "remove the line breaks", "remove newlines", "remove new lines", "no line breaks",
                        "remove the newlines"]),
        // Tidy (D)
        .init("tidy.fillers", .tidy, .deterministic, "Remove filler words",
              examples: ["remove filler words"],
              phrases: ["remove filler words", "remove the filler words", "remove fillers", "remove filler", "no filler words",
                        "strip filler words", "remove ums", "remove the ums"]),
        .init("tidy.spacing", .tidy, .deterministic, "Fix spacing",
              examples: ["fix spacing", "remove extra spaces"],
              phrases: ["fix spacing", "fix the spacing", "fix spaces", "fix the spaces", "remove extra spaces", "remove the extra spaces",
                        "remove double spaces", "remove extra spacing", "clean up spacing", "clean up the spacing"]),
        .init("tidy.trim", .tidy, .deterministic, "Trim",
              examples: ["trim"], phrases: ["trim", "trim whitespace", "trim spaces", "trim the whitespace"]),
        .init("tidy.emojis", .tidy, .deterministic, "Remove emojis",
              examples: ["remove emojis"], phrases: ["remove emojis", "remove emoji", "remove the emojis", "strip emojis", "no emojis"]),
        .init("tidy.punctuation", .tidy, .deterministic, "Remove punctuation",
              examples: ["remove punctuation"],
              phrases: ["remove punctuation", "remove the punctuation", "strip punctuation", "no punctuation"]),
        .init("tidy.fullStop", .tidy, .deterministic, "Add a full stop",
              examples: ["add a full stop"],
              phrases: ["add a full stop", "add full stop", "add a period", "add period", "end with a period", "end with a full stop",
                        "add a full stop at the end", "add a period at the end"]),
        // Markdown (D, Markdown surfaces only)
        .init("md.bold", .markdown, .deterministic, "Bold", examples: ["make this bold"], phrases: ["bold"], markdownOnly: true),
        .init("md.italic", .markdown, .deterministic, "Italic", examples: ["make this italic"], phrases: ["italic", "italics"], markdownOnly: true),
        .init("md.heading", .markdown, .deterministic, "Heading", examples: ["make this a heading"],
              phrases: ["heading", "header", "heading one"], markdownOnly: true),
        .init("md.strike", .markdown, .deterministic, "Strikethrough", examples: ["make this strikethrough"],
              phrases: ["strikethrough", "strike through", "strike", "cross out"], markdownOnly: true),
        .init("md.link", .markdown, .deterministic, "Link", examples: ["make this a link"], phrases: ["link", "hyperlink"], markdownOnly: true),
        .init("md.codeBlock", .markdown, .deterministic, "Code block", examples: ["make this a code block"],
              phrases: ["code block", "codeblock", "code"], markdownOnly: true),
        // Undo (D)
        .init("undo", .undo, .deterministic, "Undo the last edit",
              examples: ["undo that", "put it back"],
              phrases: ["undo", "undo the last edit", "undo the edit", "undo last edit", "put back", "revert", "go back", "restore"]),

        // Needs the on-device model (L)
        .init("tone", .tone, .llm, "Change the tone",
              examples: ["make this formal", "casual", "polite", "warmer", "more confident", "soften this", "more direct"],
              phrases: ["formal", "professional", "casual", "friendly", "friendlier", "polite", "warmer", "warm", "confident",
                        "aggressive", "soften", "softer", "direct", "tone", "firmer", "assertive", "apologetic", "neutral", "enthusiastic"]),
        .init("quality", .quality, .llm, "Improve",
              examples: ["make this better", "make this clearer", "rephrase", "proofread", "fix grammar", "fix spelling"],
              phrases: ["better", "improve", "clearer", "clear", "rephrase", "reword", "differently", "proofread", "grammar", "spelling", "typos"]),
        .init("length", .length, .llm, "Change the length",
              examples: ["make this shorter", "concise", "make this longer", "summarize this", "one sentence", "TL;DR"],
              phrases: ["shorter", "shorten", "concise", "tighten", "longer", "expand", "elaborate", "summarize", "summarise",
                        "one sentence", "tl dr", "tldr", "condense", "brief"]),
        .init("explain", .explain, .llm, "Explain or simplify",
              examples: ["explain this better", "simplify", "plain English", "add an example"],
              phrases: ["explain", "simplify", "simpler", "plain english", "easier to understand", "example"]),
        .init("translate", .translate, .llm, "Translate",
              examples: ["translate to Hindi", "translate to Spanish"], phrases: ["translate", "in hindi", "in spanish", "in english"]),
        .init("reshape", .reshape, .llm, "Reshape",
              examples: ["turn this into an email", "a tweet", "action items", "a table", "reorder by priority"],
              phrases: ["email", "message", "tweet", "action items", "table", "reorder", "priority"]),
        .init("ask", .ask, .llm, "Ask about it (no edit)",
              examples: ["what does this mean?", "is this correct?"]),
        .init("freeform", .other, .llm, "Anything else",
              examples: ["any other instruction"]),
    ]

    /// `StageContext.extra` key carrying the resolved `SurfaceKind.id` (same key as
    /// `FieldContext.Keys.surfaceKind`); gates the Markdown entries.
    public static let surfaceKey = FieldContext.Keys.surfaceKind

    public static func entry(_ id: String) -> EditCommandEntry? { entries.first { $0.id == id } }
    public static var freeForm: EditCommandEntry { entry("freeform")! }
    public static var deterministic: [EditCommandEntry] { entries.filter { $0.kind == .deterministic } }
    public static var needsModel: [EditCommandEntry] { entries.filter { $0.kind == .llm } }
    /// Entries grouped in display order, for the Settings page and the submenu.
    public static var grouped: [(group: EditCommandGroup, entries: [EditCommandEntry])] {
        EditCommandGroup.allCases.compactMap { g in
            let e = entries.filter { $0.group == g }
            return e.isEmpty ? nil : (g, e)
        }
    }

    // MARK: Parser

    /// The deterministic command this instruction names for this selection, or nil (→ LLM route).
    /// `surface` gates the Markdown entries.
    public static func match(_ instruction: String, selection: String, surface: SurfaceKind? = nil) -> EditCommandMatch? {
        let raw = rawForm(instruction)
        guard !raw.isEmpty else { return nil }
        if let m = matchReplaceSelection(raw) { return m }
        if let m = matchArguments(raw, selection: selection) { return m }
        let candidates = coreForms(instruction)
        for entry in entries where entry.kind == .deterministic && !entry.phrases.isEmpty {
            guard candidates.contains(where: entry.phrases.contains) else { continue }
            if entry.markdownOnly, surface != .markdownEditor { continue }
            return EditCommandMatch(entry: entry, action: EditCommandRules.action(for: entry.id, selection: selection))
        }
        return nil
    }

    /// The catalogue entry naming this instruction (D or L) — for logs and the notch copy.
    public static func classify(_ instruction: String, selection: String = "", surface: SurfaceKind? = nil) -> EditCommandEntry {
        if let m = match(instruction, selection: selection, surface: surface) { return m.entry }
        let lowered = " " + normalize(instruction) + " "
        if instruction.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return entry("ask")! }
        for e in needsModel where e.phrases.contains(where: { lowered.contains(" \($0) ") }) { return e }
        return freeForm
    }

    // MARK: Normalisation

    static let leadFillers = ["please", "ok", "okay", "so", "um", "uh", "now", "just", "hey", "and", "can you", "could you",
                              "would you", "will you", "i want you to", "i'd like you to", "go ahead and", "let's", "lets"]
    static let trailFillers = ["please", "for me", "now", "thanks", "thank you"]
    static let objectPhrases = ["the selected text", "the selection", "this text", "that text", "the text", "all of this",
                                "all of it", "all of that", "everything", "this", "it", "that", "selection"]
    static let leadVerbs: Set<String> = ["make", "turn", "convert", "change", "put", "set", "format", "transform", "wrap",
                                         "surround", "write", "rewrite", "enclose"]
    static let verbLinks: Set<String> = ["into", "to", "in", "as", "with", "using", "inside"]
    static let articles: Set<String> = ["a", "an", "the"]
    static let trailLinks: Set<String> = ["of", "to", "in", "on", "for"]

    /// Lowercased words only (letters, digits, apostrophes), single-spaced.
    static func normalize(_ s: String) -> String {
        let mapped = s.lowercased().replacingOccurrences(of: "’", with: "'").map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "'" ? ch : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func stripFillers(_ words: [String]) -> [String] {
        var w = words
        var changed = true
        while changed {
            changed = false
            for f in leadFillers {
                let fw = f.split(separator: " ").map(String.init)
                if w.count > fw.count, Array(w.prefix(fw.count)) == fw { w.removeFirst(fw.count); changed = true }
            }
            for f in trailFillers {
                let fw = f.split(separator: " ").map(String.init)
                if w.count > fw.count, Array(w.suffix(fw.count)) == fw { w.removeLast(fw.count); changed = true }
            }
        }
        return w
    }

    /// Candidate core phrases: politeness and object words removed; then also the leading
    /// "make / turn … into (a)" stripped.
    static func coreForms(_ instruction: String) -> [String] {
        var words = stripFillers(normalize(instruction).split(separator: " ").map(String.init))
        // Remove object phrases anywhere (longest first, whole words).
        for o in objectPhrases {
            let ow = o.split(separator: " ").map(String.init)
            var i = 0
            while i + ow.count <= words.count {
                if Array(words[i..<(i + ow.count)]) == ow { words.removeSubrange(i..<(i + ow.count)) } else { i += 1 }
            }
        }
        while let last = words.last, trailLinks.contains(last), words.count > 1 { words.removeLast() }
        var forms = [words.joined(separator: " ")]
        var v = words
        if let first = v.first, leadVerbs.contains(first), v.count > 1 {
            v.removeFirst()
            if let l = v.first, verbLinks.contains(l), v.count > 1 { v.removeFirst() }
            if let a = v.first, articles.contains(a), v.count > 1 { v.removeFirst() }
            forms.append(v.joined(separator: " "))
        }
        return forms.filter { !$0.isEmpty }
    }

    /// The instruction as spoken (case kept, for arguments), politeness and end punctuation removed.
    static func rawForm(_ instruction: String) -> String {
        var t = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^(?:(?:please|ok|okay|so|um|uh|now|just|hey|and|can you|could you|would you|will you|go ahead and)[,\\s]+)+",
                                   with: "", options: [.regularExpression, .caseInsensitive])
        while let last = t.last, ".!?,;".contains(last) { t.removeLast() }
        t = t.replacingOccurrences(of: "[,\\s]+please$", with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Argument commands

    static let objectAlternation = "(?:the selected text|the selection|this text|that text|the text|this|it|that|selection)"

    static func matchReplaceSelection(_ raw: String) -> EditCommandMatch? {
        let spans = raw.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: 1, audioRange: Double(i)...Double(i + 1))
        }
        switch SelectionReplaceCommand.parse(spans) {
        case .replace?: return EditCommandMatch(entry: entry("replace.with")!, action: .replaceSelection)
        case .awaitingText?: return EditCommandMatch(entry: entry("replace.ask")!, action: .replaceSelection)
        case nil: return nil
        }
    }

    static func matchArguments(_ raw: String, selection: String) -> EditCommandMatch? {
        let obj = objectAlternation
        func groups(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
            return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: raw).map { String(raw[$0]).trimmingCharacters(in: .whitespaces) } }
        }
        func isObject(_ s: String) -> Bool { objectPhrases.contains(normalize(s)) }

        // Insert around.
        if let g = groups("^(?:add|insert|put|write|type)\\s+(.+?)\\s+(?:before|in front of|at the (?:start|beginning) of)\\s+\(obj)$")
            ?? groups("^(?:add|insert|put|write|type)\\s+(.+?)\\s+at the (?:start|beginning)$")
            ?? groups("^prepend\\s+(.+?)(?:\\s+to\\s+\(obj))?$"), let x = g.first, !x.isEmpty {
            return EditCommandMatch(entry: entry("insert.before")!, action: .rewrite(EditCommandRules.prepend(x, to: selection)))
        }
        if let g = groups("^(?:add|insert|put|write|type)\\s+(.+?)\\s+(?:after|at the end of)\\s+\(obj)$")
            ?? groups("^(?:add|insert|put|write|type)\\s+(.+?)\\s+at the end$")
            ?? groups("^append\\s+(.+?)(?:\\s+(?:to|at the end of)\\s+\(obj))?$"), let x = g.first, !x.isEmpty {
            return EditCommandMatch(entry: entry("insert.after")!, action: .rewrite(EditCommandRules.append(x, to: selection)))
        }
        // Swap A and B (both must occur).
        if let g = groups("^swap\\s+(.+?)\\s+and\\s+(.+)$"), g.count == 2, !isObject(g[0]), !isObject(g[1]),
           let out = EditCommandRules.swap(g[0], g[1], in: selection) {
            return EditCommandMatch(entry: entry("find.swap")!, action: .rewrite(out))
        }
        // Find and replace inside (A must occur; "replace this with …" is H6's replace).
        if let g = groups("^(?:replace|change|swap out|substitute)\\s+(?:the word\\s+)?(.+?)\\s+(?:with|to|for|by|into)\\s+(.+)$"), g.count == 2,
           !isObject(g[0]), let out = EditCommandRules.findReplace(g[0], with: g[1], in: selection) {
            return EditCommandMatch(entry: entry("find.replace")!, action: .rewrite(out))
        }
        return nil
    }
}
