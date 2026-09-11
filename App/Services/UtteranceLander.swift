import Engine
import Foundation
import Injection
import Lab
import Pipeline
import Shared

/// Result of landing one utterance (what the pill, history and tests look at).
public struct LandingResult: Sendable {
    public var utteranceID: UUID
    public var route: Utterance.Route
    public var register: Utterance.Register
    public var text: String
    public var injection: InjectionOutcome?
    /// R2.4 — the human name of where this text was headed ("Notes"), for the held row and the
    /// Recover text menu. Taken from the focus snapshot, so it names the *intended* destination
    /// even after focus moved.
    public var focusDestination: String?
    public var repair: RepairResult?
    /// P2.3 — set when the utterance was a transform / question on a selection.
    public var transform: TransformLanding.Outcome?
    /// P1.5.2 — set when "put it back" reverted a silent correction.
    public var revertedCorrection: CorrectionEntry?
    public var pipelineMs: Double
    public var totalMs: Double
    /// R4.2 — what the insertion point turned out to *be*, once the AX hints were read. `nil` when
    /// no field context was available (no accessibility permission, or nothing focused).
    public var fieldRole: FieldRole?
    /// R4.2 — `FieldRules.allowSubmit`: whether anything downstream may press Return after this
    /// text. Always false for a terminal role, whatever the field claims about Return.
    public var allowSubmit = false

    public var landed: Bool { injection?.succeeded ?? false }

    /// R2.4 — what actually happened to this text, in the vocabulary the pill and the menu speak
    /// (`DeliveryOutcome`, R2.1). `nil` only when nothing was ever offered to the injector: a
    /// repair command, an act-domain claim, a transform, or empty spans.
    public var delivery: DeliveryOutcome? { injection.map(DeliveryOutcome.init(injection:)) }

    /// The destination name to put in a held row ("Held for Notes"), when focus was snapshotted.
    public var destinationName: String { focusDestination ?? "" }
}

extension DeliveryOutcome {
    /// Injection's outcome → the delivery outcome the surfaces render.
    ///
    /// The mapping itself belongs to `Injection` (R2.3 owns the readback rule and the refusal
    /// policy: an unconfirmed post stays *delivered but unconfirmed*, a never-inject app holds its
    /// text, a secure field does not). This is deliberately a one-line forward to
    /// `InjectionOutcome.delivery` rather than a second copy of that policy in `App` — a duplicate
    /// would silently disagree the first time the rule changed.
    public init(injection: InjectionOutcome) { self = injection.delivery }
}

/// P1.12 T1 — final spans → pipeline (gatekeeper → formatter by register → style) →
/// repair route or injection → history / zero-edit / recent-words. Pure composition; every
/// collaborator is a protocol so the latency and chaos tests drive it with mocks.
public final class UtteranceLander: @unchecked Sendable {
    public let pipeline: PipelineRunner
    public let injector: any Injector
    public let system: SystemAccess
    public let repair: RepairSession?
    public let flags: FeatureFlagService
    public let database: AppDatabase?
    public let zeroEdit: ZeroEditTracker?
    public let recentWords: RecentWordsRing?
    public var stylePersonaProvider: ((String?) -> String?)?
    public var clock: () -> Date = Date.init
    /// P2.5 — per-app persona box (+ recipient overrides) decorates every context.
    public var personaManager: PersonaManager?
    /// P2.3 — transform / question landing on a selection.
    public var transform: TransformLanding?
    /// P1.5.2 — dual-path silent correction after landing + "put it back".
    public var correction: CorrectionService?
    /// P3 — deixis/referent resolution injects `contextLine` (+ window text) before the pipeline runs.
    public var contextAugmenter: (([TranscriptSpan], StageContext) -> StageContext)?
    /// R4.2 — the focused field as a value (AX role/subrole/hints + the text around the caret).
    /// Written into the stage context before the pipeline runs, so `FieldRoleFormatterStage`
    /// classifies the insertion point; read again after it, for the continuation whitespace, the
    /// submit rule and the secure-field refusal. `nil` result = classify by role + app as before.
    /// `AppContainer` sets this to a `FieldContextReader` over the live `SystemAccess`.
    public var fieldContextProvider: ((String?) -> FieldContext?)?
    /// P4.2 — returns true (and consumes the claim) when the act pre-route hook took this utterance.
    public var actClaimConsumer: (() -> Bool)?
    /// P6.3 — script-aware text assembly (code-switch merger); nil result keeps the joined text.
    public var textFinalizer: (([TranscriptSpan]) -> String?)?
    /// Tests await the reconcile; the app runs it off the landing path.
    public var reconcileInline = false
    /// Diagnostic: when true, the raw recognised text and the landed text are written to the log
    /// verbatim, so one real utterance separates "bad recognition" from "good recognition, mangled
    /// afterwards". Off by default (the summary below is always logged and names no words); opt in
    /// with `VOICEPLUS_LOG_TEXT=1`. Local `os_log` only — nothing leaves the machine.
    public var logsText = ProcessInfo.processInfo.environment["VOICEPLUS_LOG_TEXT"] == "1"

    public init(pipeline: PipelineRunner, injector: any Injector, system: SystemAccess, repair: RepairSession?,
                flags: FeatureFlagService, database: AppDatabase?, zeroEdit: ZeroEditTracker? = nil,
                recentWords: RecentWordsRing? = nil) {
        self.pipeline = pipeline
        self.injector = injector
        self.system = system
        self.repair = repair
        self.flags = flags
        self.database = database
        self.zeroEdit = zeroEdit
        self.recentWords = recentWords
    }

    public func context(bundleID: String?) -> StageContext {
        var flagMap: [String: Bool] = [:]
        for f in flags.knownFlags { flagMap[f.id] = flags.isEnabled(f) }
        var extra: [String: String] = [:]
        if let persona = stylePersonaProvider?(bundleID) { extra["persona"] = persona }
        let ctx = StageContext(register: .unknown, appBundleID: bundleID, flags: flagMap, extra: extra)
        return personaManager?.decorate(ctx) ?? ctx
    }

    /// Runs the whole landing. `focus` is the snapshot taken at key release; injection aborts
    /// (and queues) if focus moved since.
    @discardableResult
    public func land(_ spans: [TranscriptSpan], startedAt: Date, focus: FocusSnapshot?) async -> LandingResult {
        let t0 = clock()
        let id = UUID()
        let bundleID = focus?.bundleID ?? system.frontmostApp()?.bundleID
        var ctx = context(bundleID: bundleID)
        if let contextAugmenter { ctx = contextAugmenter(spans, ctx) }
        // R4.2 — the field context goes in last so nothing else can overwrite its keys.
        let field = fieldContextProvider?(bundleID)
        if let field { FieldRolePipeline.write(field, into: &ctx) }
        var result = LandingResult(utteranceID: id, route: .none, register: .unknown, text: "", injection: nil,
                                   focusDestination: Self.destinationName(focus: focus, bundleID: bundleID),
                                   repair: nil, pipelineMs: 0, totalMs: 0)
        guard !spans.isEmpty, !spans.joinedText.trimmingCharacters(in: .whitespaces).isEmpty else { return result }

        var outSpans = spans
        var decision = GatekeeperDecision.fallback()
        do {
            let out = try await pipeline.run(spans, context: ctx)
            outSpans = out.spans
            decision = out.decision
            result.pipelineMs = out.totalLatencyMs
        } catch {
            Log.pipeline.error("pipeline failed, landing raw text: \(error)")
        }
        result.route = decision.route
        result.register = decision.register

        // P4.2 — the act pre-route hook claimed the utterance (adapter returns route .none):
        // the text is a command, never typed; the act session already received it. The claim
        // flag is authoritative even when the gatekeeper's budget guard replaced the decision
        // with the dictate fallback (debug builds can exceed the 15 ms budget on a cold parse).
        // Plain route-.none decisions (fillers-only) carry no claim and land verbatim as before.
        if actClaimConsumer?() == true {
            result.route = Utterance.Route.none
            result.text = outSpans.joinedText
            result.totalMs = ms(since: t0)
            Log.app.info("act domain claimed utterance (\(result.text.count) chars)")
            return result
        }

        // P2.3 — a selection turns the utterance into a transform / question (Bet 5). The raw
        // spans are the instruction: formatters must not rewrite what the user asked for.
        if let transform, decision.route != .repairCommand || transform.isWarm {
            let outcome = await transform.handle(spans, decision: decision, context: ctx)
            if outcome != .notHandled {
                result.transform = outcome
                result.route = transform.route(decision).route
                result.text = spans.joinedText
                result.totalMs = ms(since: t0)
                Log.app.info("transform: \(String(describing: outcome))")
                return result
            }
        }

        // P1.5.2 — "put it back" undoes a silent correction before the repair session's own undo.
        if decision.route == .repairCommand, let correction, let sink = repair?.replaceSink,
           case .revertedCorrection(let entry) = CorrectionUndoRouter.handle(text: spans.joinedText, ledger: correction.ledger, sink: sink, at: clock()) {
            result.revertedCorrection = entry
            result.text = spans.joinedText
            result.totalMs = ms(since: t0)
            return result
        }

        // Bet 3 — spoken repair of the last utterance, consumed instead of typed.
        if decision.route == .repairCommand, let repair, flags.isEnabled(.voiceRepair) {
            var repairCtx = ctx
            repairCtx.extra[RepairStage.routeKey] = Utterance.Route.repairCommand.rawValue
            _ = try? await RepairStage(session: repair).process(outSpans, context: repairCtx)
            let r = repair.lastResult
            if r.consumedUtterance {
                result.repair = r
                result.text = outSpans.joinedText
                result.totalMs = ms(since: t0)
                Log.app.info("repair: \(String(describing: r))")
                return result
            }
        }

        // Everything else types. (Transform / question routes arrive in Phase 2; until then the
        // gatekeeper's decision is logged and the text lands verbatim — never silently dropped.)
        let finalSpans = outSpans
        var text = textFinalizer?(finalSpans) ?? finalSpans.joinedText

        // R4.2 — the field-role decision, made once. `plan` runs no formatter (the pipeline's
        // `FieldRoleFormatterStage` already did that, exactly once), so this cannot format twice:
        // it only yields the rules and the continuation whitespace, which is field state, not audio.
        if let field {
            let plan = FieldRoleFormatter().plan(for: field)
            result.fieldRole = plan.role
            result.allowSubmit = plan.rules.allowSubmit
            if plan.rules.refusesDictation {
                // A password field. Nothing is formatted, nothing is typed, nothing is written to
                // history, and the words are not kept as held text — the same verdict, for the same
                // reason, that `TextInjector` reaches on its own (R2.3: `.refused(.secureField)`,
                // `holdsText == false`). Deciding it here means no method is even offered the text.
                result.text = ""
                result.injection = .refused(.secureField)
                result.totalMs = ms(since: t0)
                Log.app.notice("refused to dictate into a secure field (role \(plan.role.rawValue))")
                return result
            }
            if !text.isEmpty { text = plan.continuation.leading + text + plan.continuation.trailing }
        }
        result.text = text
        logTransform(raw: spans, landed: text, finalSpans: finalSpans)
        let caret = (try? system.focusedElement())?.selectedRange?.lowerBound ?? 0
        let outcome = injector.inject(InjectionRequest(text: text, utteranceID: id.uuidString, expectedFocus: focus))
        result.injection = outcome

        let utterance = Utterance(id: id, spans: finalSpans, startedAt: startedAt, endedAt: clock(),
                                  register: decision.register, route: decision.route)
        if outcome.succeeded {
            repair?.land(utterance, fieldOffset: caret)
            recentWords?.record(text)
            if let zeroEdit, let focus {
                zeroEdit.recordLanding(utteranceID: id.uuidString, text: text,
                                       field: FieldIdentity(appBundleID: focus.bundleID, elementID: focus.elementToken ?? "focused"))
            }
            // Bet 4 — accurate pass reconciles the landed text; off the landing path in the app.
            if let correction, correction.isEnabled(for: bundleID) {
                if reconcileInline { await correction.reconcile(utteranceID: id, landedText: text, fieldOffset: caret, bundleID: bundleID) }
                else { Task { await correction.reconcile(utteranceID: id, landedText: text, fieldOffset: caret, bundleID: bundleID) } }
            }
        }
        if let database {
            do { try database.insert(try DictationRecord(utterance: utterance, finalText: text, appBundleID: bundleID)) }
            catch { Log.db.error("history insert failed: \(error)") }
        }
        result.totalMs = ms(since: t0)
        Log.app.info("landed \(finalSpans.count) spans (\(text.count) chars) route=\(decision.route.rawValue) register=\(decision.register.rawValue) via \(String(describing: outcome)) in \(String(format: "%.0f", result.totalMs)) ms")
        return result
    }

    private func ms(since t0: Date) -> Double { clock().timeIntervalSince(t0) * 1000 }

    /// R2.4 — a name a person recognises, never a bundle ID (DESIGN §7.1). Empty when we know
    /// neither, in which case the held row falls back to "Destination changed — Copy text".
    static func destinationName(focus: FocusSnapshot?, bundleID: String?) -> String? {
        if let name = focus?.appName, !name.isEmpty { return name }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        // "com.apple.Notes" → "Notes". Better than nothing and never an identifier-looking string.
        let tail = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return tail.isEmpty ? nil : tail.capitalized
    }

    /// One line per utterance that answers "did post-processing change the words?" — the raw text
    /// out of `engine.stop()` against what is about to be typed, plus the stages that touched the
    /// spans. `distance == 0` means every difference the user sees came from recognition, not from
    /// this chain. Word-level content is logged only under `VOICEPLUS_LOG_TEXT=1`.
    private func logTransform(raw: [TranscriptSpan], landed: String, finalSpans: [TranscriptSpan]) {
        let rawText = raw.joinedText
        let distance = EditDistance.levenshtein(rawText, landed)
        var stages = [StageID]()
        for span in finalSpans { for s in span.provenance where !stages.contains(s) { stages.append(s) } }
        let names = stages.map(\.rawValue).joined(separator: ",")
        Log.pipeline.notice("landing diff: raw \(raw.count) span(s)/\(rawText.count) chars → landed \(landed.count) chars, distance \(distance), stages [\(names)]")
        if logsText { Log.pipeline.notice("landing text: raw=\u{201C}\(rawText)\u{201D} landed=\u{201C}\(landed)\u{201D}") }
    }
}

/// Bridges `RepairSession` edits to Injection's AX replace-range (Bet 4 safety rule applied there).
public final class InjectionReplaceRangeSink: ReplaceRangeSink, @unchecked Sendable {
    private let editor: ReplaceRangeEditor
    public init(system: SystemAccess) { editor = ReplaceRangeEditor(system: system) }

    public func replace(_ request: RepairReplaceRequest) -> RepairReplaceOutcome {
        switch editor.replace(ReplaceRangeRequest(range: request.range, expected: request.expected, replacement: request.replacement)) {
        case .replaced: return .replaced
        case .mismatch(let actual): return .mismatch(actual: actual)
        case .unavailable(let reason): return .unavailable(reason: reason)
        }
    }
}

/// `CorrectionSink` → history database.
public final class DatabaseCorrectionSink: CorrectionSink, @unchecked Sendable {
    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }
    public func record(_ correction: CorrectionRecord) {
        do { _ = try database.insert(correction) } catch { Log.db.error("correction insert failed: \(error)") }
    }
}

/// `ZeroEditSink` → the dictation row's `edited` flag (the honest decrement: a voice repair is
/// an edit). The AX poll in `ZeroEditTracker` sees the replaced text too and refines the count.
public final class DatabaseZeroEditSink: ZeroEditSink, @unchecked Sendable {
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database }

    public func markEdited(utteranceID: UUID, wordsEdited: Int, source: String) {
        let id = utteranceID.uuidString
        Log.app.info("zero-edit: \(id) edited \(wordsEdited) word(s) via \(source)")
        if let database {
            do {
                try database.writer.write { db in
                    try db.execute(sql: "UPDATE dictation_history SET edited = 1 WHERE id = ?", arguments: [id])
                }
            } catch { Log.db.error("zero-edit mark failed: \(error)") }
        }
    }
}

/// `FieldObserver` for the zero-edit counter over Injection's `SystemAccess` (AX, no screenshots).
public final class AXFieldObserver: FieldObserver, @unchecked Sendable {
    private let system: SystemAccess
    public init(system: SystemAccess) { self.system = system }

    public func focusedField() -> FieldIdentity? {
        guard let f = system.frontmostApp() else { return nil }
        return FieldIdentity(appBundleID: f.bundleID, elementID: f.elementToken ?? "focused")
    }

    public func value(of field: FieldIdentity) -> String? {
        guard focusedField() == field, let info = try? system.focusedElement() else { return nil }
        return info.value
    }
}
