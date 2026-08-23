import Foundation
import Shared

/// Turns cumulative preview snapshots `(audioSeconds, text)` into word spans with approximate
/// audio ranges: a word first seen in the snapshot ending at `t` is attributed to the audio since
/// the previous snapshot. Streaming preview models expose no per-word timing or confidence, so
/// confidence is `unknownConfidence` for every word.
public enum PreviewTimeline {
    public struct Snapshot: Equatable, Sendable {
        public var audioSeconds: TimeInterval
        public var text: String
        public init(audioSeconds: TimeInterval, text: String) { self.audioSeconds = audioSeconds; self.text = text }
    }

    public static func spans(from snapshots: [Snapshot], unknownConfidence: Float = 0.5) -> [TranscriptSpan] {
        var words: [(text: String, range: ClosedRange<TimeInterval>)] = []
        var previous: TimeInterval = 0
        for s in snapshots {
            let parts = s.text.split(separator: " ").map(String.init)
            for (k, w) in parts.enumerated() {
                if k < words.count { words[k].text = w } else { words.append((w, previous...max(previous, s.audioSeconds))) }
            }
            if parts.count < words.count { words.removeLast(words.count - parts.count) }
            previous = s.audioSeconds
        }
        return words.map { TranscriptSpan(text: $0.text, confidence: unknownConfidence, audioRange: $0.range, provenance: [.asr]) }
    }
}

/// T1 — runs the streaming preview and the final recogniser concurrently over the same audio and
/// records timing so the Lab can see ANE contention. `onTiming` is the profiling hook.
public final class DualPathRunner: @unchecked Sendable {
    public let preview: PreviewRecognizer
    public let final: FinalRecognizer
    public var blockSeconds: TimeInterval
    public var onTiming: (@Sendable (DualPathTiming) -> Void)?
    public var onPreviewText: (@Sendable (String) -> Void)?

    public init(preview: PreviewRecognizer, final: FinalRecognizer, blockSeconds: TimeInterval = 0.16) {
        self.preview = preview; self.final = final; self.blockSeconds = blockSeconds
    }

    public func run(_ samples: [Float], sampleRate: Double = 16_000) async throws -> DualPathResult {
        let t0 = Date()
        let block = max(1, Int(blockSeconds * sampleRate))
        let audioSeconds = Double(samples.count) / sampleRate
        async let finalTask: ([TranscriptSpan], TimeInterval, TimeInterval) = {
            let s = Date(); let spans = try await final.recognize(samples); let e = Date()
            return (spans, s.timeIntervalSince(t0), e.timeIntervalSince(t0))
        }()
        async let previewTask: ([PreviewTimeline.Snapshot], Int, TimeInterval, TimeInterval) = {
            await preview.reset()
            var snaps: [PreviewTimeline.Snapshot] = []
            var feeds = 0
            let s = Date()
            var i = 0
            while i < samples.count {
                let end = min(i + block, samples.count)
                let text = try await preview.feed(Array(samples[i..<end]))
                feeds += 1
                if snaps.last?.text != text { onPreviewText?(text) }
                snaps.append(.init(audioSeconds: Double(end) / sampleRate, text: text))
                i = end
            }
            return (snaps, feeds, s.timeIntervalSince(t0), Date().timeIntervalSince(t0))
        }()
        let (fSpans, fStart, fEnd) = try await finalTask
        let (snaps, feeds, pStart, pEnd) = try await previewTask
        let overlap = max(0, min(fEnd, pEnd) - max(fStart, pStart))
        let timing = DualPathTiming(previewWall: pEnd - pStart, finalWall: fEnd - fStart, overlap: overlap,
                                    totalWall: Date().timeIntervalSince(t0), previewFeeds: feeds, audioSeconds: audioSeconds)
        onTiming?(timing)
        return DualPathResult(preview: PreviewTimeline.spans(from: snaps), final: fSpans, timing: timing)
    }
}

/// Facade for the integration layer: gated on `FeatureFlag.dualPath`; when off, nothing runs and
/// the plan is empty (flagged code paths stay in place per Build doc §0 rule 5).
public final class DualPathReconciler: @unchecked Sendable {
    public let runner: DualPathRunner
    public let planner: CorrectionPlanner
    public let applier: CorrectionApplier
    public var flags: [String: Bool]

    public init(runner: DualPathRunner, planner: CorrectionPlanner = CorrectionPlanner(), applier: CorrectionApplier, flags: [String: Bool] = [:]) {
        self.runner = runner; self.planner = planner; self.applier = applier; self.flags = flags
    }

    public var isEnabled: Bool { flags[FeatureFlag.dualPath.id] ?? FeatureFlag.dualPath.defaultOn }

    /// Runs both passes, plans against `readback`, applies, and returns the plan + events.
    /// `fieldOffset` is where the preview text was injected.
    public func reconcile(utteranceID: UUID, samples: [Float], fieldOffset: Int, readback: DocumentReadback) async throws -> (CorrectionPlan, [CorrectionEvent]) {
        guard isEnabled else { return (CorrectionPlan(utteranceID: utteranceID, items: []), []) }
        let result = try await runner.run(samples)
        let plan = planner.plan(utteranceID: utteranceID, preview: result.preview, final: result.final,
                                layout: LandedLayout(fieldOffset: fieldOffset, spans: result.preview), readback: readback)
        return (plan, applier.apply(plan))
    }
}
