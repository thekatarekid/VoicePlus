import Foundation

/// V5 V2 — published scores per (model, set) from `Lab/results/baselines.json`, each with its source
/// URL. The harness prints Δ = measured − published and `--gate` fails when Δ exceeds `gateDelta`
/// (default +0.3 WER points). Only regressions fail the gate; being better than published passes.
public struct Baselines: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var model: String
        public var set: String
        /// `wer` (asr, %), `der` (diar, %), `restraint` / `damage` (cleanup, %).
        public var metric: String
        public var value: Double
        public var normalizer: OpenASRNormalizer.Mode?
        public var source: String
        public var note: String?
        public init(model: String, set: String, metric: String = "wer", value: Double, normalizer: OpenASRNormalizer.Mode? = .normalized,
                    source: String, note: String? = nil) {
            self.model = model; self.set = set; self.metric = metric; self.value = value
            self.normalizer = normalizer; self.source = source; self.note = note
        }
    }

    public var gateDelta: Double
    public var entries: [Entry]

    public init(gateDelta: Double = 0.3, entries: [Entry]) { self.gateDelta = gateDelta; self.entries = entries }

    public static func load(from url: URL) throws -> Baselines {
        try JSONDecoder().decode(Baselines.self, from: Data(contentsOf: url))
    }

    /// `<results>/baselines.json` when present.
    public static func load(paths: EvalPaths) -> Baselines? {
        try? load(from: paths.resultsDirectory.appendingPathComponent("baselines.json"))
    }

    public func entry(model: String, set: String, metric: String, normalizer: OpenASRNormalizer.Mode) -> Entry? {
        entries.first { $0.model == model && $0.set == set && $0.metric == metric && ($0.normalizer ?? .normalized) == normalizer }
    }

    static func headline(_ report: EvalReport) -> (String, Double)? {
        switch report.stage {
        case .asr: return report.summary.wer.map { ("wer", $0) }
        case .diar: return report.summary.der.map { ("der", $0) }
        case .cleanup: return report.summary.damage.map { ("damage", $0) }
        case .decide: return nil
        }
    }

    public func compare(_ report: EvalReport) -> BaselineComparison? {
        guard let (metric, measured) = Self.headline(report),
              let e = entry(model: report.model, set: report.set, metric: metric, normalizer: report.normalizer) else { return nil }
        let delta = measured - e.value
        return BaselineComparison(metric: metric, published: e.value, measured: measured, delta: delta, source: e.source,
                                  gateDelta: gateDelta, gatePassed: delta <= gateDelta + 1e-9)
    }
}
