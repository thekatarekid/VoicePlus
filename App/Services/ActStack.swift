import Actions
import AppKit
import Foundation
import Pipeline
import Shared

/// P4.2 — the "3-line adapter" from `Actions/ActRouting`: bridge `ActPreRouting` into the
/// gatekeeper's `GatekeeperPreRouting`. While the act domain holds the utterance (second key
/// down, or a confirmation card pending), the gatekeeper returns route `.none` so the lander
/// never types the command text; the claimed route is handed to the act session instead.
public final class ActPreRouteHook: GatekeeperPreRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _parser: (any ActPreRouting)?
    private var _onRoute: ((ActRoute) -> Void)?

    public init() {}

    public var parser: (any ActPreRouting)? {
        get { lock.lock(); defer { lock.unlock() }; return _parser }
        set { lock.lock(); _parser = newValue; lock.unlock() }
    }
    public var onRoute: ((ActRoute) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onRoute }
        set { lock.lock(); _onRoute = newValue; lock.unlock() }
    }

    public func preRoute(_ text: String, context: StageContext) -> GatekeeperDecision? {
        guard let route = parser?.preRoute(text, appBundleID: context.appBundleID) else { return nil }
        lock.lock(); claimed = true; lock.unlock()
        onRoute?(route)
        return GatekeeperDecision(route: .none, register: context.register, routeConfidence: 1,
                                  registerConfidence: 0, routeSource: .rules, registerSource: .fallback)
    }

    private var claimed = false

    /// The lander asks whether the current utterance was claimed; consuming resets the flag so a
    /// plain route-.none decision (fillers-only) is never mistaken for an act claim.
    public func consumeClaim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = claimed
        claimed = false
        return was
    }
}

/// Bet 5 is "two keys, never inferred from phrasing" — which only holds while the two keys are
/// actually two different keys. Nothing stopped the act key (default Right ⌘) and the dictation
/// key from being bound to the same physical modifier: one press then drove *both* `HotkeyService`
/// instances, so a plain dictation hold also opened the act domain, `ActSessionController`
/// raced `engine.stop()` for the transcript, and the words were parsed as an act goal — falling
/// through the deterministic catalogue into `.agentic`, the planner, and an error in the pill
/// where the user's sentence should have been.
///
/// Dictation wins the collision: it is the product. The act key stays inert until it is rebound.
public enum ActKeyBinding {
    public static func isDistinct(act: HotkeyBinding, dictation: HotkeyBinding) -> Bool {
        act.kind != dictation.kind
    }
}

/// P4.5 — Providers-backed `PlannerLLM` over the same `RoutingTable` the pipeline uses (every
/// call goes through the Data Panel logging in `RoutingTableProviderRouting`). Screenshot-free
/// by construction: the prompt is `PlannerPrompt` over the AX summary.
public final class ProviderPlanner: PlannerLLM, @unchecked Sendable {
    public static let stage: StageID = "act.planner"
    private let providers: any PipelineProviderRouting

    public init(providers: any PipelineProviderRouting) { self.providers = providers }

    public func plan(goal: String, observation: AXSummary, history: [StepRecord],
                     tools: [AgentTool]) async throws -> PlannerTurn {
        let context = StageContext()
        // Ask before calling. `complete` throws `ProviderRoutingError.disabled` when nothing is
        // pinned for `act.planner`, and that used to surface as
        // `failed(reason: "planner: disabled(stage: act.planner)")` — a debug description in the
        // pill. "No provider chosen" is a setting, so it becomes `PlannerError.unavailable`, which
        // the backend reports as a state rather than a failure.
        guard providers.isProviderEnabled(for: Self.stage, context: context) else {
            throw PlannerError.unavailable(reason: "no provider chosen for \(Self.stage.rawValue)")
        }
        let reply: String
        do {
            reply = try await providers.complete(stage: Self.stage,
                                                 prompt: PlannerPrompt.system(tools: tools),
                                                 input: PlannerPrompt.user(goal: goal, observation: observation, history: history),
                                                 context: context)
        } catch let error as ProviderRoutingError {
            throw PlannerError.unavailable(reason: Self.describe(error))
        }
        return Self.parse(reply, goal: goal)
    }

    /// Log-only breadcrumb. Never shown to a user — see `AgentRunStatus.userMessage`.
    static func describe(_ error: ProviderRoutingError) -> String {
        switch error {
        case .unavailable: return "provider unreachable for \(stage.rawValue)"
        case .disabled(let s): return "no provider chosen for \(s.rawValue)"
        }
    }

    /// The contract from `PlannerPrompt.system`: an ordered list of `tool(param=value, …)` lines,
    /// `DONE <summary>`, or `GIVEUP <reason>`. Tolerant of numbering/dashes; anything that
    /// doesn't parse to at least one step is a give-up, never a guessed action.
    public static func parse(_ reply: String, goal: String) -> PlannerTurn {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("DONE") {
            return .done(summary: String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if upper.hasPrefix("GIVEUP") || upper.hasPrefix("GIVE UP") {
            let n = upper.hasPrefix("GIVEUP") ? 6 : 7
            return .giveUp(reason: String(trimmed.dropFirst(n)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var steps: [PlanStep] = []
        for rawLine in trimmed.split(separator: "\n") {
            guard let step = parseStep(String(rawLine)) else { continue }
            steps.append(step)
        }
        guard !steps.isEmpty else { return .giveUp(reason: "planner reply had no parseable steps") }
        return .plan(StepPlan(goal: goal, steps: steps, rationale: ""))
    }

    static func parseStep(_ line: String) -> PlanStep? {
        // "<n>. click(name=Submit)" / "- scroll(direction=down, amount=5)"
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
        let head = line[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \t-*0123456789."))
        guard let kind = ActionKind(rawValue: head) else { return nil }
        var params: [String: String] = [:]
        let body = line[line.index(after: open)..<close]
        for pair in body.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !key.isEmpty { params[key] = value }
        }
        let title = "\(kind.rawValue) \(params.values.first ?? "")".trimmingCharacters(in: .whitespaces)
        return PlanStep(title: title, request: ActionRequest(kind: kind, params: params))
    }
}

/// P4.2 — second-key session: activates the act domain for the hold, captures speech through
/// the shared engine, and hands the final text to `ActRouter` (deterministic catalogue first,
/// agent for the tail). The domain stays active while a confirmation card is pending or the
/// agent is running, so spoken "confirm"/"stop" through either key reaches the router.
public final class ActSessionController: @unchecked Sendable {
    public let engine: any EngineProtocol
    public let router: ActRouter
    public let state: ActDomainState
    /// Frontmost app for catalogue scoping.
    public var appBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// Deixis context lines appended to agentic goals (P3 → P4 targets).
    public var contextLines: (() -> [String])?
    public var onDispatch: ((ActDispatch) -> Void)?
    public var onError: ((Error) -> Void)?

    public init(engine: any EngineProtocol, router: ActRouter, state: ActDomainState) {
        self.engine = engine
        self.router = router
        self.state = state
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .startCapture:
            state.activate()
            Task {
                do { try await engine.start(prewarm: true) } catch { Log.app.error("act: engine start failed: \(error)") }
            }
        case .finalize:
            Task { await self.finalizeCapture() }
        case .cancelCapture, .enterHandsFree:
            Task {
                await self.engine.cancel()
                self.deactivateIfIdle()
            }
        }
    }

    func finalizeCapture() async {
        do {
            let spans = try await engine.stop()
            let text = spans.joinedText
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                deactivateIfIdle()
                return
            }
            await dispatch(text)
        } catch {
            if case EngineError.notListening = error {} else { onError?(error) }
            deactivateIfIdle()
        }
    }

    /// Route one utterance through the act path. Also the entry point for text claimed by the
    /// gatekeeper adapter (spoken "confirm"/"stop" over the dictation key).
    public func dispatch(_ text: String) async {
        await route(router.parser.parse(text, appBundleID: appBundleID()))
    }

    public func route(_ parsed: ActRoute) async {
        var parsed = parsed
        if case .agentic(let goal) = parsed, let lines = contextLines?(), !lines.isEmpty {
            parsed = .agentic(goal: "\(goal) [\(lines.joined(separator: "; "))]")
        }
        do {
            let dispatch = try await router.dispatch(parsed)
            onDispatch?(dispatch)
        } catch {
            onError?(error)
            Log.app.error("act dispatch failed: \(error)")
        }
        deactivateIfIdle()
    }

    /// The act domain closes only when nothing is pending — a live card or a running agent
    /// keeps it open so the next utterance ("confirm", "stop") still routes here.
    public func deactivateIfIdle() {
        if !router.hasPendingConfirmation && !router.agent.isRunning { state.deactivate() }
    }
}
