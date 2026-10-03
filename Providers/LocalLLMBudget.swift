import Foundation

// MARK: - H14 · token budget and output checks for on-device LLM edits
//
// The shared model runs with a 4,096-token context (`LlamaCppEngine.contextTokens`). An edit is
// budgeted as: ~400 system + ≤ 1,200 context + the selection + output ≤ 2 × selection + 64.
// Context shrinks first (keeping the text nearest the selection); a selection over ~1,000 words is
// refused with a plain message instead of being truncated (truncation would lose text).
// Token counts are estimated (≈ 3 UTF-8 bytes per token, conservative for English and Hinglish);
// the engine still refuses an over-long prompt (`LlamaCppError.promptTooLong`).

public struct LocalLLMBudget: Equatable, Sendable {
    public var contextWindow: Int = 4_096
    public var systemReserve: Int = 400
    public var contextCap: Int = 1_200
    public var maxSelectionWords: Int = 1_000
    public init() {}

    /// H14 — per-call generation cap (2 × selection + 64) for the edit in flight. The provider reads
    /// it (`LlamaCppProvider.generate`) ahead of its config cap; nil outside an edit.
    @TaskLocal public static var outputCap: Int?

    public static let tooLongMessage = "That selection is too long to edit on this Mac. Select under 1,000 words and try again."

    public enum Refusal: Error, Equatable, Sendable {
        case selectionTooLong(words: Int)
        public var message: String { LocalLLMBudget.tooLongMessage }
    }

    public struct Plan: Equatable, Sendable {
        /// The context to send (possibly trimmed from the far end).
        public var context: String
        public var selectionTokens: Int
        public var contextTokens: Int
        /// Generation cap: 2 × selection + 64, never past the window.
        public var maxOutputTokens: Int
    }

    public static func estimateTokens(_ text: String) -> Int { (text.utf8.count + 2) / 3 }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Plan one edit. `contextBefore` is trimmed from its start, `contextAfter` from its end, so the
    /// text nearest the selection survives.
    public func plan(selection: String, contextBefore: String = "", contextAfter: String = "",
                     systemTokens: Int? = nil) -> Result<Plan, Refusal> {
        let words = Self.wordCount(selection)
        if words > maxSelectionWords { return .failure(.selectionTooLong(words: words)) }
        let sel = Self.estimateTokens(selection)
        let out = 2 * sel + 64
        let system = max(systemReserve, systemTokens ?? 0)
        let room = contextWindow - system - sel - out
        if room < 0 { return .failure(.selectionTooLong(words: words)) }
        let ctxBudget = min(contextCap, room)
        var before = contextBefore, after = contextAfter
        while Self.estimateTokens(before) + Self.estimateTokens(after) > ctxBudget {
            // Shrink the longer side by one sentence-ish chunk (or a word when there is no sentence).
            if Self.estimateTokens(before) >= Self.estimateTokens(after), !before.isEmpty {
                before = Self.dropLeading(before)
            } else if !after.isEmpty {
                after = Self.dropTrailing(after)
            } else { break }
        }
        let ctx = [before, after].filter { !$0.isEmpty }.joined(separator: "\n…\n")
        return .success(Plan(context: ctx, selectionTokens: sel, contextTokens: Self.estimateTokens(ctx),
                             maxOutputTokens: min(out, contextWindow - system - sel)))
    }

    static func dropLeading(_ s: String) -> String {
        if let r = s.range(of: #"[.!?]\s+"#, options: .regularExpression), r.upperBound < s.endIndex {
            return String(s[r.upperBound...])
        }
        let parts = s.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : ""
    }

    static func dropTrailing(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let body = trimmed.dropLast()
        if let r = body.range(of: #"[.!?]\s"#, options: [.regularExpression, .backwards]) {
            return String(body[..<r.lowerBound]) + String(body[r.lowerBound])
        }
        if let sp = trimmed.lastIndex(of: " ") { return String(trimmed[..<sp]) }
        return ""
    }
}

/// H14 — what an LLM edit's output is allowed to be. Consumed by the transform executor (L3).
public enum LocalLLMOutputCheck {
    public enum Verdict: Equatable, Sendable {
        case accepted(String, addsLineBreaks: Bool)
        case empty
        case preamble
        case tooLong
    }

    static let preambles = ["sure", "here is", "here's", "certainly", "of course", "okay, here", "ok, here",
                            "absolutely", "i've rewritten", "i have rewritten", "below is", "rewritten text:"]

    /// Strip think blocks, then reject empty / a chatty preamble / more than 3× the selection.
    /// `addsLineBreaks` = the result has line breaks the selection did not (the caller previews it).
    public static func check(output raw: String, selection: String) -> Verdict {
        let out = LlamaCppProvider.stripReasoning(raw)
        if out.isEmpty { return .empty }
        let lower = out.lowercased()
        if preambles.contains(where: { lower.hasPrefix($0) }) { return .preamble }
        if out.count > max(3 * selection.count, 24) { return .tooLong }
        let newLines = out.filter(\.isNewline).count, oldLines = selection.filter(\.isNewline).count
        return .accepted(out, addsLineBreaks: newLines > oldLines)
    }
}
