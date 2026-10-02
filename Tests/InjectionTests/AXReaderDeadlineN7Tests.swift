import Foundation
import Testing
@testable import Injection

// MARK: - N7 — bounded walks: per-node deadline + cancel, partial reads never cached, one walk per window

private let win = AXWindowID(pid: 7, windowNumber: 1)

private func wideTree(_ count: Int) -> MockAXTree {
    let tree = MockAXTree()
    let kids = (0..<count).map { MockAXNode(role: "AXGroup", children: [MockAXNode(role: "AXStaticText", value: "line \($0)")]) }
    tree.addWindow(win, root: MockAXNode(role: "AXWindow", title: "Doc", children: kids))
    return tree
}

@Suite("N7 AX reader deadline")
struct AXReaderDeadlineN7Tests {
    @Test func deadlineStopsASlowWalkAndMarksItInterrupted() throws {
        let tree = wideTree(400)
        tree.perNodeDelay = 0.005          // ~800 children calls ≈ 4 s unbounded
        let reader = AXWindowReader(access: tree)
        let started = Date()
        let options = AXReadOptions(limits: .turnSnapshot(deadline: started.addingTimeInterval(0.1)))
        let content = try reader.readWindow(win, options: options)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 0.4)
        #expect(content.interrupted)
        #expect(content.truncated)
        #expect(content.blocks.count < 400)
    }

    @Test func cancelledWalkReadsNothing() throws {
        let tree = wideTree(10)
        let token = AXReadCancellation()
        token.cancel()
        let content = try AXWindowReader(access: tree).readWindow(win, options: AXReadOptions(cancellation: token))
        #expect(content.interrupted)
        #expect(content.blocks.isEmpty)
        #expect(content.nodesVisited == 0)
    }

    @Test func nodeCapOfTheTurnSnapshotBudgetHolds() throws {
        let tree = wideTree(1_000)
        let options = AXReadOptions(limits: .turnSnapshot(deadline: Date().addingTimeInterval(5)))
        let content = try AXWindowReader(access: tree).readWindow(win, options: options)
        #expect(content.nodesVisited <= 800)
        #expect(content.truncated)
        #expect(!content.interrupted)
    }

    @Test func interruptedReadIsNotCached() throws {
        let tree = wideTree(50)
        let cached = CachedAXReader(access: tree)
        let token = AXReadCancellation()
        token.cancel()
        _ = try cached.readWindow(win, options: AXReadOptions(cancellation: token))
        let full = try cached.readWindow(win, options: .visible)
        #expect(!full.interrupted)
        #expect(full.blocks.count == 50)
        #expect(cached.walksStarted == 2)
    }

    @Test func concurrentReadersOfOneWindowShareOneWalk() throws {
        let tree = wideTree(40)
        tree.perNodeDelay = 0.003
        let cached = CachedAXReader(access: tree)
        let lock = NSLock()
        var results: [WindowContent] = []
        let done = DispatchSemaphore(value: 0)
        // Dedicated threads, not GCD: the parallel test runner can starve the global pool.
        for _ in 0..<3 {
            Thread {
                if let c = try? cached.readWindow(win, options: .visible) { lock.lock(); results.append(c); lock.unlock() }
                done.signal()
            }.start()
        }
        for _ in 0..<3 { #expect(done.wait(timeout: .now() + 10) == .success) }
        #expect(cached.walksStarted == 1)
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.blocks.count == 40 })
    }

    @Test func joinerGivesUpAtItsDeadlineInsteadOfStartingASecondWalk() throws {
        let tree = wideTree(200)
        tree.perNodeDelay = 0.005
        let cached = CachedAXReader(access: tree)
        let done = DispatchSemaphore(value: 0)
        Thread { _ = try? cached.readWindow(win, options: .visible); done.signal() }.start()
        Thread.sleep(forTimeInterval: 0.05)
        let started = Date()
        let joined = try cached.readWindow(win, options: AXReadOptions(limits: .turnSnapshot(deadline: started.addingTimeInterval(0.1))))
        #expect(Date().timeIntervalSince(started) < 0.4)
        #expect(joined.interrupted)
        #expect(cached.walksStarted == 1)
        _ = done.wait(timeout: .now() + 10)
    }

    @Test func optionsEqualityIgnoresTheCancellationToken() {
        #expect(AXReadOptions(cancellation: AXReadCancellation()) == AXReadOptions.visible)
    }
}
