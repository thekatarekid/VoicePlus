import Engine
import Foundation
import Shared

/// H2 (V4.49) — the capture side of passive enrollment and of the latch speaker filter.
///
/// A second subscriber on the capture pipeline's broadcast (the engine's view of the audio is
/// unchanged). It does two things:
/// * **Holds.** A dictation capture that was never latched is a hold-to-talk utterance: the user
///   by definition. Until a voice is enrolled, its samples (RAM only, capped) and its VAD speech
///   seconds go to `LatchController.observeHoldUtterance` off the main thread when capture stops.
///   Once a voice is enrolled nothing is buffered.
/// * **Latch segments.** While latched the audio goes into `segmentAudio`, which the runtime's
///   speaker guard takes once per closed segment (`LatchController.attach(runtime:segmentAudio:)`).
///   It starts empty on every latch entry.
///
/// Nothing here is written anywhere; the enrollment keeps embeddings only.
public final class SpeakerAudioWiring: @unchecked Sendable {
    /// Longest hold kept for an embedding. The embedder needs a voice, not the whole utterance.
    public static let maxHoldSeconds: TimeInterval = 30
    static let sampleRate: Double = 16_000

    public let segmentAudio: LatchSegmentAudio
    private let isLatched: () -> Bool
    private let wantsHolds: () -> Bool
    private let observe: ([Float], TimeInterval) -> Void

    private struct Hold {
        var dictation: Bool
        var learning: Bool
        var sawLatch = false
        var samples: [Float] = []
        var ledger = SpeechLedger()
        var end: TimeInterval = 0
    }

    private let lock = NSLock()
    private var hold: Hold?
    private var wasLatched = false
    private var isDictationCapture: () -> Bool = { false }
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - isLatched: is the app latched right now (`DictationCoordinator.latched`).
    ///   - wantsHolds: should holds be buffered at all (false once a voice is enrolled).
    ///   - observe: receives a finished hold's samples and VAD speech seconds, on the thread that
    ///     saw capture stop. Production passes `observeHolds(on:)`.
    public init(segmentAudio: LatchSegmentAudio = LatchSegmentAudio(),
                isLatched: @escaping () -> Bool,
                wantsHolds: @escaping () -> Bool,
                observe: @escaping ([Float], TimeInterval) -> Void) {
        self.segmentAudio = segmentAudio
        self.isLatched = isLatched
        self.wantsHolds = wantsHolds
        self.observe = observe
    }

    /// The production observer: each finished hold is embedded on a utility queue (a CoreML call).
    public static func observeHolds(on controller: LatchController) -> ([Float], TimeInterval) -> Void {
        { [weak controller] samples, speech in
            DispatchQueue.global(qos: .utility).async {
                guard let controller else { return }
                let result = controller.observeHoldUtterance(samples: samples, speechSeconds: speech)
                Log.app.info("speaker: passive enrollment — \(String(describing: result))")
            }
        }
    }

    deinit { task?.cancel() }

    /// Follows `audio`'s pipeline. Call again after an engine swap: the old subscription stops.
    public func bind(to audio: PipelineAudioSource) {
        bind(events: audio.pipeline.events(), isDictationCapture: { [weak audio] in audio?.currentOwner == .engine })
    }

    /// Follows an event stream (tests pass their own).
    public func bind(events: AsyncStream<AudioPipelineEvent>, isDictationCapture: @escaping () -> Bool) {
        let task = Task.detached(priority: .utility) { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
        let old = lock.withLock { () -> Task<Void, Never>? in
            let was = self.task
            self.task = task
            self.isDictationCapture = isDictationCapture
            self.hold = nil
            return was
        }
        old?.cancel()
    }

    /// One pipeline event. Internal so tests can drive it without a stream.
    func handle(_ event: AudioPipelineEvent) {
        switch event {
        case .started:
            let dictation = lock.withLock { isDictationCapture }()
            let learning = wantsHolds()
            lock.withLock { hold = Hold(dictation: dictation, learning: learning) }
        case .audio(let samples, let position):
            let latched = isLatched()
            let entered = lock.withLock { () -> Bool in
                let entered = latched && !wasLatched
                wasLatched = latched
                // Mutated in place (`hold?.…`): a copy out and back would copy the buffer per block.
                guard hold != nil else { return entered }
                hold?.end = position + Double(samples.count) / Self.sampleRate
                if latched, hold?.sawLatch == false { hold?.sawLatch = true; hold?.samples = [] }
                let buffering = hold?.learning == true && hold?.sawLatch == false && hold?.dictation == true
                let room = Int(Self.maxHoldSeconds * Self.sampleRate) - (hold?.samples.count ?? 0)
                if buffering, room > 0 { hold?.samples.append(contentsOf: samples.prefix(room)) }
                return entered
            }
            if entered { segmentAudio.reset() }
            if latched { segmentAudio.append(samples) }
        case .vad(let edge):
            lock.withLock { _ = hold?.ledger.note(edge) }
        case .stopped:
            let finished = lock.withLock { () -> Hold? in
                defer { hold = nil; wasLatched = false }
                return hold
            }
            guard let h = finished, h.dictation, h.learning, !h.sawLatch, !h.samples.isEmpty else { return }
            observe(h.samples, h.ledger.speechSeconds(from: 0, to: h.end))
        case .level, .micQuality, .chunk, .endpoint, .deviceChanged, .overrun, .captureFailed:
            break
        }
    }
}
