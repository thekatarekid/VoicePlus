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
}

/// FluidAudio `DiarizerManager` + enrolled user embedding. Decides per chunk: the mic leg is
/// compared against the enrolled embedding (rejects other people near the laptop); the system
/// leg is clustered into `others(n)` by greedy cosine against running centroids.
public final class EmbeddingLabeler: SpeakerLabeler, @unchecked Sendable {
    public let name = "embedding"
    public let enrolled: [Float]
    public var threshold: Float
    public var clusterThreshold: Float = 0.7
    private let backend: any SpeakerEmbeddingBackend
    private var centroids: [[Float]] = []
    private let lock = NSLock()

    public init(backend: any SpeakerEmbeddingBackend, enrolled: [Float], threshold: Float = 0.6) {
        self.backend = backend; self.enrolled = enrolled; self.threshold = threshold
    }

    public func label(_ chunks: [MeetingChunk]) async throws -> [LabeledChunk] {
        var out: [LabeledChunk] = []
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

public enum DiarizationFactory {
    /// Embedding labeler when the diarization models are on disk and the user is enrolled;
    /// channel labeler otherwise. Never downloads.
    public static func make(enrolledUserEmbedding: [Float]?) -> any SpeakerLabeler {
        if let enrolled = enrolledUserEmbedding, !enrolled.isEmpty, let backend = FluidSpeakerEmbedding.loadIfAvailable() {
            return EmbeddingLabeler(backend: backend, enrolled: enrolled)
        }
        return ChannelLabeler()
    }
}
