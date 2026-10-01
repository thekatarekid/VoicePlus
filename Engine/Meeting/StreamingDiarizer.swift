import CoreML
import FluidAudio
import Foundation
import Shared

// V5 M7 — live speaker labels from Sortformer.
//
// `StreamingDiarizer` runs a streaming diarizer per capture leg (mic, and system in video-call /
// hybrid) over the meeting's VAD chunks and keeps every leg's speaker turns on the meeting clock.
// `SortformerLabeler` is the `SpeakerLabeler` sessions use: it emits a `speakerIndex`-backed label
// per chunk (`SpeakerSlotMap`), deciding which mic-leg speaker is the user from the embedding labeler
// (M12, the user's voiceprint) it wraps. The backend is a protocol so all of this is testable without
// CoreML; production is `SortformerBackend` over FluidAudio's `SortformerDiarizer`.
//
// **Speaker cap (verified in the pinned FluidAudio, `SortformerConfig.numSpeakers` = 4, a `let`):**
// Sortformer tracks at most 4 speakers per stream. VoicePlus runs one stream per leg, so a meeting
// distinguishes at most 4 voices in the room (mic) + 4 on the call (system); a 5th voice on one leg is
// folded into one of its 4 slots. The offline re-diarization (M8) has the same cap per leg.
//
// **Latency (measured from the config, not the model):** the high-context v2.1 variant the catalog
// installs finalizes in 340-frame chunks (27.2 s) with 40 frames (3.2 s) of right context, so the first
// labels of each leg arrive ~30 s in. Until a chunk is covered, its label is the wrapped labeler's
// (voiceprint / channel) and marked provisional (confidence 0.5); M8 relabels everything at the end.

/// One speaker's activity on one stream. `speaker` is the diarizer's slot (0..<cap).
public struct SpeakerTurn: Equatable, Sendable {
    public var speaker: Int
    public var range: ClosedRange<TimeInterval>
    public init(speaker: Int, range: ClosedRange<TimeInterval>) { self.speaker = speaker; self.range = range }
    public var duration: TimeInterval { range.upperBound - range.lowerBound }
}

/// A streaming diarizer with one independent stream per leg. Times are seconds of audio *fed to that
/// leg's stream* (the caller maps them onto the meeting clock).
public protocol StreamingSpeakerDiarizing: AnyObject, Sendable {
    var name: String { get }
    /// Most speakers one stream can tell apart.
    var maxSpeakers: Int { get }
    /// Load the model (through `ModelResidency`). Throws when it cannot.
    func prepare() async throws
    /// Appends 16 kHz mono `samples` to `leg`'s stream; returns every turn known on it so far.
    func push(_ samples: [Float], leg: MeetingChannel) throws -> [SpeakerTurn]
    /// Flushes `leg`'s stream; returns its final turns.
    func finish(leg: MeetingChannel) throws -> [SpeakerTurn]
}

/// Maps a leg's fed-audio seconds back onto the meeting clock. Silent chunks never reach the
/// diarizer, so fed time is the meeting time with the gaps squeezed out.
public struct FedClock: Sendable, Equatable {
    struct Piece: Sendable, Equatable { var fed: TimeInterval; var meeting: TimeInterval; var duration: TimeInterval }
    private(set) var pieces: [Piece] = []
    public private(set) var fedSeconds: TimeInterval = 0

    public init() {}

    public mutating func append(meetingStart: TimeInterval, duration: TimeInterval) {
        guard duration > 0 else { return }
        pieces.append(Piece(fed: fedSeconds, meeting: meetingStart, duration: duration))
        fedSeconds += duration
    }

    /// The meeting-clock ranges a fed range covers (one per piece it touches).
    public func meetingRanges(_ fed: ClosedRange<TimeInterval>) -> [ClosedRange<TimeInterval>] {
        pieces.compactMap { p in
            let lo = max(fed.lowerBound, p.fed), hi = min(fed.upperBound, p.fed + p.duration)
            guard hi > lo else { return nil }
            return (p.meeting + lo - p.fed)...(p.meeting + hi - p.fed)
        }
    }
}

/// M7 — the per-leg streaming diarization state of one meeting, on the meeting clock.
public final class StreamingDiarizer: @unchecked Sendable {
    public let backend: any StreamingSpeakerDiarizing
    public let legs: Set<MeetingChannel>
    private let lock = NSLock()
    private var clocks: [MeetingChannel: FedClock] = [:]
    private var turns: [MeetingChannel: [SpeakerTurn]] = [:]
    private var finished: Set<MeetingChannel> = []

    /// `legs`: which legs to diarize — the mic always; the system leg in video-call / hybrid modes.
    public init(backend: any StreamingSpeakerDiarizing, legs: Set<MeetingChannel> = [.mic, .system]) {
        self.backend = backend; self.legs = legs
    }

    public func prepare() async throws { try await backend.prepare() }

    /// Feeds one chunk (ignored for a leg that is not diarized, or after `finish`).
    public func ingest(_ chunk: MeetingChunk) throws {
        let leg = chunk.channel
        guard legs.contains(leg), lock.withLock({ !finished.contains(leg) }) else { return }
        let fedTurns = try backend.push(chunk.chunk.samples, leg: leg)
        lock.withLock {
            var clock = clocks[leg] ?? FedClock()
            clock.append(meetingStart: chunk.range.lowerBound, duration: Double(chunk.chunk.samples.count) / 16_000)
            clocks[leg] = clock
            turns[leg] = Self.onMeetingClock(fedTurns, clock: clock)
        }
    }

    /// The slot with the most speech over `range` on `leg`, with its share of the range, if any.
    public func speakerIndex(leg: MeetingChannel, over range: ClosedRange<TimeInterval>) -> (index: Int, share: Double)? {
        let known = lock.withLock { turns[leg] ?? [] }
        return Self.dominant(in: known, over: range)
    }

    /// Every leg's turns as known now (meeting clock).
    public var currentTurns: [MeetingChannel: [SpeakerTurn]] { lock.withLock { turns } }

    /// Flushes every leg (idempotent) and returns the final turns on the meeting clock.
    @discardableResult
    public func finish() -> [MeetingChannel: [SpeakerTurn]] {
        for leg in legs where lock.withLock({ finished.insert(leg).inserted }) {
            guard let fed = try? backend.finish(leg: leg) else { continue }
            lock.withLock { if let clock = clocks[leg] { turns[leg] = Self.onMeetingClock(fed, clock: clock) } }
        }
        return currentTurns
    }

    static func onMeetingClock(_ fed: [SpeakerTurn], clock: FedClock) -> [SpeakerTurn] {
        fed.flatMap { t in clock.meetingRanges(t.range).map { SpeakerTurn(speaker: t.speaker, range: $0) } }
    }

    /// Slot with the largest overlap with `range`; nil when no turn overlaps it.
    public static func dominant(in turns: [SpeakerTurn], over range: ClosedRange<TimeInterval>) -> (index: Int, share: Double)? {
        var overlap: [Int: Double] = [:]
        for t in turns {
            let o = min(t.range.upperBound, range.upperBound) - max(t.range.lowerBound, range.lowerBound)
            if o > 0 { overlap[t.speaker, default: 0] += o }
        }
        guard let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        let length = max(range.upperBound - range.lowerBound, 1e-3)
        return (best.key, min(1, best.value / length))
    }
}

/// M7 — the session's labeler when Sortformer is installed. Each chunk of a diarized leg is labelled
/// from its Sortformer slot: system-leg slots are always other people; a mic-leg slot is the user when
/// the wrapped labeler (the M12 embedding labeler against the user's voiceprint, or the channel
/// labeler without one) has called its chunks "You" more often than not. Chunks the diarizer has not
/// covered yet get the wrapped labeler's answer, provisional (confidence ≤ 0.5). If the model cannot
/// load, every batch is the wrapped labeler's — never worse than before M7.
public final class SortformerLabeler: SpeakerLabeler, @unchecked Sendable {
    public let name = "sortformer"
    public let diarizer: StreamingDiarizer
    public let fallback: any SpeakerLabeler
    private let lock = NSLock()
    private var slots = SpeakerSlotMap()
    private var youVotes: [SpeakerSlotMap.Slot: (you: Int, other: Int)] = [:]
    private var unavailable = false

    public init(diarizer: StreamingDiarizer, fallback: any SpeakerLabeler) {
        self.diarizer = diarizer; self.fallback = fallback
    }

    public func label(_ chunks: [MeetingChunk]) async throws -> [LabeledChunk] {
        let base = try await fallback.label(chunks)
        if !lock.withLock({ unavailable }) {
            do { try await diarizer.prepare() } catch {
                Log.engine.warning("meeting: Sortformer unavailable, \(self.fallback.name) labels only: \(error)")
                lock.withLock { unavailable = true }
            }
        }
        guard !lock.withLock({ unavailable }) else { return base }
        for c in chunks { try? diarizer.ingest(c) }
        return base.map(relabel)
    }

    private func relabel(_ b: LabeledChunk) -> LabeledChunk {
        let leg = b.chunk.channel
        guard diarizer.legs.contains(leg), let hit = diarizer.speakerIndex(leg: leg, over: b.chunk.range) else {
            return LabeledChunk(chunk: b.chunk, speaker: b.speaker, confidence: min(b.confidence, 0.5))
        }
        let slot = SpeakerSlotMap.Slot(leg: leg, index: hit.index)
        let speaker = lock.withLock { () -> MeetingSpeaker in
            if leg == .mic {
                var v = youVotes[slot] ?? (0, 0)
                if b.speaker == .you { v.you += 1 } else { v.other += 1 }
                youVotes[slot] = v
                if v.you > v.other { slots.markYou(slot) } else { slots.unmarkYou(slot) }
            }
            return slots.speaker(for: slot)
        }
        return LabeledChunk(chunk: b.chunk, speaker: speaker, confidence: Float(0.5 + 0.5 * hit.share))
    }

    /// Which (leg, slot) pairs are the user, by the votes so far (M8 reuses this).
    public var userSlots: Set<SpeakerSlotMap.Slot> { lock.withLock { slots.youSlots } }
}

// MARK: - FluidAudio Sortformer backend

/// M7 — FluidAudio's `SortformerDiarizer` (high-context v2.1, the catalog's `.sortformer`), one
/// instance per leg sharing one loaded model. The model is registered with `ModelResidency` as
/// `.onDemand` and loaded on the first `prepare()`; `push`/`finish` throw `SpeakerError
/// .backendUnavailable` while it is not resident. Calls are serialised (the shared model's scratch
/// buffers are not reentrant).
public final class SortformerBackend: StreamingSpeakerDiarizing, @unchecked Sendable {
    public static let residencyKey = "meeting.sortformer"
    public let name = "sortformer-high-v2.1"
    public let maxSpeakers = 4
    public static var config: SortformerConfig { .highContextV2_1 }

    private let bundle: URL
    private let residency: ModelResidency
    private let box = ModelBox()
    private let lock = NSLock()
    private var registered = false
    private var streams: [MeetingChannel: SortformerDiarizer] = [:]

    final class ModelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _models: SortformerModels?
        var models: SortformerModels? {
            get { lock.withLock { _models } }
            set { lock.withLock { _models = newValue } }
        }
    }

    /// `folder`: the installed `.sortformer` model folder (`ModelManager.locate(.sortformer)`).
    public init(folder: URL, residency: ModelResidency = .shared) {
        self.bundle = folder.appendingPathComponent(SortformerFiles.bundle, isDirectory: true)
        self.residency = residency
    }

    /// Where the installed model is, if complete (`ModelIntegrity`). Never downloads.
    public static func locate(modelsRoot: URL = ModelCatalog.modelsRoot(), fileManager: FileManager = .default) -> URL? {
        let folder = ModelCatalog.folder(for: .sortformer, in: modelsRoot)
        return ModelIntegrity.isComplete(ModelCatalog.descriptor(.sortformer), at: folder, fileManager: fileManager) ? folder : nil
    }

    public func prepare() async throws {
        let first = lock.withLock { () -> Bool in defer { registered = true }; return !registered }
        if first {
            let box = box, bundle = bundle
            await residency.register(Self.residencyKey, tier: .onDemand,
                                     estimatedBytes: ModelCatalog.descriptor(.sortformer).approxBytes * 2,
                                     owner: "meeting.diarization",
                                     load: {
                                         guard box.models == nil else { return }
                                         let cfg = MLModelConfiguration()
                                         cfg.computeUnits = SortformerModels.recommendedComputeUnits(for: Self.config)
                                         let main = try MLModel(contentsOf: bundle, configuration: cfg)
                                         box.models = try SortformerModels(config: Self.config, main: main)
                                     },
                                     unload: { box.models = nil })
        }
        try await residency.acquire(Self.residencyKey)
    }

    private func stream(_ leg: MeetingChannel) throws -> SortformerDiarizer {
        if let s = streams[leg] { return s }
        guard let models = box.models else { throw SpeakerError.backendUnavailable }
        let s = SortformerDiarizer(config: Self.config)
        s.initialize(models: models)
        streams[leg] = s
        return s
    }

    public func push(_ samples: [Float], leg: MeetingChannel) throws -> [SpeakerTurn] {
        try lock.withLock {
            let s = try stream(leg)
            _ = try s.process(samples: samples)
            return Self.turns(of: s.timeline, includeTentative: true)
        }
    }

    public func finish(leg: MeetingChannel) throws -> [SpeakerTurn] {
        try lock.withLock {
            guard let s = streams[leg] else { return [] }
            _ = try s.finalizeSession()
            return Self.turns(of: s.timeline, includeTentative: true)
        }
    }

    static func turns(of timeline: DiarizerTimeline, includeTentative: Bool) -> [SpeakerTurn] {
        timeline.speakers.values.flatMap { sp in
            (sp.finalizedSegments + (includeTentative ? sp.tentativeSegments : [])).map {
                SpeakerTurn(speaker: sp.index, range: Double($0.startTime)...Double(max($0.startTime, $0.endTime)))
            }
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// M8 — the whole recording of one leg through a fresh stream on the same resident model.
    func diarizeComplete(_ samples: [Float]) throws -> [SpeakerTurn] {
        try lock.withLock {
            guard let models = box.models else { throw SpeakerError.backendUnavailable }
            let s = SortformerDiarizer(config: Self.config)
            s.initialize(models: models)
            return Self.turns(of: try s.processComplete(samples), includeTentative: true)
        }
    }
}
