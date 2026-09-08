import Foundation
import Shared

/// Native agent loop (no Cua, no screenshots): observe AX → plan → run each step through `ConsentEngine`
/// + `ActionExecutor` → re-observe. "stop" is honoured between steps and inside the planner wait; a
/// wall-clock watchdog enforces `timeout`; on stop/timeout queued steps are dropped and executed steps
/// with compensating actions are reversed in LIFO order.
public final class NativeAgentBackend: AgentActionBackend, @unchecked Sendable {
    public struct Config: Sendable {
        public var maxRounds = 6
        public var maxStepsPerRound = 12
        public var timeout: TimeInterval = 60
        public init() {}
    }
    public let planner: any PlannerLLM
    public let executor: ActionExecutor
    public let consent: ConsentEngine
    public var config: Config
    public var tools: [AgentTool] = AgentTool.vocabulary
    /// Decides a confirmation card for an irreversible step: the App wires the slide-out card (click / spoken "confirm").
    /// Default declines — an agent never self-confirms.
    public var confirmation: @Sendable (ConfirmationCard) async -> Bool = { _ in false }
    public var onChips: (@Sendable (StepChipsModel) -> Void)?
    public var now: @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

    private let lock = NSLock()
    private var stopRequested = false
    private var running = false
    private var cancelPlanner: (@Sendable () -> Void)?
    public private(set) var chips = StepChipsModel()

    public init(planner: any PlannerLLM, executor: ActionExecutor, consent: ConsentEngine, config: Config = Config()) {
        self.planner = planner; self.executor = executor; self.consent = consent; self.config = config
    }

    private func sync<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
    public var isRunning: Bool { sync { running } }
    private var shouldStop: Bool { sync { stopRequested } }

    public func stop() async { requestStop() }
    /// Synchronous form for UI callbacks (pill tap) — same semantics as `stop()`.
    public func requestStop() {
        let c: (@Sendable () -> Void)? = sync { stopRequested = true; return cancelPlanner }
        c?()
    }

    private func publish(_ f: (inout StepChipsModel) -> Void) { f(&chips); onChips?(chips) }

    public func run(goal: String) async -> AgentRunReport {
        let busy: Bool = sync { if running { return true }; running = true; stopRequested = false; return false }
        if busy { return AgentRunReport(goal: goal, status: .failed(reason: "already running"), records: [], rounds: 0) }
        defer { sync { running = false; cancelPlanner = nil } }
        chips = StepChipsModel()

        let deadline = now() + config.timeout
        let watchdog = Task { [weak self, timeout = config.timeout] in
            try? await Task.sleep(for: .seconds(timeout)); await self?.stop()
        }
        defer { watchdog.cancel() }

        var records: [StepRecord] = []
        var status: AgentRunStatus = .gaveUp(reason: "no rounds")
        var rounds = 0
        loop: while rounds < config.maxRounds {
            rounds += 1
            if shouldStop || now() > deadline { status = now() > deadline ? .timedOut : .stopped; break }
            publish { $0.phase = .thinking }
            let observation = AXSummary(system: executor.system)
            let turn: PlannerTurn
            do {
                let task = Task { try await planner.plan(goal: goal, observation: observation, history: records, tools: tools) }
                sync { cancelPlanner = { task.cancel() } }
                turn = try await task.value
            } catch {
                // A planner that is simply not configured is a *state*, not a failure: it gets its
                // own status so the UI can say something a person understands, and so nothing
                // upstream mistakes "the act feature is off" for "the turn went wrong".
                // `String(describing:)` on an `Error` is a debug description — it must never
                // become the reason a user reads (see `AgentRunStatus.userMessage`).
                if shouldStop { status = .stopped }
                else if case PlannerError.unavailable(let why) = error { status = .unavailable(reason: why) }
                else { status = .failed(reason: "planner did not answer") }
                break
            }
            switch turn {
            case .done(let s): status = .completed(summary: s); break loop
            case .giveUp(let r): status = .gaveUp(reason: r); break loop
            case .plan(var plan):
                plan.steps = Array(plan.steps.prefix(config.maxStepsPerRound))
                if plan.steps.isEmpty { status = .gaveUp(reason: "empty plan"); break loop }
                publish { $0.load(plan) }
                for step in plan.steps {
                    if shouldStop || now() > deadline { status = now() > deadline ? .timedOut : .stopped; break loop }
                    publish { $0.set(step.id, .current) }
                    let (rec, cont) = await perform(step)
                    records.append(rec)
                    if case .failed(let why) = rec.outcome, cont { status = .failed(reason: "\(step.title): \(why)") }
                    if !cont { status = shouldStop ? .stopped : .declined; break loop }
                    if case .failed = rec.outcome { break loop }
                    status = .completed(summary: "ran \(records.count) step(s)")
                }
            }
        }
        if status == .stopped || status == .timedOut {
            publish { $0.cancelUpcoming(); $0.phase = .halted }
            records = await rollback(records)
        } else { publish { $0.phase = .finished } }
        return AgentRunReport(goal: goal, status: status, records: records, rounds: rounds)
    }

    /// One step through consent. Returns `cont == false` when the run must halt (declined card / stop).
    private func perform(_ step: PlanStep) async -> (StepRecord, cont: Bool) {
        let box = ResultBox()
        let exec: ConsentEngine.Executor = { [executor] _ in
            let r = executor.run(step.request); box.set(r)
            if case .failed(let ph, let why) = r.outcome { throw ActionSystemError.failed("\(ph): \(why)") }
            return ExecutionReceipt(handle: step.id)
        }
        do {
            var creq = ConsentRequest.forAction(step.request); creq.title = step.title
            let (token, out) = try await consent.submit(creq, execute: exec)
            if case .awaitingConfirmation(let card) = out {
                publish { $0.phase = .awaitingConfirmation(step.title) }
                let ok = shouldStop ? false : await confirmation(card)
                guard ok, !shouldStop else { consent.cancel(token); publish { $0.set(step.id, .cancelled) }; return (StepRecord(step: step, outcome: .skipped), false) }
                _ = try await consent.confirm(token)
                publish { $0.phase = .acting }
            }
        } catch {
            publish { $0.set(step.id, .failed) }
            return (StepRecord(step: step, outcome: .failed(box.get().map { "\($0.outcome)" } ?? "\(error)")), true)
        }
        let verified: Bool = { if case .success(let v) = box.get()?.outcome { return v }; return false }()
        publish { $0.set(step.id, .done) }
        return (StepRecord(step: step, outcome: .done(verified: verified)), true)
    }

    /// Reverse executed steps that carry a compensating action, newest first. Compensations are reversals of
    /// already-consented work, so they run straight through the executor.
    private func rollback(_ records: [StepRecord]) async -> [StepRecord] {
        var out = records
        for i in records.indices.reversed() {
            guard case .done = records[i].outcome, let comp = records[i].step.compensating else { continue }
            if executor.run(comp).outcome.isSuccess { out[i] = StepRecord(step: records[i].step, outcome: .rolledBack); publish { $0.set(records[i].step.id, .rolledBack) } }
        }
        return out
    }
}

private final class ResultBox: @unchecked Sendable {
    private var r: ActionResult?; private let l = NSLock()
    func set(_ v: ActionResult) { l.lock(); r = v; l.unlock() }
    func get() -> ActionResult? { l.lock(); defer { l.unlock() }; return r }
}
