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
    public var repair: RepairResult?
    public var pipelineMs: Double
    public var totalMs: Double

    public var landed: Bool { injection?.succeeded ?? false }
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
        return StageContext(register: .unknown, appBundleID: bundleID, flags: flagMap, extra: extra)
    }

    /// Runs the whole landing. `focus` is the snapshot taken at key release; injection aborts
    /// (and queues) if focus moved since.
    @discardableResult
    public func land(_ spans: [TranscriptSpan], startedAt: Date, focus: FocusSnapshot?) async -> LandingResult {
        let t0 = clock()
        let id = UUID()
        let bundleID = focus?.bundleID ?? system.frontmostApp()?.bundleID
        let ctx = context(bundleID: bundleID)
        var result = LandingResult(utteranceID: id, route: .none, register: .unknown, text: "", injection: nil,
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
        let text = finalSpans.joinedText
        result.text = text
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
