import Foundation
import Pipeline
import Shared

/// R4.2 wiring — how `FieldRoleFormatterStage` enters the app's pipeline: **in place of** the
/// register-routed formatters, never alongside them.
///
/// `StageRegistry.builtIn` deliberately does not contain `FieldRoleFormatterStage`: that list runs
/// one formatter per register, and `FieldRoleFormatterStage` picks and runs an inner formatter
/// itself (from the field role, which is what knows that a terminal inside an editor is a terminal).
/// Keeping both would format the same spans twice — a doubled trailing period, a re-capitalized
/// first word. So the substitution happens here, at the one place that assembles the app's stage
/// list, and it is a `static func` so a test can assert on the exact list the app runs.
public enum FieldRolePipeline {
    /// The per-register formatters `FieldRoleFormatterStage` subsumes.
    public static let replacedFormatterIDs: Set<StageID> = [
        .formatterProse, .formatterEmail, .formatterChat, .formatterCode, .formatterTerminal,
    ]

    /// Writes `field` into the run's `StageContext` — and, when the field's rules contradict the
    /// two edits `StyleStage` makes, switches that stage off for this one run.
    ///
    /// `StyleStage` is the last pass (Bet 8) and it knows only the app's learned style profile, not
    /// the insertion point. The only things it changes are the first word's capitalization and the
    /// terminal period — which are exactly the two things the field role and the continuation plan
    /// have just decided. Left alone it re-capitalizes and re-appends a period over a mid-sentence
    /// insertion, silently undoing R4.2. So when either decision is "no", the run opts out through
    /// `StyleStage.enabledKey` (a documented per-run switch — no change to `Pipeline`).
    ///
    /// An ordinary insertion at the end of a prose field keeps its learned style: there, the field
    /// rules and the style profile want the same two edits, and nothing is switched off.
    public static func write(_ field: FieldContext, into context: inout StageContext) {
        field.write(into: &context)
        // N9 — record the surface (kind, confidence, signals) for later stages and the turn
        // record; an upstream resolution with richer evidence is kept as is.
        if context.extra[FieldContext.Keys.surfaceConfidence] == nil {
            FieldContext.write(field.surface, into: &context)
        }
        let plan = FieldRoleFormatter().plan(for: field)
        if !plan.rules.trailingPeriod || !plan.continuation.capitalizeFirstWord {
            context.extra[StyleStage.enabledKey] = "false"
            // N26 — style off is not "skip cleanup": cleanup still runs, but keeps the edges the
            // field rules just decided (no re-capitalized first word, no re-added period).
            context.extra[CleanupStage.keepEdgesKey] = "true"
        }
    }

    /// `stages` with every per-register formatter removed and one `FieldRoleFormatterStage` put in
    /// the position of the first one. Order is otherwise preserved, so `StyleStage` still runs last
    /// (style is the final pass, Bet 8). Idempotent: a list that already has the field-role stage
    /// gains no second copy.
    public static func replacingFormatters(in stages: [any PipelineStage]) -> [any PipelineStage] {
        var out: [any PipelineStage] = []
        var inserted = stages.contains { $0.id == FieldRoleFormatterStage.stageID }
        for stage in stages {
            guard replacedFormatterIDs.contains(stage.id) else { out.append(stage); continue }
            if !inserted {
                out.append(FieldRoleFormatterStage())
                inserted = true
            }
        }
        return out
    }
}
