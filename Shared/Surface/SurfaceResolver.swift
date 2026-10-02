import Foundation

/// N9 — "what surface is this?" (Investigation R3 §E1).
///
/// Evidence is **added up**, never decided by a first match: every signal votes for a kind
/// with a weight, the best kind wins, and its confidence reflects both its total and its lead
/// over the runner-up. Below `threshold` the answer is plain prose with safe line breaks,
/// which is never wrong in a dangerous way. A secure field or macOS secure input is a veto.
///
/// Weights (starting points from §E1): focused element role / label / placeholder high
/// (3–4), web URL high (2–2.5), pty-shell ownership medium-high (2.5), user override 3,
/// learned history up to 2, seed table 1.5, window title 1–1.5. Known-app tables only raise
/// confidence: an app on no list is resolved from structure alone.
public enum SurfaceResolver {
    public static let threshold = 0.5

    public enum Weight {
        public static let roleStrong = 4.0
        public static let browserChrome = 2.0
        public static let seed = 1.5
        public static let seedSpreadsheet = 2.0
        public static let pty = 2.5
        public static let title = 1.5
        public static let override = 3.0
        public static let historyPerTurn = 0.5
        public static let historyCap = 2.0
    }

    /// Roles a spreadsheet app reports for a cell or its in-cell editor.
    public static let cellRoles: Set<String> = ["AXCell", "AXTable", "AXLayoutItem", "AXGroup",
                                                "AXTextArea", "AXTextField", "AXGrid", "AXWebArea"]
    public static let singleLineRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]
    public static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    public static let secureRole = "AXSecureTextField"

    static let titleTerminalWords: Set<String> = ["zsh", "bash", "fish", "ssh", "tmux", "sh", "pwsh"]
    static let titleMailWords: Set<String> = ["inbox", "compose", "draft"]
    static let codeExtensions: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "c", "h", "cpp",
                                              "hpp", "java", "kt", "rb", "php", "cs", "m", "mm", "json", "yaml",
                                              "yml", "toml", "sh", "sql", "lua", "scala", "dart"]

    public static func resolve(_ e: SurfaceEvidence) -> SurfaceResolution {
        let seed = SeedHints.hint(for: e.bundleID)
        let runtime = e.runtime ?? seed?.runtime
        let role = e.role ?? ""
        let isWeb = e.isInWebArea || (runtime?.isWebContent ?? false) || e.treeIsEmpty

        // 1 · Veto: secure input, a secure role, or a password label on a text-entry role.
        if e.secureInputActive {
            return SurfaceResolution(kind: .secure, confidence: 1, isWebArea: isWeb, signals: ["veto:secureInput"])
        }
        if role == secureRole || e.subrole == secureRole {
            return SurfaceResolution(kind: .secure, confidence: 1, isWebArea: isWeb, signals: ["veto:secureRole"])
        }
        let texts = e.fieldTexts.map(SurfaceLexicon.words)
        if textEntryRoles.contains(role) || role.isEmpty && e.isEditable == true,
           texts.contains(where: { t in SurfaceLexicon.passwordWords.contains { SurfaceLexicon.contains(t, $0) } }) {
            return SurfaceResolution(kind: .secure, confidence: 1, isWebArea: isWeb, signals: ["veto:passwordLabel"])
        }

        var scores: [SurfaceKind: Double] = [:]
        var signals: [String] = []
        func vote(_ kind: SurfaceKind, _ w: Double, _ why: String) {
            scores[kind, default: 0] += w
            signals.append("\(why)→\(kind.id)+\(fmt(w))")
        }

        let singleLine = singleLineRoles.contains(role) || e.isMultiline == false
        let searchRole = role == "AXSearchField" || e.subrole == "AXSearchField"

        // 2 · Focused element: role.
        if searchRole { vote(.searchField, Weight.roleStrong, "role:AXSearchField") }
        if role == "AXCell" { vote(.spreadsheetCell, Weight.roleStrong, "role:AXCell") }
        if role == "AXCanvas" || e.subrole == "AXCanvas", e.isEditable != true { vote(.canvas, Weight.roleStrong, "role:canvas") }

        // 3 · Focused element: label, placeholder, description, hints (word-level, all add up).
        var labelSearch = false
        for (i, t) in texts.enumerated() {
            if t.last == "cell" {   // "cell", "Selected cell", "B2 cell" (not "cell phone")
                vote(.spreadsheetCell, Weight.roleStrong, "label:cell")
                continue
            }
            var hits = SurfaceLexicon.phrases.filter { SurfaceLexicon.contains(t, $0.words) }
            // Keep the longest phrases: "message body" outvotes its own "message".
            hits = hits.filter { h in !hits.contains { o in o.words.count > h.words.count && SurfaceLexicon.contains(o.words, h.words) } }
            var counted = Set<SurfaceKind>()
            for h in hits {
                if h.singleLineOnly && !singleLine && !(role.isEmpty && e.isMultiline == nil) { continue }
                if h.outsideWebOnly && e.isInWebArea { continue }
                if h.kind == .canvas && e.isEditable == true { continue }
                guard counted.insert(h.kind).inserted else { continue }   // one vote per kind per text
                if h.kind == .searchField { labelSearch = true }
                let source = i == 0 && e.placeholder?.isEmpty == false ? "placeholder" : "label"
                vote(h.kind, h.weight, "\(source):\(h.words.joined(separator: " "))")
            }
        }

        // 4 · Web area + URL (patterns are data).
        let cellish = role.isEmpty || cellRoles.contains(role)
        if e.isInWebArea {
            for (host, p) in SurfaceLexicon.urlMatches(e.url) {
                if p.kind == .spreadsheetCell && (!cellish || searchRole || labelSearch) { continue }
                vote(p.kind, p.weight, "url:\(host)")
            }
        }

        // 5 · The app owns a shell on a pty.
        if let shell = e.shell { vote(.terminal, Weight.pty, "pty:\(shell.shellName ?? "shell")") }

        // 6 · Window title.
        if let title = e.windowTitle, !title.isEmpty {
            let w = SurfaceLexicon.words(title)
            if w.contains(where: titleTerminalWords.contains) { vote(.terminal, Weight.title, "title:shell") }
            if w.contains(where: titleMailWords.contains) || SurfaceLexicon.contains(w, ["new", "message"]) {
                vote(.emailBody, 1, "title:mail")
            }
            let lower = title.lowercased()
            if lower.range(of: #"\.md\b"#, options: .regularExpression) != nil { vote(.markdownEditor, 1, "title:.md") }
            else if let ext = lower.range(of: #"\.([a-z]{1,5})\b"#, options: .regularExpression)
                        .map({ String(lower[$0].dropFirst()) }), codeExtensions.contains(ext), !isURLLike(lower) {
                vote(.codeEditor, 1, "title:.\(ext)")
            }
        }

        // 7 · Seed table (hint only) and browser chrome.
        if let seed {
            if seed.family == .browser {
                if !e.isInWebArea, singleLine || role == "AXComboBox" { vote(.urlBar, Weight.browserChrome, "seed:browserChrome") }
            } else if seed.family == .spreadsheet {
                if cellish && !searchRole && !labelSearch { vote(.spreadsheetCell, Weight.seedSpreadsheet, "seed:spreadsheet") }
            } else if let kind = SeedHints.kind(for: seed.family) {
                // A one-line find box in an IDE or terminal is not the code / shell surface.
                if (kind == .codeEditor) && singleLine && !e.isInWebArea {
                    signals.append("seed:code(singleLine, ignored)")
                } else {
                    vote(kind, Weight.seed, "seed:\(seed.family.rawValue)")
                }
            }
        }
        if let runtime { signals.append("runtime:\(runtime.rawValue)") }

        // 8 · The user's override and what this app resolved to before.
        if let o = e.appOverride { vote(o, Weight.override, "override") }
        if let (kind, n) = majority(e.previousKinds.suffix(5)) {
            vote(kind, min(Weight.historyCap, Weight.historyPerTurn * Double(n)), "history×\(n)")
        }

        // Decide.
        let ranked = scores.sorted { $0.value != $1.value ? $0.value > $1.value : priority($0.key) < priority($1.key) }
        guard let best = ranked.first, best.value > 0 else {
            signals.append("fallback:noEvidence")
            return SurfaceResolution(kind: .prose, confidence: 0, isWebArea: isWeb, signals: signals,
                                     isFallback: true, candidate: .prose)
        }
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        let confidence = (best.value / (best.value + runnerUp)) * min(1, best.value / 2.5)
        if confidence < threshold || best.value == runnerUp {   // a tie is ambiguous
            signals.append("fallback:belowThreshold")
            return SurfaceResolution(kind: .prose, confidence: confidence, isWebArea: isWeb, signals: signals,
                                     isFallback: true, candidate: best.key)
        }
        return SurfaceResolution(kind: best.key, confidence: confidence, isWebArea: isWeb, signals: signals,
                                 candidate: best.key)
    }

    /// Tie-break order: the safer formatting first.
    static func priority(_ k: SurfaceKind) -> Int {
        switch k {
        case .secure: return 0
        case .canvas: return 1
        case .terminal: return 2
        case .spreadsheetCell: return 3
        case .searchField: return 4
        case .urlBar: return 5
        case .formField: return 6
        case .codeEditor: return 7
        case .chatComposer: return 8
        case .emailBody: return 9
        case .markdownEditor: return 10
        case .prose: return 11
        }
    }

    static func majority<S: Sequence>(_ kinds: S) -> (SurfaceKind, Int)? where S.Element == SurfaceKind {
        var counts: [SurfaceKind: Int] = [:]
        var last: SurfaceKind?
        for k in kinds { counts[k, default: 0] += 1; last = k }
        guard let top = counts.max(by: { $0.value != $1.value ? $0.value < $1.value : $1.key == last }) else { return nil }
        return (top.key, top.value)
    }

    static func isURLLike(_ s: String) -> Bool { s.contains("http") || s.contains("www.") || s.contains(".com") }

    static func fmt(_ w: Double) -> String { w == w.rounded() ? String(Int(w)) : String(format: "%.1f", w) }
}
