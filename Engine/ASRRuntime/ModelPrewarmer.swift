import Foundation
import Shared

// MARK: - V5 D5 · Prewarm on hotkey-down + idle unload
//
// The cleanup LLM is `.onDemand` (HW2), so after the D5 idle timeout (5 min, `ModelResidency`'s
// sweeper) it leaves memory. The first utterance after that would pay the load on the critical path.
// The fix is the `prewarmDictation` pattern: start loading at hotkey-down, while the user is still
// speaking, so the model is resident by the time the transcript reaches cleanup.
//
// `hotkeyDown()` is fire-and-forget and never throws. It:
// - asks the plan which keys to prewarm (`ResidencyPlan.prewarmKeys` → the cleanup LLM),
// - swaps each to its lighter alternative under critical pressure (`preferredKey(for:)`),
// - skips keys nobody registered yet (the cleanup stage registers when it is built),
// - never prewarms an `.exclusive` model (that would evict on-demand models for a guess),
// - touches an already-resident model so a busy user never watches it idle out,
// - coalesces: a second press while a prewarm is still loading reuses that task,
// - bounds every load attempt by `attemptTimeout` and retries a failed / timed-out load up to
//   `maxAttempts` times (a timed-out load is not retried in the same pass), so a loader that
//   never returns cannot wedge the prewarmer: the pass ends with `.timedOut`, the in-flight slot
//   clears, and the next hotkey-down tries again.
// Unloading is not this type's job: the residency's idle sweeper does it (`ModelResidency.sweepIdle`).

public final class ModelPrewarmer: @unchecked Sendable {
    /// What one prewarm pass did per key — for logs and tests.
    public enum Outcome: Equatable, Sendable {
        case loaded(String)
        case alreadyResident(String)
        case notRegistered(String)
        case skippedExclusive(String)
        case failed(String)
        /// The load outlived `attemptTimeout` (the loader never returned in time).
        case timedOut(String)
    }

    /// Retry/timeout policy for one key's load.
    public struct Policy: Sendable {
        public var attemptTimeout: TimeInterval
        public var maxAttempts: Int
        public var retryDelay: TimeInterval
        public init(attemptTimeout: TimeInterval = 30, maxAttempts: Int = 2, retryDelay: TimeInterval = 0.25) {
            self.attemptTimeout = max(0.001, attemptTimeout)
            self.maxAttempts = max(1, maxAttempts)
            self.retryDelay = max(0, retryDelay)
        }
    }

    public static let shared = ModelPrewarmer()

    private let residency: ModelResidency
    private let keys: @Sendable () -> [String]
    private let policy: Policy
    private let lock = NSLock()
    private var inFlight: Task<[Outcome], Never>?

    public init(residency: ModelResidency = .shared,
                keys: @escaping @Sendable () -> [String] = { ResidencyPlanStore.shared.plan.prewarmKeys },
                policy: Policy = Policy()) {
        self.residency = residency
        self.keys = keys
        self.policy = policy
    }

    /// Call at dictation hotkey-down. Returns the (possibly shared) prewarm task; callers may ignore it.
    @discardableResult
    public func hotkeyDown() -> Task<[Outcome], Never> {
        lock.lock(); defer { lock.unlock() }
        if let inFlight { return inFlight }
        let residency = self.residency
        let keys = self.keys()
        let policy = self.policy
        let task = Task<[Outcome], Never> { [weak self] in
            var outcomes: [Outcome] = []
            for key in keys { outcomes.append(await Self.prewarm(key, residency: residency, policy: policy)) }
            self?.finish()
            return outcomes
        }
        inFlight = task
        return task
    }

    private func finish() { lock.lock(); inFlight = nil; lock.unlock() }

    static func prewarm(_ requested: String, residency: ModelResidency, policy: Policy = Policy()) async -> Outcome {
        let key = await residency.preferredKey(for: requested)
        guard let entry = await residency.snapshot().entries.first(where: { $0.key == key }) else {
            return .notRegistered(key)
        }
        if entry.tier == .exclusive { return .skippedExclusive(key) }
        if entry.resident {
            await residency.touch(key)
            return .alreadyResident(key)
        }
        var last: Outcome = .failed(key)
        for attempt in 1...policy.maxAttempts {
            if attempt > 1, policy.retryDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(policy.retryDelay * 1_000_000_000))
            }
            switch await acquire(key, residency: residency, timeout: policy.attemptTimeout) {
            case .success:
                Log.engine.info("prewarm: \(key) loaded at hotkey-down")
                return .loaded(key)
            case .timedOut:
                // Not retried: the residency still owns that load, so a retry would only join the
                // same stuck load and hold the pass for another timeout. The next hotkey-down tries.
                Log.engine.notice("prewarm: \(key) load attempt \(attempt) timed out")
                return .timedOut(key)
            case let .failed(error):
                Log.engine.notice("prewarm: \(key) not loaded (attempt \(attempt)) — \(error)")
                last = .failed(key)
            }
        }
        return last
    }

    enum AttemptResult { case success, timedOut, failed(any Error) }

    /// One load attempt raced against `timeout`. The load runs unstructured, so a loader that never
    /// returns (and ignores cancellation) cannot hold the caller: the timeout answers and the load
    /// is left to finish (or not) on its own — the residency still owns its state.
    static func acquire(_ key: String, residency: ModelResidency, timeout: TimeInterval) async -> AttemptResult {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<AttemptResult, Never>?
            init(_ c: CheckedContinuation<AttemptResult, Never>) { continuation = c }
            func resume(_ r: AttemptResult) {
                lock.lock(); let c = continuation; continuation = nil; lock.unlock()
                c?.resume(returning: r)
            }
        }
        return await withCheckedContinuation { (c: CheckedContinuation<AttemptResult, Never>) in
            let once = Once(c)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled { once.resume(.timedOut) }
            }
            Task {
                do { try await residency.acquire(key); once.resume(.success) } catch { once.resume(.failed(error)) }
                timer.cancel()
            }
        }
    }
}
