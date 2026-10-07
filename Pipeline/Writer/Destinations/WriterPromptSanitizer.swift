import Foundation

// Context Writer — what screen-derived text goes through before it reaches a prompt.
//
// Everything in the packet except the profile text is data the model must never obey: the thread,
// the field's text, screen terms, vocabulary, even the heard words. `CleanupPromptSanitizer` (D4)
// already knows the shapes of an attempt to instruct the model; this reuses it and adds the two
// things the writer prompt needs on top:
// - **our own labels** (`HEARD:`, `THREAD:` …) at the start of a data line are neutralised, so a
//   screen line cannot open a section of the user message;
// - thread and document lines are dropped when they are *directive-shaped* (role label, "ignore
//   previous…", template marker), but a plain imperative from a colleague ("send me the deck") is
//   kept — it is a message being quoted, and losing it costs the model the thread.
// Terms and record values are list items: the strict rule applies (losing one costs nothing).

enum WriterPromptSanitizer {

    /// The section labels `WriterPrompt` writes at a line start; a data line starting with one is
    /// rewritten with a modifier-letter colon (U+A789) so it reads the same but is not a label.
    static let labels: [String] = ["MODE", "DESTINATION", "THREAD", "DOCUMENT", "BEFORE", "AFTER", "TERMS",
                                   "VOCAB", "RECENT", "HEARD", "BOOSTED", "ALT", "PERSONA", "UNCHANGED", "EARLIER"]

    /// Normalised (invisible scalars, template markers), delimiters escaped, labels neutralised.
    /// Words are kept. Newlines are kept; `\r` becomes `\n`.
    static func text(_ s: String) -> String {
        let normalized = CleanupPromptSanitizer.normalized(s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n"))
        return CleanupPrompt.escape(normalized).split(separator: "\n", omittingEmptySubsequences: false)
            .map { neutralizeLabel(String($0)) }.joined(separator: "\n")
    }

    /// One line of data: `text`, flattened to a single line, or `nil` when it is empty.
    static func line(_ s: String) -> String? {
        let flat = text(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }

    /// The heard text: words untouched, only normalised and label-safe (the model must see exactly
    /// what the recogniser wrote, including an injection, which is a sentence to correct).
    static func heard(_ s: String) -> String { line(CleanupPromptSanitizer.transcript(s)) ?? "" }

    /// A thread / document / field line: `nil` when it is directive-shaped or empty.
    static func proseLine(_ s: String) -> String? {
        guard let flat = line(s), !isDirective(flat) else { return nil }
        return flat
    }

    /// A list item (a screen term, a vocabulary term, a record value): the strict D4 rule.
    static func item(_ s: String) -> String? {
        guard let flat = line(s), !CleanupPromptSanitizer.isInstructionLike(flat) else { return nil }
        return flat
    }

    /// Role label at the start or anywhere as `role:`, an injection phrase, a template marker.
    static func isDirective(_ s: String) -> Bool {
        let lower = s.lowercased()
        for role in CleanupPromptSanitizer.roleLabels where lower.hasPrefix(role + ":") || lower.contains(" " + role + ":") {
            return true
        }
        for phrase in CleanupPromptSanitizer.injectionPhrases where lower.contains(phrase) { return true }
        for phrase in strongDirectives where lower.contains(phrase) { return true }
        return CleanupPromptSanitizer.containsTemplateMarker(s)
    }

    /// Phrases that only read as an attempt to steer the model (a colleague's "don't forget" is not one).
    static let strongDirectives: [String] = [
        "you must now", "you are an ai", "as a language model", "override your", "output only", "respond only with",
        "reply only with", "print the system", "reveal the system", "api key", "secret key", "bearer ",
    ]

    static func neutralizeLabel(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let colon = trimmed.firstIndex(of: ":") else { return line }
        let head = trimmed[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
        let bare = head.split(separator: " ").first.map(String.init) ?? head
        guard labels.contains(bare) else { return line }
        return String(line[..<colon]) + "꞉" + String(line[line.index(after: colon)...])
    }

    /// The raw text bounded *before* sanitising, so a multi-megabyte screen block costs nothing: only
    /// what can still fit a budget is kept (`fromEnd` keeps the tail, for text before the caret and
    /// thread lines where the newest words win). Counted in UTF-8 bytes; a cut marker fragment is
    /// still neutralised by the sanitiser afterwards.
    static func bounded(_ s: String, cap: Int, fromEnd: Bool) -> String {
        guard s.utf8.count > cap else { return s }
        return fromEnd ? String(s.suffix(cap)) : String(s.prefix(cap))
    }

    /// `s` cut to `budget` characters on a word boundary, with an ellipsis when cut.
    static func clip(_ s: String, _ budget: Int) -> String {
        guard s.count > budget, budget > 1 else { return s }
        var head = String(s.prefix(budget - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > budget / 2 {
            head = String(head[..<space])
        }
        return head + "…"
    }

    /// The last `budget` characters of `s`, starting on a word, with a leading ellipsis when cut.
    static func tail(_ s: String, _ budget: Int) -> String {
        guard s.count > budget, budget > 1 else { return s }
        var t = String(s.suffix(budget - 1))
        if let space = t.firstIndex(of: " "), t.distance(from: t.startIndex, to: space) < budget / 2 {
            t = String(t[t.index(after: space)...])
        }
        return "…" + t
    }
}
