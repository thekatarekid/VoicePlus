import Foundation
import Shared

public extension StageID {
    /// P2.4 — answer a question about the selection. Same raw value as P2.1's `.question`
    /// (declared in Pipeline/Transform) so provenance and provider routing agree.
    static let questionAnswer: StageID = "question"
}

/// Where the injector should put a stage's output relative to the current selection.
public enum InsertionIntent: Equatable, Sendable {
    /// Replace the selected range (transforms, P2.2).
    case replaceSelection
    /// Keep the selection; insert `text` on a new line after its end (`selectionLength` chars).
    case insertBelow(selectionLength: Int)
    /// Nothing to insert.
    case none
}

/// Answers a question about a piece of text. Implementations: `HeuristicAnswerer` (offline,
/// extractive) and `ProviderAnswerer` (routes to the user's provider, falls back to heuristic).
public protocol QuestionAnswering: Sendable {
    func answer(question: String, selection: String, surrounding: String?, context: StageContext) async throws -> String
}

/// Output of `QuestionAnswerStage.answer`. `spans` = the question spans (provenance stamped)
/// followed by one appended answer span carrying the visible attribution.
public struct QuestionAnswerOutput: Equatable, Sendable {
    public var spans: [TranscriptSpan]
    public var answer: String?
    public var intent: InsertionIntent
    /// Exactly the text the injector types below the selection (leading newline + attribution).
    public var insertion: String { answer.map { "\n" + QuestionAnswerStage.attribution($0) } ?? "" }
}

/// `question` route → answer typed *below* the selection with an "answer:" prefix. The stage
/// never touches the selection and never rewrites the question spans; the answer is a new span
/// with full confidence and a zero-length audio range at the end of the utterance.
public struct QuestionAnswerStage: PipelineStage {
    public let id: StageID = .questionAnswer
    public let answerer: any QuestionAnswering
    public static let attributionPrefix = "answer:"
    /// `StageContext.extra` keys supplied by the selection detector (P2.1).
    public static let selectionKey = "selection.text"
    public static let surroundingKey = "selection.context"

    public init(answerer: any QuestionAnswering = HeuristicAnswerer()) { self.answerer = answerer }

    public static func attribution(_ answer: String) -> String { "\(attributionPrefix) \(answer)" }

    /// Strips any attribution/quoting a model may echo and collapses whitespace to one line
    /// per paragraph; `nil` when nothing usable remains.
    public static func sanitize(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let prefix = ["answer:", "Answer:", "ANSWER:", "A:"].first(where: { t.hasPrefix($0) }) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        t = t.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
             .filter { !$0.isEmpty }.joined(separator: "\n")
        return t.isEmpty ? nil : t
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        try await answer(spans, context: context).spans
    }

    public func answer(_ spans: [TranscriptSpan], context: StageContext) async throws -> QuestionAnswerOutput {
        let stamped = spans.map { $0.touched(by: id) }
        let selection = context.extra[Self.selectionKey] ?? ""
        let question = spans.joinedText.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QuestionAnswerOutput(spans: stamped, answer: nil, intent: .none)
        }
        let raw = try await answerer.answer(question: question, selection: selection,
                                            surrounding: context.extra[Self.surroundingKey], context: context)
        guard let clean = Self.sanitize(raw) else { return QuestionAnswerOutput(spans: stamped, answer: nil, intent: .none) }
        let end = spans.map(\.audioRange.upperBound).max() ?? 0
        let answerSpan = TranscriptSpan(text: Self.attribution(clean), confidence: 1, audioRange: end...end, provenance: [id])
        return QuestionAnswerOutput(spans: stamped + [answerSpan], answer: clean,
                                    intent: .insertBelow(selectionLength: selection.count))
    }
}

/// Provider-backed answerer (P1.10 via the T10 hook). Falls back to `HeuristicAnswerer` when
/// the provider is disabled/unavailable. Persona text, when present, shapes the answer's voice.
public struct ProviderAnswerer: QuestionAnswering {
    public let providers: any PipelineProviderRouting
    public let fallback: any QuestionAnswering
    public init(providers: any PipelineProviderRouting, fallback: any QuestionAnswering = HeuristicAnswerer()) {
        self.providers = providers; self.fallback = fallback
    }

    public static func prompt(question: String, selection: String, surrounding: String?, persona: String?) -> String {
        var p = "Answer the question about the SELECTED TEXT in one short paragraph. Return only the answer, no preamble, "
        p += "no 'answer:' prefix. Do not rewrite or repeat the selected text.\n"
        if let persona, !persona.isEmpty { p += "Voice: \(persona)\n" }
        if let surrounding, !surrounding.isEmpty { p += "SURROUNDING CONTEXT:\n\(surrounding)\n" }
        p += "SELECTED TEXT:\n\(selection)\nQUESTION: \(question)"
        return p
    }

    public func answer(question: String, selection: String, surrounding: String?, context: StageContext) async throws -> String {
        let prompt = Self.prompt(question: question, selection: selection, surrounding: surrounding, persona: context.extra["persona"])
        return try await providers.completeOrLocal(stage: .questionAnswer, prompt: prompt, input: question, context: context) {
            try await fallback.answer(question: question, selection: selection, surrounding: surrounding, context: context)
        }
    }
}

/// Offline, extractive answerer. Handles counting questions, "what does this say" (first
/// sentence), keyword lookups (sentence sharing the most content words with the question),
/// and otherwise says it cannot answer offline — honest beats invented.
public struct HeuristicAnswerer: QuestionAnswering {
    public static let cannotAnswer = "I can't answer that offline; enable a provider for questions."
    public init() {}

    static let stop: Set<String> = ["what", "who", "is", "does", "how", "why", "when", "where", "which", "can", "this", "that",
                                    "it", "the", "a", "an", "of", "in", "to", "say", "mean", "about", "do", "are", "was", "did", "there"]

    public func answer(question: String, selection: String, surrounding: String?, context: StageContext) async throws -> String {
        let q = GatekeeperTokenizer.words(question)
        let words = selection.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if q.contains("many") || q.contains("count") || q.contains("long") {
            if q.contains("word") || q.contains("words") || q.contains("long") { return "\(words.count) words" }
            if q.contains("character") || q.contains("characters") { return "\(selection.count) characters" }
            if q.contains("sentence") || q.contains("sentences") { return "\(Self.sentences(selection).count) sentences" }
            if q.contains("line") || q.contains("lines") { return "\(selection.split(whereSeparator: \.isNewline).count) lines" }
        }
        let sentences = Self.sentences(selection)
        if q.contains("say") || q.contains("about") || q.contains("summary") || q.contains("gist") {
            if let first = sentences.first { return first }
        }
        let content = Set(q.filter { !Self.stop.contains($0) && $0.count > 2 })
        if !content.isEmpty {
            let scored = sentences.map { s -> (String, Int) in
                (s, Set(GatekeeperTokenizer.words(s)).intersection(content).count)
            }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        }
        return Self.cannotAnswer
    }

    /// Splits on terminal punctuation followed by whitespace/end (so "4.2%" and "e.g." survive).
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []; var cur = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            let atEnd = i == chars.count - 1 || chars[i + 1].isWhitespace || chars[i + 1].isNewline
            if (".!?".contains(ch) && atEnd) || ch.isNewline {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }; cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out.append(t) }
        return out
    }
}
