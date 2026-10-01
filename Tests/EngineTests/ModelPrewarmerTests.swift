import Foundation
import Shared
import Testing
@testable import Engine

/// V5 D5 — hotkey-down prewarm of the cleanup LLM through `ModelResidency`, and the idle unload that
/// follows. The real llama.cpp cleanup model does not exist yet (D2, W4): a counted loader stands in.
@Suite("Model prewarmer (D5)")
struct ModelPrewarmerTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    }

    private static let mb: Int64 = 1_000_000

    private static func register(_ r: ModelResidency, _ key: String, tier: ResidencyTier = .onDemand,
                                 bytes: Int64 = 500 * mb, lighter: String? = nil,
                                 loads: Count, delayMs: UInt64 = 0) async {
        await r.register(key, tier: tier, estimatedBytes: bytes, lighterAlternative: lighter,
                         load: {
                             if delayMs > 0 { try await Task.sleep(nanoseconds: delayMs * 1_000_000) }
                             loads.bump()
                         },
                         unload: {})
    }

    @Test func hotkeyDownLoadsTheCleanupModel() async {
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let loads = Count()
        await Self.register(r, ResidencyKey.cleanup, loads: loads)
        let p = ModelPrewarmer(residency: r, keys: { ResidencyPlan.for(.standard).prewarmKeys })
        let out = await p.hotkeyDown().value
        #expect(out == [.loaded(ResidencyKey.cleanup)])
        #expect(await r.isResident(ResidencyKey.cleanup))
        #expect(loads.value == 1)
        // Second press: already resident, no reload.
        #expect(await p.hotkeyDown().value == [.alreadyResident(ResidencyKey.cleanup)])
        #expect(loads.value == 1)
    }

    @Test func unregisteredKeyIsANoOp() async {
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.cleanup] })
        #expect(await p.hotkeyDown().value == [.notRegistered(ResidencyKey.cleanup)])
    }

    @Test func exclusiveModelsAreNeverPrewarmed() async {
        let r = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let loads = Count()
        await Self.register(r, ResidencyKey.computerUseS1, tier: .exclusive, loads: loads)
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.computerUseS1] })
        #expect(await p.hotkeyDown().value == [.skippedExclusive(ResidencyKey.computerUseS1)])
        #expect(loads.value == 0)
    }

    @Test func rapidPressesShareOneLoad() async {
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let loads = Count()
        await Self.register(r, ResidencyKey.cleanup, loads: loads, delayMs: 100)
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.cleanup] })
        let a = p.hotkeyDown(), b = p.hotkeyDown()
        _ = await a.value; _ = await b.value
        #expect(loads.value == 1)
    }

    @Test func criticalPressurePrewarmsTheLighterModel() async {
        let r = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let heavy = Count(), light = Count()
        await Self.register(r, ResidencyKey.localLLM4B, lighter: ResidencyKey.localLLM2B, loads: heavy)
        await Self.register(r, ResidencyKey.localLLM2B, loads: light)
        await r.handleMemoryPressure(.critical)
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.localLLM4B] })
        #expect(await p.hotkeyDown().value == [.loaded(ResidencyKey.localLLM2B)])
        #expect(heavy.value == 0 && light.value == 1)
    }

    @Test func loadFailureIsReportedNotThrown() async {
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        struct Boom: Error {}
        await r.register(ResidencyKey.cleanup, tier: .onDemand, estimatedBytes: Self.mb,
                         load: { throw Boom() }, unload: {})
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.cleanup] })
        #expect(await p.hotkeyDown().value == [.failed(ResidencyKey.cleanup)])
    }

    @Test func prewarmedModelIdlesOutAfterTimeoutAndPressKeepsItAlive() async {
        let clock = Clock()
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib, idleTimeout: 300, now: { clock.now() })
        let loads = Count()
        await Self.register(r, ResidencyKey.cleanup, loads: loads)
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.cleanup] })
        _ = await p.hotkeyDown().value

        clock.advance(240)
        _ = await p.hotkeyDown().value            // touched: idle clock resets
        clock.advance(240)
        #expect(await r.sweepIdle().isEmpty)
        #expect(await r.isResident(ResidencyKey.cleanup))

        clock.advance(61)                          // 301 s since the last press
        #expect(await r.sweepIdle() == [ResidencyKey.cleanup])
        #expect(!(await r.isResident(ResidencyKey.cleanup)))
        #expect(await r.recentEvents().last?.reason == .idle)

        // Next press loads it again.
        #expect(await p.hotkeyDown().value == [.loaded(ResidencyKey.cleanup)])
        #expect(loads.value == 2)
    }

    // MARK: D5 follow-up — a loader that never returns cannot wedge the prewarmer

    @Test func hungLoaderTimesOutAndTheNextPressTriesAgain() async {
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let calls = Count()
        await r.register(ResidencyKey.cleanup, tier: .onDemand, estimatedBytes: Self.mb,
                         load: {
                             calls.bump()
                             // Effectively never returns (an hour; nothing cancels the residency's load).
                             try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                         },
                         unload: {})
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.cleanup] },
                               policy: .init(attemptTimeout: 0.05, maxAttempts: 2, retryDelay: 0))
        let start = Date()
        #expect(await p.hotkeyDown().value == [.timedOut(ResidencyKey.cleanup)])
        #expect(Date().timeIntervalSince(start) < 5, "bounded by the attempt timeouts, not the loader")
        // The slot cleared: a new press is a new pass (it times out again rather than hanging).
        #expect(await p.hotkeyDown().value == [.timedOut(ResidencyKey.cleanup)])
        #expect(calls.value >= 1)
    }

    @Test func transientFailureIsRetried() async {
        let r = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        struct Boom: Error {}
        let calls = Count()
        await r.register(ResidencyKey.cleanup, tier: .onDemand, estimatedBytes: Self.mb,
                         load: { calls.bump(); if calls.value == 1 { throw Boom() } },
                         unload: {})
        let p = ModelPrewarmer(residency: r, keys: { [ResidencyKey.cleanup] },
                               policy: .init(attemptTimeout: 5, maxAttempts: 2, retryDelay: 0))
        #expect(await p.hotkeyDown().value == [.loaded(ResidencyKey.cleanup)])
        #expect(calls.value == 2)
        #expect(await r.isResident(ResidencyKey.cleanup))
    }
}
