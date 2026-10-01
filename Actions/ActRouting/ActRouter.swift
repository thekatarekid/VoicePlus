import Foundation
import Shared

/// What the act path reports back to the pill/chips UI.
public enum ActDispatch: Equatable, Sendable {
    case ignored(reason: String)
    case stopped
    case confirmed(ConsentOutcome)
    case cancelled
    case deterministic(ActionResult?, ConsentOutcome)   // result nil while awaiting confirmation
    case agentic(AgentRunReport)
}

/// V5 CU4 — the single-step element chooser (CUA-S1) as the act router sees it. One `choose` per
/// utterance; `endTurn` after it (CU9: the 4B unloads unless the memory plan keeps it warm).
public protocol SingleStepChoosing: AnyObject, Sendable {
    func choose(goal: String, observation: AXSummary) async throws -> CuaS1Choice
    func endTurn() async
}

/// Front door for the second key: parse → consent → deterministic executor, or hand the goal to the agent.
/// Every executed step, deterministic or agentic, passes `ConsentEngine.submit`.
///
/// V5 CU4 (§O-d Layer 2) between the catalogue and the planner: an utterance the fuzzy catalogue did
/// not take is retrieved against the embedded catalogue phrasings (top 3 → fuzzy confirm → execute at
/// ≥ 0.8); still unmatched and single-step, CUA-S1 picks one (element, action) from the AX tree; only
/// then the planner.
public final class ActRouter: @unchecked Sendable {
    public let parser: ActIntentParser
    public let consent: ConsentEngine
    public let executor: ActionExecutor
    public let agent: any AgentActionBackend
    private let lock = NSLock()
    private var pendingToken: UUID?
    /// Last deterministic result produced inside a consent executor (for `.deterministic` reporting).
    private var lastResult: ActionResult?
    private var _retrieval: CatalogRetrievalIndex?
    private var _chooser: (any SingleStepChoosing)?
    private var _chooserProvider: (@Sendable () async -> (any SingleStepChoosing)?)?
    private var chooserResolved = false
    /// A CUA-S1 pick below this probability is not trusted; the planner gets the goal instead.
    public static let chooserMinProbability = 0.5

    /// CU4 retrieval index (nil → no Layer-2 catalogue retrieval).
    public var retrieval: CatalogRetrievalIndex? {
        get { sync { _retrieval } }
        set { sync { _retrieval = newValue } }
    }
    /// CU4 single-step chooser. Set directly, or lazily through `chooserProvider` on first need.
    public var chooser: (any SingleStepChoosing)? {
        get { sync { _chooser } }
        set { sync { _chooser = newValue; chooserResolved = newValue != nil } }
    }
    public var chooserProvider: (@Sendable () async -> (any SingleStepChoosing)?)? {
        get { sync { _chooserProvider } }
        set { sync { _chooserProvider = newValue; chooserResolved = _chooser != nil } }
    }

    public init(parser: ActIntentParser, consent: ConsentEngine, executor: ActionExecutor, agent: any AgentActionBackend) {
        self.parser = parser; self.consent = consent; self.executor = executor; self.agent = agent
    }

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    public var hasPendingConfirmation: Bool { lock.lock(); defer { lock.unlock() }; return pendingToken != nil }

    public func handle(_ text: String, appBundleID: String? = nil) async throws -> ActDispatch {
        guard let route = parser.preRoute(text, appBundleID: appBundleID) else { return .ignored(reason: "act domain inactive") }
        return try await dispatch(await refine(route, appBundleID: appBundleID))
    }

    /// CU4: catalogue retrieval over an `.agentic` route (other routes unchanged).
    public func refine(_ route: ActRoute, appBundleID: String?) async -> ActRoute {
        await parser.refine(route, appBundleID: appBundleID, retrieval: retrieval)
    }

    public func dispatch(_ route: ActRoute) async throws -> ActDispatch {
        switch route {
        case .empty: return .ignored(reason: "empty")
        case .stop:
            await agent.stop()
            if let t = takePending() { consent.cancel(t) }
            return .stopped
        case .confirm:
            guard let t = takePending() else { return .ignored(reason: "nothing to confirm") }
            let out = try await consent.confirm(t, spoken: "confirm")
            return .confirmed(out)
        case .cancel:
            if let t = takePending() { consent.cancel(t); return .cancelled }
            await agent.stop()
            return .cancelled
        case .deterministic(_, let req):
            return try await runThroughConsent(req)
        case .agentic(let goal):
            if let single = try await singleStep(goal) { return single }
            return .agentic(await agent.run(goal: goal))
        }
    }

    private func runThroughConsent(_ req: ActionRequest) async throws -> ActDispatch {
        sync { lastResult = nil }
        let (token, out) = try await consent.submit(ConsentRequest.forAction(req)) { [self] _ in
            let r = executor.run(req)
            sync { lastResult = r }
            if case .failed(let phase, let why) = r.outcome { throw ActionSystemError.failed("\(phase): \(why)") }
            return ExecutionReceipt(handle: req.catalogID ?? req.kind.rawValue)
        }
        if case .awaitingConfirmation = out { sync { pendingToken = token } }
        let r: ActionResult? = sync { lastResult }
        return .deterministic(r, out)
    }

    private func resolveChooser() async -> (any SingleStepChoosing)? {
        let (current, resolved, provider) = sync { (_chooser, chooserResolved, _chooserProvider) }
        if let current { return current }
        guard !resolved, let provider else { return nil }
        let made = await provider()
        sync { if _chooser == nil { _chooser = made }; chooserResolved = true }
        return sync { _chooser }
    }

    /// CU4: CUA-S1 for a single-step goal. Nil → the planner takes it (no chooser, multi-step, no
    /// actionable element, model missing or refused, or a low-confidence pick). The chooser's turn
    /// ends before anything runs, so the 4B is gone before the planner might load (CU9).
    private func singleStep(_ goal: String) async throws -> ActDispatch? {
        guard !ActIntentParser.isMultiStep(goal), executor.system.isAvailable,
              let chooser = await resolveChooser() else { return nil }
        let observation = AXSummary(system: executor.system)
        let choice: CuaS1Choice
        do {
            choice = try await chooser.choose(goal: goal, observation: observation)
            await chooser.endTurn()
        } catch {
            await chooser.endTurn()
            return nil
        }
        guard choice.probability >= Self.chooserMinProbability else { return nil }
        return try await runThroughConsent(choice.request)
    }

    private func takePending() -> UUID? { lock.lock(); defer { lock.unlock() }; let t = pendingToken; pendingToken = nil; return t }
}
