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

/// Front door for the second key: parse → consent → deterministic executor, or hand the goal to the agent.
/// Every executed step, deterministic or agentic, passes `ConsentEngine.submit`.
public final class ActRouter: @unchecked Sendable {
    public let parser: ActIntentParser
    public let consent: ConsentEngine
    public let executor: ActionExecutor
    public let agent: any AgentActionBackend
    private let lock = NSLock()
    private var pendingToken: UUID?
    /// Last deterministic result produced inside a consent executor (for `.deterministic` reporting).
    private var lastResult: ActionResult?

    public init(parser: ActIntentParser, consent: ConsentEngine, executor: ActionExecutor, agent: any AgentActionBackend) {
        self.parser = parser; self.consent = consent; self.executor = executor; self.agent = agent
    }

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    public var hasPendingConfirmation: Bool { lock.lock(); defer { lock.unlock() }; return pendingToken != nil }

    public func handle(_ text: String, appBundleID: String? = nil) async throws -> ActDispatch {
        guard let route = parser.preRoute(text, appBundleID: appBundleID) else { return .ignored(reason: "act domain inactive") }
        return try await dispatch(route)
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
        case .agentic(let goal):
            return .agentic(await agent.run(goal: goal))
        }
    }

    private func takePending() -> UUID? { lock.lock(); defer { lock.unlock() }; let t = pendingToken; pendingToken = nil; return t }
}
