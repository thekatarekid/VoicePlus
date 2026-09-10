import Foundation
import Shared

/// R4.2 — the formatter chosen by **AX role + app**, plus continuation.
///
/// It is a `[TranscriptSpan] -> [TranscriptSpan]` stage like every other: it picks the inner
/// formatter from `FieldRules`, runs it, then applies the field-role rules the inner formatter
/// cannot know about (identifier preservation, no trailing period, no auto-capitalization) and the
/// continuation decision read off the text before the cursor.
///
/// Not registered in `StageRegistry.builtIn` on purpose: the built-in list already runs one
/// formatter per register, and running both would format twice. `App` builds this stage instead,
/// when it has a field context to give it (see `FieldContext.Keys`).
public struct FieldRoleFormatterStage: PipelineStage {
    public static let stageID: StageID = "formatter.fieldRole"
    public let id: StageID = FieldRoleFormatterStage.stageID

    /// Inner formatter lookup. Injectable so tests can substitute stubs.
    public var formatter: @Sendable (Utterance.Register) -> (any PipelineStage)?

    public init(formatter: @escaping @Sendable (Utterance.Register) -> (any PipelineStage)? = { StageRegistry.formatter(for: $0) }) {
        self.formatter = formatter
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard !spans.isEmpty else { return [] }
        let field = FieldContext(stageContext: context)
        let rules = FieldRules.rules(for: field)
        let plan = ContinuationPlanner.plan(for: field, rules: rules)
        return try await apply(spans, field: field, rules: rules, plan: plan, context: context)
    }

    func apply(_ spans: [TranscriptSpan], field: FieldContext, rules: FieldRules,
               plan: ContinuationPlan, context: StageContext) async throws -> [TranscriptSpan] {
        // A password field gets no formatting at all; `Injection` refuses it anyway (R2.3).
        guard !rules.refusesDictation else { return spans.map { $0.touched(by: id) } }

        var inner = context
        inner.register = rules.register
        var out = spans
        if let stage = formatter(rules.register) {
            out = try await stage.process(out, context: inner)
        }
        if rules.preserveIdentifiers {
            out = CodeIdentifier.restore(CodeIdentifier.spellings(in: spans), in: out)
        }
        if !rules.trailingPeriod {
            out = Self.stripAddedTrailingPeriod(out, original: spans)
        }
        out = Self.applyFirstWordCase(out, original: spans, plan: plan)
        return out.map { $0.touched(by: id) }
    }

    // MARK: - Field-role fixups

    /// Removes a period the inner formatter appended. Never removes one the user dictated, and
    /// never touches `...`, `?` or `!`.
    static func stripAddedTrailingPeriod(_ spans: [TranscriptSpan], original: [TranscriptSpan]) -> [TranscriptSpan] {
        guard let last = spans.lastIndex(where: { !$0.text.isEmpty }) else { return spans }
        var out = spans
        let text = out[last].text
        guard !out[last].isLowConfidence, text.hasSuffix("."), !text.hasSuffix("..") else { return spans }
        let spokenHere = original.first { $0.audioRange == out[last].audioRange }?.text
            ?? original.last(where: { !$0.text.isEmpty })?.text ?? ""
        guard !spokenHere.hasSuffix(".") else { return spans }
        out[last].text = String(text.dropLast())
        return out
    }

    /// Applies `plan.capitalizeFirstWord` to the first word of the insertion.
    ///
    /// Lowercasing back is only ever done when the *spoken* word was lowercase — the formatter
    /// capitalized it because it assumed a sentence start, and the text before the cursor says
    /// otherwise. A proper noun, an all-caps word, "I", and anything identifier-shaped are left
    /// exactly as the formatter left them.
    static func applyFirstWordCase(_ spans: [TranscriptSpan], original: [TranscriptSpan],
                                   plan: ContinuationPlan) -> [TranscriptSpan] {
        guard let index = spans.firstIndex(where: { !$0.isLowConfidence && $0.text.contains(where: \.isLetter) })
        else { return spans }
        var out = spans
        let text = out[index].text
        guard let letter = text.firstIndex(where: \.isLetter) else { return spans }
        let character = text[letter]

        if plan.capitalizeFirstWord {
            guard character.isLowercase else { return spans }
            out[index].text = text.replacingCharacters(in: letter...letter, with: character.uppercased())
            return out
        }
        guard character.isUppercase else { return spans }
        let word = String(text[letter...].prefix { !$0.isWhitespace })
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"')]}"))
        guard !iForms.contains(core), !CodeIdentifier.looksLikeIdentifier(word),
              core != core.uppercased() || core.count == 1,
              spokenFirstLetterIsLowercase(original) else { return spans }
        out[index].text = text.replacingCharacters(in: letter...letter, with: character.lowercased())
        return out
    }

    static let iForms: Set<String> = ["I", "I'm", "I'll", "I've", "I'd"]

    static func spokenFirstLetterIsLowercase(_ original: [TranscriptSpan]) -> Bool {
        for span in original {
            if let c = span.text.first(where: \.isLetter) { return c.isLowercase }
        }
        return false
    }
}

/// The result the injector needs: the spans (for history and provenance) and the exact string,
/// continuation whitespace included.
public struct FormattedField: Sendable, Equatable {
    public var spans: [TranscriptSpan]
    public var role: FieldRole
    public var rules: FieldRules
    public var continuation: ContinuationPlan
    /// Exactly what `Injection` should send: `continuation.leading` + the formatted words +
    /// `continuation.trailing`.
    public var text: String
    /// Convenience mirror of `rules.allowSubmit`. Always false for a terminal role.
    public var allowSubmit: Bool { rules.allowSubmit }
}

/// Synchronous-friendly façade over the stage, for `App`/`Injection` and for the golden tests.
public struct FieldRoleFormatter: Sendable {
    public var stage: FieldRoleFormatterStage

    public init(stage: FieldRoleFormatterStage = FieldRoleFormatterStage()) { self.stage = stage }

    /// Rules + continuation without running any formatter (cheap; useful for a pre-flight check).
    public func plan(for field: FieldContext) -> (role: FieldRole, rules: FieldRules, continuation: ContinuationPlan) {
        let rules = FieldRules.rules(for: field)
        return (rules.role, rules, ContinuationPlanner.plan(for: field, rules: rules))
    }

    public func format(_ spans: [TranscriptSpan], field: FieldContext,
                       context: StageContext = StageContext()) async throws -> FormattedField {
        let (role, rules, continuation) = plan(for: field)
        var stageContext = context
        field.write(into: &stageContext)
        let out = try await stage.apply(spans, field: field, rules: rules, plan: continuation, context: stageContext)
        let words = out.renderedText
        // A refusing field yields no text at all: a caller that reads `text` and ignores
        // `rules.refusesDictation` still cannot post a password field's contents anywhere.
        let text = (words.isEmpty || rules.refusesDictation) ? "" : continuation.leading + words + continuation.trailing
        return FormattedField(spans: out, role: role, rules: rules, continuation: continuation, text: text)
    }
}
