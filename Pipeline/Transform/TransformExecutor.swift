import Foundation
import Shared

/// Which model tier the user wants for rewrites (PRODUCT-SPEC Part 4.6: local default,
/// best-available only where the user enabled it). Carried in `StageContext.extra`.
public enum TransformPreference: String, Sendable {
    case local, bestAvailable
    public static let contextKey = "transform.preference"
    public static func from(_ context: StageContext) -> TransformPreference {
        context.extra[contextKey].flatMap(TransformPreference.init(rawValue:)) ?? .local
    }
}

public struct TransformResult: Equatable, Sendable {
    public enum Source: String, Sendable { case provider, local }
    public var request: TransformRequest
    /// The rewritten selection. Never empty on success.
    public var output: String
    /// Instruction spans with provenance appended (Bet 9: low-confidence words flagged, never rewritten).
    public var instructionSpans: [TranscriptSpan]
    public var diff: WordDiff
    public var source: Source
    public var latencyMs: Double
    /// The replace-range request to hand to the injector (P1.8 T5).
    public var replace: TransformReplaceRequest {
        TransformReplaceRequest(range: request.selection.range, expected: request.selection.text, replacement: output,
                                elementToken: request.selection.elementToken)
    }
}

public enum TransformError: Error, Equatable, Sendable {
    /// The instruction contains low-confidence words; executing would be a guess (Bet 9).
    case uncertainInstruction([String])
    case emptySelection
    case emptyOutput
}

/// P2.2 — runs a `TransformRequest` through the provider hook (Providers routing, wired by the
/// app) with a deterministic local fallback so a rewrite always lands on-device.
public struct TransformExecutor: Sendable {
    public let id: StageID = .transform
    public let providers: any PipelineProviderRouting
    public var local: any LocalTransforming

    public init(providers: any PipelineProviderRouting = LocalOnlyProviderRouting(), local: any LocalTransforming = LocalTransformRules()) {
        self.providers = providers
        self.local = local
    }

    public func execute(_ request: TransformRequest, context: StageContext) async throws -> TransformResult {
        let start = DispatchTime.now().uptimeNanoseconds
        guard request.selection.isMeaningful else { throw TransformError.emptySelection }
        let uncertain = request.uncertainInstructionWords
        if !uncertain.isEmpty { throw TransformError.uncertainInstruction(uncertain.map(\.text)) }

        var stageContext = context
        stageContext.extra[TransformPreference.contextKey] = TransformPreference.from(context).rawValue
        stageContext.extra["transform.kind"] = request.kind.rawValue
        stageContext.extra["transform.system"] = request.systemPrompt

        var source = TransformResult.Source.local
        var text = ""
        if providers.isProviderEnabled(for: id, context: stageContext) {
            if let out = try? await providers.complete(stage: id, prompt: request.prompt, input: request.selection.text, context: stageContext) {
                text = Self.clean(out); source = .provider
            }
        }
        if text.isEmpty { text = Self.clean(local.transform(request)); source = .local }
        guard !text.isEmpty else { throw TransformError.emptyOutput }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        return TransformResult(request: request, output: text,
                               instructionSpans: request.instruction.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.touched(by: id) },
                               diff: WordDiff.compute(old: request.selection.text, new: text), source: source, latencyMs: ms)
    }

    /// Strip wrapper quotes / code fences / "Rewritten:" style preambles models add.
    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```"), t.hasSuffix("```") {
            t = t.dropFirst(3).dropLast(3).trimmingCharacters(in: .whitespacesAndNewlines)
            if let nl = t.firstIndex(of: "\n"), !t[..<nl].contains(" ") { t = String(t[t.index(after: nl)...]) }
        }
        for prefix in ["Rewritten:", "Rewrite:", "Output:", "Here is the rewritten text:", "Here's the rewritten text:"] where t.lowercased().hasPrefix(prefix.lowercased()) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if t.count >= 2, t.first == "\"", t.last == "\"", t.dropFirst().dropLast().filter({ $0 == "\"" }).isEmpty {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// On-device, rule-based rewrite used when no model is enabled or the provider fails.
/// Conservative: it only applies transformations it can do deterministically and otherwise
/// returns the selection unchanged (the UX shows "no change" rather than inventing text).
public protocol LocalTransforming: Sendable {
    func transform(_ request: TransformRequest) -> String
}

public struct LocalTransformRules: LocalTransforming {
    public init() {}

    public func transform(_ request: TransformRequest) -> String {
        let text = request.selection.text
        let words = GatekeeperTokenizer.words(request.instructionText)
        switch request.kind {
        case .shorten:
            return Self.stripFillers(text)
        case .restructure:
            if words.contains("list") || words.contains("bullet") || words.contains("bullets") || words.contains("points") {
                return Self.sentences(text).map { "- \($0)" }.joined(separator: "\n")
            }
            if words.contains("numbered") || words.contains("steps") {
                return Self.sentences(text).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            }
            if words.contains("paragraph") || words.contains("line") { return Self.sentences(text).joined(separator: " ") }
            if words.contains("lines") { return Self.sentences(text).joined(separator: "\n") }
            return text
        case .fix:
            return Self.fixCasingAndSpacing(text)
        case .tone:
            if words.contains("uppercase") || words.contains("shout") { return text.uppercased() }
            if words.contains("lowercase") { return text.lowercased() }
            return text
        case .translateFormat, .expand, .general:
            if words.contains("uppercase") { return text.uppercased() }
            if words.contains("lowercase") { return text.lowercased() }
            return text
        }
    }

    static let fillers: Set<String> = ["um", "uh", "like", "basically", "actually", "really", "just", "very", "kind of", "sort of", "you know", "I think", "I guess"]

    static func stripFillers(_ text: String) -> String {
        var t = text
        for f in fillers.sorted(by: { $0.count > $1.count }) {
            t = t.replacingOccurrences(of: "\\b\(NSRegularExpression.escapedPattern(for: f)),?\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?".contains(ch) { out.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = "" }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out.filter { !$0.isEmpty }
    }

    static func fixCasingAndSpacing(_ text: String) -> String {
        let parts = sentences(text).map { s -> String in
            guard let first = s.first else { return s }
            return first.uppercased() + s.dropFirst()
        }
        return parts.joined(separator: " ").replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\bi\\b", with: "I", options: .regularExpression)
    }
}
