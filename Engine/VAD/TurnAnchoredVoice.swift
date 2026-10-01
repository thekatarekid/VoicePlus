import Foundation

/// V5 K4 — turn-anchored voice.
///
/// Whoever pressed the key is the user *for this turn*. The anchor is a speaker embedding (WeSpeaker
/// via `FluidSpeakerEmbedder`) of the first 500 ms of the turn's speech after key-down; every later
/// VAD segment is embedded and compared by cosine. Below the threshold it is another voice:
///
/// * **hold** (push-to-talk) — the segment is dropped;
/// * **latch** (hands-free) — the segment is routed to Notes instead of the field;
/// * every **confirmed** latch segment (one the decision layer kept as the user's) re-anchors, so a
///   long latched session follows the user's voice as it warms up, moves away, or changes mic.
///
/// This is the voice half of "who spoke" beside `NearFieldGate` (K2, the level half); both are read
/// by the O-b ownership rule and the L segment filter. It needs no enrolment: the anchor is rebuilt
/// at every key-down, so a borrowed Mac works too.
///
/// **Short anchors need a lower bar (measured).** WeSpeaker on the `Fixtures/audio/clean` voices
/// (three `say` speakers), anchor = the first N s of one clip, cosine against whole other clips:
///
/// | anchor | same voice | other voices |
/// |---|---|---|
/// | 0.3 s | 0.06–0.18 | 0.03–0.16 (no separation) |
/// | 0.5 s | 0.44–0.47 | 0.06–0.23 |
/// | 1 s   | 0.45–0.71 | 0.22–0.28 |
/// | 2 s   | 0.62–0.90 | 0.23–0.30 |
/// | whole clip | 0.80–0.83 | 0.20–0.27 |
///
/// So a flat 0.6 against a 500 ms anchor would drop the user's own words, and 300 ms cannot tell
/// voices apart at all: the anchor needs ≥ 500 ms (`anchorMinSeconds`), and the threshold steps with
/// the anchor's length (`thresholdSteps`: 0.35 under 1 s, 0.4 under 2 s, 0.5 under 4 s, then 0.6).
/// The anchor **grows**: every kept segment of the turn is appended to it (up to `anchorGrowSeconds`,
/// 4 s) and re-embedded, so it reaches the 0.6 regime within a few seconds of the user's speech.
///
/// Honest when it cannot tell: with an embedder that does not identify speakers (the MFCC fallback,
/// `identifiesSpeakers == false`), with no anchor yet, or on a segment too short to embed, the verdict
/// is `.unjudged` and the segment is kept — never a guess that throws away the user's words.
///
/// Holds at most `anchorGrowSeconds` of the turn's own kept speech; forgotten at the next key-down.
/// Driven from one task; not thread-safe.
public final class TurnAnchoredVoice: @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Shortest anchor worth embedding (500 ms: 300 ms does not separate voices, see the table);
        /// a turn with less speech has no anchor.
        public var anchorMinSeconds: TimeInterval = 0.5
        /// The anchor is first fixed once this much speech has been heard (500 ms).
        public var anchorMaxSeconds: TimeInterval = 0.5
        /// Kept segments extend the anchor up to this much speech (4 s).
        public var anchorGrowSeconds: TimeInterval = 4
        /// Cosine below this is another voice, once the anchor holds `anchorGrowSeconds`.
        public var threshold: Float = 0.6
        /// (anchor shorter than seconds, threshold) — the bar for a shorter anchor; else `threshold`.
        public var thresholdSteps: [(below: TimeInterval, threshold: Float)] = [(1, 0.35), (2, 0.4), (4, 0.5)]
        /// Segments shorter than this are not judged (kept).
        public var minSegmentSeconds: TimeInterval = 0.3
        public var sampleRate: Int = 16_000

        public init(anchorMinSeconds: TimeInterval = 0.5, anchorMaxSeconds: TimeInterval = 0.5,
                    anchorGrowSeconds: TimeInterval = 4, threshold: Float = 0.6,
                    minSegmentSeconds: TimeInterval = 0.3) {
            self.anchorMinSeconds = anchorMinSeconds
            self.anchorMaxSeconds = anchorMaxSeconds
            self.anchorGrowSeconds = anchorGrowSeconds
            self.threshold = threshold
            self.minSegmentSeconds = minSegmentSeconds
        }

        /// The cosine bar for an anchor of `seconds` of speech.
        public func threshold(forAnchorSeconds seconds: TimeInterval) -> Float {
            thresholdSteps.first { seconds < $0.below }?.threshold ?? threshold
        }

        public static func == (a: Config, b: Config) -> Bool {
            a.anchorMinSeconds == b.anchorMinSeconds && a.anchorMaxSeconds == b.anchorMaxSeconds
                && a.anchorGrowSeconds == b.anchorGrowSeconds && a.threshold == b.threshold
                && a.minSegmentSeconds == b.minSegmentSeconds && a.sampleRate == b.sampleRate
                && a.thresholdSteps.map(\.below) == b.thresholdSteps.map(\.below)
                && a.thresholdSteps.map(\.threshold) == b.thresholdSteps.map(\.threshold)
        }

        var anchorMinSamples: Int { Int(anchorMinSeconds * Double(sampleRate)) }
        var anchorMaxSamples: Int { Int(anchorMaxSeconds * Double(sampleRate)) }
        var anchorGrowSamples: Int { Int(anchorGrowSeconds * Double(sampleRate)) }
        var minSegmentSamples: Int { Int(minSegmentSeconds * Double(sampleRate)) }
    }

    /// What a rejected segment becomes.
    public enum Mode: String, Sendable, Equatable {
        /// Push-to-talk: another voice is dropped.
        case hold
        /// Hands-free: another voice goes to Notes, never into the field.
        case latch
    }

    public enum UnjudgedReason: String, Sendable, Equatable {
        case noAnchor
        case segmentTooShort
        /// The embedder cannot identify speakers (MFCC fallback): K4 is off, not guessing.
        case embedderCannotIdentify
        case embeddingFailed
    }

    public enum Verdict: Sendable, Equatable {
        /// Same voice as the anchor.
        case keep(similarity: Float)
        /// Another voice, hold mode.
        case drop(similarity: Float)
        /// Another voice, latch mode.
        case routeToNotes(similarity: Float)
        /// Not judged; the segment is kept.
        case unjudged(UnjudgedReason)

        /// Does the segment go where the turn's text goes?
        public var keeps: Bool {
            switch self {
            case .keep, .unjudged: return true
            case .drop, .routeToNotes: return false
            }
        }

        public var similarity: Float? {
            switch self {
            case .keep(let s), .drop(let s), .routeToNotes(let s): return s
            case .unjudged: return nil
            }
        }

        /// Short reason code for the Q13 turn diagnostics (`TurnDiagnosticsEvent.decision.reason`):
        /// enums and a number only, never audio or text.
        public var diagnosticsReason: String {
            switch self {
            case .keep: return "k4.voice.same"
            case .drop: return "k4.voice.other.drop"
            case .routeToNotes: return "k4.voice.other.notes"
            case .unjudged(let why): return "k4.voice.unjudged.\(why.rawValue)"
            }
        }
    }

    public let config: Config
    public var mode: Mode
    private let embedder: any SpeakerEmbedder
    private var anchorAudio: [Float] = []
    private var anchorClosed = false
    /// The anchor embedding, once fixed.
    public private(set) var anchor: SpeakerEmbedding?
    /// The speech the anchor was embedded from (≤ `anchorGrowSeconds`).
    private var anchorSpeech: [Float] = []
    /// Seconds of speech in the anchor (0 without one).
    public var anchorSeconds: TimeInterval { anchor == nil ? 0 : Double(anchorSpeech.count) / Double(config.sampleRate) }
    /// The bar a segment must clear now.
    public var currentThreshold: Float { config.threshold(forAnchorSeconds: anchorSeconds) }
    /// How many times this turn's anchor was replaced by a confirmed latch segment.
    public private(set) var reanchorCount = 0

    public init(embedder: any SpeakerEmbedder, mode: Mode = .hold, config: Config = Config()) {
        self.embedder = embedder
        self.mode = mode
        self.config = config
    }

    /// False with the MFCC fallback: every verdict is then `.unjudged(.embedderCannotIdentify)`.
    public var canIdentify: Bool { embedder.identifiesSpeakers }

    /// Key-down: forgets the previous turn's anchor.
    public func beginTurn(mode: Mode? = nil) {
        if let mode { self.mode = mode }
        anchorAudio.removeAll(keepingCapacity: true)
        anchorClosed = false
        anchor = nil
        anchorSpeech.removeAll(keepingCapacity: false)
        reanchorCount = 0
    }

    /// Feed the turn's speech audio (VAD speech after key-down, in order). The first
    /// `anchorMaxSeconds` become the anchor; it is fixed as soon as that much was heard.
    public func noteSpeech(_ samples: [Float]) {
        guard !anchorClosed else { return }
        let need = config.anchorMaxSamples - anchorAudio.count
        if need > 0 { anchorAudio.append(contentsOf: samples.prefix(need)) }
        if anchorAudio.count >= config.anchorMaxSamples { closeAnchor() }
    }

    /// Fixes the anchor from the speech heard so far (a turn whose first segment was shorter than
    /// `anchorMaxSeconds`). Under `anchorMinSeconds` there is no anchor for this turn.
    public func closeAnchor() {
        guard !anchorClosed else { return }
        anchorClosed = true
        defer { anchorAudio.removeAll(keepingCapacity: false) }
        guard canIdentify, anchorAudio.count >= config.anchorMinSamples else { return }
        anchor = try? embedder.embed(anchorAudio)
        if anchor != nil { anchorSpeech = anchorAudio }
    }

    /// Judges one later VAD segment against the anchor.
    public func evaluate(_ segment: [Float]) -> Verdict {
        guard canIdentify else { return .unjudged(.embedderCannotIdentify) }
        guard let anchor else { return .unjudged(.noAnchor) }
        guard segment.count >= config.minSegmentSamples else { return .unjudged(.segmentTooShort) }
        guard let e = try? embedder.embed(segment) else { return .unjudged(.embeddingFailed) }
        let s = anchor.cosine(e)
        guard s >= currentThreshold else {
            return mode == .hold ? .drop(similarity: s) : .routeToNotes(similarity: s)
        }
        grow(with: segment)
        return .keep(similarity: s)
    }

    /// A kept segment extends a short anchor (re-embedded); a failed re-embed keeps the old anchor.
    private func grow(with segment: [Float]) {
        let room = config.anchorGrowSamples - anchorSpeech.count
        guard room > 0 else { return }
        let extended = anchorSpeech + segment.prefix(room)
        guard let e = try? embedder.embed(extended) else { return }
        anchor = e
        anchorSpeech = extended
    }

    /// Latch: the decision layer confirmed `segment` as the user's — it becomes the anchor. Returns
    /// false (anchor unchanged) when the segment is too short or cannot be embedded.
    @discardableResult
    public func reanchor(onConfirmed segment: [Float]) -> Bool {
        let clip = Array(segment.prefix(config.anchorGrowSamples))
        guard canIdentify, clip.count >= config.anchorMinSamples,
              let e = try? embedder.embed(clip) else { return false }
        anchorClosed = true
        anchorAudio.removeAll(keepingCapacity: false)
        anchor = e
        anchorSpeech = clip
        reanchorCount += 1
        return true
    }

    /// A whole hold turn at once: the first segments set the anchor, then every segment is judged.
    /// Segments that took part in the anchor are judged too (they match it by construction).
    public func filter(_ segments: [[Float]]) -> [Verdict] {
        beginTurn()
        for s in segments where !anchorClosed { noteSpeech(s) }
        closeAnchor()
        return segments.map(evaluate)
    }
}
