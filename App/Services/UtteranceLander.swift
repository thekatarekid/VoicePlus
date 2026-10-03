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
    /// D1 — the caret state the text was formatted for; `nil` when no field reader is wired.
    /// `.unknown` is what the pill's "placed as spoken" hint keys on.
    public var caret: CaretState.Kind?
    /// S3 — set by `land(…, inject: false)`: `text` is the formatted, immutable final payload and
    /// nothing has been offered to the injector yet. `inject(payload:)` finishes the landing.
    public var pending: PendingInsertion?
    /// S3 — the method that wrote posted and then threw, unconfirmed: part of the text may be in
    /// the field (`DeliveryOutcome.partial`, D07).
    public var partialWrite = false
    /// S3 — the commit guard refused this insert as a second one for the same turn and revision.
    /// Nothing was posted by this call.
    public var duplicateCommit = false
    /// V5 N2 — the utterance was stored in Notes instead of typed (`UtteranceLander.notesClaim`),
    /// with the route that sent it there. Nothing was offered to the injector.
    public var noted: NoteSource?
    /// N3 — the delivery ladder's answer for a field the reader could not read (`nil` when the
    /// field was readable or no reader is wired). `.deliver` = typed anyway; `.notes(.noWindow)` =
    /// there never was a destination.
    public var ladder: DeliveryLadder.Decision?
    /// N7 — ms spent gathering context before the pipeline ran (augmenter chain + field read). With
    /// the turn snapshot this is bounded by its budget, whatever the source does.
    public var contextMs: Double = 0

    public var landed: Bool { injection?.succeeded ?? false }

    /// S3 — the final payload is ready and waiting for its one insert.
    public var isAwaitingInsertion: Bool { pending != nil && injection == nil }

    /// R2.4 — what actually happened to this text, in the vocabulary the pill and the menu speak
    /// (`DeliveryOutcome`, R2.1). `nil` only when nothing was ever offered to the injector: a
    /// repair command, an act-domain claim, a transform, or empty spans.
    /// N2 — the reason a held payload carries when it is not the injector's own ("kept, not typed").
    public var heldReason: String? = nil

    public var delivery: DeliveryOutcome? {
        guard let injection else { return nil }
        if let heldReason, case .abortedFocusChanged = injection { return .held(reason: heldReason) }
        if partialWrite, case let .injected(method, verified) = injection, !verified {
            return .partial(method: method.rawValue)
        }
        return DeliveryOutcome(injection: injection)
    }

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

/// S3 — what `inject(payload:)` needs to finish a landing that `land(…, inject: false)` formatted:
/// everything the post-insert bookkeeping (landing memory, repair, history, correction) reads.
public struct PendingInsertion: Sendable {
    /// The formatted final spans the payload text was rendered from.
    public var spans: [TranscriptSpan]
    /// What the engine returned, before formatting (`TurnRecord.rawText`).
    public var rawSpans: [TranscriptSpan]
    /// Where the text is going: the snapshot the landing was aimed at.
    public var focus: FocusSnapshot?
    public var bundleID: String?
    public var startedAt: Date
    /// AX role of the field the text was formatted for.
    public var axRole: String?
    /// When `land` began, for `totalMs`.
    public var landStarted: Date
    /// The uncertainty marks of the payload text, as UTF-16 ranges of `LandingResult.text`
    /// (`TurnRecord.uncertainSpans`): S5's `UncertaintyMarkMapper` through formatting, so their count
    /// is the marks the pill draws ("1 word to review") and drives the 1800 ms dwell.
    public var uncertainRanges: [Range<Int>]
    /// A rewrite forced a phrase or the whole result to be marked: the rows read "Review this phrase"
    /// (T05) instead of a word count.
    public var needsPhraseReview: Bool = false
    /// Owner decision (pull back) — the key-down window's token (`FocusedWindowReading`), set by the
    /// turn gate; the delivery ladder holds if another window has focus at write time.
    public var windowToken: String? = nil

    public var rawText: String { rawSpans.joinedText }
    public var uncertainCount: Int { uncertainRanges.count }
}

/// S3 — the turn gate. When a lander has one, every `land(…)` that would insert (a latch segment, a
/// guided landing) hands its final payload here instead of injecting: the gate previews it, dwells,
/// revalidates the destination and inserts it once through `inject(payload:commit:)`.
/// `TurnController` is the gate. Hold turns reach it directly through `land(…, inject: false)`.
public protocol LandingGate: AnyObject {
    func admit(_ payload: LandingResult, from lander: UtteranceLander) async -> LandingResult
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
    /// W3H — Privacy's "Save dictation history" (`DictationHistoryGate`), read per landing: off keeps
    /// landed and held text out of `dictation_history`. Held text itself is untouched (focus guard).
    public var recordsHistory: () -> Bool = { true }
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
    /// V5 N2 — the routes into Notes decided at landing time (no focused field, latch during a
    /// meeting, an agent action running): given the formatted text and whether a field is focused,
    /// stores it and returns the source, or nil to land as usual. Asked once per landing, after act /
    /// transform / repair claims and after the secure-field refusal (a password is never a note).
    /// Not copied to the holding sibling: text held for a named destination stays held.
    public var notesClaim: ((_ text: String, _ hasFocusedField: Bool) -> NoteSource?)?
    /// N3 — whether the destination app has a focused window (`nil` = cannot tell). Defaults to the
    /// system's `FocusedWindowReading`. Only consulted when the field reader found nothing readable:
    /// the ladder then delivers anyway while there is a window, and only "no window" is Notes.
    public var windowPresence: ((FocusSnapshot?) -> Bool?)?
    /// P6.3 — script-aware text assembly (code-switch merger); nil result keeps the rendered text.
    public var textFinalizer: (([TranscriptSpan]) -> String?)?
    /// V4 gate "cold launch → first landing": told of every write that posted text; logs only the
    /// first one after launch (`timing: cold launch → first landing N ms`).
    public var launchTiming: LaunchLandingTiming? = .shared
    /// D3/D6 — Settings → spacing and unknown-caret style, read once per landing. Defaults to the
    /// app's settings domain (`UserDefaultsSettingsStore`, the store `AppContainer` uses).
    public var formattingPreferences: () -> FormattingPreferences = {
        FormattingSettings.preferences(UserDefaultsSettingsStore())
    }
    /// D5 — our last landing, so the next one can join onto it where AX shows no caret. The
    /// same instance `FieldContextReader` consults: both attach to this `system`.
    public var landingMemory: LandingMemory
    /// Tests await the reconcile; the app runs it off the landing path.
    public var reconcileInline = false
    /// Diagnostic: when true, the raw recognised text and the landed text are written to the log
    /// verbatim, so one real utterance separates "bad recognition" from "good recognition, mangled
    /// afterwards". Off by default (the summary below is always logged and names no words); opt in
    /// with `VOICEPLUS_LOG_TEXT=1`. Local `os_log` only — nothing leaves the machine.
    public var logsText = ProcessInfo.processInfo.environment["VOICEPLUS_LOG_TEXT"] == "1"
    /// S3 — the turn gate (`TurnController`). Weak: the controller owns the lander.
    public weak var gate: LandingGate?
    /// S3 — the commit guard for an injector that has none of its own (anything but
    /// `TextInjector`, e.g. a test spy): one insert per `TurnCommitKey` whatever the injector.
    public let commitGuard = TurnCommitGuard()

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
        self.landingMemory = LandingMemory.attached(to: system)
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
    ///
    /// S3 — `inject: false` stops at the final payload: formatted, immutable, nothing offered to the
    /// injector (`result.isAwaitingInsertion`); `inject(payload:commit:)` finishes it. With
    /// `inject: true` and a `gate`, the payload goes through the gate (preview, dwell, revalidation,
    /// one insert) rather than straight to the injector.
    @discardableResult
    public func land(_ spans: [TranscriptSpan], startedAt: Date, focus: FocusSnapshot?,
                     inject: Bool = true) async -> LandingResult {
        let t0 = clock()
        let id = UUID()
        let bundleID = focus?.bundleID ?? system.frontmostApp()?.bundleID
        var ctx = context(bundleID: bundleID)
        // N7 — the augmenters read the turn's bounded snapshot (`AXWindowText.snapshot`), never a
        // live walk; the time is measured so the turn record shows it.
        let contextStarted = clock()
        if let contextAugmenter { ctx = contextAugmenter(spans, ctx) }
        // R4.2 — the field context goes in last so nothing else can overwrite its keys.
        // D1 — a wired reader that finds no readable element means the caret is `unknown`, and
        // the run says so (no leading space, no invented capital or period, StyleStage off).
        let readField = fieldContextProvider?(bundleID)
        var field = readField ?? (fieldContextProvider == nil ? nil : FieldContext(appBundleID: bundleID, caret: .unknown))
        if field != nil { field?.preferences = formattingPreferences() }
        if let field { FieldRolePipeline.write(field, into: &ctx) }
        // V5 E5/E6 — the persona for a browser sub-app (`bundle|host`) and a thread participant.
        if let field { FieldPersonaRedecoration.apply(field, to: &ctx, manager: personaManager) }
        var result = LandingResult(utteranceID: id, route: .none, register: .unknown, text: "", injection: nil,
                                   focusDestination: Self.destinationName(focus: focus, bundleID: bundleID),
                                   repair: nil, pipelineMs: 0, totalMs: 0)
        result.caret = field?.caret.kind
        result.contextMs = ms(since: contextStarted)
        guard !spans.isEmpty, !spans.renderedText.trimmingCharacters(in: .whitespaces).isEmpty else { return result }

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
            result.text = outSpans.renderedText
            result.totalMs = ms(since: t0)
            Log.app.info("act domain claimed utterance (\(result.text.count) chars)")
            return result
        }

        // P2.3 — a selection turns the utterance into a transform / question (Bet 5). The raw
        // spans are the instruction: formatters must not rewrite what the user asked for.
        // H6 (Q4) — with a meaningful selection the edit parser owns the utterance *before* repair
        // routing: "uppercase", "scratch that", "capitalize this" over a selection are edits, not
        // repairs of the last dictation. Without a selection `handle` declines and nothing changes.
        var replacingSelection = false
        if let transform {
            let outcome = await transform.handle(spans, decision: decision, context: ctx)
            if case .replaceSelection(let rest) = outcome {
                // "replace with …": the rest is dictation, formatted below and typed over the
                // selection by the normal injector (secure-field refusal and Q1 newline rules apply).
                result.transform = outcome
                replacingSelection = true
                do {
                    outSpans = try await pipeline.runDictationStages(rest, decision: decision, context: ctx)
                } catch {
                    Log.pipeline.error("dictation stages failed for a selection replace, landing raw text: \(error)")
                    outSpans = rest
                }
                decision.route = .dictate
                result.route = .dictate
            } else if outcome != .notHandled {
                result.transform = outcome
                result.route = transform.route(decision).route
                result.text = spans.renderedText
                landingMemory.invalidate(.otherEdit)
                result.totalMs = ms(since: t0)
                Log.app.info("transform: \(String(describing: outcome))")
                return result
            }
        }

        // P1.5.2 — "put it back" undoes a silent correction before the repair session's own undo.
        if !replacingSelection, decision.route == .repairCommand, let correction, let sink = repair?.replaceSink,
           case .revertedCorrection(let entry) = CorrectionUndoRouter.handle(text: spans.renderedText, ledger: correction.ledger, sink: sink, at: clock()) {
            result.revertedCorrection = entry
            result.text = spans.renderedText
            landingMemory.invalidate(.otherEdit)
            result.totalMs = ms(since: t0)
            return result
        }

        // Bet 3 — spoken repair of the last utterance, consumed instead of typed.
        if !replacingSelection, decision.route == .repairCommand, let repair, flags.isEnabled(.voiceRepair) {
            var repairCtx = ctx
            repairCtx.extra[RepairStage.routeKey] = Utterance.Route.repairCommand.rawValue
            _ = try? await RepairStage(session: repair).process(outSpans, context: repairCtx)
            let r = repair.lastResult
            if r.consumedUtterance {
                result.repair = r
                result.text = outSpans.renderedText
                landingMemory.invalidate(.otherEdit)
                result.totalMs = ms(since: t0)
                Log.app.info("repair: \(String(describing: r))")
                return result
            }
        }

        // Everything else types — as dictation. A question / transform route with no selection to act
        // on (Bet 5: the transform declined above), or a repair command nothing consumed, got only the
        // gatekeeper from the runner; it is formatted now like any dictation (numbers, fillers, field
        // role, style) instead of landing as the recognizer wrote it — "two three four zero rupees" was
        // typed verbatim whenever the route model read a statement as a question (V4 digits gate).
        if decision.route != .dictate, decision.route != .none {
            do {
                outSpans = try await pipeline.runDictationStages(outSpans, decision: decision, context: ctx)
                Log.app.info("lander: \(decision.route.rawValue) route with nothing to act on — formatted as dictation")
            } catch {
                Log.pipeline.error("dictation stages failed for a \(decision.route.rawValue) route, landing raw text: \(error)")
            }
            result.route = .dictate
        }
        let finalSpans = outSpans
        // V4.13 — `renderedText`: a blanked span (a removed filler, a number the ITN collapsed)
        // leaves no leading or doubled space.
        var text = textFinalizer?(finalSpans) ?? finalSpans.renderedText

        // R4.2 — the field-role decision, made once. `plan` runs no formatter (the pipeline's
        // `FieldRoleFormatterStage` already did that, exactly once), so this cannot format twice:
        // it only yields the rules and the continuation whitespace, which is field state, not audio.
        if let field {
            let plan = FieldRoleFormatter().plan(for: field)
            if readField != nil { result.fieldRole = plan.role }
            // Q1 — never Return-to-send in an app where ↩ sends (Electron / Cursor / browsers).
            result.allowSubmit = bundleID.map { SubmitPolicy.allowSubmit(requested: plan.rules.allowSubmit, bundleID: $0) }
                ?? plan.rules.allowSubmit
            if plan.rules.refusesDictation {
                // A password field. Nothing is formatted, nothing is typed, nothing is written to
                // history, and the words are not kept as held text — the same verdict, for the same
                // reason, that `TextInjector` reaches on its own (R2.3: `.refused(.secureField)`,
                // `holdsText == false`). Deciding it here means no method is even offered the text.
                result.text = ""
                result.injection = .refused(.secureField)
                result.totalMs = ms(since: t0)
                Log.app.notice("refused to dictate into a secure field (role \(plan.role.rawValue))")
                UtteranceRecorder.noteSecureRefusal()   // V5 F3 — the turn's audio is not kept either
                return result
            }
            if !text.isEmpty { text = plan.continuation.leading + text + plan.continuation.trailing }
        }
        // V5 N2 — no field to land in, a latch inside a meeting, an agent at work: Notes keeps it.
        // A wired reader that found no focused element is "no field"; no reader means "unknown",
        // which is never routed (tests, headless runs).
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // N3 — an unreadable field is not "no field": the delivery ladder decides. Same app with a
        // window → deliver anyway (verified later when readable, else neutral); Notes only when
        // there is no window at all. Focus moves and password fields are held/refused elsewhere.
        var hasDestination = fieldContextProvider == nil || readField != nil
        if !hasDestination, !words.isEmpty {
            let ladder = unreadableFieldLadder(focus: focus, multiline: words.contains(where: \.isNewline))
            result.ladder = ladder
            hasDestination = !Self.isNotes(ladder)
            Log.app.info("N3 lander: unreadable field, ladder \(String(describing: ladder))")
        }
        if let notesClaim, !words.isEmpty,
           let source = notesClaim(words, hasDestination) {
            result.route = Utterance.Route.none
            result.text = words
            result.noted = source
            result.totalMs = ms(since: t0)
            Log.app.info("lander: stored in Notes (\(source.rawValue), \(words.count) chars)")
            return result
        }
        result.text = text
        logTransform(raw: spans, landed: text, finalSpans: finalSpans)
        // S5 — the marks the pill will draw, mapped through formatting: their ranges are the record's
        // `uncertainSpans` and their count the "N words to review" (T05 "Review this phrase").
        let marks = UncertaintyMarkMapper.map(source: finalSpans, finalText: text)
        result.pending = PendingInsertion(spans: finalSpans, rawSpans: spans, focus: focus, bundleID: bundleID,
                                          startedAt: startedAt, axRole: field?.axRole, landStarted: t0,
                                          uncertainRanges: marks.uncertainRanges,
                                          needsPhraseReview: marks.needsPhraseReview)
        // S3 — the final payload exists; whoever asked for it decides when (and whether) it goes in.
        guard inject else {
            result.totalMs = ms(since: t0)
            return result
        }
        if let gate { return await gate.admit(result, from: self) }
        return await self.inject(payload: result)
    }

    /// S3 — the one insert of a payload from `land(…, inject: false)`, and everything that follows
    /// a landing (landing memory, repair, recent words, zero-edit, correction, history).
    ///
    /// With a `commit` key the insert goes through the idempotent commit guard (`TextInjector`'s own,
    /// or `commitGuard` for any other injector): a second call for the same turn and revision posts
    /// nothing and returns `duplicateCommit`. A payload that is not awaiting insertion comes back
    /// unchanged.
    public func inject(payload: LandingResult, commit key: TurnCommitKey? = nil) async -> LandingResult {
        guard payload.isAwaitingInsertion, let pending = payload.pending else { return payload }
        var result = payload
        let text = result.text
        let id = result.utteranceID
        let focus = pending.focus
        let bundleID = pending.bundleID
        let request = InjectionRequest(text: text, utteranceID: id.uuidString, expectedFocus: focus,
                                       expectedWindowToken: pending.windowToken)
        // FX1 — a write into VoicePlus's own window (the onboarding practice field) runs on the main
        // actor: AppKit may only be touched there, and an AX write aimed at ourselves from this
        // background task deadlocked TextKit 2 (the 1.11 onboarding freeze). Awaited, so no thread
        // blocks waiting for the main one. Every other destination is written from here, as before.
        let step: WriteStep
        if OwnProcess.owns(focus ?? system.frontmostApp()) {
            step = await MainActor.run { self.writeStep(request, key: key) }
        } else {
            step = writeStep(request, key: key)
        }
        let caret = step.caret
        let outcome: InjectionOutcome
        switch step.committed {
        case .some(.committed(let report)):
            outcome = report.outcome
            result.partialWrite = report.postedThenThrew
        case .some(.duplicate(_, let previous)):
            // Nothing was posted by this call, so nothing else here may run a second time.
            result.duplicateCommit = true
            result.injection = previous?.outcome
            result.partialWrite = previous?.postedThenThrew ?? false
            Log.app.notice("lander: duplicate commit for turn \(key?.description ?? "-") refused")
            return result
        case .none:
            outcome = step.outcome ?? .failed(attempts: [])
        }
        result.injection = outcome

        let utterance = Utterance(id: id, spans: pending.spans, startedAt: pending.startedAt, endedAt: clock(),
                                  register: result.register, route: result.route)
        if outcome.succeeded {
            launchTiming?.noteLanding()
            // D5 — the caret now sits right after this text, until the user touches anything.
            if let element = LandedElement(focus: focus ?? system.frontmostApp(), role: pending.axRole) {
                landingMemory.record(text: text, in: element)
            }
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
        recordHistory(utterance, text: text, bundleID: bundleID)
        result.totalMs = ms(since: pending.landStarted)
        Log.app.info("landed \(pending.spans.count) spans (\(text.count) chars) route=\(result.route.rawValue) register=\(result.register.rawValue) via \(String(describing: outcome)) in \(String(format: "%.0f", result.totalMs)) ms")
        return result
    }

    /// The write itself: the caret read the repair session keys on, then the one insert (through the
    /// commit guard when there is a key). FX1 — runs on the main actor for our own window.
    struct WriteStep: Sendable {
        var caret: Int
        var committed: TurnCommitResult?
        var outcome: InjectionOutcome?
    }

    private func writeStep(_ request: InjectionRequest, key: TurnCommitKey?) -> WriteStep {
        let caret = (try? system.focusedElement())?.selectedRange?.lowerBound ?? 0
        guard let key else { return WriteStep(caret: caret, committed: nil, outcome: injector.inject(request)) }
        let committed = (injector as? TurnCommitting)?.commit(request, key: key)
            ?? commitGuard.commit(key) { TurnCommitReport(injector.inject(request)) }
        return WriteStep(caret: caret, committed: committed, outcome: nil)
    }

    /// S3 — the payload could not go in safely (the destination changed during the preview): it is
    /// held in `focusGuard` for Insert here / Copy / Discard, recorded in history like any landing,
    /// and the result reads as a focus-changed abort, exactly as the injector's own abort does.
    public func hold(payload: LandingResult, reason: String, in focusGuard: FocusGuard,
                     actual: FocusSnapshot?, turnID: TurnID?) -> LandingResult {
        guard payload.isAwaitingInsertion, let pending = payload.pending else { return payload }
        var result = payload
        let request = InjectionRequest(text: result.text, utteranceID: result.utteranceID.uuidString,
                                       expectedFocus: pending.focus)
        focusGuard.hold(request, reason: reason, destination: pending.focus, turnID: turnID)
        result.injection = .abortedFocusChanged(expected: pending.focus, actual: actual)
        if reason == DeliveryReason.keptByUser || PullBackReason.all.contains(reason) { result.heldReason = reason }
        let utterance = Utterance(id: result.utteranceID, spans: pending.spans, startedAt: pending.startedAt,
                                  endedAt: clock(), register: result.register, route: result.route)
        recordHistory(utterance, text: result.text, bundleID: pending.bundleID)
        result.totalMs = ms(since: pending.landStarted)
        Log.app.notice("held \(result.text.count) chars: \(reason)")
        return result
    }

    private func recordHistory(_ utterance: Utterance, text: String, bundleID: String?) {
        // V5 F3 — the turn's recording (saved at capture stop, when recordings are on) gets its
        // transcript, final text and app. A no-op when nothing was recorded.
        UtteranceRecorder.noteLanded(transcript: utterance.text, finalText: text, appBundleID: bundleID)
        guard let database, recordsHistory() else { return }
        do { try database.insert(try DictationRecord(utterance: utterance, finalText: text, appBundleID: bundleID)) }
        catch { Log.db.error("history insert failed: \(error)") }
    }

    /// The low-confidence words of `text` as UTF-16 ranges: S5's marks, mapped through formatting
    /// with `WordAligner` (`UncertaintyMarkMapper`) — a reworded span gets its phrase's range, a
    /// removed filler none. One mapping for the pill, the count and `TurnRecord.uncertainSpans`.
    public static func uncertainRanges(of spans: [TranscriptSpan], in text: String) -> [Range<Int>] {
        UncertaintyMarkMapper.map(source: spans, finalText: text).uncertainRanges
    }

    /// N3 — the ladder for a field the reader could not read: focus is the key-up app (the turn
    /// gate pulls back / holds on a move), secure input and password fields are checked again
    /// right before the write. What is left is the window: present → deliver, none → Notes.
    func unreadableFieldLadder(focus: FocusSnapshot?, multiline: Bool) -> DeliveryLadder.Decision {
        let present = windowPresence.map { $0(focus) } ?? defaultWindowPresence(focus)
        let window: DeliveryLadder.WindowState
        switch present {
        case true?: window = .same
        case false?: window = .none
        case nil: window = .unknown
        }
        return DeliveryLadder.decide(focusSame: true, window: window, secureInput: false, fieldReadable: false,
                                     surface: nil, multiline: multiline)
    }

    private func defaultWindowPresence(_ focus: FocusSnapshot?) -> Bool? {
        guard let reader = system as? FocusedWindowReading,
              let target = focus ?? system.frontmostApp() else { return nil }
        return reader.focusedWindowToken(pid: target.pid) != nil
    }

    static func isNotes(_ decision: DeliveryLadder.Decision) -> Bool {
        if case .notes = decision { return true }
        return false
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
