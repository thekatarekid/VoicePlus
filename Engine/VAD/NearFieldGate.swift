import Foundation

/// V5 K2 — near-field level gate.
///
/// The user is the closest talker to the mic. A turn's **anchor** is the loudest *sustained* level
/// (≥ 100 ms held) in the first second of speech the turn hears; every later VAD segment whose own
/// sustained level is more than `dropBelowDB` (12 dB by default) under the anchor is someone farther
/// away — a colleague across the room, a TV — and is dropped. A one-frame click can't become the
/// anchor because the level must be held. This is the level half of "who spoke" (V5 §0 rule 3);
/// consumers are the O-b ownership rule 3 and the latched (L) segment filter. It replaces reading
/// `DirectedSpeechFeatures.meanLevelDB` as an absolute loudness (which moves with mic gain): the
/// comparison is relative to this turn's own anchor.
///
/// Pure value type, fed in stream order; no audio is retained beyond the first second of speech.
public struct NearFieldGate: Sendable, Equatable {
    public struct Config: Sendable, Equatable {
        /// Seconds of speech the anchor is measured over (from the first speech of the turn).
        public var anchorWindow: TimeInterval = 1.0
        /// A segment more than this many dB below the anchor is dropped.
        public var dropBelowDB: Double = 12
        /// Level frame (20 ms at 16 kHz).
        public var frameSamples: Int = 320
        /// How long a level must be held to count ("sustained"): 5 × 20 ms = 100 ms.
        public var sustainFrames: Int = 5
        public var sampleRate: Int = 16_000
        public init(anchorWindow: TimeInterval = 1.0, dropBelowDB: Double = 12) {
            self.anchorWindow = anchorWindow
            self.dropBelowDB = dropBelowDB
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// Close enough to the anchor (or louder).
        case keep(levelDB: Double, anchorDB: Double)
        /// More than `dropBelowDB` under the anchor.
        case drop(levelDB: Double, anchorDB: Double)
        /// No anchor yet, or the segment is too short to measure: not judged, kept.
        case unjudged

        public var keeps: Bool { if case .drop = self { return false }; return true }
    }

    public var config: Config
    /// The anchor in dBFS, once the first `anchorWindow` of speech has been heard (or `closeAnchor()`).
    public private(set) var anchorDB: Double?
    private var anchorAudio: [Float] = []

    public init(config: Config = Config()) { self.config = config }

    /// Starts a new turn: forgets the anchor.
    public mutating func beginTurn() { anchorDB = nil; anchorAudio.removeAll() }

    /// Feed the turn's **speech** audio (VAD-speech samples, in order). Only the first
    /// `anchorWindow` is used; the anchor is fixed as soon as that much has been heard.
    public mutating func noteSpeech(_ samples: [Float]) {
        guard anchorDB == nil else { return }
        let need = Int(config.anchorWindow * Double(config.sampleRate)) - anchorAudio.count
        guard need > 0 else { closeAnchor(); return }
        anchorAudio.append(contentsOf: samples.prefix(need))
        if anchorAudio.count >= Int(config.anchorWindow * Double(config.sampleRate)) { closeAnchor() }
    }

    /// Fix the anchor from whatever speech has been heard (a turn shorter than `anchorWindow`).
    public mutating func closeAnchor() {
        guard anchorDB == nil else { return }
        anchorDB = Self.sustainedPeakDB(anchorAudio, config: config)
        anchorAudio.removeAll()
    }

    /// Judges one VAD segment's audio against the anchor.
    public func evaluate(_ segment: [Float]) -> Verdict {
        guard let anchor = anchorDB, let level = Self.sustainedPeakDB(segment, config: config) else { return .unjudged }
        return level < anchor - config.dropBelowDB ? .drop(levelDB: level, anchorDB: anchor) : .keep(levelDB: level, anchorDB: anchor)
    }

    /// Convenience for a whole turn: the first segment(s) set the anchor, then every segment is
    /// judged. Returns the indices kept, in order.
    public mutating func filter(_ segments: [[Float]]) -> [Int] {
        beginTurn()
        for s in segments where anchorDB == nil { noteSpeech(s) }
        closeAnchor()
        return segments.indices.filter { evaluate(segments[$0]).keeps }
    }

    /// The loudest level (dBFS) held for `sustainFrames` consecutive frames: max over windows of the
    /// window's quietest frame. nil when the audio is shorter than one window or silent.
    public static func sustainedPeakDB(_ samples: [Float], config: Config = Config()) -> Double? {
        let n = samples.count / config.frameSamples
        guard n >= config.sustainFrames else { return nil }
        var levels = [Double](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { buf in
            for i in 0..<n {
                var acc: Float = 0
                for j in (i * config.frameSamples)..<((i + 1) * config.frameSamples) { acc += buf[j] * buf[j] }
                let rms = Double((acc / Float(config.frameSamples)).squareRoot())
                levels[i] = 20 * log10(max(rms, 1e-6))
            }
        }
        var best = -Double.infinity
        for start in 0...(n - config.sustainFrames) {
            let held = levels[start..<(start + config.sustainFrames)].min()!
            best = max(best, held)
        }
        return best <= -100 ? nil : best
    }
}
