import Foundation
import Shared

// V5 lane 6b — the user's voice and the meeting's speaker labels.
//
// * `PassiveVoiceprint` (M6): the user's voice, learned from hold-to-talk turns, as a running mean
//   weighted by each turn's SNR. Used for meetings (M12) once `minimumTurns` turns are in.
// * `SignalQuality` (M6): the SNR estimate that weights a turn.
// * `SpeakerSlotMap` (M7/M8): diarizer slots (leg, index) → `MeetingSpeaker`, numbered in order of
//   first appearance so labels stay stable across legs and passes.

/// M6 — the user's voiceprint from dictation turns (passive; no enrollment phrase).
///
/// Every hold-to-talk turn is the user by definition (they pressed the key; K4's `.you` anchor), so
/// its embedding is averaged in, weighted by how clean the turn was (`weight(snrDB:)`). The mean is
/// usable after `minimumTurns` turns; until then `embedding` is nil and meetings fall back to the
/// enrolled profile or channel labels. After `maxTotalWeight` the mean keeps adapting as an
/// exponential average (a cold, a new microphone), never freezing and never forgetting at once.
///
/// A turn that does not sound like the voice learned so far (`outlierSimilarity`, checked once
/// `outlierCheckAfter` turns are in) is not averaged in: someone else was louder than the user.
/// A turn from a different embedder (the weights changed) starts the voiceprint over — vectors
/// from two embedders cannot be averaged. Embeddings only; never audio.
public struct PassiveVoiceprint: Codable, Equatable, Sendable {
    public static let minimumTurns = 5
    /// Cap on the accumulated weight: past it each turn moves the mean by at least w / 20.
    public static let maxTotalWeight: Float = 20
    public static let outlierCheckAfter = 3
    public static let outlierSimilarity: Float = 0.3

    /// L2-normalised weighted mean (cosine space). Empty before the first turn.
    public private(set) var mean: [Float] = []
    public private(set) var embedder: String = ""
    /// Turns averaged in (outliers excluded).
    public private(set) var turns: Int = 0
    public private(set) var totalWeight: Float = 0
    public private(set) var updatedAt: Date?

    public init() {}

    public enum Outcome: Equatable, Sendable {
        /// Averaged in; `turns` so far (still below `minimumTurns`).
        case learning(Int)
        /// This turn made the voiceprint usable (exactly once per voiceprint).
        case ready
        /// Averaged into a voiceprint that was already usable.
        case updated(Int)
        /// Not the voice learned so far; not averaged in.
        case outlier(similarity: Float)
        /// Not a cosine embedding (MFCC fallback): nothing learned.
        case unusable
    }

    public var isUsable: Bool { turns >= Self.minimumTurns && !mean.isEmpty }

    /// The voiceprint, once usable.
    public var embedding: SpeakerEmbedding? {
        isUsable ? SpeakerEmbedding(vector: mean, embedder: embedder, metric: .cosine) : nil
    }

    /// SNR (dB) → weight in 0.05…1: 5 dB (barely above the room) counts 1/20 of a 25 dB turn.
    public static func weight(snrDB: Float) -> Float {
        guard snrDB.isFinite else { return 0.05 }
        return min(1, max(0.05, (snrDB - 5) / 20))
    }

    @discardableResult
    public mutating func update(_ e: SpeakerEmbedding, snrDB: Float, at now: Date = Date()) -> Outcome {
        guard e.metric == .cosine, !e.vector.isEmpty else { return .unusable }
        if !mean.isEmpty, embedder != e.embedder || mean.count != e.vector.count { self = PassiveVoiceprint() }
        if turns >= Self.outlierCheckAfter {
            let s = SpeakerEmbedding(vector: mean, embedder: embedder, metric: .cosine).similarity(e)
            if s < Self.outlierSimilarity { return .outlier(similarity: s) }
        }
        let w = Self.weight(snrDB: snrDB)
        if mean.isEmpty {
            mean = e.vector
            embedder = e.embedder
        } else {
            let total = min(totalWeight, Self.maxTotalWeight - w)
            let a = total / (total + w), b = w / (total + w)
            mean = zip(mean, e.vector).map { $0 * a + $1 * b }
            mean = SpeakerEmbedding(vector: mean, embedder: embedder, metric: .cosine).vector
        }
        totalWeight = min(Self.maxTotalWeight, totalWeight + w)
        turns += 1
        updatedAt = now
        if turns == Self.minimumTurns { return .ready }
        return turns < Self.minimumTurns ? .learning(turns) : .updated(turns)
    }
}

/// M6 — how clean a turn was. Frame energies (20 ms) → SNR ≈ loud-frame level (90th percentile)
/// over the noise floor (10th percentile), in dB. Crude, scale-free and cheap; good enough to weight
/// a quiet-office turn above a café turn.
public enum SignalQuality {
    public static func snrDB(_ samples: [Float], sampleRate: Int = 16_000) -> Float {
        let frame = max(1, sampleRate / 50)
        guard samples.count >= frame * 4 else { return 0 }
        var energies: [Float] = []
        energies.reserveCapacity(samples.count / frame)
        var i = 0
        while i + frame <= samples.count {
            var e: Float = 0
            for k in i..<(i + frame) { e += samples[k] * samples[k] }
            energies.append(e / Float(frame))
            i += frame
        }
        energies.sort()
        let noise = max(energies[energies.count / 10], 1e-10)
        let signal = max(energies[(energies.count * 9) / 10], 1e-10)
        return 10 * log10(signal / noise)
    }
}

/// M7/M8 — a diarizer's (leg, slot) pairs as meeting speakers. The slot judged to be the user is
/// `.you`; every other slot becomes `.others(n)`, numbered by first appearance across both legs
/// (so "Others 2" on the call never collides with someone across the room).
public struct SpeakerSlotMap: Sendable, Equatable {
    public struct Slot: Hashable, Sendable {
        public var leg: MeetingChannel
        public var index: Int
        public init(leg: MeetingChannel, index: Int) { self.leg = leg; self.index = index }
    }

    private var others: [Slot: Int] = [:]
    public private(set) var youSlots: Set<Slot> = []

    public init() {}

    public mutating func markYou(_ slot: Slot) { youSlots.insert(slot) }
    public mutating func unmarkYou(_ slot: Slot) { youSlots.remove(slot) }

    public mutating func speaker(for slot: Slot) -> MeetingSpeaker {
        if youSlots.contains(slot) { return .you }
        if let n = others[slot] { return .others(n) }
        let n = others.count + 1
        others[slot] = n
        return .others(n)
    }
}
