import Foundation
import Testing
import Shared
@testable import Engine

@Suite("P1.5.1 T1 — dual-path runner")
struct ReconcileRunnerTests {
    @Test func runsBothPassesConcurrentlyAndReportsTiming() async throws {
        let preview = ScriptedPreviewRecognizer(texts: ["send", "send it", "send it to", "send it to cotari"]); preview.delay = 0.1
        let final = ScriptedFinalRecognizer(spans: [sp("send", 0...0.2), sp("it", 0.2...0.4), sp("to", 0.4...0.5), sp("Kothari", 0.5...0.64)]); final.delay = 0.4
        let runner = DualPathRunner(preview: preview, final: final, blockSeconds: 0.16)
        let box = TimingBox(); runner.onTiming = { box.set($0) }
        var texts: [String] = []; let lock = NSLock()
        runner.onPreviewText = { t in lock.withLock { texts.append(t) } }
        let r = try await runner.run([Float](repeating: 0, count: 16_000 * 64 / 100))  // 0.64 s → 4 blocks
        #expect(r.preview.map(\.text) == ["send", "it", "to", "cotari"] && r.final.map(\.text) == ["send", "it", "to", "Kothari"])
        #expect(r.timing.previewFeeds == 4 && abs(r.timing.audioSeconds - 0.64) < 1e-6)
        #expect(r.timing.finalRealTimeFactor > 0)
        #expect(box.get() == r.timing && lock.withLock { texts } == ["send", "send it", "send it to", "send it to cotari"])
        // Sequential would be previewWall + finalWall (≈ 0.8 s); concurrent overlaps them. Wall-clock
        // overlap depends on the cooperative pool having a free thread, which a parallel test run
        // (ASR model inference in sibling suites) can starve — so retry a few times and require
        // that at least one run demonstrates the overlap.
        var timings = [r.timing]
        for _ in 0..<3 where !timings.contains(where: overlapped) { timings.append(try await runner.run([Float](repeating: 0, count: 16_000 * 64 / 100)).timing) }
        #expect(timings.contains(where: overlapped), "no run overlapped: \(timings)")
    }

    private func overlapped(_ t: DualPathTiming) -> Bool {
        t.totalWall < t.previewWall + t.finalWall - 0.05 && t.overlap > 0.1 && t.contentionRatio > 0.3
    }

    @Test func finalFailurePropagates() async {
        struct Boom: Error {}
        final class Failing: FinalRecognizer, @unchecked Sendable { let name = "f"; func recognize(_ s: [Float]) async throws -> [TranscriptSpan] { throw Boom() } }
        let runner = DualPathRunner(preview: ScriptedPreviewRecognizer(texts: ["x"]), final: Failing())
        await #expect(throws: Boom.self) { try await runner.run([Float](repeating: 0, count: 1600)) }
    }

    final class TimingBox: @unchecked Sendable {
        private let lock = NSLock(); private var t: DualPathTiming?
        func set(_ v: DualPathTiming) { lock.withLock { t = v } }
        func get() -> DualPathTiming? { lock.withLock { t } }
    }
}
