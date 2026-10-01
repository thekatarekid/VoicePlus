import Foundation
import Testing
@testable import Shared

/// V5 HW1 / HW3 — the one memory budget every model shares.
@Suite("Model residency (HW1/HW3)")
struct ModelResidencyTests {
    static let gib = ResidencyBudget.gib
    static let gb: Int64 = 1_000_000_000

    /// Records load/unload calls in order.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return log }
        var unloads: [String] { all.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) } }
        func loads(of key: String) -> Int { all.filter { $0 == "+" + key }.count }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    }

    static func make(budget: Int64, idle: TimeInterval = 300, clock: Clock = Clock()) -> ModelResidency {
        ModelResidency(budgetBytes: budget, idleTimeout: idle, now: { clock.now() })
    }

    static func reg(_ r: ModelResidency, _ key: String, _ tier: ResidencyTier, _ bytes: Int64,
                    lighter: String? = nil, calls: Calls, delayNs: UInt64 = 0) async {
        await r.register(key, tier: tier, estimatedBytes: bytes, lighterAlternative: lighter, owner: "test",
                         load: { if delayNs > 0 { try await Task.sleep(nanoseconds: delayNs) }; calls.add("+" + key) },
                         unload: { calls.add("-" + key) })
    }

    // MARK: Budget arithmetic

    @Test func budgetFollowsPhysicalMemory() {
        #expect(ResidencyBudget.bytes(forPhysicalMemory: 8 << 30) == 2 * Self.gib)
        #expect(ResidencyBudget.bytes(forPhysicalMemory: 16 << 30) == Self.gib * 9 / 2)
        #expect(ResidencyBudget.bytes(forPhysicalMemory: 18 << 30) == Self.gib * 9 / 2)
        #expect(ResidencyBudget.bytes(forPhysicalMemory: 24 << 30) == 8 * Self.gib)
        #expect(ResidencyBudget.bytes(forPhysicalMemory: 48 << 30) == 16 * Self.gib)
        #expect(ResidencyBudget.forThisMac > 0)
    }

    @Test func usedBytesSumsResidentModels() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        await Self.reg(r, "asr", .always, 1 * Self.gb, calls: c)
        await Self.reg(r, "llm", .onDemand, 2 * Self.gb, calls: c)
        await Self.reg(r, "unused", .onDemand, 3 * Self.gb, calls: c)
        try await r.acquire("asr"); try await r.acquire("llm")
        let snap = await r.snapshot()
        #expect(snap.usedBytes == 3 * Self.gb)
        #expect(snap.residentKeys == ["asr", "llm"])
        #expect(snap.budgetBytes == 10 * Self.gb)
    }

    @Test func acquireTwiceLoadsOnce() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        await Self.reg(r, "llm", .onDemand, Self.gb, calls: c, delayNs: 20_000_000)
        async let a: Void = r.acquire("llm")
        async let b: Void = r.acquire("llm")
        _ = try await (a, b)
        try await r.acquire("llm")
        #expect(c.loads(of: "llm") == 1)
    }

    @Test func unregisteredKeyThrows() async {
        let r = Self.make(budget: Self.gb)
        await #expect(throws: ResidencyError.notRegistered("x")) { try await r.acquire("x") }
    }

    // MARK: Eviction order

    @Test func lruOnDemandEvictedFirstUnderBudget() async throws {
        let clock = Clock()
        let r = Self.make(budget: 4 * Self.gb, clock: clock), c = Calls()
        await Self.reg(r, "asr", .always, 1 * Self.gb, calls: c)
        await Self.reg(r, "a", .onDemand, 1 * Self.gb, calls: c)
        await Self.reg(r, "b", .onDemand, 1 * Self.gb, calls: c)
        await Self.reg(r, "c", .onDemand, 2 * Self.gb, calls: c)
        try await r.acquire("asr")
        try await r.acquire("a"); clock.advance(1)
        try await r.acquire("b"); clock.advance(1)
        await r.touch("a")                 // b is now least recently used
        try await r.acquire("c")           // needs 2 GB: 1 asr + 1 a + 1 b + 2 c = 5 > 4 → evict b only
        #expect(c.unloads == ["b"])
        #expect(await r.snapshot().residentKeys == ["a", "asr", "c"])
        let ev = await r.recentEvents().filter { $0.kind == .unload }
        #expect(ev.map(\.reason) == [.budget])
    }

    @Test func alwaysTierNeverEvictedAndNeverRefused() async throws {
        let r = Self.make(budget: 1 * Self.gb), c = Calls()
        await Self.reg(r, "asr", .always, 1 * Self.gb, calls: c)
        await Self.reg(r, "eou", .always, 1 * Self.gb, calls: c)
        try await r.acquire("asr")
        try await r.acquire("eou")          // over budget, still loads
        #expect(c.unloads.isEmpty)
        #expect(await r.snapshot().usedBytes == 2 * Self.gb)
    }

    @Test func onDemandRefusedWhenNothingEvictable() async throws {
        let r = Self.make(budget: 2 * Self.gb), c = Calls()
        await Self.reg(r, "asr", .always, 1 * Self.gb, calls: c)
        await Self.reg(r, "big", .onDemand, 3 * Self.gb, calls: c)
        try await r.acquire("asr")
        await #expect(throws: ResidencyError.overBudget(requested: "big", neededBytes: 4 * Self.gb, budgetBytes: 2 * Self.gb)) {
            try await r.acquire("big")
        }
        #expect(c.loads(of: "big") == 0)
        #expect(await r.snapshot().usedBytes == 1 * Self.gb)
        #expect(await r.recentEvents().last?.kind == .refused)
    }

    @Test func pinnedModelIsNotEvicted() async throws {
        let r = Self.make(budget: 2 * Self.gb), c = Calls()
        await Self.reg(r, "a", .onDemand, 1 * Self.gb, calls: c)
        await Self.reg(r, "b", .onDemand, 2 * Self.gb, calls: c)
        try await r.withModel("a") {
            await #expect(throws: ResidencyError.self) { try await r.acquire("b") }
        }
        #expect(c.unloads.isEmpty)
        try await r.acquire("b")            // unpinned now → a goes
        #expect(c.unloads == ["a"])
    }

    @Test func failedLoadFreesItsReservation() async throws {
        struct Boom: Error {}
        let r = Self.make(budget: 2 * Self.gb)
        await r.register("bad", tier: .onDemand, estimatedBytes: Self.gb, load: { throw Boom() }, unload: {})
        await #expect(throws: Boom.self) { try await r.acquire("bad") }
        #expect(await r.snapshot().usedBytes == 0)
        #expect(await r.isResident("bad") == false)
    }

    // MARK: Exclusive

    @Test func exclusiveEvictsAllOnDemandFirst() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        await Self.reg(r, "asr", .always, 1 * Self.gb, calls: c)
        await Self.reg(r, "llm", .onDemand, 1 * Self.gb, calls: c)
        await Self.reg(r, "kev", .onDemand, 1 * Self.gb, calls: c)
        await Self.reg(r, "cua", .exclusive, 4 * Self.gb, calls: c)
        for k in ["asr", "llm", "kev"] { try await r.acquire(k) }
        try await r.acquire("cua")          // fits the budget, but exclusive still clears on-demand
        #expect(Set(c.unloads) == ["llm", "kev"])
        #expect(c.all.last == "+cua")
        #expect(await r.snapshot().residentKeys == ["asr", "cua"])
        #expect(await r.recentEvents().filter { $0.kind == .unload }.allSatisfy { $0.reason == .exclusive })
    }

    @Test func secondExclusiveIsRefusedWhileFirstResident() async throws {
        let r = Self.make(budget: 20 * Self.gb), c = Calls()
        await Self.reg(r, "cua", .exclusive, 4 * Self.gb, calls: c)
        await Self.reg(r, "planner4b", .exclusive, 3 * Self.gb, calls: c)
        try await r.acquire("cua")
        await #expect(throws: ResidencyError.exclusiveConflict(requested: "planner4b", resident: "cua")) {
            try await r.acquire("planner4b")
        }
        #expect(c.loads(of: "planner4b") == 0)
        await r.unload("cua")
        try await r.acquire("planner4b")    // allowed once the first is gone
        #expect(await r.isResident("planner4b"))
    }

    // MARK: Idle (D5 policy)

    @Test func idleOnDemandUnloadsAfterTimeout() async throws {
        let clock = Clock()
        let r = Self.make(budget: 10 * Self.gb, idle: 300, clock: clock), c = Calls()
        await Self.reg(r, "asr", .always, Self.gb, calls: c)
        await Self.reg(r, "llm", .onDemand, Self.gb, calls: c)
        await Self.reg(r, "cua", .exclusive, Self.gb, calls: c)
        for k in ["asr", "cua", "llm"] { try await r.acquire(k) }   // cua first: an exclusive load clears on-demand
        clock.advance(299)
        #expect(await r.sweepIdle().isEmpty)
        clock.advance(2)
        #expect(await r.sweepIdle() == ["cua", "llm"])
        #expect(await r.isResident("asr"))
        await r.setIdleTimeout(10)          // configurable
        try await r.acquire("llm"); clock.advance(11)
        #expect(await r.sweepIdle() == ["llm"])
        #expect(await r.recentEvents().filter { $0.kind == .unload }.allSatisfy { $0.reason == .idle })
    }

    // MARK: HW3 memory pressure

    @Test func warningUnloadsUnpinnedOnDemandOnly() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        await Self.reg(r, "asr", .always, Self.gb, calls: c)
        await Self.reg(r, "llm", .onDemand, Self.gb, calls: c)
        await Self.reg(r, "kev", .onDemand, Self.gb, calls: c)
        await Self.reg(r, "cua", .exclusive, Self.gb, calls: c)
        for k in ["asr", "llm", "kev"] { try await r.acquire(k) }
        try await r.withModel("kev") {
            await r.handleMemoryPressure(.warning)
        }
        #expect(c.unloads == ["llm"])
        #expect(await r.isRunningLighter == false)
        #expect(await r.preferredKey(for: "kev") == "kev")
    }

    @Test func criticalSwapsToLighterAndRaisesChip() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        let chips = Calls()
        await r.setLighterModeObserver { on in chips.add(on ? "on" : "off") }
        await Self.reg(r, "asr", .always, Self.gb, calls: c)
        await Self.reg(r, "decide.kev", .onDemand, 2 * Self.gb, lighter: "decide.laya", calls: c)
        await Self.reg(r, "decide.laya", .onDemand, Self.gb / 2, calls: c)
        await Self.reg(r, "planner.4b", .exclusive, 3 * Self.gb, lighter: "planner.2b", calls: c)
        await Self.reg(r, "planner.2b", .exclusive, Self.gb, calls: c)
        for k in ["asr", "decide.kev", "planner.4b"] { try await r.acquire(k) }

        await r.handleMemoryPressure(.critical)
        #expect(await r.isRunningLighter)
        #expect(chips.all == ["on"])
        #expect(Set(c.unloads) == ["decide.kev", "planner.4b"])
        #expect(await r.isResident("asr"))
        #expect(await r.preferredKey(for: "decide.kev") == "decide.laya")
        #expect(await r.preferredKey(for: "planner.4b") == "planner.2b")
        #expect(await r.preferredKey(for: "asr") == "asr")
        #expect(ModelResidency.lighterModelsMessage == "Running lighter models — memory is low")

        await r.handleMemoryPressure(.normal)
        #expect(await r.isRunningLighter == false)
        #expect(chips.all == ["on", "off"])
        #expect(await r.preferredKey(for: "decide.kev") == "decide.kev")
    }

    @Test func eventsCarryReasonsForLogging() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        let seen = Calls()
        await r.setEventObserver { e in seen.add("\(e.kind.rawValue):\(e.key):\(e.reason.rawValue)") }
        await Self.reg(r, "llm", .onDemand, Self.gb, calls: c)
        try await r.acquire("llm")
        await r.unload("llm")
        #expect(seen.all == ["load:llm:requested", "unload:llm:explicit"])
    }

    @Test func unregisterAllByOwnerFreesBudget() async throws {
        let r = Self.make(budget: 10 * Self.gb), c = Calls()
        await Self.reg(r, "a", .always, Self.gb, calls: c)
        try await r.acquire("a")
        await r.unregisterAll(owner: "test")
        #expect(await r.snapshot().usedBytes == 0)
        #expect(await r.isRegistered("a") == false)
    }
}
