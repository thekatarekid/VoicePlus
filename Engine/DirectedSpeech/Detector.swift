import Foundation

/// P5.1 — the always-on lightweight path: audio → ring; VAD events → feature extraction →
/// classifier → `DirectedSpeechDecision`. Nothing persisted, nothing transmitted.
public struct DirectedSpeechDecision: Equatable, Sendable {
    public var utterance: ClosedRange<TimeInterval>
    public var probability: Double
    public var directed: Bool
    public var features: DirectedSpeechFeatures
}

public enum DirectedSpeechFlags {
    /// Engine-local flag id. Stays default-OFF ("experimental") unless the harness clears the ship bar.
    public static let experimentalModeID = "engine.directedSpeech.experimental"
    public static let shipBarFalseTriggersPerDay = 1.0
}

public final class DirectedSpeechDetector: @unchecked Sendable {
    public let ring: RollingAudioRing
    public let classifier: DirectedSpeechClassifier
    public var extractor = DirectedSpeechFeatureExtractor()
    public var context = DirectedSpeechContext()
    /// Latest streaming-ASR preview text (first words). Cleared on each decision.
    public var preview = ""
    /// How long after a directed decision `addressedRecently` stays true.
    public var addressedWindow: TimeInterval = 20
    public private(set) var lastDecision: DirectedSpeechDecision?
    private var speechStart: TimeInterval?
    private var lastDirectedAt: TimeInterval = -.infinity
    private let lock = NSLock()

    public init(ring: RollingAudioRing = RollingAudioRing(), classifier: DirectedSpeechClassifier = DirectedSpeechClassifier()) {
        self.ring = ring; self.classifier = classifier
    }

    public func appendAudio(_ samples: [Float]) { ring.append(samples) }

    /// Feed VAD events; returns a decision on `speechEnd`.
    @discardableResult
    public func handle(_ event: VADEvent) -> DirectedSpeechDecision? {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .speechStart(let t):
            speechStart = t; return nil
        case .speechEnd(let t):
            guard let s = speechStart else { return nil }
            speechStart = nil
            var ctx = context
            ctx.addressedRecently = ctx.addressedRecently || (t - lastDirectedAt) <= addressedWindow
            let f = extractor.extract(samples: ring.samples(in: s...t), preview: preview, context: ctx)
            preview = ""
            let p = classifier.probability(f)
            let d = DirectedSpeechDecision(utterance: s...t, probability: p, directed: p >= classifier.threshold, features: f)
            if d.directed { lastDirectedAt = t }
            lastDecision = d
            return d
        }
    }

    /// User said "not you" about the last decision → one online update.
    public func markNotYou() {
        lock.lock(); defer { lock.unlock() }
        guard let d = lastDecision else { return }
        classifier.update(d.features, directed: false)
        lastDirectedAt = -.infinity
    }

    public func markWasMe() {
        lock.lock(); defer { lock.unlock() }
        guard let d = lastDecision else { return }
        classifier.update(d.features, directed: true)
        lastDirectedAt = d.utterance.upperBound
    }

    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        ring.wipe(); lastDecision = nil; speechStart = nil; preview = ""
    }
}
