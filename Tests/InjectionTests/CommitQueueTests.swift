import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - R2.3: the ordered commit queue

@Suite struct CommitQueueTests {
    let session = UUID()
    func seg(_ index: Int, session: UUID? = nil) -> SegmentID {
        SegmentID(sessionID: session ?? self.session, index: index)
    }
    func entry(_ index: Int, _ text: String, session: UUID? = nil) -> CommitQueue.Entry {
        CommitQueue.Entry(segment: seg(index, session: session), request: InjectionRequest(text: text))
    }

    // MARK: The queue in isolation

    @Test func inOrderSegmentsPassStraightThrough() {
        let q = CommitQueue()
        #expect(q.submit(entry(0, "a")).map(\.segment.index) == [0])
        #expect(q.submit(entry(1, "b")).map(\.segment.index) == [1])
        #expect(q.submit(entry(2, "c")).map(\.segment.index) == [2])
        #expect(q.pending.isEmpty)
    }

    @Test func aLateEarlierSegmentReleasesBothInOrder() {
        let q = CommitQueue()
        #expect(q.submit(entry(1, "second")).isEmpty)      // waits: 0 has not arrived
        #expect(q.pending.count == 1)
        let released = q.submit(entry(0, "first"))
        #expect(released.map(\.segment.index) == [0, 1])
        #expect(released.map(\.request.text) == ["first", "second"])
        #expect(q.pending.isEmpty)
    }

    @Test func theSameSegmentIsNeverReleasedTwice() {
        let q = CommitQueue()
        #expect(q.submit(entry(0, "once")).count == 1)
        #expect(q.submit(entry(0, "once")).isEmpty)
        #expect(q.submit(entry(0, "again, different text")).isEmpty)
        #expect(q.hasDelivered(seg(0)))
    }

    @Test func aDuplicateStillPendingIsIgnored() {
        let q = CommitQueue()
        #expect(q.submit(entry(2, "x")).isEmpty)
        #expect(q.submit(entry(2, "x")).isEmpty)
        #expect(q.pending.count == 1)
    }

    @Test func aStaleIndexBelowTheWatermarkIsDropped() {
        let q = CommitQueue()
        _ = q.submit(entry(0, "a"))
        _ = q.submit(entry(1, "b"))
        #expect(q.nextIndex == 2)
        #expect(q.submit(entry(0, "very late")).isEmpty)
    }

    @Test func theWaitIsBoundedSoAMissingSegmentCannotStallTheRest() {
        let q = CommitQueue()
        q.maxPending = 1
        #expect(q.submit(entry(1, "b")).isEmpty)
        // Segment 0 never arrives. Past the bound the queue releases what it has rather than
        // holding committed text forever.
        let released = q.submit(entry(2, "c"))
        #expect(released.map(\.segment.index) == [1, 2])
        #expect(q.pending.isEmpty)
    }

    @Test func aNewSessionReleasesTheOldOnesOrphansFirst() {
        let q = CommitQueue()
        #expect(q.submit(entry(3, "orphan")).isEmpty)
        let other = UUID()
        let released = q.submit(entry(0, "new session", session: other))
        #expect(released.map(\.request.text) == ["orphan", "new session"])
        #expect(q.session == other)
        #expect(q.nextIndex == 1)
    }

    @Test func flushReleasesEverythingStillWaitingInOrder() {
        let q = CommitQueue()
        _ = q.submit(entry(3, "d"))
        _ = q.submit(entry(1, "b"))
        #expect(q.flush().map(\.segment.index) == [1, 3])
        #expect(q.pending.isEmpty)
        #expect(q.flush().isEmpty)
    }

    @Test func duplicateMemoryIsBounded() {
        let q = CommitQueue()
        q.deliveredMemory = 4
        for i in 0..<10 { _ = q.submit(entry(i, "t\(i)")) }
        #expect(q.deliveredIDs.count == 4)
        #expect(q.deliveredIDs.map(\.index) == [6, 7, 8, 9])
    }

    @Test func resetForgetsTheSession() {
        let q = CommitQueue()
        _ = q.submit(entry(5, "x"))
        q.reset()
        #expect(q.pending.isEmpty)
        #expect(q.session == nil)
        #expect(q.nextIndex == 0)
    }

    // MARK: Through the injector

    @Test func outOfOrderCommitsReachTheFieldInSegmentOrder() {
        let (injector, mock, _) = makeStack()
        #expect(injector.commit(InjectionRequest(text: "world."), segment: seg(1)).isEmpty)
        #expect(mock.field.value == "")   // nothing lands while an earlier segment is outstanding
        let released = injector.commit(InjectionRequest(text: "Hello "), segment: seg(0))
        #expect(released.map(\.segment.index) == [0, 1])
        #expect(released.allSatisfy { $0.outcome.succeeded })
        #expect(mock.field.value == "Hello world.")
    }

    @Test func aRepeatedSegmentIsNotTypedTwice() {
        let (injector, mock, store) = makeStack()
        #expect(injector.commit(InjectionRequest(text: "once. "), segment: seg(0)).count == 1)
        #expect(injector.commit(InjectionRequest(text: "once. "), segment: seg(0)).isEmpty)
        #expect(mock.field.value == "once. ")
        #expect(store.records.count == 1)
    }

    @Test func flushCommitsDeliversWhatWasStillWaiting() {
        let (injector, mock, _) = makeStack()
        #expect(injector.commit(InjectionRequest(text: "tail"), segment: seg(2)).isEmpty)
        let flushed = injector.flushCommits()
        #expect(flushed.map(\.segment.index) == [2])
        #expect(mock.field.value == "tail")
    }

    @Test func aCommitThatCannotBeDeliveredIsHeldWithItsSegmentID() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.apple.Safari", pid: 300)
        let released = injector.commit(InjectionRequest(text: "held segment", expectedFocus: snapshot), segment: seg(0))
        #expect(released.count == 1)
        guard case .abortedFocusChanged = released[0].outcome else { Issue.record("\(released[0].outcome)"); return }
        #expect(injector.focusGuard.held.first?.segmentID == seg(0))
        #expect(mock.field.value == "")
    }
}
