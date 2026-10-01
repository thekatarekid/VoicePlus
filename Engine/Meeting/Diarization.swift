import FluidAudio
import Foundation
import Shared

/// Who spoke. Meeting capture only ever distinguishes the enrolled user from everyone else;
/// `others(index)` keeps distinct remote speakers apart when the diarizer can.
public enum MeetingSpeaker: Codable, Equatable, Hashable, Sendable {
    case you
    case others(Int)

    public var label: String {
        switch self {
        case .you: return "You"
        case .others(let i): return i <= 1 ? "Others" : "Others \(i)"
        }
    }
}

/// A chunk with its speaker decision.
public struct LabeledChunk: Sendable, Equatable {
    public var chunk: MeetingChunk
    public var speaker: MeetingSpeaker
    /// 0…1 confidence in the label (1 for channel-based labels).
    public var confidence: Float
    public init(chunk: MeetingChunk, speaker: MeetingSpeaker, confidence: Float) {
        self.chunk = chunk; self.speaker = speaker; self.confidence = confidence
    }
}

public protocol SpeakerLabeler: AnyObject, Sendable {
    var name: String { get }
    func label(_ chunks: [MeetingChunk]) async throws -> [LabeledChunk]
}

/// Fallback that is always correct for a two-leg capture: whatever the mic hears is "You",
/// whatever the system plays is "Others". Residual echo is already removed by the AEC.
public final class ChannelLabeler: SpeakerLabeler {
    public let name = "channel"
    public init() {}
    public func label(_ chunks: [MeetingChunk]) async throws -> [LabeledChunk] {
        chunks.map { LabeledChunk(chunk: $0, speaker: $0.channel == .mic ? .you : .others(1), confidence: 1) }
    }
}

/// Cosine similarity of speaker embeddings (WeSpeaker vectors are L2-comparable).
public enum EmbeddingMatch {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d > 0 ? dot / d : 0
    }

    /// Maps a diarizer speaker embedding to You/Others against the enrolled user embedding.
    public static func classify(_ embedding: [Float], enrolled: [Float], threshold: Float = 0.6) -> (MeetingSpeaker, Float) {
        let sim = cosine(embedding, enrolled)
        return sim >= threshold ? (.you, sim) : (.others(1), 1 - max(0, sim))
    }
}

/// Embedding-producing backend so the labeling logic is testable without CoreML.
public protocol SpeakerEmbeddingBackend: AnyObject, Sendable {
    func embedding(for samples: [Float]) throws -> [Float]
    /// V5 M12 — make the model resident before a batch (through `ModelResidency`). Default: no-op.
    func prepare() async throws
}

extension SpeakerEmbeddingBackend {
    public func prepare() async throws {}
}

/// FluidAudio `DiarizerManager` + enrolled user embedding. Decides per chunk: the mic leg is
/// compared against the enrolled embedding (rejects other people near the laptop); the system
/// leg is clustered into `others(n)` by greedy cosine against running centroids.
public final class EmbeddingLabeler: SpeakerLabeler, @unchecked Sendable {
    public let name = "embedding"
    public let enrolled: [Float]
    public var threshold: Float
    public var clusterThreshold: Float = 0.7
    let backend: any SpeakerEmbeddingBackend
    private var centroids: [[Float]] = []
    private let lock = NSLock()

    public init(backend: any SpeakerEmbeddingBackend, enrolled: [Float], threshold: Float = 0.6) {
        self.backend = backend; self.enrolled = enrolled; self.threshold = threshold
    }

    public func label(_ chunks: [MeetingChunk]) async throws -> [LabeledChunk] {
        var out: [LabeledChunk] = []
        try? await backend.prepare()   // a failed load degrades each chunk to its channel label below
        for c in chunks {
            guard let emb = try? backend.embedding(for: c.chunk.samples), !emb.isEmpty else {
                out.append(LabeledChunk(chunk: c, speaker: c.channel == .mic ? .you : .others(1), confidence: 0.5)); continue
            }
            if c.channel == .mic {
                let (who, conf) = EmbeddingMatch.classify(emb, enrolled: enrolled, threshold: threshold)
                out.append(LabeledChunk(chunk: c, speaker: who, confidence: conf))
            } else {
                out.append(LabeledChunk(chunk: c, speaker: .others(cluster(emb)), confidence: 0.8))
            }
        }
        return out
    }

    private func cluster(_ emb: [Float]) -> Int {
        lock.lock(); defer { lock.unlock() }
        var best = -1; var bestSim: Float = -1
        for (i, c) in centroids.enumerated() {
            let s = EmbeddingMatch.cosine(emb, c)
            if s > bestSim { bestSim = s; best = i }
        }
        if best >= 0, bestSim >= clusterThreshold {
            centroids[best] = zip(centroids[best], emb).map { ($0 * 0.8) + ($1 * 0.2) }
            return best + 1
        }
        centroids.append(emb)
        return centroids.count
    }
}

/// FluidAudio-backed embedding extractor. Loads models only if already on disk; never downloads.
public final class FluidSpeakerEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
    private let manager: DiarizerManager
    public static var modelDirectory: URL { MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer) }
    public static var areModelsPresent: Bool {
        let d = modelDirectory
        return FileManager.default.fileExists(atPath: d.appendingPathComponent(ModelNames.Diarizer.segmentationFile).path)
            && FileManager.default.fileExists(atPath: d.appendingPathComponent(ModelNames.Diarizer.embeddingFile).path)
    }

    public static func loadIfAvailable() -> FluidSpeakerEmbedding? {
        guard areModelsPresent else { return nil }
        do {
            let d = modelDirectory
            let models = try DiarizerModels.load(
                localSegmentationModel: d.appendingPathComponent(ModelNames.Diarizer.segmentationFile),
                localEmbeddingModel: d.appendingPathComponent(ModelNames.Diarizer.embeddingFile))
            let m = DiarizerManager(config: .default)
            m.initialize(models: models)
            return FluidSpeakerEmbedding(manager: m)
        } catch {
            Log.engine.warning("meeting: diarizer load failed, channel labels only: \(error)")
            return nil
        }
    }

    init(manager: DiarizerManager) { self.manager = manager }
    public func embedding(for samples: [Float]) throws -> [Float] { try manager.extractSpeakerEmbedding(from: samples) }
}

/// V5 M12 — WeSpeaker for meeting labels, loaded through `ModelResidency` (§10) from wherever
/// `SpeakerEmbedderFactory.locateModel()` finds a complete copy (our install first, then the bundle,
/// then FluidAudio's cache). `.onDemand`: resident while a meeting labels chunks, unloaded by the
/// idle sweeper or memory pressure afterwards. Never downloads.
public final class ResidentSpeakerEmbedding: SpeakerEmbeddingBackend, @unchecked Sendable {
    public static let residencyKey = "meeting.speaker-embedding"
    private let directory: URL
    private let residency: ModelResidency
    private let box = Box()
    private let lock = NSLock()
    private var registered = false

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _backend: FluidSpeakerEmbedder?
        var backend: FluidSpeakerEmbedder? {
            get { lock.withLock { _backend } }
            set { lock.withLock { _backend = newValue } }
        }
    }

    public init(directory: URL, residency: ModelResidency = .shared) {
        self.directory = directory; self.residency = residency
    }

    public func prepare() async throws {
        let first = lock.withLock { () -> Bool in defer { registered = true }; return !registered }
        if first {
            let box = box, dir = directory
            let bytes = ModelCatalog.descriptor(.speakerEmbedding).approxBytes * 2
            await residency.register(Self.residencyKey, tier: .onDemand, estimatedBytes: bytes, owner: "meeting.diarization",
                                     load: {
                                         guard box.backend == nil else { return }
                                         guard let loaded = FluidSpeakerEmbedder.load(from: dir) else { throw SpeakerError.backendUnavailable }
                                         box.backend = loaded
                                     },
                                     unload: { box.backend = nil })
        }
        try await residency.acquire(Self.residencyKey)
    }

    public func embedding(for samples: [Float]) throws -> [Float] {
        guard let backend = box.backend else { throw SpeakerError.backendUnavailable }
        return try backend.embed(samples).vector   // the same space the voiceprint was built in
    }
}

public enum DiarizationFactory {
    /// V5 M12 — mic-leg cosine bar against the user's voice. WeSpeaker, 3–5 s chunk vs a many-turn
    /// centroid: same voice ≳ 0.6, other voices ≲ 0.3 (`TurnAnchoredVoice`'s measurements), so 0.5
    /// keeps the user's own quieter chunks as "You" without admitting another voice.
    public static let micThreshold: Float = 0.5

    /// Embedding labeler when the WeSpeaker weights are on disk and the user's voice is known
    /// (`SpeakerProfileStore.meetingEmbedding()`: the M6 voiceprint or an enrolled WeSpeaker
    /// profile); channel labeler otherwise. Never downloads; the model loads through
    /// `ModelResidency` on the first labelled batch.
    public static func make(enrolledUserEmbedding: [Float]?,
                            locate: () -> URL? = { SpeakerEmbedderFactory.locateModel() },
                            residency: ModelResidency = .shared) -> any SpeakerLabeler {
        if let enrolled = enrolledUserEmbedding, !enrolled.isEmpty, let directory = locate() {
            return EmbeddingLabeler(backend: ResidentSpeakerEmbedding(directory: directory, residency: residency),
                                    enrolled: enrolled, threshold: micThreshold)
        }
        return ChannelLabeler()
    }
}
