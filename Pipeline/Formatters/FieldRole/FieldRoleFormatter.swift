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

    /// V5 E2/E3 — the formatter for a field whose numbers are always digits (a spreadsheet cell, a
    /// phone / email / URL box): prose rules with every number as digits and no added period.
    public var valueFormatter: @Sendable () -> any PipelineStage

    public init(formatter: @escaping @Sendable (Utterance.Register) -> (any PipelineStage)? = { StageRegistry.formatter(for: $0) },
                valueFormatter: @escaping @Sendable () -> any PipelineStage = { FieldRoleFormatterStage.digitsFormatter }) {
        self.formatter = formatter
        self.valueFormatter = valueFormatter
    }

    /// Prose formatting with "ITN always on": 0–9 become digits, nothing appends a period.
    public static var digitsFormatter: ProseListFormatter {
        var options = ProseListFormatter.Options()
        options.spellOutSmallNumbers = false
        options.addTerminalPeriod = false
        return ProseListFormatter(options: options)
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
        let digitsOnly = rules.alwaysNormalizeNumbers && rules.category != .code && rules.category != .terminal
        if let stage = digitsOnly ? valueFormatter() : formatter(rules.register) {
            out = try await stage.process(out, context: inner)
        }
        // V5 E3 — an email / URL box: "jo at example dot com" → "jo@example.com".
        if let kind = rules.inputKind, kind == .email || kind == .url {
            out = FieldValueCompactor.compact(out, kind: kind)
        }
        if rules.preserveIdentifiers {
            out = CodeIdentifier.restore(CodeIdentifier.spellings(in: spans), in: out)
        }
        // D2 — which marks the user dictated; those are never stripped below.
        out = PunctuationProvenance.annotate(out, original: spans)
        // A cell entry that starts with a number ("5 units") is a value, never a sentence.
        let startsWithNumber = out.renderedText.first(where: { !$0.isWhitespace })?.isNumber ?? false
        let decision = Self.decision(plan: plan, rules: rules, field: field,
                                     wordCount: startsWithNumber && rules.role == .spreadsheetCell ? 0 : Self.wordCount(out))
        out = Self.applyTerminalPeriod(out, original: spans, keepModel: decision.keepModelPeriod,
                                       keepAdded: decision.keepAddedPeriod && rules.trailingPeriod)
        out = Self.applyFirstWordCase(out, original: spans, action: decision.firstWord)
        return out.map { $0.touched(by: id) }
    }

    /// The continuation decision, with the V5 E2/E3 value-field overrides: a spreadsheet cell or a
    /// value box never keeps a period it did not hear, and a short cell label gets no invented
    /// capital (a longer, sentence-like cell entry is capitalised like any sentence).
    static func decision(plan: ContinuationPlan, rules: FieldRules, field: FieldContext,
                         wordCount: Int) -> ContinuationPlan.Resolved {
        if rules.role == .spreadsheetCell {
            let sentence = wordCount > FieldRules.shortLabelMaxWords
            var sentenceRules = rules
            sentenceRules.autoCapitalize = true
            let sentencePlan = sentence ? ContinuationPlanner.plan(for: field, rules: sentenceRules) : plan
            var resolved = sentencePlan.resolved(wordCount: wordCount, textRole: sentence)
            if !sentence { resolved.firstWord = .lowercaseAddedOnly }
            resolved.keepModelPeriod = false
            resolved.keepAddedPeriod = false
            return resolved
        }
        var resolved = plan.resolved(wordCount: wordCount, textRole: rules.autoCapitalize)
        if rules.alwaysNormalizeNumbers {
            resolved.keepModelPeriod = false
            resolved.keepAddedPeriod = false
        }
        return resolved
    }

    /// Words in the insertion (tokens with a letter or digit), after fillers were removed.
    static func wordCount(_ spans: [TranscriptSpan]) -> Int {
        spans.renderedText.split(whereSeparator: { $0.isWhitespace }).filter { PunctuationProvenance.hasContent(String($0)) }.count
    }

    // MARK: - Field-role fixups

    /// D2 — the final period, by origin: a spoken one always stays; the recogniser's stays when
    /// `keepModel`; one a formatter appended stays when `keepAdded`. `?`, `!`, `...`, an
    /// abbreviation's dot and a low-confidence span are never touched.
    static func applyTerminalPeriod(_ spans: [TranscriptSpan], original: [TranscriptSpan],
                                    keepModel: Bool, keepAdded: Bool) -> [TranscriptSpan] {
        guard let (index, origin) = PunctuationProvenance.trailingPeriod(in: spans, original: original) else { return spans }
        var out = spans
        let keep: Bool
        switch origin {
        case .spoken: keep = true
        case .model: keep = keepModel
        case .stage: keep = keepAdded
        }
        if keep {
            if origin == .stage { out[index].punctuationOrigin = .stage }
            return out
        }
        let text = out[index].text
        guard let dot = text.lastIndex(of: "."),
              text[text.index(after: dot)...].allSatisfy(\.isWhitespace) else { return spans }
        out[index].text.remove(at: dot)
        return out
    }

    /// D2 — the first word's capital.
    ///
    /// `.capitalize` uppercases a lowercase first letter. `.lowercase` lowercases a capital from
    /// the recogniser or a formatter; `.lowercaseAddedOnly` only one a formatter added (the heard
    /// word was lowercase). Either way a proper-noun-shaped word is left alone: "I", an acronym,
    /// an identifier, a weekday or month. A low-confidence first span is never rewritten.
    static func applyFirstWordCase(_ spans: [TranscriptSpan], original: [TranscriptSpan],
                                   action: FirstWordAction) -> [TranscriptSpan] {
        guard let index = spans.firstIndex(where: { $0.text.contains(where: \.isLetter) }),
              !spans[index].isLowConfidence else { return spans }
        var out = spans
        let text = out[index].text
        guard let letter = text.firstIndex(where: \.isLetter) else { return spans }
        let character = text[letter]

        if action == .capitalize {
            guard character.isLowercase else { return spans }
            out[index].text = text.replacingCharacters(in: letter...letter, with: character.uppercased())
            return out
        }
        guard character.isUppercase else { return spans }
        let word = String(text[letter...].prefix { !$0.isWhitespace })
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"')]}"))
        guard !iForms.contains(core), !CodeIdentifier.looksLikeIdentifier(word),
              core != core.uppercased() || core.count == 1,
              !Capitalizer.always.contains(core.lowercased()) else { return spans }
        if action == .lowercaseAddedOnly,
           !PunctuationProvenance.heardFirstLetterIsLowercase(for: spans[index], original: original) { return spans }
        out[index].text = text.replacingCharacters(in: letter...letter, with: character.lowercased())
        return out
    }

    static let iForms: Set<String> = ["I", "I'm", "I'll", "I've", "I'd"]
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
