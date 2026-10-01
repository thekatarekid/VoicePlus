import Foundation
import Testing
import Shared
@testable import Lab

/// A stage that uppercases known entities when the biasing flag is on (simulates Bet 2) and
/// burns a deterministic "latency" via the injected clock.
struct FakeBiasingStage: PipelineStage {
    let id: StageID = .biasing
    func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        spans.map { span in
            if context.isEnabled(.dualPath), span.text.lowercased() == "anthropic", !span.isLowConfidence {
                return span.rewritten("Anthropic", by: id)
            }
            return span.touched(by: id)
        }
    }
}

struct ThrowingStage: PipelineStage {
    struct Boom: Error {}
    let id: StageID = "boom"
    func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] { throw Boom() }
}

final class FakeClock: @unchecked Sendable {
    var t: TimeInterval = 0
    func now() -> TimeInterval { t += 0.005; return t }
}

@Suite struct HarnessTests {
    static let suites = ["clean", "entity"]

    func runner(clock: FakeClock = FakeClock()) -> LabRunner {
        LabRunner(clock: { clock.now() }, hardware: "test-hw", thermal: { .fair })
    }

    @Test func fixtureSuitesLoad() throws {
        let available = FixtureSuite.available()
        #expect(available.contains("clean") && available.contains("entity") && available.contains("technical"))
        let entity = try FixtureSuite.load(named: "entity")
        #expect(entity.items.count == 10)
        #expect(entity.items.allSatisfy { FileManager.default.fileExists(atPath: entity.audioURL(for: $0).path) })
        #expect(throws: LabError.suiteNotFound("nope")) { try FixtureSuite.load(named: "nope") }
    }

    @Test func perfectTranscriberScoresZeroWER() async throws {
        let config = LabConfig(name: "perfect", transcriber: "perfect", suites: Self.suites)
        let lab = runner()
        let suites = try lab.loadSuites(config)
        let report = try await lab.run(config: config, transcriber: ScriptedTranscriber.perfect(suites: suites), stages: [])
        #expect(report.overall.items == 22)
        #expect(report.overall.wer == 0)
        #expect(report.overall.zeroEditRate == 1)
        #expect(report.overall.entityRecall == 1)
        #expect(report.overall.falseEntityRate == 0)
        #expect(report.suites.map(\.suite) == Self.suites)
        #expect(report.thermalStates == ["fair"])
        #expect(report.hardware == "test-hw")
        #expect(report.overall.latencyP95Ms >= report.overall.latencyP50Ms)
        #expect(report.overall.latencyP50Ms >= 120)
    }

    @Test func harnessIsDeterministic() async throws {
        let config = LabConfig(name: "degraded", transcriber: "degraded", stages: ["biasing"], suites: Self.suites)
        var reports: [LabReport] = []
        for _ in 0..<3 {
            let lab = runner()
            let suites = try lab.loadSuites(config)
            let t = try LabRegistry.mocks.transcriber("degraded", suites: suites)
            reports.append(try await lab.run(config: config, transcriber: t, stages: [FakeBiasingStage()]))
        }
        #expect(reports[0].scoreSignature == reports[1].scoreSignature)
        #expect(reports[1].scoreSignature == reports[2].scoreSignature)
        #expect(reports[0].overall == reports[1].overall)
        #expect(reports[0].overall.wer > 0 && reports[0].overall.wer < 0.5)
        #expect(reports[0].overall.zeroEditRate < 1)
        #expect(abs(reports[0].stageLatencyMs["biasing"]! - 5.0) < 1e-6)
        #expect(reports[0].items.allSatisfy { abs($0.stageLatencyMs["biasing"]! - 5.0) < 1e-6 })
    }

    @Test func flagsReachStagesAndMoveEntityRecall() async throws {
        var t = ScriptedTranscriber(name: "lower", confidence: 0.9)
        let suites = try runner().loadSuites(LabConfig(name: "x", transcriber: "lower", suites: ["entity"]))
        for item in suites[0].items { t.references[item.file] = item.transcript }
        t.transform = { _, ref in ref.replacingOccurrences(of: "Anthropic", with: "anthropic") }
        let on = LabConfig(name: "on", transcriber: "lower", stages: ["biasing"], flags: ["dualPath": true], suites: ["entity"])
        let off = LabConfig(name: "off", transcriber: "lower", stages: ["biasing"], flags: ["dualPath": false], suites: ["entity"])
        let rOn = try await runner().run(config: on, transcriber: t, stages: [FakeBiasingStage()])
        let rOff = try await runner().run(config: off, transcriber: t, stages: [FakeBiasingStage()])
        #expect(rOn.overall.entityRecall == 1)
        #expect(rOff.overall.entityRecall! < 1)
        #expect(rOn.overall.wer == 0 && rOff.overall.wer == 0, "case changes are not WER errors")
        #expect(rOff.items.first { $0.file == "entity_05_daniel.wav" }?.entitiesFound.contains("Anthropic") == false)
        let md = ReportWriter.comparison([rOn, rOff])
        #expect(md.contains("| Entity recall | 100.0% |"))
    }

    @Test func itemScoringFlagsRepairAsNotZeroEdit() {
        let item = FixtureItem(file: "f.wav", transcript: "hello world", suite: "t")
        let spans = [TranscriptSpan(text: "hello", confidence: 0.4, audioRange: 0...1, provenance: [.asr]).flaggedForRepair(by: .gatekeeper),
                     TranscriptSpan(text: "world", confidence: 0.9, audioRange: 1...2, provenance: [.asr])]
        let s = LabRunner.score(item: item, spans: spans, asrLatencyMs: 100, stageLatencyMs: ["gatekeeper": 3])
        #expect(s.wer == 0)
        #expect(s.needsRepairCount == 1)
        #expect(!s.predictedZeroEdit)
        #expect(s.totalLatencyMs == 103)
        #expect(abs(s.meanConfidence - 0.65) < 1e-6)
    }

    @Test func stageErrorsPropagate() async throws {
        let config = LabConfig(name: "x", transcriber: "perfect", suites: ["clean"])
        let lab = runner()
        let t = ScriptedTranscriber.perfect(suites: try lab.loadSuites(config))
        await #expect(throws: ThrowingStage.Boom.self) { try await lab.run(config: config, transcriber: t, stages: [ThrowingStage()]) }
    }

    @Test func reportPersistsAsLabRunRecordAndRoundTripsJSON() async throws {
        let db = try AppDatabase.inMemory()
        let config = LabConfig(name: "persist", transcriber: "degraded", suites: ["entity"])
        let lab = runner()
        let t = try LabRegistry.mocks.transcriber("degraded", suites: try lab.loadSuites(config))
        let report = try await lab.run(config: config, transcriber: t, stages: [])
        let rec = try report.persist(to: db)
        #expect(rec.id != nil)
        let runs = try db.labRuns()
        #expect(runs.count == 1 && runs[0].name == "persist" && runs[0].hardware == "test-hw")
        let metrics = try JSONDecoder().decode([String: Double].self, from: Data(runs[0].metricsJSON.utf8))
        #expect(metrics["wer"] == report.overall.wer)
        #expect(metrics["entity.entityRecall"] == report.suites[0].entityRecall)
        let cfg = try JSONDecoder().decode(LabConfig.self, from: Data(runs[0].configJSON.utf8))
        #expect(cfg == config)

        let json = try ReportWriter.json(report)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(LabReport.self, from: Data(json.utf8))
        #expect(back.items == report.items && back.overall == report.overall)
    }

    @Test func engineAdapterDrivesEngineProtocol() async throws {
        let fixture = TranscriptFixture(name: "t", spans: [
            .init(text: "hello", confidence: 0.9, audioStart: 0, audioEnd: 0.4),
            .init(text: "world", confidence: 0.8, audioStart: 0.4, audioEnd: 0.8),
        ])
        let engine = MockEngine(fixture: fixture, delayScale: 0, prewarmMs: 0)
        let fed = FedBox()
        let clock = FakeClock()
        let t = EngineFixtureTranscriber(name: "mock", engine: engine, clock: { clock.now() }) { url in fed.urls.append(url) }
        let r = try await t.transcribe(audioURL: URL(fileURLWithPath: "/x/a.wav"))
        #expect(r.spans.joinedText == "hello world")
        #expect(fed.urls.map(\.lastPathComponent) == ["a.wav"])
        #expect(r.latencyMs == 5)
        #expect(engine.state == .idle)
    }

    final class FedBox: @unchecked Sendable { var urls: [URL] = [] }
}
