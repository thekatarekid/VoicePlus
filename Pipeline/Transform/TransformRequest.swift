import Foundation
import Shared

/// Coarse instruction class. Drives the local fallback and the prompt; the model sees the
/// verbatim instruction regardless.
public enum TransformKind: String, Codable, Sendable, CaseIterable {
    case tone, shorten, expand, restructure, translateFormat, fix, general

    static let lexicon: [(TransformKind, [String])] = [
        (.shorten, ["shorter", "shorten", "condense", "tighten", "concise", "brief", "trim", "summarize", "summarise", "cut", "fewer",
                    "one sentence", "one line", "headline", "punchier", "punchy", "tweet", "half"]),
        (.expand, ["longer", "expand", "elaborate", "flesh", "detail", "more detail"]),
        (.translateFormat, ["translate", "hindi", "spanish", "french", "german", "japanese", "markdown", "json", "csv", "table", "html",
                            "yaml", "format", "uppercase", "lowercase", "title case", "shell", "command", "date", "link"]),
        (.restructure, ["list", "bullet", "bullets", "bulletize", "numbered", "paragraph", "paragraphs", "lines", "reorder", "restructure",
                        "headings", "steps", "two lines", "sentences", "split", "merge", "break", "first", "checklist", "question",
                        "bold", "italic", "call out", "highlight"]),
        (.tone, ["formal", "casual", "friendly", "friendlier", "polite", "professional", "warmer", "softer", "firmer", "aggressive",
                 "assertive", "apologetic", "enthusiastic", "neutral", "tone", "sound", "confident", "manager"]),
        (.fix, ["grammar", "typos", "spelling", "proofread", "fix", "clean", "correct", "punctuation"]),
    ]

    public static func infer(from instruction: String) -> TransformKind {
        let lowered = instruction.lowercased()
        let words = Set(GatekeeperTokenizer.words(instruction))
        for (kind, cues) in lexicon where cues.contains(where: { $0.contains(" ") ? lowered.contains($0) : words.contains($0) }) {
            return kind
        }
        return .general
    }
}

/// Everything the rewrite model needs for one turn (P2.1 "selection text + surrounding context").
public struct TransformRequest: Equatable, Sendable {
    public var instruction: [TranscriptSpan]
    public var selection: SelectionSnapshot
    public var kind: TransformKind
    public var register: Utterance.Register
    public var appBundleID: String?
    public var persona: String?
    /// Prior turns on the same selection (chained turns, Kivi pattern) — newest last.
    public var history: [String]

    public init(instruction: [TranscriptSpan], selection: SelectionSnapshot, context: StageContext, history: [String] = []) {
        self.instruction = instruction
        self.selection = selection
        self.kind = TransformKind.infer(from: instruction.joinedText)
        self.register = context.register
        self.appBundleID = context.appBundleID ?? selection.bundleID
        self.persona = context.extra["persona"]
        self.history = history
    }

    public var instructionText: String { instruction.joinedText }

    /// Bet 9 at the instruction level: a low-confidence word in a short instruction changes what
    /// the user asked for ("make it *formal*" vs "*normal*"). We refuse to guess.
    public var uncertainInstructionWords: [TranscriptSpan] { instruction.filter(\.isLowConfidence) }

    /// H8 (old H5) — the uncertain words that decide the command. Fillers, politeness and the
    /// words that only point at the selection ("this", "it", "the text") never do.
    public var decisiveUncertainWords: [TranscriptSpan] {
        uncertainInstructionWords.filter { span in
            let words = GatekeeperTokenizer.words(span.text)
            return !words.isEmpty && !words.allSatisfy(Self.nonDecidingWords.contains)
        }
    }

    static let nonDecidingWords: Set<String> = [
        "um", "uh", "er", "erm", "ah", "hmm", "mm", "like", "so", "well", "okay", "ok", "please", "just", "now",
        "can", "could", "would", "you", "hey", "the", "a", "an", "this", "it", "that", "these", "those",
        "selection", "selected", "text", "bit", "little",
    ]

    public var systemPrompt: String {
        var s = "You rewrite text in place. Apply the user's instruction to the SELECTION only. "
        s += "Return ONLY the rewritten selection — no quotes, no commentary, no preamble. "
        s += "Keep facts, names, numbers and links unchanged unless the instruction says otherwise. "
        s += "Match the destination register: \(register.rawValue)."
        if let persona { s += " Writing style: \(persona)." }
        return s
    }

    public var prompt: String {
        var p = ""
        if !selection.before.isEmpty { p += "CONTEXT BEFORE:\n\(selection.before)\n\n" }
        p += "SELECTION:\n\(selection.text)\n\n"
        if !selection.after.isEmpty { p += "CONTEXT AFTER:\n\(selection.after)\n\n" }
        if !history.isEmpty { p += "PREVIOUS INSTRUCTIONS (already applied):\n" + history.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        p += "INSTRUCTION: \(instructionText)"
        return p
    }
}
