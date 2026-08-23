import Foundation
import Testing
import Shared
@testable import Engine

@Suite("P1.5.1 T2 — correction planner + degrade-to-suggestion paths")
struct ReconcilePlannerTests {
    static let preview = [sp("send", 0...0.2, 0.5), sp("it", 0.2...0.4, 0.5), sp("to", 0.4...0.5, 0.5), sp("cotari", 0.5...0.9, 0.5), sp("now", 0.9...1.1, 0.5)]
    static let final = [sp("send", 0...0.2, 0.95), sp("it", 0.2...0.4, 0.95), sp("to", 0.4...0.5, 0.95), sp("Kothari", 0.5...0.9, 0.92), sp("now", 0.9...1.1, 0.95)]
    static let id = UUID()

    static func setup(prefix: String = "Hi. ", document: String? = nil) -> (InMemoryReplaceRangeSink, SinkReadback, LandedLayout) {
        let sink = InMemoryReplaceRangeSink(document: document ?? prefix + preview.joinedText + " tail")
        return (sink, SinkReadback(sink), LandedLayout(fieldOffset: prefix.utf16.count, spans: preview))
    }

    @Test func layoutRangesAreUTF16Offsets() {
        let layout = LandedLayout(fieldOffset: 4, words: ["señor", "it", "x"])
        #expect(layout.range(for: 0..<1) == 4..<9 && layout.range(for: 1..<2) == 10..<12 && layout.range(for: 0..<3) == 4..<14)
        #expect(layout.range(for: 1..<1) == 9..<9 && layout.range(for: 0..<0) == 4..<4)
    }

    @Test func cleanDisagreementIsCorrectedAndLogged() {
        let (sink, readback, layout) = Self.setup()
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: Self.preview, final: Self.final, layout: layout, readback: readback)
        #expect(plan.items.count == 1 && plan.corrections.count == 1)
        #expect(plan.items[0].range == 15..<21 && plan.items[0].expected == "cotari" && plan.items[0].replacement == "Kothari")
        let events = InMemoryCorrectionEventSink(); let log = InMemoryCorrectionSink()
        let out = CorrectionApplier(replaceSink: sink, eventSink: events, correctionLog: log).apply(plan)
        #expect(sink.document == "Hi. send it to Kothari now tail")
        #expect(out.count == 1 && out[0].kind == .applied && out[0].range == 15..<22 && out[0].was == "cotari" && out[0].now == "Kothari")
        #expect(events.events == out && log.records.count == 1 && log.records[0].source == "dualPath")
    }

    @Test func casePunctuationOnlyDifferenceIsDropped() {
        let (_, readback, layout) = Self.setup()
        var f = Self.preview; f[3] = sp("Cotari,", 0.5...0.9, 0.95)
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: Self.preview, final: f, layout: layout, readback: readback)
        #expect(plan.isEmpty)   // the aligner already treats case/punctuation as a match
        let d = Disagreement(previewRange: 3..<4, finalRange: 3..<4, previewText: "cotari", finalText: "Cotari,",
                             previewConfidence: 0.5, finalConfidence: 0.95, audioRange: 0.5...0.9)
        #expect(CorrectionPlanner().decide(d, utteranceID: Self.id, layout: layout, document: readback.currentText()).decision == .drop(reason: .semanticallyEqual))
    }

    @Test func smallConfidenceDeltaIsDropped() {
        let (_, readback, layout) = Self.setup()
        var f = Self.final; f[3] = sp("Kothari", 0.5...0.9, 0.6)
        let plan = CorrectionPlanner(deltaThreshold: 0.2).plan(utteranceID: Self.id, preview: Self.preview, final: f, layout: layout, readback: readback)
        #expect(plan.items.map(\.decision) == [.drop(reason: .confidenceDeltaBelowThreshold)])
    }

    @Test func lowConfidenceFinalDegradesToSuggestion() {
        let (_, readback, layout) = Self.setup()
        var f = Self.final; f[3] = sp("Kothari", 0.5...0.9, 0.45)
        let plan = CorrectionPlanner(deltaThreshold: -1)
            .plan(utteranceID: Self.id, preview: Self.preview, final: f, layout: layout, readback: readback)
        #expect(plan.items.map(\.decision) == [.suggest(reason: .lowFinalConfidence)])
    }

    @Test func userEditedTargetDegradesToSuggestionAndDocumentUntouched() {
        let (sink, readback, layout) = Self.setup(document: "Hi. send it to cotariX now tail")
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: Self.preview, final: Self.final, layout: layout, readback: readback)
        #expect(plan.items.map(\.decision) == [.suggest(reason: .safetyMismatch)] && plan.suggestions.count == 1)
        let events = CorrectionApplier(replaceSink: sink).apply(plan)
        #expect(events.map(\.kind) == [.suggested(.safetyMismatch)] && sink.document == "Hi. send it to cotariX now tail" && sink.requests.isEmpty)
    }

    @Test func editElsewhereInLandedRegionAlsoDegrades() {
        // The target word is intact but an earlier word changed → offsets are untrustworthy.
        let (_, readback, layout) = Self.setup(document: "Hi. sent it to cotari now tail")
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: Self.preview, final: Self.final, layout: layout, readback: readback)
        #expect(plan.items.map(\.decision) == [.suggest(reason: .safetyMismatch)])
    }

    @Test func readbackUnavailableDegradesToSuggestion() {
        let (_, readback, layout) = Self.setup(); readback.unavailable = true
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: Self.preview, final: Self.final, layout: layout, readback: readback)
        #expect(plan.items.map(\.decision) == [.suggest(reason: .readbackUnavailable)])
    }

    @Test func sinkRefusalAtWriteTimeIsReportedAndFreezesRest() {
        let (sink, readback, layout) = Self.setup()
        var f = Self.final; f[0] = sp("Sent", 0...0.2, 0.95)
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: Self.preview, final: f, layout: layout, readback: readback)
        #expect(plan.corrections.count == 2)
        sink.failNext = .mismatch(actual: "zzz")   // document changes between plan and apply
        let events = CorrectionApplier(replaceSink: sink).apply(plan)
        #expect(events.map(\.kind) == [.suggested(.safetyMismatch), .refused])
        #expect(sink.document == "Hi. send it to cotari now tail")
    }

    @Test func insertionAndMultiWordRegionsSpliceCorrectly() {
        let p = [sp("meet", 0...0.2, 0.5), sp("tomorrow", 0.6...0.9, 0.5)]
        let f = [sp("meet", 0...0.2, 0.95), sp("Raj", 0.25...0.5, 0.9), sp("tomorrow", 0.6...0.9, 0.95)]
        let sink = InMemoryReplaceRangeSink(document: "meet tomorrow")
        let plan = CorrectionPlanner().plan(utteranceID: Self.id, preview: p, final: f, layout: LandedLayout(fieldOffset: 0, spans: p), readback: SinkReadback(sink))
        #expect(plan.corrections.count == 1 && plan.items[0].range == 4..<4 && plan.items[0].replacement == " Raj")
        CorrectionApplier(replaceSink: sink).apply(plan)
        #expect(sink.document == "meet Raj tomorrow")
    }

    @Test func flagOffSkipsEverything() async throws {
        let sink = InMemoryReplaceRangeSink(document: "x")
        let runner = DualPathRunner(preview: ScriptedPreviewRecognizer(texts: ["a"]), final: ScriptedFinalRecognizer(spans: [sp("b", 0...0.1)]))
        let r = DualPathReconciler(runner: runner, applier: CorrectionApplier(replaceSink: sink))
        #expect(!r.isEnabled)
        let (plan, events) = try await r.reconcile(utteranceID: Self.id, samples: [Float](repeating: 0, count: 1600), fieldOffset: 0, readback: SinkReadback(sink))
        #expect(plan.isEmpty && events.isEmpty && sink.requests.isEmpty)
        r.flags[FeatureFlag.dualPath.id] = true
        #expect(r.isEnabled)
    }
}

// MARK: - Scripted recognizers

final class ScriptedPreviewRecognizer: PreviewRecognizer, @unchecked Sendable {
    private let lock = NSLock(); private var texts: [String]; private var i = 0
    var delay: TimeInterval = 0
    init(texts: [String]) { self.texts = texts }
    func feed(_ samples: [Float]) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return lock.withLock { defer { i += 1 }; return texts[min(i, texts.count - 1)] }
    }
    func reset() async { lock.withLock { i = 0 } }
}

final class ScriptedFinalRecognizer: FinalRecognizer, @unchecked Sendable {
    let name = "scripted-final"; let spans: [TranscriptSpan]; var delay: TimeInterval = 0
    init(spans: [TranscriptSpan]) { self.spans = spans }
    func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return spans
    }
}
