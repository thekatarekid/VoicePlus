@preconcurrency import CoreML
import FluidAudio
import Foundation
import Shared

// V5 M9 — which speaker-embedding model meetings use: WeSpeaker v2 (256-d, shipped with the speech
// stack) or CAM++ (FunASR, 192-d, CoreML, on demand). The two are compared on the V1 harness
// (`--stage diar`, VoxConverse / AMI) with the same clustering (`EmbeddingClusterDiarizer`), and the
// lower DER becomes the default (`MeetingEmbeddingChoice.pick`). Until a measurement exists the
// default stays WeSpeaker. Vectors from the two models live in different spaces and are never
// compared with each other (every stored vector carries its model id).

/// The meeting embedding models.
public enum MeetingEmbeddingChoice: String, Codable, CaseIterable, Sendable {
    case wespeaker
    case campPlus = "campplus"

    /// Embedder id stored beside every vector (`SpeakerEmbedding.embedder`, `VoiceprintStore`).
    /// WeSpeaker's matches `FluidSpeakerEmbedder.name` so the M6 voiceprint and meeting vectors agree.
    public var embedderID: String {
        switch self {
        case .wespeaker: return "fluid-wespeaker"
        case .campPlus: return "fluid-campplus"
        }
    }

    /// Model id the V1 harness reports under (`Lab/results/<date>-<set>-<model>.json`).
    public var evalModelID: String { "diar-\(rawValue)" }

    public var modelID: ModelID {
        switch self {
        case .wespeaker: return .speakerEmbedding
        case .campPlus: return .campPlus
        }
    }

    /// `UserDefaults` override ("wespeaker" / "campplus"); absent → the measured pick.
    public static let overrideKey = "meeting.embeddingModel"
    /// Sets V1 picks on: the two the build doc names.
    public static let decidingSets = ["voxconverse-test", "ami"]

    /// One DER measurement read back from `Lab/results`.
    public struct Measurement: Equatable, Sendable {
        public var set: String
        public var choice: MeetingEmbeddingChoice
        public var der: Double
        public var date: String
        public init(set: String, choice: MeetingEmbeddingChoice, der: Double, date: String) {
            self.set = set; self.choice = choice; self.der = der; self.date = date
        }
    }

    /// The default by measurement: per deciding set, the latest DER of each model; the model with the
    /// lower mean DER over the sets *both* were measured on wins. A tie or no shared set →
    /// `shippedDefault`.
    public static func pick(_ measurements: [Measurement]) -> MeetingEmbeddingChoice {
        var latest: [String: [MeetingEmbeddingChoice: Measurement]] = [:]
        for m in measurements where decidingSets.contains(where: { m.set.hasPrefix($0) }) {
            if let have = latest[m.set]?[m.choice], have.date >= m.date { continue }
            latest[m.set, default: [:]][m.choice] = m
        }
        var w = 0.0, c = 0.0, n = 0
        for (_, byChoice) in latest {
            guard let a = byChoice[.wespeaker], let b = byChoice[.campPlus] else { continue }
            w += a.der; c += b.der; n += 1
        }
        guard n > 0 else { return shippedDefault }
        return c < w ? .campPlus : (w < c ? .wespeaker : shippedDefault)
    }

    /// `Lab/results` beside `Fixtures/` in a source checkout; nil in a packaged app, which uses
    /// `shippedDefault` (the pick recorded here when the V1 run lands).
    public static func resultsDirectory() -> URL? {
        guard let fixtures = AppPaths.fixturesDirectory() else { return nil }
        let dir = fixtures.deletingLastPathComponent().appendingPathComponent("Lab/results", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// The default a packaged app ships with. WeSpeaker until the V1 DER run says otherwise
    /// (not yet measured: VoxConverse / AMI are not on this machine — T1).
    public static let shippedDefault: MeetingEmbeddingChoice = .wespeaker

    /// `--stage diar` reports in `directory` (`Lab/results`) for either model.
    public static func measurements(in directory: URL? = resultsDirectory(),
                                    fileManager: FileManager = .default) -> [Measurement] {
        guard let directory else { return [] }
        struct Report: Decodable {
            struct Summary: Decodable { var der: Double? }
            var set: String; var stage: String; var model: String; var date: String; var summary: Summary
        }
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let r = try? JSONDecoder().decode(Report.self, from: data), r.stage == "diar", let der = r.summary.der,
                  let choice = allCases.first(where: { $0.evalModelID == r.model }) else { return nil }
            return Measurement(set: r.set, choice: choice, der: der, date: r.date)
        }
    }

    /// The model meetings use now: the user's override, else the measured pick.
    public static func current(defaults: UserDefaults = .standard,
                               measured: () -> [Measurement] = { measurements() }) -> MeetingEmbeddingChoice {
        if let raw = defaults.string(forKey: overrideKey), let c = MeetingEmbeddingChoice(rawValue: raw) { return c }
        return pick(measured())
    }

    /// The installed weights for this choice, if any (never downloads).
    public func locate() -> URL? {
        switch self {
        case .wespeaker: return SpeakerEmbedderFactory.locateModel()
        case .campPlus: return ResidentCampPlusEmbedding.locate()
        }
    }

    /// A residency-managed backend for this choice when its weights are on disk.
    public func backend(residency: ModelResidency = .shared) -> (any SpeakerEmbeddingBackend)? {
        guard let dir = locate() else { return nil }
        switch self {
        case .wespeaker: return ResidentSpeakerEmbedding(directory: dir, residency: residency)
        case .campPlus: return ResidentCampPlusEmbedding(directory: dir, residency: residency)
        }
    }
}

/// V5 M9 — CAM++ for meeting labels, loaded through `ModelResidency` (§10) from our install
/// (`ModelID.campPlus`) or FluidAudio's cache. `.onDemand`, never downloads. Same contract as
/// `ResidentSpeakerEmbedding`: `prepare()` makes it resident, `embedding(for:)` is synchronous.
public final class ResidentCampPlusEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
    public static let residencyKey = "meeting.campplus"
    public static let dimension = 192
    private static let waveformScale: Float = 32_768   // kaldi int16 range, as FluidAudio's embedder
    private let directory: URL
    private let residency: ModelResidency
    private let box = Box()
    private let lock = NSLock()
    private var registered = false

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _models: CampPlusModels?
        var models: CampPlusModels? {
            get { lock.withLock { _models } }
            set { lock.withLock { _models = newValue } }
        }
    }

    public init(directory: URL, residency: ModelResidency = .shared) {
        self.directory = directory; self.residency = residency
    }

    /// Our folder first, then FluidAudio's cache (`~/Library/Application Support/FluidAudio/Models/campplus`).
    public static func candidates(modelsRoot: URL = ModelCatalog.modelsRoot()) -> [URL] {
        var out = [ModelCatalog.folder(for: .campPlus, in: modelsRoot)]
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            out.append(support.appendingPathComponent("FluidAudio/Models/\(Repo.campPlus.folderName)", isDirectory: true))
        }
        return out
    }

    public static func locate(in candidates: [URL] = candidates(), fileManager: FileManager = .default) -> URL? {
        let d = ModelCatalog.descriptor(.campPlus)
        return candidates.first { ModelIntegrity.isComplete(d, at: $0, fileManager: fileManager) }
    }

    public func prepare() async throws {
        let first = lock.withLock { () -> Bool in defer { registered = true }; return !registered }
        if first {
            let box = box, dir = directory
            await residency.register(Self.residencyKey, tier: .onDemand,
                                     estimatedBytes: ModelCatalog.descriptor(.campPlus).approxBytes * 3,
                                     owner: "meeting.diarization",
                                     load: {
                                         guard box.models == nil else { return }
                                         box.models = try CampPlusModels.load(from: dir)
                                     },
                                     unload: { box.models = nil })
        }
        try await residency.acquire(Self.residencyKey)
    }

    /// 16 kHz mono → 192-d L2-normalised embedding (FluidAudio `CampPlusEmbedder.embed(audio:)`'s
    /// two stages, synchronously).
    public func embedding(for samples: [Float]) throws -> [Float] {
        guard let models = box.models else { throw SpeakerError.backendUnavailable }
        guard samples.count >= 1_600 else { return [] }   // < 0.1 s: no fbank frames worth pooling
        let wav = try MLMultiArray(shape: [1, samples.count as NSNumber], dataType: .float32)
        let p = wav.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<samples.count { p[i] = samples[i] * Self.waveformScale }
        let feats = try models.preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: wav)]))
        guard let fbank = feats.featureValue(for: "features")?.multiArrayValue else { throw SpeakerError.backendUnavailable }
        let out = try models.model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["feats": MLFeatureValue(multiArray: fbank)]))
        guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else { throw SpeakerError.backendUnavailable }
        var v = [Float](repeating: 0, count: emb.count)
        for i in 0..<emb.count { v[i] = emb[i].floatValue }
        let norm = max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        return v.map { $0 / norm }
    }
}

/// V5 M9 — the offline diarizer the V1 comparison runs both embedding models through: fixed windows
/// → one embedding each → greedy agglomerative clustering on cosine → merged turns. Deliberately
/// simple and identical for both models, so DER differences are the embeddings', not the pipeline's.
public struct EmbeddingClusterDiarizer: Sendable {
    public var window: TimeInterval = 1.5
    public var hop: TimeInterval = 0.75
    /// Clusters merge while their centroids' cosine is at least this.
    public var mergeThreshold: Float = 0.55
    /// Windows quieter than this RMS are silence (no turn).
    public var silenceRMS: Float = 0.005
    public var sampleRate: Int = 16_000

    public init() {}

    public struct Turn: Equatable, Sendable {
        public var speaker: Int
        public var start: TimeInterval
        public var end: TimeInterval
    }

    public func diarize(_ samples: [Float], backend: any SpeakerEmbeddingBackend) throws -> [Turn] {
        let win = Int(window * Double(sampleRate)), step = max(1, Int(hop * Double(sampleRate)))
        var starts: [Int] = [], vectors: [[Float]] = []
        var i = 0
        while i + win <= max(samples.count, win), i < samples.count {
            let slice = Array(samples[i..<min(samples.count, i + win)])
            let rms = (slice.reduce(0) { $0 + $1 * $1 } / Float(max(1, slice.count))).squareRoot()
            if rms >= silenceRMS, let v = try? backend.embedding(for: slice), !v.isEmpty {
                starts.append(i); vectors.append(v)
            }
            i += step
        }
        let labels = Self.cluster(vectors, threshold: mergeThreshold)
        var turns: [Turn] = []
        for (k, s) in starts.enumerated() {
            // Each window owns its central hop so overlapping windows do not double-count.
            let lo = Double(s) / Double(sampleRate) + (k == 0 ? 0 : (window - hop) / 2)
            let hi = Double(min(samples.count, s + win)) / Double(sampleRate) - (k == starts.count - 1 ? 0 : (window - hop) / 2)
            if var last = turns.last, last.speaker == labels[k], lo - last.end < 0.05 {
                last.end = max(last.end, hi); turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speaker: labels[k], start: lo, end: hi))
            }
        }
        return turns
    }

    /// Two-phase clustering on cosine: windows join a running micro-cluster at ≥ `preThreshold`
    /// (keeps hour-long files tractable), then micro-clusters merge by average linkage while their
    /// centroids' cosine ≥ `threshold`. Labels numbered by first appearance.
    public static func cluster(_ vectors: [[Float]], threshold: Float, preThreshold: Float = 0.8) -> [Int] {
        guard !vectors.isEmpty else { return [] }
        var sums: [[Float]] = []
        var members: [[Int]] = []
        for (i, v) in vectors.enumerated() {
            var best = -1; var bestSim: Float = -2
            for (k, c) in sums.enumerated() {
                let s = EmbeddingMatch.cosine(v, c)
                if s > bestSim { bestSim = s; best = k }
            }
            if best >= 0, bestSim >= max(threshold, preThreshold) {
                sums[best] = zip(sums[best], v).map { $0 + $1 }; members[best].append(i)
            } else {
                sums.append(v); members.append([i])
            }
        }
        while members.count > 1 {
            var best = (0, 0), bestSim: Float = -2
            for a in 0..<members.count {
                for b in (a + 1)..<members.count {
                    let s = EmbeddingMatch.cosine(sums[a], sums[b])
                    if s > bestSim { bestSim = s; best = (a, b) }
                }
            }
            guard bestSim >= threshold else { break }
            let (a, b) = best
            members[a] += members[b]
            sums[a] = zip(sums[a], sums[b]).map { $0 + $1 }
            members.remove(at: b); sums.remove(at: b)
        }
        var label = [Int](repeating: 0, count: vectors.count)
        for (c, m) in members.enumerated() { for i in m { label[i] = c } }
        var order: [Int: Int] = [:]
        return label.map { l in
            if let n = order[l] { return n }
            let n = order.count; order[l] = n; return n
        }
    }
}
