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
// - coalesces: a second press while a prewarm is still loading reuses that task.
// Unloading is not this type's job: the residency's idle sweeper does it (`ModelResidency.sweepIdle`).

public final class ModelPrewarmer: @unchecked Sendable {
    /// What one prewarm pass did per key — for logs and tests.
    public enum Outcome: Equatable, Sendable {
        case loaded(String)
        case alreadyResident(String)
        case notRegistered(String)
        case skippedExclusive(String)
        case failed(String)
    }

    public static let shared = ModelPrewarmer()

    private let residency: ModelResidency
    private let keys: @Sendable () -> [String]
    private let lock = NSLock()
    private var inFlight: Task<[Outcome], Never>?

    public init(residency: ModelResidency = .shared,
                keys: @escaping @Sendable () -> [String] = { ResidencyPlanStore.shared.plan.prewarmKeys }) {
        self.residency = residency
        self.keys = keys
    }

    /// Call at dictation hotkey-down. Returns the (possibly shared) prewarm task; callers may ignore it.
    @discardableResult
    public func hotkeyDown() -> Task<[Outcome], Never> {
        lock.lock(); defer { lock.unlock() }
        if let inFlight { return inFlight }
        let residency = self.residency
        let keys = self.keys()
        let task = Task<[Outcome], Never> { [weak self] in
            var outcomes: [Outcome] = []
            for key in keys { outcomes.append(await Self.prewarm(key, residency: residency)) }
            self?.finish()
            return outcomes
        }
        inFlight = task
        return task
    }

    private func finish() { lock.lock(); inFlight = nil; lock.unlock() }

    static func prewarm(_ requested: String, residency: ModelResidency) async -> Outcome {
        let key = await residency.preferredKey(for: requested)
        guard let entry = await residency.snapshot().entries.first(where: { $0.key == key }) else {
            return .notRegistered(key)
        }
        if entry.tier == .exclusive { return .skippedExclusive(key) }
        if entry.resident {
            await residency.touch(key)
            return .alreadyResident(key)
        }
        do {
            try await residency.acquire(key)
            Log.engine.info("prewarm: \(key) loaded at hotkey-down")
            return .loaded(key)
        } catch {
            Log.engine.notice("prewarm: \(key) not loaded — \(error)")
            return .failed(key)
        }
    }
}
