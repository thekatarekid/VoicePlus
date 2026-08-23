import Foundation
import Shared

/// One benchmark configuration: which engine/transcriber, which stages, which flags, which suites.
public struct LabConfig: Codable, Equatable, Sendable {
    public var name: String
    public var transcriber: String
    public var stages: [String]
    public var flags: [String: Bool]
    public var suites: [String]
    public var register: Utterance.Register

    public init(name: String, transcriber: String, stages: [String] = [], flags: [String: Bool] = [:],
                suites: [String] = FixtureSuite.defaultNames, register: Utterance.Register = .unknown) {
        self.name = name
        self.transcriber = transcriber
        self.stages = stages
        self.flags = flags
        self.suites = suites
        self.register = register
    }
}

public struct ItemScore: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var suite: String
    public var file: String
    public var reference: String
    public var hypothesis: String
    public var wer: Double
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var entitiesExpected: [String]
    public var entitiesFound: [String]
    public var falseEntities: [String]
    public var asrLatencyMs: Double
    public var stageLatencyMs: [String: Double]
    public var meanConfidence: Double
    public var needsRepairCount: Int
    /// True when the final text matches the reference after normalisation — the harness's
    /// prediction that the user would not have to edit it.
    public var predictedZeroEdit: Bool

    public var totalLatencyMs: Double { asrLatencyMs + stageLatencyMs.values.reduce(0, +) }
}

public struct SuiteMetrics: Codable, Equatable, Sendable {
    public var suite: String
    public var items: Int
    public var wer: Double
    public var entityRecall: Double?
    public var falseEntityRate: Double
    public var zeroEditRate: Double
    public var latencyP50Ms: Double
    public var latencyP95Ms: Double
}

public struct LabReport: Codable, Equatable, Sendable {
    public var config: LabConfig
    public var startedAt: Date
    public var finishedAt: Date
    public var hardware: String
    public var thermalStates: [String]
    public var items: [ItemScore]
    public var suites: [SuiteMetrics]
    public var overall: SuiteMetrics
    /// Mean per-stage latency across all items, in stage order (the waterfall).
    public var stageLatencyMs: [String: Double]

    public var scoreSignature: [ItemScore] {
        items.map { var c = $0; c.asrLatencyMs = 0; c.stageLatencyMs = [:]; return c }
    }
}

/// Runs suites through a transcriber + stage chain and scores them. Deterministic given a
/// deterministic transcriber and stages (latency is the only wall-clock dependent field).
public struct LabRunner: Sendable {
    public var fixturesDirectory: URL?
    public var clock: @Sendable () -> TimeInterval
    public var hardware: String
    public var thermal: @Sendable () -> ProcessInfo.ThermalState
    public var progress: (@Sendable (Int, Int, ItemScore) -> Void)?

    public init(fixturesDirectory: URL? = AppPaths.fixturesDirectory(),
                clock: @escaping @Sendable () -> TimeInterval = LabClock.now,
                hardware: String = LabRunner.hardwareDescription(),
                thermal: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
                progress: (@Sendable (Int, Int, ItemScore) -> Void)? = nil) {
        self.fixturesDirectory = fixturesDirectory
        self.clock = clock
        self.hardware = hardware
        self.thermal = thermal
        self.progress = progress
    }

    public static func hardwareDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let cpu = String(cString: buf)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(cpu.isEmpty ? "unknown-cpu" : cpu) / \(os) / \(ProcessInfo.processInfo.physicalMemory / (1 << 30)) GB"
    }

    public func loadSuites(_ config: LabConfig) throws -> [FixtureSuite] {
        try config.suites.map { try FixtureSuite.load(named: $0, fixturesDirectory: fixturesDirectory) }
    }

    public func run(config: LabConfig, transcriber: any FixtureTranscriber, stages: [any PipelineStage]) async throws -> LabReport {
        let suites = try loadSuites(config)
        let startedAt = Date()
        var items: [ItemScore] = []
        var thermals: Set<String> = []
        let total = suites.reduce(0) { $0 + $1.items.count }
        let context = StageContext(register: config.register, flags: config.flags)

        for suite in suites {
            for item in suite.items {
                let result = try await transcriber.transcribe(audioURL: suite.audioURL(for: item))
                var spans = result.spans
                var stageLatency: [String: Double] = [:]
                for stage in stages {
                    let t0 = clock()
                    spans = try await stage.process(spans, context: context)
                    stageLatency[stage.id.rawValue, default: 0] += (clock() - t0) * 1000
                }
                let score = Self.score(item: item, spans: spans, asrLatencyMs: result.latencyMs, stageLatencyMs: stageLatency)
                items.append(score)
                thermals.insert(Self.thermalName(thermal()))
                progress?(items.count, total, score)
            }
        }

        let perSuite = suites.map { suite in Self.aggregate(suite.name, items.filter { $0.suite == suite.name }) }
        var stageMeans: [String: Double] = [:]
        if !items.isEmpty {
            for stage in stages {
                let key = stage.id.rawValue
                stageMeans[key] = items.reduce(0) { $0 + ($1.stageLatencyMs[key] ?? 0) } / Double(items.count)
            }
        }
        return LabReport(config: config, startedAt: startedAt, finishedAt: Date(), hardware: hardware,
                         thermalStates: thermals.sorted(), items: items, suites: perSuite,
                         overall: Self.aggregate("all", items), stageLatencyMs: stageMeans)
    }

    public static func score(item: FixtureItem, spans: [TranscriptSpan], asrLatencyMs: Double,
                             stageLatencyMs: [String: Double]) -> ItemScore {
        let hypothesis = spans.joinedText
        let wer = WERScorer.score(reference: item.transcript, hypothesis: hypothesis)
        let ent = EntityScorer.score(reference: item.transcript, hypothesis: hypothesis, entities: item.entities)
        let meanConf = spans.isEmpty ? 0 : spans.reduce(0.0) { $0 + Double($1.confidence) } / Double(spans.count)
        return ItemScore(
            id: item.id, suite: item.suite, file: item.file, reference: item.transcript, hypothesis: hypothesis,
            wer: wer.wer, substitutions: wer.substitutions, deletions: wer.deletions, insertions: wer.insertions,
            entitiesExpected: ent.expected, entitiesFound: ent.found, falseEntities: ent.falseEntities,
            asrLatencyMs: asrLatencyMs, stageLatencyMs: stageLatencyMs, meanConfidence: meanConf,
            needsRepairCount: spans.filter(\.needsRepair).count,
            predictedZeroEdit: wer.errors == 0 && !spans.contains(where: \.needsRepair)
        )
    }

    /// Corpus-level WER (total errors / total reference words), micro-averaged entity recall.
    public static func aggregate(_ name: String, _ items: [ItemScore]) -> SuiteMetrics {
        guard !items.isEmpty else {
            return SuiteMetrics(suite: name, items: 0, wer: 0, entityRecall: nil, falseEntityRate: 0, zeroEditRate: 0,
                                latencyP50Ms: 0, latencyP95Ms: 0)
        }
        let refWords = items.reduce(0) { $0 + TextNormalizer.words($1.reference).count }
        let errors = items.reduce(0) { $0 + $1.substitutions + $1.deletions + $1.insertions }
        let expected = items.reduce(0) { $0 + $1.entitiesExpected.count }
        let found = items.reduce(0) { $0 + $1.entitiesFound.count }
        let hypWords = items.reduce(0) { $0 + TextNormalizer.rawTokens($1.hypothesis).count }
        let falseCount = items.reduce(0) { $0 + $1.falseEntities.count }
        let latencies = items.map(\.totalLatencyMs)
        return SuiteMetrics(
            suite: name, items: items.count,
            wer: refWords == 0 ? 0 : Double(errors) / Double(refWords),
            entityRecall: expected == 0 ? nil : Double(found) / Double(expected),
            falseEntityRate: hypWords == 0 ? 0 : Double(falseCount) / Double(hypWords),
            zeroEditRate: Double(items.filter(\.predictedZeroEdit).count) / Double(items.count),
            latencyP50Ms: Percentile.value(latencies, p: 50), latencyP95Ms: Percentile.value(latencies, p: 95)
        )
    }

    public static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: Persistence

public extension LabReport {
    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func record() throws -> LabRunRecord {
        let cfg = String(decoding: try Self.jsonEncoder.encode(config), as: UTF8.self)
        var metrics: [String: Double] = [
            "wer": overall.wer, "falseEntityRate": overall.falseEntityRate, "zeroEditRate": overall.zeroEditRate,
            "latencyP50Ms": overall.latencyP50Ms, "latencyP95Ms": overall.latencyP95Ms, "items": Double(overall.items),
        ]
        if let r = overall.entityRecall { metrics["entityRecall"] = r }
        for s in suites { metrics["\(s.suite).wer"] = s.wer; if let r = s.entityRecall { metrics["\(s.suite).entityRecall"] = r } }
        for (k, v) in stageLatencyMs { metrics["stage.\(k).ms"] = v }
        let m = String(decoding: try Self.jsonEncoder.encode(metrics), as: UTF8.self)
        return LabRunRecord(startedAt: startedAt, finishedAt: finishedAt, name: config.name, configJSON: cfg,
                            metricsJSON: m, hardware: hardware)
    }

    @discardableResult
    func persist(to db: AppDatabase) throws -> LabRunRecord { try db.insert(try record()) }
}
