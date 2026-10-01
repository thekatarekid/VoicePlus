import Actions
import AppKit
import Foundation
import Pipeline
import Providers
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

    /// The single predicate that decides whether an act-key edge may open the act domain.
    ///
    /// Two independent reasons to stay shut, and both are re-read per event rather than at launch:
    /// the feature is switched off (`ActKeySettings`, off on a fresh install), or the user has
    /// bound both keys to the same physical key, in which case dictation wins and the act key is
    /// inert until it is rebound.
    public static func isLive(enabled: Bool, act: HotkeyBinding, dictation: HotkeyBinding) -> Bool {
        enabled && isDistinct(act: act, dictation: dictation)
    }
}

/// P4.5 — Providers-backed `PlannerLLM` over the same `RoutingTable` the pipeline uses (every
/// call goes through the Data Panel logging in `RoutingTableProviderRouting`). Screenshot-free
/// by construction: the prompt is `PlannerPrompt` over the AX summary.
///
/// V5 CU8: a provider pinned for `act.planner` (Ollama, LM Studio, CLI, ChatGPT, a key) is tried
/// first; otherwise the shipped local model (`SharedLocalLLM`, Qwen3.5-2B/4B on llama.cpp) plans.
/// Neither present → `PlannerError.unavailable`, a state the pill reports, never a failure.
public final class ProviderPlanner: PlannerLLM, @unchecked Sendable {
    public static let stage: StageID = "act.planner"
    private let providers: any PipelineProviderRouting
    private let local: (any LocalPlannerRouting)?

    /// `local` nil → the launch-installed `SharedLocalLLM.shared` route, read per call.
    public init(providers: any PipelineProviderRouting, local: (any LocalPlannerRouting)? = nil) {
        self.providers = providers
        self.local = local
    }

    public func plan(goal: String, observation: AXSummary, history: [StepRecord],
                     tools: [AgentTool]) async throws -> PlannerTurn {
        var context = StageContext()
        let system = PlannerPrompt.system(tools: tools)
        let user = PlannerPrompt.user(goal: goal, observation: observation, history: history)
        // The stage renders its own prompt; every TextGenerator sends it unchanged (D2 contract).
        context.extra[PromptBuilder.systemOverrideKey] = system
        context.extra[PromptBuilder.userOverrideKey] = user
        let reply: String
        if providers.isProviderEnabled(for: Self.stage, context: context) {
            do {
                reply = try await providers.complete(stage: Self.stage, prompt: system, input: user, context: context)
            } catch let error as ProviderRoutingError {
                throw PlannerError.unavailable(reason: Self.describe(error))
            }
        } else if let local = local ?? SharedLocalLLM.shared.plannerRoute {
            // Ask before calling. "Model not downloaded" is a setting, not a failure.
            guard await local.isAvailable() else {
                throw PlannerError.unavailable(reason: "local planner model not installed for \(Self.stage.rawValue)")
            }
            do {
                reply = try await local.complete(stage: Self.stage, system: system, user: user)
            } catch {
                throw PlannerError.unavailable(reason: "local planner did not answer for \(Self.stage.rawValue)")
            }
        } else {
            // `complete` throws `ProviderRoutingError.disabled` when nothing is pinned, and that used
            // to surface as a debug description in the pill. No provider and no local model is a
            // setting, so it becomes `PlannerError.unavailable`.
            throw PlannerError.unavailable(reason: "no provider chosen for \(Self.stage.rawValue)")
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

    /// V5 CU8: the strict-JSON `StepPlan` from `PlannerPrompt.system`, parsed with repair
    /// (`PlannerJSON`). A reply with no JSON at all falls back to the legacy contract: an ordered
    /// list of `tool(param=value, …)` lines, `DONE <summary>`, or `GIVEUP <reason>`. Anything that
    /// doesn't parse to at least one step is a give-up, never a guessed action.
    public static func parse(_ reply: String, goal: String) -> PlannerTurn {
        let cleaned = LlamaCppProvider.stripReasoning(reply)
        if let turn = PlannerJSON.parse(cleaned, goal: goal) { return turn }
        return parseLines(cleaned, goal: goal)
    }

    static func parseLines(_ reply: String, goal: String) -> PlannerTurn {
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
    /// V5 CU1 — where Settings › Computer use is read from at the start of each act turn (timeout,
    /// consent defaults, plan chips). The app's store is `UserDefaults.standard`-backed, so the
    /// default reads the same values the page writes; tests inject an in-memory store.
    public var settings: SettingsStore? = UserDefaultsSettingsStore()

    /// `installLayer2` (V5 CU4): give the router catalogue retrieval + the CUA-S1 chooser source
    /// unless it already has them (`ComputerUseLayer2.install`).
    public init(engine: any EngineProtocol, router: ActRouter, state: ActDomainState, installLayer2: Bool = true) {
        self.engine = engine
        self.router = router
        self.state = state
        if installLayer2 { ComputerUseLayer2.install(on: router) }
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        switch action {
        case .startCapture:
            applySettings()
            state.activate()
            Task {
                do { try await engine.start(prewarm: true) } catch { Log.app.error("act: engine start failed: \(error)") }
            }
            // CU9: a kept-warm CUA-S1 (≥ 24 GB) loads while the user speaks; 16 GB loads on demand.
            Task.detached(priority: .utility) { [router] in await router.beginActTurn() }
        case .finalize:
            Task { await self.finalizeCapture() }
        // R3.1: `.enterLatch`. The act key never latches — a second tap on
        // it tears the capture down, exactly as a cancel does.
        case .cancelCapture, .enterLatch:
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

    /// Push Settings › Computer use into the router's consent engine and agent (V5 CU1).
    public func applySettings() {
        ComputerUseSettings.apply(settings, consent: router.consent, agent: router.agent)
    }

    /// V5 CU7 — an ambient utterance the intent arbiter gave to `act` (Listen & act only; the
    /// guarantees already checked mode, voice and band). It takes the same path as the act key:
    /// parse → CU4 refine → deixis → `ActRouter.dispatch` → consent, with the consent rules
    /// unchanged. The one difference is the confirmation rule (L2 guarantee 4): an ambient
    /// utterance never confirms a pending card — a confirm needs a turn the user started or a
    /// click. The domain is opened for the dispatch exactly as a key press would, so a card it
    /// raises keeps it open and the user's explicit "confirm" (either key) or a click reaches it.
    @discardableResult
    public func dispatchAmbient(_ text: String) async -> ActDispatch {
        let parsed = router.parser.parse(text, appBundleID: appBundleID())
        switch parsed {
        case .empty:
            return .ignored(reason: "empty")
        case .confirm:
            return .ignored(reason: Self.ambientCannotConfirm)
        default:
            break
        }
        state.activate()
        return await route(parsed) ?? .ignored(reason: "act dispatch failed")
    }

    /// The reason an ambient "confirm" is dropped (never forwarded to the consent engine).
    public static let ambientCannotConfirm = "ambient cannot confirm"

    @discardableResult
    public func route(_ parsed: ActRoute) async -> ActDispatch? {
        applySettings()
        // CU4: catalogue retrieval runs on the words as spoken, before deixis context is appended.
        var parsed = await router.refine(parsed, appBundleID: appBundleID())
        if case .agentic(let goal) = parsed, let lines = contextLines?(), !lines.isEmpty {
            parsed = .agentic(goal: "\(goal) [\(lines.joined(separator: "; "))]")
        }
        var result: ActDispatch?
        do {
            let dispatch = try await router.dispatch(parsed)
            onDispatch?(dispatch)
            result = dispatch
        } catch {
            onError?(error)
            Log.app.error("act dispatch failed: \(error)")
        }
        deactivateIfIdle()
        return result
    }

    /// The act domain closes only when nothing is pending — a live card or a running agent
    /// keeps it open so the next utterance ("confirm", "stop") still routes here.
    public func deactivateIfIdle() {
        if !router.hasPendingConfirmation && !router.agent.isRunning { state.deactivate() }
    }
}

/// V5 CU7 — ambient-driven computer use. The ambient decision pipeline's capability sink
/// (`AmbientDelivering`): an utterance the guarantees delivered as `.act` goes to the act session's
/// `dispatchAmbient`, the same path as the act key. Re-checked here, per utterance, as defence in
/// depth: the mode is still Listen & act and Computer use is switched on (`ActKeySettings`). Owners
/// other than `.act` (dictate / edit / ask) are forwarded to `next`, which their lanes attach.
public final class AmbientActDelivery: AmbientDelivering, @unchecked Sendable {
    /// The app's one instance: the pipeline holds its delivery weakly, so this keeps it alive.
    public static let shared = AmbientActDelivery()

    public enum Outcome: Equatable, Sendable {
        case dispatched(ActDispatch)
        case forwarded(UtteranceOwner)
        case refused(String)
    }

    private let lock = NSLock()
    private weak var _session: ActSessionController?
    private var _next: (any AmbientDelivering)?
    private var _mode: (() -> AmbientMode)?
    /// Every delivery's outcome (diagnostics, tests).
    public var onOutcome: ((Outcome) -> Void)?

    public init() {}

    /// The act session ambient `act` utterances go to (held weakly; the app delegate owns it).
    public var session: ActSessionController? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }
    /// Where non-act owners go (dictate / edit / ask). Nil → they are dropped here.
    public var next: (any AmbientDelivering)? {
        get { lock.withLock { _next } }
        set { lock.withLock { _next = newValue } }
    }
    /// The live ambient mode; nil → read from the session's settings store.
    public var mode: (() -> AmbientMode)? {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    public func attach(_ session: ActSessionController, mode: (() -> AmbientMode)? = nil) {
        lock.withLock { _session = session; if let mode { _mode = mode } }
    }

    public func deliver(_ text: String, owner: UtteranceOwner, decision: UtteranceDecision) async {
        guard owner == .act else {
            if let next { await next.deliver(text, owner: owner, decision: decision); report(.forwarded(owner)) }
            else { report(.refused("no delivery for \(owner.rawValue)")) }
            return
        }
        guard let session else { return report(.refused("no act session")) }
        let current = mode?() ?? AmbientModeSettings.mode(session.settings)
        guard current.mayAct else { return report(.refused("not Listen & act")) }
        guard ActKeySettings.isEnabled(session.settings) else { return report(.refused("computer use off")) }
        report(.dispatched(await session.dispatchAmbient(text)))
    }

    private func report(_ o: Outcome) { onOutcome?(o) }
}
