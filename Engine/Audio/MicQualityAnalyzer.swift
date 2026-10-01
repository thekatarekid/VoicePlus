import Foundation
import Shared

/// V4.18 — the mic-quality verdict measures signal against noise.
///
/// v1 took p90/p10 of frame RMS inside a 300 ms window of *speech*: that is the syllabic modulation
/// depth of one word (3–6 dB), not SNR, so clean close speech read "Noisy mic", a quieter room read
/// *lower*, and the 1.5 s deadline graded the pause itself as "Mic level is very low". v2:
///
/// * **Noise floor** — p10 of 10 ms frame RMS over the pre-speech window: capture start (key-down) up
///   to the first VAD `speechStart`, when that window holds at least 200 ms of audio. Otherwise the
///   running minimum frame RMS over the 4 s before the verdict is taken (see `feed`) — the minimum
///   statistics `EnergyVAD`'s floor tracker keeps, per 10 ms frame and without its 60 ms hold. It is
///   tracked here because the VAD's value is private, scaled up for onset detection, and Silero keeps
///   none. (No hold here: it would erase the short gaps between words it is meant to find, so the
///   microphone's start-up dip can still be this floor, or the p10 of a pre-speech window shorter
///   than ~0.5 s — which reads the SNR high, never low. Open: DECISIONS.md, F1 fix.)
///   A window that reached speech level (its p90 within 10 dB of the signal's) while its p10 sat more
///   than 10 dB above that running minimum held speech the VAD missed — the energy VAD learns its
///   floor from its first frames, so words from the first sample read as floor. The running minimum
///   is used then too.
/// * **Signal** — p90 of frame RMS over the VAD-speech frames of the first 1 s of speech.
/// * **Once** — the verdict is published exactly once, as soon as both exist. `flush()` at stop grades
///   whatever speech there was, and returns nothing when there was none: a pause is never graded.
/// * **Low level** — only speech that peaks below −40 dBFS. Silence is not "very low"; it is silence.
/// * **Verdict** — bad below 5 dB, poor below 10 dB. Both bounds are a `hypothesis` until the Wave 2
///   corpus sets them. The clipping bounds are kept from v1 (> 2 % bad, > 0.2 % poor).
///
/// Frames quieter than −100 dBFS are digital silence (device warm-up, pre-roll padding, virtual
/// devices): the absence of a signal rather than a noise floor, so a few zero buffers at key-down
/// cannot hide a noisy room. Neither floor estimate counts them; a pre-speech window of nothing but
/// digital silence gives the digital floor itself, which also caps the SNR (100 dB).
///
/// Time is stream time in seconds since `reset()`: the clock the VAD's events carry. `AudioPipeline`
/// resets both at `start()` and feeds both the same samples. Driven from one task (the pipeline's
/// worker); not thread-safe.
///
/// **Deterministic.** The verdict is a function of the samples and of where in them each event was
/// noted — never of how the samples were split into `feed` calls, nor of when those calls ran.
/// `AudioPipeline` feeds the analyzer one VAD frame at a time, just before the VAD hears that frame,
/// so where each event lands is itself fixed by the audio. (Fed a whole ring read at once, as it was
/// before, a busy machine handed it the file in one block: the "last 4 s" of the running minimum
/// then ended at the file's end instead of at the speech, and the same recording read 26 dB alone
/// and 8 dB under a parallel test run.)
public final class MicQualityAnalyzer: @unchecked Sendable {
    public static let sampleRate = 16_000
    /// 10 ms analysis frames.
    public static let frameSamples = 160
    public static let frameDuration: TimeInterval = 0.01
    /// The pre-speech window must be at least this long to be the floor.
    public static let minimumPreSpeech: TimeInterval = 0.2
    /// Span of the running-minimum floor used when the pre-speech window is too short.
    public static let runningFloorWindow: TimeInterval = 4
    /// Speech graded for the signal estimate: the first second of VAD speech.
    public static let signalWindow: TimeInterval = 1
    /// `hypothesis` (V4.18; DECISIONS.md 2026-09-19 "F1, mic-quality thresholds"): the Wave 2 corpus sets it.
    public static let poorBelowSNR: Float = 10
    /// `hypothesis` (V4.18; DECISIONS.md 2026-09-19 "F1, mic-quality thresholds"): the Wave 2 corpus sets it.
    public static let badBelowSNR: Float = 5
    public static let lowLevelPeakDB: Float = -40
    public static let clipThreshold: Float = 0.985
    public static let poorClipping: Float = 0.002
    public static let badClipping: Float = 0.02
    /// Missed-onset test: the pre-speech p90 within this of the signal's p90, and its p10 more than
    /// this above the running minimum.
    public static let missedOnsetMarginDB: Float = 10
    /// −100 dBFS: below any real microphone's self-noise.
    public static let digitalSilence: Float = 1e-5
    /// Unclassified frames kept while no speech segment is open (30 s). The pre-speech window is the
    /// most recent 30 s before onset; VAD events trail the audio by well under a second.
    static let unclassifiedLimit = 3_000

    static var signalFrameCount: Int { Int((signalWindow / frameDuration).rounded()) }
    static var runningFrameCount: Int { Int((runningFloorWindow / frameDuration).rounded()) }
    static var minimumPreSpeechFrames: Int { Int((minimumPreSpeech / frameDuration).rounded()) }

    /// Which estimate the published floor came from.
    public enum FloorSource: Equatable, Sendable {
        /// p10 over a pre-speech window of at least 200 ms.
        case preSpeech
        /// Running minimum over the last 4 s: the pre-speech window was under 200 ms.
        case runningMinimum
        /// Running minimum over the last 4 s: the pre-speech window held speech the VAD missed.
        case missedOnset
        /// The pre-speech window (or, failing that, the last 4 s) held only digital silence.
        case digitalSilence
    }

    /// What the verdict was computed from — diagnostics for the Lab and tests.
    public struct Measurement: Equatable, Sendable {
        public var floorRMS: Float
        public var signalRMS: Float
        public var speechPeak: Float
        public var floorSource: FloorSource
        /// Speech actually graded (≤ `signalWindow`; less when `flush()` graded a short utterance).
        public var speechSeconds: TimeInterval

        public var floorDBFS: Float { MicQualityAnalyzer.dbfs(floorRMS) }
        public var signalDBFS: Float { MicQualityAnalyzer.dbfs(signalRMS) }
        public var speechPeakDBFS: Float { MicQualityAnalyzer.dbfs(speechPeak) }
    }

    struct Frame: Equatable {
        var rms: Float
        var peak: Float
        var clipped: Int
    }

    private(set) public var result: MicQuality?
    private(set) public var measurement: Measurement?

    private var partial: [Float] = []
    /// Frames not yet classified as speech or dropped; absolute index `frameBase + i`.
    private var frames: [Frame] = []
    private var frameBase = 0
    /// Non-silent frame RMS within the last `runningFloorWindow`, by absolute frame index.
    private var runningFloor: [(index: Int, rms: Float)] = []
    private var onset: TimeInterval?
    private var preSpeechFloor: PreSpeech?
    /// Start of the VAD segment still open (no `speechEnd` yet).
    private var openStart: TimeInterval?
    /// Frames of closed segments, in time order, capped at `signalFrameCount`.
    private var speech: [Frame] = []

    /// V5 C1 — stream time after `reset()` whose frames never feed a floor estimate (pre-speech p10
    /// or running minimum): an AGC still ramping reads as a quiet room. Survives `reset()`; 0 = off.
    public var warmup: TimeInterval = 0
    private var warmupFrames: Int { Int((warmup / Self.frameDuration).rounded()) }

    public init() {}

    public func reset() {
        partial.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        frameBase = 0
        runningFloor.removeAll(keepingCapacity: true)
        onset = nil
        preSpeechFloor = nil
        openStart = nil
        speech.removeAll(keepingCapacity: true)
        result = nil
        measurement = nil
    }

    // MARK: input

    /// Feed audio in stream order. Returns the verdict exactly once: at the call in which the VAD's
    /// speech reaches a full second.
    ///
    /// The verdict is taken at the 10 ms frame that completes that second (or, when a `speechEnd`
    /// completed it, before any later audio), never at the end of the block that carried it: the
    /// running-minimum floor ends there too, so how the audio was split into calls changes nothing.
    @discardableResult
    public func feed(_ samples: [Float]) -> MicQuality? {
        guard result == nil, !samples.isEmpty else { return nil }
        if speechFrameCount >= Self.signalFrameCount { return publish() }
        var i = 0
        while i < samples.count {
            let frame: Frame
            if partial.isEmpty, samples.count - i >= Self.frameSamples {
                frame = Self.frame(samples[i..<i + Self.frameSamples])
                i += Self.frameSamples
            } else {
                let take = min(Self.frameSamples - partial.count, samples.count - i)
                partial.append(contentsOf: samples[i..<i + take])
                i += take
                guard partial.count == Self.frameSamples else { break }
                frame = Self.frame(partial[...])
                partial.removeAll(keepingCapacity: true)
            }
            append(frame)
            if openStart != nil, speechFrameCount >= Self.signalFrameCount { return publish() }
        }
        if openStart == nil { trimUnclassified() }
        return nil
    }

    /// A VAD event on the same clock as the fed audio. The first `speechStart` closes the pre-speech
    /// window; every segment's frames become signal candidates.
    public func note(_ event: VADEvent) {
        guard result == nil else { return }
        switch event {
        case .speechStart(let start):
            guard openStart == nil else { return }
            if onset == nil {
                onset = start
                preSpeechFloor = Self.preSpeechFloor(frames.prefix(max(0, Self.firstFrame(atOrAfter: start) - frameBase))
                    .dropFirst(max(0, warmupFrames - frameBase)))
            }
            drop(before: start)            // pause between segments: never graded
            openStart = start
        case .speechEnd(let end):
            guard let start = openStart else { return }
            let from = max(Self.firstFrame(atOrAfter: start), frameBase) - frameBase
            let to = min(max(Self.firstFrame(atOrAfter: end) - frameBase, from), frames.count)
            let room = Self.signalFrameCount - speech.count
            if room > 0, from < to { speech.append(contentsOf: frames[from..<min(to, from + room)]) }
            drop(before: end)
            openStart = nil
        }
    }

    /// Stop: grades the speech collected so far (an utterance shorter than a second). Returns nil when
    /// no speech was heard, or when the verdict was already published.
    public func flush() -> MicQuality? {
        guard result == nil else { return nil }
        return publish()
    }

    // MARK: grading

    public static func verdict(snr: Float, clipping: Float, lowLevel: Bool) -> MicQuality.Verdict {
        if lowLevel || clipping > badClipping || snr < badBelowSNR { return .bad }
        if clipping > poorClipping || snr < poorBelowSNR { return .poor }
        return .good
    }

    /// Offline statistic over one raw buffer (Lab, tests): the buffer's own p10 and p90 frame RMS,
    /// its peak and its clipping, graded by `verdict`. It cannot tell speech from a pause, so it is
    /// *not* the live verdict. The live verdict comes from `feed`/`note`/`flush`.
    public static func analyze(_ samples: [Float]) -> MicQuality {
        guard !samples.isEmpty else { return MicQuality(snr: 0, clipping: 0, lowLevel: true, verdict: .bad) }
        var all: [Frame] = []
        var i = 0
        while i + frameSamples <= samples.count {
            all.append(frame(samples[i..<i + frameSamples]))
            i += frameSamples
        }
        if all.isEmpty { all = [frame(samples[...])] }
        let floor = percentile(all.map(\.rms), 0.1)
        return grade(all, floor: floor, samples: samples.count).quality
    }

    // MARK: internals

    private var speechFrameCount: Int {
        guard let start = openStart else { return speech.count }
        let first = max(Self.firstFrame(atOrAfter: start), frameBase)
        return speech.count + max(0, frameBase + frames.count - first)
    }

    private func append(_ frame: Frame) {
        let index = frameBase + frames.count
        frames.append(frame)
        if frame.rms >= Self.digitalSilence, index >= warmupFrames { runningFloor.append((index, frame.rms)) }
        let expired = runningFloor.prefix(while: { $0.index <= index - Self.runningFrameCount }).count
        if expired > 0 { runningFloor.removeFirst(expired) }
    }

    /// Drops frames whose centre precedes `time`.
    private func drop(before time: TimeInterval) {
        let k = min(max(Self.firstFrame(atOrAfter: time) - frameBase, 0), frames.count)
        guard k > 0 else { return }
        frames.removeFirst(k)
        frameBase += k
    }

    private func trimUnclassified() {
        let excess = frames.count - Self.unclassifiedLimit
        guard excess > 0 else { return }
        frames.removeFirst(excess)
        frameBase += excess
    }

    private func publish() -> MicQuality? {
        var signal = speech
        if let start = openStart, signal.count < Self.signalFrameCount {
            let from = max(Self.firstFrame(atOrAfter: start), frameBase) - frameBase
            if from < frames.count { signal.append(contentsOf: frames[from...].prefix(Self.signalFrameCount - signal.count)) }
        }
        guard !signal.isEmpty else { return nil }
        let (floor, source) = currentFloor(signal: Self.percentile(signal.map(\.rms), 0.9))
        let graded = Self.grade(signal, floor: floor, samples: signal.count * Self.frameSamples)
        result = graded.quality
        measurement = Measurement(floorRMS: max(floor, Self.digitalSilence), signalRMS: graded.signal,
                                  speechPeak: graded.peak, floorSource: source,
                                  speechSeconds: Double(signal.count) * Self.frameDuration)
        // Published once; nothing below is read again until `reset()`.
        frames.removeAll(); speech.removeAll(); runningFloor.removeAll(); partial.removeAll()
        return result
    }

    private func currentFloor(signal: Float) -> (Float, FloorSource) {
        let running = runningFloor.lazy.map(\.rms).min()
        if let pre = preSpeechFloor {
            if pre.source == .preSpeech, let running,
               Self.dbfs(pre.loud) > Self.dbfs(signal) - Self.missedOnsetMarginDB,
               Self.dbfs(pre.floor) - Self.dbfs(running) > Self.missedOnsetMarginDB {
                return (running, .missedOnset)
            }
            return (pre.floor, pre.source)
        }
        if let running { return (running, .runningMinimum) }
        return (Self.digitalSilence, .digitalSilence)
    }

    /// p10 of the pre-speech window, or nil when the window is shorter than `minimumPreSpeech` (the
    /// caller then falls back to the running minimum). Digital-silence frames count towards the
    /// window's length but not towards its floor.
    static func preSpeechFloor<C: Collection>(_ window: C) -> PreSpeech? where C.Element == Frame {
        guard window.count >= minimumPreSpeechFrames else { return nil }
        let audible = window.map(\.rms).filter { $0 >= digitalSilence }
        guard !audible.isEmpty else { return PreSpeech(floor: digitalSilence, loud: digitalSilence, source: .digitalSilence) }
        return PreSpeech(floor: percentile(audible, 0.1), loud: percentile(audible, 0.9), source: .preSpeech)
    }

    /// The pre-speech window's p10 (the floor) and p90 (for the missed-onset test).
    struct PreSpeech: Equatable {
        var floor: Float
        var loud: Float
        var source: FloorSource
    }

    static func grade(_ frames: [Frame], floor: Float, samples: Int) -> (quality: MicQuality, signal: Float, peak: Float) {
        let signal = percentile(frames.map(\.rms), 0.9)
        let peak = frames.lazy.map(\.peak).max() ?? 0
        let clipped = frames.reduce(0) { $0 + $1.clipped }
        let snr = max(0, 20 * log10(max(signal, digitalSilence) / max(floor, digitalSilence)))
        let clipping = Float(clipped) / Float(max(1, samples))
        let lowLevel = dbfs(peak) < lowLevelPeakDB
        let quality = MicQuality(snr: snr, clipping: clipping, lowLevel: lowLevel,
                                 verdict: verdict(snr: snr, clipping: clipping, lowLevel: lowLevel))
        return (quality, signal, peak)
    }

    static func frame(_ samples: ArraySlice<Float>) -> Frame {
        var acc: Float = 0
        var peak: Float = 0
        var clipped = 0
        for s in samples {
            let a = abs(s)
            acc += s * s
            if a > peak { peak = a }
            if a >= clipThreshold { clipped += 1 }
        }
        return Frame(rms: (acc / Float(max(1, samples.count))).squareRoot(), peak: peak, clipped: clipped)
    }

    /// Index of the first 10 ms frame whose centre is at or after `time`.
    static func firstFrame(atOrAfter time: TimeInterval) -> Int {
        max(0, Int((time / frameDuration - 0.5 - 1e-9).rounded(.up)))
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[Int(Double(sorted.count - 1) * p)]
    }

    static func dbfs(_ value: Float) -> Float { 20 * log10(max(value, 1e-9)) }
}
