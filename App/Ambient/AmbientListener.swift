import Engine
import Foundation
import Shared

// V5 L3 · ambient on the always-on capture (fixes X13).
//
// Before L3 ambient hung off `LatchRuntime.onTranscript`, a seam that carried text and a SegmentID but
// no audio — so `SpeakerGate.verdict(for:embedder:)` could never run, the verdict stayed `.unknown`,
// and the enrolled-only gate discarded every segment (X13: "Ambient capture switch discards every
// segment"). And nothing ever set `LatchRuntime.source = .ambient` in production, so there were no
// segments to discard in the first place.
//
// Now ambient is a **recorder** on O1's one capture graph (`PipelineAudioSource.attachRecorder(.ambient)`,
// tracked by `SessionCoordinator` as `.ambient`): it subscribes to the `AudioPipeline.Broadcaster`,
// cuts speech segments on the pipeline's own VAD edges (`AmbientSegmenter`), and for each closed
// segment — and only then (L5) — runs ASR on the segment's samples, the speaker verdict on the same
// samples, and hands both to the gate → Timeline → decision pipeline (`AmbientWiring.process`).

/// One closed stretch of speech from the shared capture. Stream seconds, 16 kHz mono.
public struct AmbientSpeechSegment: Equatable, Sendable {
    public var samples: [Float]
    /// Stream time of `samples[0]` (pre-roll included).
    public var start: TimeInterval
    public var sampleRate: Double

    public init(samples: [Float], start: TimeInterval, sampleRate: Double = 16_000) {
        self.samples = samples; self.start = start; self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }
    public var end: TimeInterval { start + duration }
}

/// Cuts speech segments out of the pipeline's event stream on its VAD edges.
///
/// Holds a short rolling history so a segment starts a little before the VAD fired (`preRoll`: the
/// VAD reports speech after it has heard some). Between segments nothing but that history is kept,
/// and nothing downstream runs (L5: ASR only on speech). A segment is cut at `maxSeconds` while speech
/// continues (the rest becomes the next segment), and dropped when shorter than `minSeconds` (a
/// click is not an utterance). Not thread-safe: driven from one task.
public struct AmbientSegmenter: Sendable {
    public struct Config: Equatable, Sendable {
        public var preRoll: TimeInterval = 0.3
        public var maxSeconds: TimeInterval = 30
        public var minSeconds: TimeInterval = 0.4
        public var sampleRate: Double = 16_000
        public init(preRoll: TimeInterval = 0.3, maxSeconds: TimeInterval = 30, minSeconds: TimeInterval = 0.4) {
            self.preRoll = preRoll; self.maxSeconds = maxSeconds; self.minSeconds = minSeconds
        }
        /// History kept between segments.
        var historySamples: Int { Int((preRoll + 1) * sampleRate) }
    }

    public let config: Config
    private var history: [Float] = []
    private var historyStart: TimeInterval = 0
    private var current: [Float]?
    private var currentStart: TimeInterval = 0
    /// Stream time just past the last audio block seen.
    public private(set) var position: TimeInterval = 0

    public init(config: Config = Config()) { self.config = config }

    /// True while a segment is open (speech heard, not yet ended).
    public var isInSpeech: Bool { current != nil }

    /// Feeds one pipeline event; returns the segments it closed (usually none, at most a few).
    public mutating func handle(_ event: AudioPipelineEvent) -> [AmbientSpeechSegment] {
        switch event {
        case .started:
            reset()
            return []
        case .audio(let samples, let at):
            if history.isEmpty { historyStart = at }
            history.append(contentsOf: samples)
            let overflow = history.count - config.historySamples
            if overflow > 0 {
                history.removeFirst(overflow)
                historyStart += Double(overflow) / config.sampleRate
            }
            position = at + Double(samples.count) / config.sampleRate
            guard current != nil else { return [] }
            current?.append(contentsOf: samples)
            let maxSamples = Int(config.maxSeconds * config.sampleRate)
            guard let open = current, open.count >= maxSamples else { return [] }
            // Speech goes on past the bound: close this piece, keep listening in a fresh one.
            let closed = AmbientSpeechSegment(samples: Array(open.prefix(maxSamples)), start: currentStart,
                                              sampleRate: config.sampleRate)
            current = Array(open.dropFirst(maxSamples))
            currentStart += config.maxSeconds
            return [closed]
        case .vad(.speechStart(let at)):
            guard current == nil else { return [] }
            let from = max(historyStart, at - config.preRoll)
            let offset = min(history.count, max(0, Int(((from - historyStart) * config.sampleRate).rounded())))
            current = Array(history[offset...])
            currentStart = historyStart + Double(offset) / config.sampleRate
            return []
        case .vad(.speechEnd):
            return close()
        case .stopped, .captureFailed:
            defer { reset() }
            return close()
        default:
            return []
        }
    }

    private mutating func close() -> [AmbientSpeechSegment] {
        guard let open = current else { return [] }
        current = nil
        let segment = AmbientSpeechSegment(samples: open, start: currentStart, sampleRate: config.sampleRate)
        return segment.duration >= config.minSeconds ? [segment] : []
    }

    private mutating func reset() {
        history.removeAll(keepingCapacity: true)
        current = nil
        historyStart = 0
        position = 0
    }
}

/// The one capture graph, as ambient sees it: join as a recorder, leave again.
public protocol AmbientAudioAttaching: AnyObject, Sendable {
    /// Joins the shared capture. Throws when the microphone is unavailable (hard mute, no permission,
    /// no device) — the listener then stays quiet and tries again on the next `refresh()`.
    func attachAmbient() throws -> AmbientAudioAttachment
}

/// A live recorder subscription: every pipeline event from now on, and the way to leave.
public struct AmbientAudioAttachment: Sendable {
    public var events: AsyncStream<AudioPipelineEvent>
    public var detach: @Sendable () -> Void
    public init(events: AsyncStream<AudioPipelineEvent>, detach: @escaping @Sendable () -> Void) {
        self.events = events; self.detach = detach
    }
}

public enum AmbientAttachError: Error, Equatable, Sendable {
    case muted
    case noCapture
}

/// Production attachment: `SessionCoordinator` records `.ambient` as a running recorder (so hard
/// mute, lock and sleep stand it down), and `PipelineAudioSource.attachRecorder(.ambient)` hands
/// out the subscription. Never constructs a capture of its own (§10).
public final class PipelineAmbientAudio: AmbientAudioAttaching, @unchecked Sendable {
    private let audio: () -> PipelineAudioSource?
    private let isMuted: () -> Bool
    private weak var session: SessionCoordinator?

    public init(audio: @escaping () -> PipelineAudioSource?, session: SessionCoordinator?, isMuted: @escaping () -> Bool) {
        self.audio = audio; self.session = session; self.isMuted = isMuted
    }

    public func attachAmbient() throws -> AmbientAudioAttachment {
        // Checked first so a muted Mac never reaches `requestMicrophone` (whose refusal shows a pill
        // notice — not something a background recorder should do every retry).
        guard !isMuted() else { throw AmbientAttachError.muted }
        guard let source = audio() else { throw AmbientAttachError.noCapture }
        guard session?.requestMicrophone(.ambient).isGranted ?? true else { throw AmbientAttachError.muted }
        let subscription: AudioPipeline.Subscription
        do { subscription = try source.attachRecorder(.ambient) }
        catch { session?.release(.ambient); throw error }
        let session = self.session
        return AmbientAudioAttachment(events: subscription.events) { [weak source] in
            source?.detachRecorder(subscription)
            session?.release(.ambient)
        }
    }
}

/// Ambient listening on the always-on capture.
///
/// Attached while the mode listens (`AmbientMode.listens`), detached when it is Off. Each closed
/// segment is transcribed and judged **once**, serially, at segment end — the decision layer never
/// sees partial speech (L5). The transcriber and the verdict are closures so tests drive the whole
/// path without a microphone, a model or an enrolled voice.
public final class AmbientListener: @unchecked Sendable {
    public typealias Transcribe = @Sendable ([Float]) async throws -> [TranscriptSpan]
    public typealias Verdict = @Sendable ([Float]) -> SpeakerGate.Verdict
    /// Receives one transcribed segment (production: `AmbientWiring.process`).
    public typealias Deliver = @Sendable (AmbientHeard) -> Void

    private let audio: any AmbientAudioAttaching
    private let listens: () -> Bool
    /// An explicit claim (hold key, latch, act key) is active: that speech is the claim's, already
    /// decided by its trigger (Layer 0), so ambient neither transcribes nor decides it a second time.
    private let claimed: () -> Bool
    private let transcribe: () -> Transcribe?
    private let verdict: Verdict
    private let deliver: Deliver
    private let now: @Sendable () -> Date
    private let config: AmbientSegmenter.Config

    private let lock = NSLock()
    private var attachment: AmbientAudioAttachment?
    private var reader: Task<Void, Never>?
    private var chain: Task<Void, Never>?
    private var segmentIndex = 0
    private let sessionID = UUID()
    /// Counters for L5 and tests: segments closed, ASR runs, and how many audio blocks went by.
    public private(set) var stats = Stats()

    public struct Stats: Equatable, Sendable {
        public var audioBlocks = 0
        public var segments = 0
        public var transcriptions = 0
        public var attaches = 0
        /// Segments skipped because an explicit claim owned the speech.
        public var claimedSegments = 0
    }

    public init(audio: any AmbientAudioAttaching,
                listens: @escaping () -> Bool,
                claimed: @escaping () -> Bool = { false },
                transcribe: @escaping () -> Transcribe?,
                verdict: @escaping Verdict,
                config: AmbientSegmenter.Config = AmbientSegmenter.Config(),
                now: @escaping @Sendable () -> Date = { Date() },
                deliver: @escaping Deliver) {
        self.audio = audio; self.listens = listens; self.claimed = claimed; self.transcribe = transcribe
        self.verdict = verdict; self.config = config; self.now = now; self.deliver = deliver
    }

    deinit { reader?.cancel() }

    /// Attached to the shared capture right now.
    public var isAttached: Bool { lock.withLock { attachment != nil } }

    /// Matches the mode: attach when it listens, detach when it does not. Call on every mode change,
    /// on unmute, and after an engine swap (the old graph's stream ends; the next refresh rejoins).
    public func refresh() {
        if listens() { attach() } else { detach() }
    }

    private func attach() {
        guard !isAttached else { return }
        let attached: AmbientAudioAttachment
        do { attached = try audio.attachAmbient() }
        catch {
            Log.app.notice("ambient: not listening — \(String(describing: error))")
            return
        }
        lock.withLock {
            attachment = attached
            stats.attaches += 1
        }
        Log.app.info("ambient: listening on the shared capture")
        let events = attached.events
        let task = Task.detached(priority: .utility) { [weak self] in
            var segmenter = AmbientSegmenter(config: self?.config ?? AmbientSegmenter.Config())
            var claimedDuringSegment = false
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                if case .audio = event {
                    self.lock.withLock { self.stats.audioBlocks += 1 }
                    if segmenter.isInSpeech, self.claimed() { claimedDuringSegment = true }
                }
                if case .vad(.speechStart) = event { claimedDuringSegment = self.claimed() }
                for segment in segmenter.handle(event) {
                    if claimedDuringSegment || self.claimed() {
                        self.lock.withLock { self.stats.claimedSegments += 1 }
                    } else {
                        self.enqueue(segment, streamNow: segmenter.position)
                    }
                    claimedDuringSegment = segmenter.isInSpeech && self.claimed()
                }
            }
            // The stream ended under us (mute stood the recorder down, the graph was swapped).
            self?.streamEnded()
        }
        lock.withLock { reader = task }
    }

    /// Leaves the shared capture. A segment already closed is still transcribed and delivered.
    public func detach() {
        let (attached, task) = lock.withLock { () -> (AmbientAudioAttachment?, Task<Void, Never>?) in
            defer { attachment = nil; reader = nil }
            return (attachment, reader)
        }
        guard let attached else { return }
        attached.detach()
        task?.cancel()
        Log.app.info("ambient: stopped listening")
    }

    private func streamEnded() {
        let attached = lock.withLock { () -> AmbientAudioAttachment? in
            defer { attachment = nil; reader = nil }
            return attachment
        }
        attached?.detach()
    }

    /// Waits for every closed segment to be transcribed and delivered (tests, shutdown).
    public func settle() async {
        while let task = lock.withLock({ chain }) {
            await task.value
            if lock.withLock({ chain }) == task { return }
        }
    }

    private func enqueue(_ segment: AmbientSpeechSegment, streamNow: TimeInterval) {
        // Wall clock for the segment's start: stream positions are relative to the graph's start.
        let capturedAt = now().addingTimeInterval(-max(0, streamNow - segment.start))
        lock.withLock {
            stats.segments += 1
            segmentIndex += 1
            let id = "ambient-\(sessionID.uuidString)-\(segmentIndex)"
            let previous = chain
            chain = Task.detached(priority: .utility) { [weak self] in
                await previous?.value
                await self?.process(segment, id: id, capturedAt: capturedAt)
            }
        }
    }

    private func process(_ segment: AmbientSpeechSegment, id: String, capturedAt: Date) async {
        guard let transcribe = transcribe() else { return }   // no model yet: nothing to hear
        let spans: [TranscriptSpan]
        do {
            lock.withLock { stats.transcriptions += 1 }
            spans = try await transcribe(segment.samples)
        } catch {
            Log.app.error("ambient: segment \(id) not transcribed: \(error)")
            return
        }
        let text = spans.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The verdict runs on the segment's own samples — what X13 never had.
        let voice = text.isEmpty ? SpeakerGate.Verdict.unknown : verdict(segment.samples)
        let confidence = spans.isEmpty ? 0 : spans.map(\.confidence).reduce(0, +) / Float(spans.count)
        deliver(AmbientHeard(id: id, text: text, verdict: voice, capturedAt: capturedAt,
                             duration: segment.duration, confidence: confidence))
    }
}

/// One transcribed ambient segment, with the speaker verdict computed from its samples.
public struct AmbientHeard: Equatable, Sendable {
    public var id: String
    public var text: String
    public var verdict: SpeakerGate.Verdict
    public var capturedAt: Date
    public var duration: TimeInterval
    public var confidence: Float

    public init(id: String, text: String, verdict: SpeakerGate.Verdict, capturedAt: Date,
                duration: TimeInterval, confidence: Float = 1) {
        self.id = id; self.text = text; self.verdict = verdict; self.capturedAt = capturedAt
        self.duration = duration; self.confidence = confidence
    }
}
