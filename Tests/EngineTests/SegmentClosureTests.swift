import Foundation
import Testing
import Shared
@testable import Engine

// MARK: - Doubles

/// An `AudioSource` the test pushes samples into by hand, so segment boundaries are placed
/// exactly where the test wants them instead of wherever a timer happened to land.
final class SegmentAudioSource: AudioSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    func prewarm() throws {}
    func start() throws {}
    func stop() {}
    func push(seconds: Double) {
        let samples = [Float](repeating: 0.2, count: Int(seconds * 16_000))
        samples.withUnsafeBufferPointer { sink?($0) }
    }
}

/// Pass 1. Names the audio it was given, so a test can tell one segment's text from another's and
/// catch a segment being handed the wrong slice.
final class LengthNamingFinal: FinalRecognizer, @unchecked Sendable {
    let name = "length-naming"
    private let lock = NSLock()
    private var lengths: [Int] = []
    var receivedLengths: [Int] { lock.withLock { lengths } }

    func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        lock.withLock { lengths.append(samples.count) }
        return [TranscriptSpan(text: "pass1-\(samples.count)", confidence: 0.8,
                               audioRange: 0...Double(samples.count) / 16_000, provenance: [.asr])]
    }
}

/// A latch that every waiter blocks on until the test opens it. Lets several segments be held in
/// the refinement pass *at the same time* without a sleep-and-hope race — which is the only way to
/// observe a bounded backlog at all.
actor RefinerGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// A second pass that parks on `gate` and then rewrites the text, so a committed segment's text
/// says plainly whether refinement ran for it or the pass-1 text was kept.
struct GatedRefiner: RefinementSession {
    let gate: RefinerGate
    func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        await gate.wait()
        return [TranscriptSpan(text: "pass2-\(samples.count)", confidence: 0, audioRange: 0...1,
                               provenance: [.refineQwen3])]
    }
}

/// Collects the segment stream off the engine.
final class SegmentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SegmentEvent] = []
    private var task: Task<Void, Never>?

    init(_ engine: RealEngine) {
        let stream = engine.segmentEvents()
        task = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }
    }

    private func append(_ event: SegmentEvent) { lock.withLock { storage.append(event) } }
    var events: [SegmentEvent] { lock.withLock { storage } }
    func stop() { task?.cancel() }

    var opened: [SegmentID] { events.compactMap { if case .opened(let id) = $0 { return id } else { return nil } } }
    var closed: [(segment: SegmentID, spans: [TranscriptSpan], stability: Stability, reason: SegmentCloseReason)] {
        events.compactMap {
            if case .closed(let s, let spans, let stability, let reason) = $0 {
                return (s, spans, stability, reason)
            }
            return nil
        }
    }
    var previews: [(segment: SegmentID, spans: [TranscriptSpan])] {
        events.compactMap { if case .preview(let s, let spans) = $0 { return (s, spans) } else { return nil } }
    }

    /// Waits until `count` `.closed` events have arrived, or gives up. The engine emits from
    /// whichever task finished a pass, so a consumer is always one hop behind.
    func waitForClosed(_ count: Int) async {
        for _ in 0..<200 where closed.count < count { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

private func makeEngine(
    final: FinalRecognizer,
    bounds: SegmentTracker.Bounds = .init()
) -> (RealEngine, SegmentAudioSource) {
    let audio = SegmentAudioSource()
    let engine = RealEngine(audio: audio,
                            provider: StaticRecognizerProvider(final: final, preview: nil),
                            segmentBounds: bounds)
    return (engine, audio)
}

// MARK: - Closure

@Suite("R2.2 segment closure")
struct SegmentClosureTests {
    /// Hold (V3 §4.2): key release closes the session's only segment, and it is `.final`.
    @Test func keyReleaseClosesTheSegment() async throws {
        let final = LengthNamingFinal()
        let (engine, audio) = makeEngine(final: final)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        for _ in 0..<100 where await engine.bufferedSampleCount() < 16_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let spans = try await engine.stop()
        await log.waitForClosed(1)

        #expect(log.opened.map(\.index) == [0])
        #expect(log.closed.count == 1)
        let closed = try #require(log.closed.first)
        #expect(closed.segment.index == 0)
        #expect(closed.reason == .keyRelease)
        #expect(closed.stability == .final)
        #expect(closed.spans.map(\.text) == ["pass1-16000"])
        #expect(Set(closed.spans.map(\.stability)) == [.final])
        // The whole utterance reached pass 1, exactly as it did before R2.2.
        #expect(final.receivedLengths == [16_000])
        #expect(spans == closed.spans)
        #expect(engine.segments.openSegment == nil)
    }

    /// Latch (V3 §4.3): an endpoint closes a segment as `.committed` and opens the next one, and
    /// the microphone is never interrupted — audio pushed after the endpoint lands in segment 1.
    @Test func endpointClosesSegmentAndKeepsCapturing() async throws {
        let final = LengthNamingFinal()
        let (engine, audio) = makeEngine(final: final)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        for _ in 0..<100 where await engine.bufferedSampleCount() < 16_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let first = await engine.closeSegmentAtEndpoint()
        #expect(first?.index == 0)
        // Still listening: the next segment is open and taking audio.
        #expect(engine.segments.openSegment?.index == 1)
        audio.push(seconds: 0.5)
        for _ in 0..<100 where await engine.bufferedSampleCount() < 24_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let trailing = try await engine.stop()
        await log.waitForClosed(2)

        #expect(log.opened.map(\.index) == [0, 1])
        #expect(log.closed.map(\.segment.index) == [0, 1])
        #expect(log.closed.map(\.reason) == [.endpoint, .keyRelease])
        // The segment closed mid-session is committed, not final: delivered once, never retracted,
        // but the session had not ended. Only the release-closed segment is `.final`.
        #expect(log.closed.map(\.stability) == [.committed, .final])
        #expect(Set(log.closed[0].spans.map(\.stability)) == [.committed])
        #expect(Set(log.closed[1].spans.map(\.stability)) == [.final])
        // Each segment saw only its own audio — 1.0 s then 0.5 s, no overlap and nothing lost.
        #expect(final.receivedLengths == [16_000, 8_000])
        #expect(log.closed.map { $0.spans.map(\.text).joined() } == ["pass1-16000", "pass1-8000"])
        #expect(trailing.map(\.text) == ["pass1-8000"])
        #expect(engine.segments.openSegment == nil)
    }

    /// Every segment is announced before it takes audio, and the indices never skip or repeat.
    @Test func segmentsAreAnnouncedInOrderAcrossSeveralEndpoints() async throws {
        let final = LengthNamingFinal()
        let (engine, audio) = makeEngine(final: final)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        var expected = 0
        for _ in 0..<3 {
            audio.push(seconds: 0.6)
            expected += 9_600
            for _ in 0..<100 where await engine.bufferedSampleCount() < expected {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            await engine.closeSegmentAtEndpoint()
        }
        audio.push(seconds: 0.6)
        expected += 9_600
        for _ in 0..<100 where await engine.bufferedSampleCount() < expected {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = try await engine.stop()
        await log.waitForClosed(4)

        #expect(log.opened.map(\.index) == [0, 1, 2, 3])
        #expect(log.closed.map(\.segment.index) == [0, 1, 2, 3])
        #expect(log.closed.map(\.reason) == [.endpoint, .endpoint, .endpoint, .keyRelease])
        #expect(log.closed.map(\.stability) == [.committed, .committed, .committed, .final])
        #expect(final.receivedLengths == [9_600, 9_600, 9_600, 9_600])
        // One session throughout: the same UUID, distinct indices.
        #expect(Set(log.closed.map(\.segment.sessionID)).count == 1)
    }

    /// Preview text belongs to the open segment and is `.provisional` — the pill's to rewrite,
    /// nobody's to deliver.
    @Test func previewSpansAreProvisionalAndCarryTheOpenSegment() async throws {
        let audio = SegmentAudioSource()
        let engine = RealEngine(audio: audio,
                                provider: StaticRecognizerProvider(final: LengthNamingFinal(),
                                                                   preview: CountingPreview()))
        engine.previewBlock = 0.05
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        for _ in 0..<100 where log.previews.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = try await engine.stop()

        let preview = try #require(log.previews.first)
        #expect(preview.segment.index == 0)
        #expect(preview.spans.map(\.isProvisional) == [true])
        #expect(Set(preview.spans.map(\.stability)) == [.provisional])
    }

    /// Cancel abandons the open segment instead of leaving a consumer waiting for a commit that
    /// is never coming, and commits nothing.
    @Test func cancelAbandonsTheOpenSegment() async throws {
        let final = LengthNamingFinal()
        let (engine, audio) = makeEngine(final: final)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        await engine.cancel()
        await log.waitForClosed(1)

        #expect(log.closed.map(\.reason) == [.cancelled])
        #expect(log.closed.flatMap(\.spans).isEmpty)
        #expect(final.receivedLengths.isEmpty)
        #expect(engine.segments.currentSessionID == nil)
    }

    /// A second dictation is a different session, and its segments count from 0 again — so an
    /// old session's `SegmentID` can never be mistaken for a new one's.
    @Test func eachSessionGetsItsOwnIdentity() async throws {
        let final = LengthNamingFinal()
        let (engine, audio) = makeEngine(final: final)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        for _ in 0..<100 where await engine.bufferedSampleCount() < 16_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = try await engine.stop()
        let firstSession = log.closed.first?.segment.sessionID

        try await engine.start(prewarm: true)
        audio.push(seconds: 1.0)
        for _ in 0..<100 where await engine.bufferedSampleCount() < 16_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        _ = try await engine.stop()
        await log.waitForClosed(2)

        #expect(log.closed.count == 2)
        #expect(log.closed.map(\.segment.index) == [0, 0])
        #expect(firstSession != log.closed[1].segment.sessionID)
        #expect(log.closed[1].segment.isSameSession(as: log.closed[0].segment) == false)
    }
}

/// A preview recognizer that always has something to say, so the preview path is reachable
/// without a model.
final class CountingPreview: PreviewRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var fed = 0
    func feed(_ samples: [Float]) async throws -> String {
        lock.withLock { fed += samples.count; return "preview \(fed)" }
    }
    func reset() async { lock.withLock { fed = 0 } }
}

// MARK: - Bounds

@Suite("R2.2 bounds")
struct SegmentBoundsTests {
    /// The backlog is two deep. The third segment in flight commits its pass-1 text rather than
    /// queueing more work behind the two already waiting (V3 §5.3) — and it still lands in order.
    @Test func fullBacklogCommitsPassOne() async throws {
        let final = LengthNamingFinal()
        let (engine, audio) = makeEngine(final: final, bounds: .init(maxPendingSegments: 2))
        let gate = RefinerGate()
        engine.refiner = GatedRefiner(gate: gate)
        engine.refinementDeadline = .seconds(30)
        let log = SegmentLog(engine)
        defer { log.stop() }

        try await engine.start(prewarm: true)
        // Three endpoint closures, each started before the previous one's refinement can finish:
        // the gate holds every arrival, so all three are genuinely in flight together.
        var closes: [Task<SegmentID?, Never>] = []
        var expected = 0
        for _ in 0..<3 {
            audio.push(seconds: 0.5)
            expected += 8_000
            for _ in 0..<100 where await engine.bufferedSampleCount() < expected {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            closes.append(Task { await engine.closeSegmentAtEndpoint() })
            // Let this close claim its index and reach the refiner before the next one starts, so
            // the bound falls on the third segment rather than an arbitrary one.
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        // Segment 2 was refused a backlog slot, so it is already committed; 0 and 1 are parked.
        #expect(engine.segments.isBacklogFull)
        await gate.open()
        for task in closes { _ = await task.value }
        await log.waitForClosed(3)

        #expect(log.closed.count >= 3)
        let first3 = Array(log.closed.prefix(3))
        // Ordering survives the bound: still 0, 1, 2, in spoken order.
        #expect(first3.map(\.segment.index) == [0, 1, 2])
        #expect(first3.map(\.reason) == [.endpoint, .endpoint, .backlogBound])
        #expect(Set(first3.map(\.stability)) == [.committed])
        // The two that got a slot were refined; the bounded one kept pass-1.
        #expect(first3[0].spans.map(\.text) == ["pass2-8000"])
        #expect(first3[1].spans.map(\.text) == ["pass2-8000"])
        #expect(first3[2].spans.map(\.text) == ["pass1-8000"])
        // Two refinements ran, not three — the bound stopped work, it did not just relabel it.
        let arrivals = await gate.arrivals
        #expect(arrivals == 2)
        await engine.cancel()
    }

    /// The ring buffer is bounded: the oldest audio is dropped, and the newest — the words being
    /// spoken now — is what survives.
    @Test func ringBufferIsBounded() async throws {
        let final = LengthNamingFinal()
        // 1 s is the floor `Bounds` allows; anything smaller is clamped up to it.
        let (engine, audio) = makeEngine(final: final, bounds: .init(maxBufferedSeconds: 1))
        try await engine.start(prewarm: true)

        for _ in 0..<4 { audio.push(seconds: 0.5) }
        for _ in 0..<100 where await engine.bufferedSampleCount() < 16_000 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        // 2.0 s pushed, 1.0 s kept — and it is the *last* second, so the final pass sees the words
        // most recently spoken rather than the ones the user has already moved past.
        let buffered = await engine.bufferedSampleCount()
        #expect(buffered == 16_000)
        _ = try await engine.stop()
        #expect(final.receivedLengths == [16_000])
    }

    /// `Bounds` refuses a backlog of zero — a bound that admits nothing would commit pass-1 for
    /// every segment and quietly disable refinement altogether.
    @Test func boundsAreClamped() {
        #expect(SegmentTracker.Bounds(maxPendingSegments: 0).maxPendingSegments == 1)
        #expect(SegmentTracker.Bounds(maxPendingSegments: -5).maxPendingSegments == 1)
        #expect(SegmentTracker.Bounds(maxBufferedSeconds: 0).maxBufferedSeconds == 1)
        #expect(SegmentTracker.Bounds().maxPendingSegments == 2)
    }
}

// MARK: - Identity, ordering and staleness

@Suite("R2.2 segment identity and ordering")
struct SegmentTrackerTests {
    @Test func commitsReleaseInIndexOrderEvenWhenTheyArriveBackwards() throws {
        let tracker = SegmentTracker()
        let s0 = tracker.beginSession()
        _ = tracker.closeOpenSegment(openNext: true)   // opens 1
        _ = tracker.closeOpenSegment(openNext: true)   // opens 2
        let s1 = s0.next
        let s2 = s1.next

        // Segment 2 finishes first: accepted, but not deliverable yet.
        #expect(tracker.commit(s2, spans: [span("c")]) == .released([]))
        #expect(tracker.lastCommittedSegment == nil)
        // Segment 1 next: still waiting on 0.
        #expect(tracker.commit(s1, spans: [span("b")]) == .released([]))
        // Segment 0 lands and the whole run drains, in order.
        let outcome = tracker.commit(s0, spans: [span("a")])
        guard case .released(let ready) = outcome else { Issue.record("expected a release"); return }
        #expect(ready.map(\.segment.index) == [0, 1, 2])
        #expect(ready.flatMap { $0.spans.map(\.text) } == ["a", "b", "c"])
        #expect(tracker.lastCommittedSegment == s2)
    }

    @Test func aResultFromAnotherSessionIsRefused() throws {
        let tracker = SegmentTracker()
        let mine = tracker.beginSession()
        let foreign = SegmentID(sessionID: UUID(), index: 0)
        #expect(tracker.rejection(for: foreign) == .foreignSession)
        #expect(tracker.commit(foreign, spans: [span("x")]) == .rejected(.foreignSession))
        // The foreign result changed nothing: this session's own segment still commits.
        #expect(tracker.commit(mine, spans: [span("mine")]) == .released([(mine, [span("mine")])]))
    }

    /// The point of `isSameSession(as:)` / `precedes(_:)` over a raw `<`: `SegmentID`'s
    /// `Comparable` tiebreaks across sessions on the UUID string, which means a foreign result
    /// can compare as "newer" *or* "older" purely by luck of the UUID. Both must be refused as
    /// foreign, never accepted and never mistaken for stale.
    @Test func crossSessionOrderIsNeverConsulted() throws {
        // A UUID that sorts before the session's, and one that sorts after.
        let tracker = SegmentTracker()
        let mine = tracker.beginSession()
        _ = tracker.commit(mine, spans: [span("first")])

        var lower: UUID?
        var higher: UUID?
        for _ in 0..<500 where lower == nil || higher == nil {
            let candidate = UUID()
            guard candidate != mine.sessionID else { continue }
            if candidate.uuidString < mine.sessionID.uuidString { lower = lower ?? candidate }
            else { higher = higher ?? candidate }
        }
        let below = try #require(lower)
        let above = try #require(higher)

        // Raw `<` would call one of these "newer than the last committed" and let it through.
        #expect(SegmentID(sessionID: below, index: 99).precedes(mine) == nil)
        #expect(SegmentID(sessionID: above, index: 99).precedes(mine) == nil)
        #expect(tracker.rejection(for: SegmentID(sessionID: below, index: 99)) == .foreignSession)
        #expect(tracker.rejection(for: SegmentID(sessionID: above, index: 99)) == .foreignSession)
    }

    @Test func aResultOlderThanTheLastCommittedIsRefused() throws {
        let tracker = SegmentTracker()
        let s0 = tracker.beginSession()
        _ = tracker.closeOpenSegment(openNext: true)
        let s1 = s0.next
        _ = tracker.commit(s0, spans: [span("a")])
        _ = tracker.commit(s1, spans: [span("b")])

        // A late second pass for a segment that already landed. Committed text is never rewritten.
        #expect(tracker.rejection(for: s0) == .alreadyCommitted)
        #expect(tracker.rejection(for: s1) == .alreadyCommitted)
        #expect(tracker.commit(s0, spans: [span("a-refined")]) == .rejected(.alreadyCommitted))
        #expect(tracker.lastCommittedSegment == s1)
    }

    @Test func unopenedAndSessionlessSegmentsAreRefused() throws {
        let tracker = SegmentTracker()
        let s0 = tracker.beginSession()
        // Index 4 was never opened; only 0 exists.
        #expect(tracker.rejection(for: SegmentID(sessionID: s0.sessionID, index: 4)) == .unknownSegment)
        #expect(tracker.rejection(for: SegmentID(sessionID: s0.sessionID, index: -1)) == .unknownSegment)
        tracker.endSession()
        #expect(tracker.rejection(for: s0) == .noSession)
        #expect(tracker.commit(s0, spans: [span("late")]) == .rejected(.noSession))
    }

    @Test func theBacklogAdmitsExactlyTwo() throws {
        let tracker = SegmentTracker(bounds: .init(maxPendingSegments: 2))
        let s0 = tracker.beginSession()
        _ = tracker.closeOpenSegment(openNext: true)
        _ = tracker.closeOpenSegment(openNext: true)
        let s1 = s0.next
        let s2 = s1.next

        #expect(tracker.enqueuePending(s0))
        #expect(tracker.enqueuePending(s1))
        #expect(tracker.isBacklogFull)
        #expect(tracker.enqueuePending(s2) == false)
        // Re-asking for a slot already held is not a second slot.
        #expect(tracker.enqueuePending(s0))
        #expect(tracker.pendingCount == 2)
        // Committing one frees its slot.
        _ = tracker.commit(s0, spans: [span("a")])
        #expect(tracker.pendingCount == 1)
        #expect(tracker.enqueuePending(s2))
    }

    @Test func closingWithoutOpeningNextEndsTheRun() throws {
        let tracker = SegmentTracker()
        let s0 = tracker.beginSession()
        let closure = try #require(tracker.closeOpenSegment(openNext: false))
        #expect(closure.closed == s0)
        #expect(closure.opened == nil)
        #expect(tracker.openSegment == nil)
        #expect(tracker.closeOpenSegment(openNext: false) == nil)
    }
}

private func span(_ text: String) -> TranscriptSpan {
    TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...1, provenance: [.asr])
}
