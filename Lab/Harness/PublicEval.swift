import Foundation
import Shared

// V5 V1 — public-set replay harness. Manifest in, per-item outputs from an `EvalBackend`, metrics
// broken down by condition tag, Δ vs the published baseline (V2), JSON to `Lab/results`.

/// What a backend returns for one item. Backends that time themselves (e.g. a replayed
/// hypothesis file from a real-model run) set `latencyMs` / `peakRSSBytes`; otherwise the runner
/// measures wall-clock latency and this process's peak RSS.
public struct EvalOutput: Codable, Equatable, Sendable {
    public var text: String?
    public var turns: [SpeakerTurn]?
    public var label: String?
    public var latencyMs: Double?
    public var peakRSSBytes: UInt64?
    /// V4 — duration of the item's audio (duration segment classes).
    public var audioSeconds: Double?
    /// V4 — extra per-item numbers a backend measured (e.g. `snrDB` from the mic-quality analyzer).
    public var metrics: [String: Double]?

    public init(text: String? = nil, turns: [SpeakerTurn]? = nil, label: String? = nil,
                latencyMs: Double? = nil, peakRSSBytes: UInt64? = nil, audioSeconds: Double? = nil, metrics: [String: Double]? = nil) {
        self.text = text; self.turns = turns; self.label = label; self.latencyMs = latencyMs; self.peakRSSBytes = peakRSSBytes
        self.audioSeconds = audioSeconds; self.metrics = metrics
    }
}

/// Anything that can be evaluated: an ASR model (audio → text), a cleanup model (input → text),
/// a diarizer (audio → turns), a decision model (text → label). The app registers real models
/// (`LabWiring`); Lab ships mocks and the replay backend.
public protocol EvalBackend: Sendable {
    var modelID: String { get }
    func evaluate(_ item: EvalItem, audioURL: URL?, stage: EvalStage) async throws -> EvalOutput
}

/// Mock: returns the reference (or a transform of it). WER 0 unless transformed.
public struct ScriptedEvalBackend: EvalBackend {
    public var modelID: String
    public var respond: @Sendable (EvalItem, EvalStage) -> EvalOutput
    public init(modelID: String, respond: @escaping @Sendable (EvalItem, EvalStage) -> EvalOutput = { item, _ in
        EvalOutput(text: item.reference, turns: item.segments, label: item.label)
    }) {
        self.modelID = modelID; self.respond = respond
    }
    public func evaluate(_ item: EvalItem, audioURL: URL?, stage: EvalStage) async throws -> EvalOutput { respond(item, stage) }
}

/// Hypotheses produced elsewhere (e.g. `Tests/EngineTests/EvalPublicSetTests` running the real
/// model, which the dependency-free Lab target cannot link) replayed through the same scoring.
public struct ReplayBackend: EvalBackend {
    public struct File: Codable, Equatable, Sendable {
        public var model: String
        public var set: String
        public var peakRSSBytes: UInt64?
        public var items: [String: EvalOutput]
        public init(model: String, set: String, peakRSSBytes: UInt64? = nil, items: [String: EvalOutput]) {
            self.model = model; self.set = set; self.peakRSSBytes = peakRSSBytes; self.items = items
        }
    }
    public var modelID: String
    public var file: File

    public init(file: File) { self.file = file; self.modelID = file.model }
    public init(url: URL) throws { try self.init(file: JSONDecoder().decode(File.self, from: Data(contentsOf: url))) }

    public func evaluate(_ item: EvalItem, audioURL: URL?, stage: EvalStage) async throws -> EvalOutput {
        guard var out = file.items[item.id] else { throw EvalError.backendUnavailable("\(modelID): no hypothesis for \(item.id)") }
        if out.peakRSSBytes == nil { out.peakRSSBytes = file.peakRSSBytes }
        return out
    }
}

/// Aggregated metrics for a set or one condition. Rates are percentages.
public struct EvalSummary: Codable, Equatable, Sendable {
    public var items: Int
    public var wer: Double?
    public var cer: Double?
    public var referenceWords: Int?
    public var entityRecall: Double?
    public var restraint: Double?
    public var edit: Double?
    public var damage: Double?
    public var der: Double?
    public var accuracy: Double?
    public var latencyP50Ms: Double
    public var latencyP95Ms: Double
    public var peakRSSMB: Double

    public init(items: Int, latencyP50Ms: Double = 0, latencyP95Ms: Double = 0, peakRSSMB: Double = 0) {
        self.items = items; self.latencyP50Ms = latencyP50Ms; self.latencyP95Ms = latencyP95Ms; self.peakRSSMB = peakRSSMB
    }
}

public struct EvalItemResult: Codable, Equatable, Sendable {
    public var id: String
    public var tags: [String]
    public var hypothesis: String?
    public var label: String?
    public var errors: Int?
    public var referenceWords: Int?
    public var latencyMs: Double
}

public struct BaselineComparison: Codable, Equatable, Sendable {
    public var metric: String
    public var published: Double
    public var measured: Double
    public var delta: Double
    public var source: String
    public var gateDelta: Double
    public var gatePassed: Bool
}

public struct EvalReport: Codable, Equatable, Sendable {
    public var set: String
    public var stage: EvalStage
    public var model: String
    public var date: String
    public var normalizer: OpenASRNormalizer.Mode
    public var hardware: String
    public var summary: EvalSummary
    public var byCondition: [String: EvalSummary]
    public var baseline: BaselineComparison?
    public var items: [EvalItemResult]
    public var notes: [String]
}

public struct PublicEval: Sendable {
    public var paths: EvalPaths
    public var clock: @Sendable () -> TimeInterval
    public var hardware: String
    public var now: @Sendable () -> Date

    public init(paths: EvalPaths = EvalPaths(), clock: @escaping @Sendable () -> TimeInterval = LabClock.now,
                hardware: String = LabRunner.hardwareDescription(), now: @escaping @Sendable () -> Date = Date.init) {
        self.paths = paths; self.clock = clock; self.hardware = hardware; self.now = now
    }

    public struct Options: Sendable {
        public var stage: EvalStage = .asr
        public var mode: OpenASRNormalizer.Mode = .normalized
        public var limit: Int?
        public var tags: [String] = []
        public init(stage: EvalStage = .asr, mode: OpenASRNormalizer.Mode = .normalized, limit: Int? = nil, tags: [String] = []) {
            self.stage = stage; self.mode = mode; self.limit = limit; self.tags = tags
        }
    }

    public func run(manifest: EvalManifest, backend: any EvalBackend, options: Options = Options(),
                    baselines: Baselines? = nil) async throws -> EvalReport {
        var items = manifest.items
        if !options.tags.isEmpty { items = items.filter { !Set($0.tags).isDisjoint(with: options.tags) } }
        if let limit = options.limit { items = Array(items.prefix(limit)) }

        var scored: [(EvalItem, EvalOutput, Double)] = []
        for item in items {
            var url: URL?
            if options.stage == .asr || options.stage == .diar {
                url = paths.audioURL(item, manifest: manifest)
                if let u = url, !(backend is ReplayBackend), !FileManager.default.fileExists(atPath: u.path) {
                    throw EvalError.audioMissing(u.path)
                }
            }
            let t0 = clock()
            let out = try await backend.evaluate(item, audioURL: url, stage: options.stage)
            scored.append((item, out, out.latencyMs ?? (clock() - t0) * 1000))
        }

        let peak = max(scored.compactMap { $0.1.peakRSSBytes }.max() ?? 0, EvalMetrics.peakRSSBytes())
        var notes: [String] = []
        if options.stage == .diar { notes.append("DER: 10 ms frames, no collar, overlap scored, greedy speaker map") }
        if options.limit != nil { notes.append("subset: first \(items.count) of \(manifest.items.count) items") }
        let summary = summarize(scored, stage: options.stage, mode: options.mode, peakRSS: peak)
        var byCondition: [String: EvalSummary] = [:]
        for tag in Set(scored.flatMap { $0.0.tags }) {
            byCondition[tag] = summarize(scored.filter { $0.0.tags.contains(tag) }, stage: options.stage, mode: options.mode, peakRSS: peak)
        }
        let results = scored.map { item, out, latency -> EvalItemResult in
            let w = (options.stage == .asr) ? EvalMetrics.wer(reference: item.reference, hypothesis: out.text ?? "", mode: options.mode) : nil
            return EvalItemResult(id: item.id, tags: item.tags, hypothesis: out.text, label: out.label,
                                  errors: w?.errors, referenceWords: w?.referenceWords, latencyMs: latency)
        }
        var report = EvalReport(set: manifest.set, stage: options.stage, model: backend.modelID,
                                date: Self.day(now()), normalizer: options.mode, hardware: hardware, summary: summary,
                                byCondition: byCondition, baseline: nil, items: results, notes: notes)
        if let baselines { report.baseline = baselines.compare(report) }
        return report
    }

    func summarize(_ rows: [(EvalItem, EvalOutput, Double)], stage: EvalStage, mode: OpenASRNormalizer.Mode,
                   peakRSS: UInt64) -> EvalSummary {
        let lat = rows.map(\.2)
        var s = EvalSummary(items: rows.count, latencyP50Ms: Percentile.value(lat, p: 50), latencyP95Ms: Percentile.value(lat, p: 95),
                            peakRSSMB: Double(peakRSS) / 1_048_576)
        switch stage {
        case .asr:
            var errors = 0, words = 0, cerErr = 0, chars = 0, entExpected = 0, entHit = 0
            for (item, out, _) in rows {
                let w = EvalMetrics.wer(reference: item.reference, hypothesis: out.text ?? "", mode: mode)
                errors += w.errors; words += w.referenceWords
                let c = EvalMetrics.cer(reference: item.reference, hypothesis: out.text ?? "", mode: mode)
                cerErr += c.errors; chars += c.chars
                if let ents = item.entities, !ents.isEmpty {
                    entExpected += ents.count; entHit += EvalMetrics.entityHits(entities: ents, hypothesis: out.text ?? "")
                }
            }
            s.wer = words == 0 ? 0 : 100 * Double(errors) / Double(words)
            s.cer = chars == 0 ? 0 : 100 * Double(cerErr) / Double(chars)
            s.referenceWords = words
            if entExpected > 0 { s.entityRecall = 100 * Double(entHit) / Double(entExpected) }
        case .cleanup:
            let v = rows.map { EvalMetrics.cleanup(input: $0.0.input ?? "", target: $0.0.reference, output: $0.1.text ?? "") }
            let keep = v.filter { !$0.needsEdit }, fix = v.filter(\.needsEdit)
            s.restraint = keep.isEmpty ? nil : 100 * Double(keep.filter(\.restrained).count) / Double(keep.count)
            s.edit = fix.isEmpty ? nil : 100 * Double(fix.filter(\.edited).count) / Double(fix.count)
            s.damage = v.isEmpty ? nil : 100 * Double(v.filter(\.damaged).count) / Double(v.count)
        case .diar:
            var miss = 0.0, fa = 0.0, conf = 0.0, total = 0.0
            for (item, out, _) in rows {
                let d = EvalMetrics.der(reference: item.segments ?? [], hypothesis: out.turns ?? [])
                miss += d.missed; fa += d.falseAlarm; conf += d.confusion; total += d.referenceSpeech
            }
            s.der = total == 0 ? 0 : 100 * (miss + fa + conf) / total
        case .decide:
            let labelled = rows.filter { $0.0.label != nil }
            s.accuracy = labelled.isEmpty ? nil : 100 * Double(labelled.filter { $0.0.label == $0.1.label }.count) / Double(labelled.count)
        }
        return s
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// `Lab/results/<date>-<set>-<model>.json`.
    @discardableResult
    public func write(_ report: EvalReport) throws -> URL {
        try FileManager.default.createDirectory(at: paths.resultsDirectory, withIntermediateDirectories: true)
        let url = paths.resultsDirectory.appendingPathComponent("\(report.date)-\(report.set)-\(report.model).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: url)
        return url
    }

    /// The printed table: overall row, then one row per condition tag.
    public static func table(_ r: EvalReport) -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        var lines = ["# eval — \(r.set) · \(r.stage.rawValue) · \(r.model) · \(r.date) · normaliser \(r.normalizer.rawValue)", ""]
        let head: String, row: (String, EvalSummary) -> String
        switch r.stage {
        case .asr:
            head = "| condition | n | WER % | CER % | entity recall % | p50 ms | p95 ms | peak RSS MB |\n|---|---|---|---|---|---|---|---|"
            row = { "| \($0) | \($1.items) | \(pct($1.wer)) | \(pct($1.cer)) | \(pct($1.entityRecall)) | \(Int($1.latencyP50Ms)) | \(Int($1.latencyP95Ms)) | \(Int($1.peakRSSMB)) |" }
        case .cleanup:
            head = "| condition | n | restraint % | edit % | damage % | p50 ms | p95 ms | peak RSS MB |\n|---|---|---|---|---|---|---|---|"
            row = { "| \($0) | \($1.items) | \(pct($1.restraint)) | \(pct($1.edit)) | \(pct($1.damage)) | \(Int($1.latencyP50Ms)) | \(Int($1.latencyP95Ms)) | \(Int($1.peakRSSMB)) |" }
        case .diar:
            head = "| condition | n | DER % | p50 ms | p95 ms | peak RSS MB |\n|---|---|---|---|---|---|"
            row = { "| \($0) | \($1.items) | \(pct($1.der)) | \(Int($1.latencyP50Ms)) | \(Int($1.latencyP95Ms)) | \(Int($1.peakRSSMB)) |" }
        case .decide:
            head = "| condition | n | accuracy % | p50 ms | p95 ms | peak RSS MB |\n|---|---|---|---|---|---|"
            row = { "| \($0) | \($1.items) | \(pct($1.accuracy)) | \(Int($1.latencyP50Ms)) | \(Int($1.latencyP95Ms)) | \(Int($1.peakRSSMB)) |" }
        }
        lines.append(head)
        lines.append(row("all", r.summary))
        for tag in r.byCondition.keys.sorted() where r.byCondition.count > 1 || tag != "all" { lines.append(row(tag, r.byCondition[tag]!)) }
        if let b = r.baseline {
            lines.append("")
            lines.append(String(format: "baseline %@: published %.2f · measured %.2f · Δ %+.2f (gate +%.2f) %@ — %@",
                                b.metric, b.published, b.measured, b.delta, b.gateDelta, b.gatePassed ? "PASS" : "FAIL", b.source))
        }
        for n in r.notes { lines.append("note: \(n)") }
        return lines.joined(separator: "\n")
    }
}
