import Foundation

// R4.1b — the ranked list as a bounded prompt string (V3 §7.3).
//
// Two rules decide every line in this file.
//
// 1. **Screen text is data, never instructions.** A term harvested from the focused window is a
//    string some other program put on the screen; a chat log, a web page, a README can all contain
//    "ignore the previous instructions and …". By the time the list reaches a model that reads
//    text, that string is indistinguishable from something the user asked for — so it is dropped
//    *here*, before the prompt exists, rather than trusted to survive a model's judgement.
// 2. **The prompt is bounded, unconditionally.** `build` returns a string no longer than
//    `Limits.maxCharacters` for every input, including a single ten-megabyte "term".
//
// And one absence: nothing in this file logs. No `Log`, no `print`, no `os_log`, not the list, not
// the prompt, not a rejected term (`PromptBuilderPrivacyTests` scans the source to keep it true).

/// Turns a `RankedContext` into the text a refinement pass can be primed with.
public struct PromptBuilder: Sendable {

    /// Hard bounds. The character cap is on the **whole prompt**, header included.
    public struct Limits: Sendable, Equatable {
        /// Cap on the returned string's length, in characters.
        public var maxCharacters: Int
        /// Cap on how many terms may be listed (independent of the character cap).
        public var maxTerms: Int
        /// Longest single term. Longer ones are cut at a word boundary, not dropped.
        public var maxTermCharacters: Int
        /// A term with more words than this is a sentence, not a name: dropped.
        public var maxTermWords: Int

        public init(maxCharacters: Int = 1_000, maxTerms: Int = RankedContext.defaultCap,
                    maxTermCharacters: Int = 48, maxTermWords: Int = 4) {
            self.maxCharacters = max(0, maxCharacters)
            self.maxTerms = max(0, maxTerms)
            self.maxTermCharacters = max(1, maxTermCharacters)
            self.maxTermWords = max(1, maxTermWords)
        }

        public static let `default` = Limits()
    }

    /// What a build produced, in counts only — safe to show in Lab or log.
    public struct Result: Sendable, Equatable {
        public var prompt: String
        /// Terms that made it into the prompt.
        public var included: Int
        /// Terms rejected as instruction-like, URL-like or empty.
        public var rejected: Int
        /// Terms dropped because the character or term cap was reached.
        public var elided: Int
        /// True when the character budget, not the input, ended the list.
        public var hitCharacterCap: Bool

        public var isEmpty: Bool { prompt.isEmpty }
        /// Counts only. Never a term.
        public var shape: String {
            "\(prompt.count)/\(included) chars/terms (rejected \(rejected), elided \(elided)"
                + (hitCharacterCap ? ", char cap hit)" : ")")
        }
    }

    public var limits: Limits
    /// Sentence in front of the terms. Ours, not harvested — the only imperative in the prompt.
    public var header: String
    /// Separator between terms.
    public var separator: String

    public init(limits: Limits = .default,
                header: String = "Spellings that may occur in this audio:",
                separator: String = ", ") {
        self.limits = limits
        self.header = header
        self.separator = separator
    }

    // MARK: - Building

    /// The prompt for one utterance. Empty string when nothing survives — an empty context must
    /// read as "no prompt", never as a prompt with an empty list. This is the call R5.2/R5.3 make.
    public func prompt(for context: RankedContext) -> String { build(context).prompt }

    /// The prompt plus the counts.
    public func build(_ context: RankedContext) -> Result {
        // N1: a term only Contacts produced never reaches the cleanup context.
        build(terms: context.terms.filter { term in
            term.sources.isEmpty || term.sources.contains { ContactsChannelPolicy.admits($0, channel: .cleanupContext) }
        }.map(\.text))
    }

    public func build(terms: [String]) -> Result {
        var result = Result(prompt: "", included: 0, rejected: 0, elided: 0, hitCharacterCap: false)
        var kept: [String] = []
        var seen = Set<String>()
        var budget = limits.maxCharacters - header.count
        for (offset, raw) in terms.enumerated() {
            if kept.count >= limits.maxTerms {
                result.elided += terms.count - offset
                break
            }
            guard let term = Self.sanitized(raw, limits: limits) else {
                result.rejected += 1
                continue
            }
            guard seen.insert(term.lowercased()).inserted else { continue }
            // " " after the header, then the separator before every later term.
            let cost = term.count + (kept.isEmpty ? 1 : separator.count)
            if cost > budget {
                result.hitCharacterCap = true
                // Nothing shorter than two characters is ever kept, so once the budget cannot
                // hold even that, the rest of the input is elided without being examined.
                if budget < 2 + separator.count {
                    result.elided += terms.count - offset
                    break
                }
                result.elided += 1
                continue
            }
            budget -= cost
            kept.append(term)
        }
        result.included = kept.count
        guard !kept.isEmpty else { return result }
        // The prefix is belt and braces: every branch above already respects the cap, and this
        // line makes the guarantee true by construction for any future edit as well.
        result.prompt = String((header + " " + kept.joined(separator: separator)).prefix(limits.maxCharacters))
        return result
    }

    // MARK: - Sanitising one term

    /// The cleaned term, or nil when it must not reach the prompt.
    ///
    /// Order matters: the input is **bounded first** (so a ten-megabyte string costs a bounded
    /// amount of work), then normalised, then judged.
    public static func sanitized(_ raw: String, limits: Limits = .default) -> String? {
        // 1. Bound the work. Scan a little more than we can keep, so a rejectable word just past
        //    the keep-length is still seen.
        let scanned = String(raw.prefix(limits.maxTermCharacters * 4))
        // 2. Normalise: strip control, zero-width and bidirectional-override characters (a term
        //    can otherwise read one way and mean another), collapse whitespace runs.
        var normalized = ""
        var lastWasSpace = false
        for scalar in scanned.unicodeScalars {
            if Self.invisible.contains(scalar) { continue }
            let ch = Character(scalar)
            if ch.isWhitespace || ch.isNewline {
                if !lastWasSpace, !normalized.isEmpty { normalized.append(" ") }
                lastWasSpace = true
                continue
            }
            if scalar.properties.generalCategory == .control { continue }
            normalized.append(ch)
            lastWasSpace = false
        }
        let term = normalized.trimmingCharacters(in: .whitespaces)
        // 3. Judge.
        guard term.count >= 2 else { return nil }
        guard term.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let words = term.split(separator: " ").map(String.init)
        guard words.count <= limits.maxTermWords else { return nil }
        guard !isURLLike(term) else { return nil }
        guard !isInstructionLike(term) else { return nil }
        guard !containsTemplateMarker(term) else { return nil }
        // 4. Keep, cut to length at a word boundary when possible.
        return truncate(term, to: limits.maxTermCharacters)
    }

    /// Instruction-shaped text: a role label, a directive word, or an imperative opening.
    public static func isInstructionLike(_ term: String) -> Bool {
        let lower = term.lowercased()
        // "system:", "assistant:", "instruction:", … — the shape of a chat turn.
        for role in roleLabels where lower.contains(role + ":") { return true }
        // Directives that mean nothing as vocabulary and everything as an instruction.
        for phrase in directivePhrases where lower.contains(phrase) { return true }
        // An imperative opening ("send the deck", "run swift build", a bare "ignore").
        let words = lower.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        if let first = words.first, imperativeVerbs.contains(first) { return true }
        return false
    }

    /// A URL, a scheme, a bare host or an email address.
    public static func isURLLike(_ term: String) -> Bool {
        let lower = term.lowercased()
        if lower.contains("://") || lower.contains("<a href") { return true }
        if lower.hasPrefix("www.") || lower.hasPrefix("http") || lower.hasPrefix("ftp.") { return true }
        for scheme in uriSchemes where lower.hasPrefix(scheme) { return true }
        // name@host.tld
        if let at = lower.firstIndex(of: "@"), lower[at...].contains(".") { return true }
        // host.tld / host.tld/path — but not `gpt-4o`, `voiceplus.sqlite`, `Info.plist`.
        for token in lower.split(separator: " ") {
            let head = token.split(separator: "/").first ?? token
            guard let dot = head.lastIndex(of: "."), dot != head.startIndex else { continue }
            let tld = String(head[head.index(after: dot)...])
            if webTLDs.contains(tld) { return true }
        }
        return false
    }

    /// Template / chat-markup markers, the other way instruction text arrives.
    public static func containsTemplateMarker(_ term: String) -> Bool {
        for marker in templateMarkers where term.contains(marker) { return true }
        return false
    }

    static func truncate(_ term: String, to limit: Int) -> String {
        guard term.count > limit else { return term }
        let cut = String(term.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
            return String(cut[..<space])
        }
        return cut
    }

    // MARK: - Word lists

    static let roleLabels: Set<String> = [
        "system", "assistant", "user", "human", "ai", "model", "developer", "admin", "root",
        "instruction", "instructions", "prompt", "rule", "rules", "note", "important", "warning",
        "context", "task", "role", "tool", "function",
    ]

    static let directivePhrases: [String] = [
        "ignore", "disregard", "override", "instead of", "you must", "you should", "you are",
        "your task", "new task", "do not", "don't", "never ", "always ", "as an ai", "pretend",
        "act as", "from now on", "prior instructions", "previous instructions", "above instructions",
        "jailbreak", "api key", "password", "secret key", "bearer ",
    ]

    static let imperativeVerbs: Set<String> = [
        "ignore", "disregard", "forget", "override", "delete", "remove", "erase", "drop",
        "send", "email", "mail", "forward", "reply", "respond", "answer", "post", "publish",
        "share", "upload", "download", "install", "execute", "run", "exec", "eval", "open",
        "click", "press", "type", "paste", "copy", "print", "output", "write", "say", "tell",
        "repeat", "translate", "summarize", "summarise", "rewrite", "transcribe", "follow",
        "stop", "cancel", "confirm", "approve", "submit", "grant", "allow", "enable", "disable",
        "buy", "pay", "transfer", "wire", "reveal", "show", "list", "dump", "export", "fetch",
        "curl", "wget", "sudo", "rm", "please", "let's", "lets", "make", "set", "update", "change",
        "add", "create", "call", "ask", "help", "check", "verify", "ensure", "use", "keep", "put",
        "give", "take", "go", "do", "be", "read", "look", "find", "search", "try", "start", "begin",
    ]

    static let uriSchemes: [String] = [
        "mailto:", "file:", "data:", "javascript:", "tel:", "sms:", "ssh:", "smb:", "vnc:",
    ]

    static let webTLDs: Set<String> = [
        "com", "net", "org", "io", "dev", "co", "ai", "app", "sh", "me", "gov", "edu", "info",
        "biz", "xyz", "cloud", "site", "online", "in", "uk", "us", "eu", "de", "fr", "jp", "cn",
    ]

    static let templateMarkers: [String] = [
        "{{", "}}", "<|", "|>", "```", "<script", "</", "[[", "]]", "<!--", "${",
    ]

    /// Zero-width and bidirectional formatting scalars: invisible in a UI, meaningful in a prompt.
    static let invisible: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = []
        for value: UInt32 in 0x200B...0x200F { if let s = Unicode.Scalar(value) { set.insert(s) } }
        for value: UInt32 in 0x202A...0x202E { if let s = Unicode.Scalar(value) { set.insert(s) } }
        for value: UInt32 in 0x2066...0x2069 { if let s = Unicode.Scalar(value) { set.insert(s) } }
        for value: UInt32 in [0xFEFF, 0x00AD, 0x2060, 0x180E] { if let s = Unicode.Scalar(value) { set.insert(s) } }
        return set
    }()
}
