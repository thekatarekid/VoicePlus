import Foundation
import Shared

/// Which capture leg a chunk came from.
public enum MeetingChannel: String, Codable, Sendable, CaseIterable { case mic, system }

/// A VAD-bounded 3–5 s chunk from one channel, positioned on the shared meeting clock.
public struct MeetingChunk: Sendable, Equatable {
    public var channel: MeetingChannel
    public var chunk: AudioChunk
    /// V5 M3 — mic chunks only: when the system leg carried energy within `MeetingEchoVeto.window`
    /// of this chunk (meeting-clock seconds). Empty when the mode has no system leg.
    public var systemActivity: [ClosedRange<TimeInterval>]
    public init(channel: MeetingChannel, chunk: AudioChunk, systemActivity: [ClosedRange<TimeInterval>] = []) {
        self.channel = channel; self.chunk = chunk; self.systemActivity = systemActivity
    }
    public var range: ClosedRange<TimeInterval> { chunk.range }
}

/// V5 M5 — receives the raw legs as they are drained, on the meeting clock (`MeetingAudioRecorder`).
/// `system` is nil while the mode does not capture system audio; when present it starts at the
/// same instant as `mic`.
public protocol MeetingLegRecording: AnyObject, Sendable {
    func record(mic: [Float], system: [Float]?)
}

/// Mic + system capture on one clock: the system leg is the AEC reference for the mic leg, then
/// each leg runs its own VAD + `Chunker` (3–5 s at speech ends, Muesli-validated).
/// V5 M1–M3 — `mode` decides the legs: in person opens the microphone alone (no reference, no AEC);
/// video call and hybrid open both. `setMode` switches a running capture (the panel's override).
/// Sources push from their own threads into per-channel pending buffers; `drain()` (async, VAD)
/// processes what has arrived, so tests can replay fixtures synchronously and drain once.
public final class DualCapture: @unchecked Sendable {
    public struct Options: Sendable {
        public var minChunk: TimeInterval = 3
        public var maxChunk: TimeInterval = 5
        /// Silence (both legs) skipped entirely: chunks with no VAD speech are dropped.
        public var dropSilentChunks = true
        public init() {}
    }

    private final class Leg {
        let channel: MeetingChannel
        let vad: any VADProtocol
        var chunker: Chunker
        var pending: [Float] = []
        var vadCarry: [Float] = []
        var speechSeen = false
        var inSpeech = false
        /// Samples fed through VAD so far, on the meeting clock (the leg's clock).
        var fed = 0
        /// Where this leg's chunker clock starts on the meeting clock (a leg opened mid-meeting).
        var timeOffset: TimeInterval = 0
        init(channel: MeetingChannel, vad: any VADProtocol, options: Options) {
            self.channel = channel; self.vad = vad
            chunker = Chunker(minDuration: options.minChunk, maxDuration: options.maxChunk)
        }
    }

    public let mic: any AudioCaptureSource
    public let system: any AudioCaptureSource
    public let aec: any EchoCanceller
    public let options: Options
    private let micLeg: Leg
    private let systemLeg: Leg
    private var rawMic: [Float] = []
    private var rawSystem: [Float] = []
    private let lock = NSLock()
    private(set) public var isRunning = false
    /// Total samples delivered per channel (for the live bar / diagnostics).
    private(set) public var delivered: [MeetingChannel: Int] = [.mic: 0, .system: 0]
    /// V5 M1–M3 — which legs run. Default video call (both legs + AEC), the pre-V5 behaviour.
    public private(set) var mode: MeetingMode
    /// V5 M5 — the meeting's saved audio; nil = not saved ("Never", or tests).
    public var recording: (any MeetingLegRecording)?
    /// System-leg energy spans (seconds), newest last; pruned to `activityHorizon`.
    private var systemActivity: [ClosedRange<TimeInterval>] = []
    private var systemFlushPending = false
    private var systemStarted = false
    /// Mic samples taken for processing so far (the meeting clock, in samples).
    private var micTaken = 0
    /// Set when system audio is switched on mid-meeting: the meeting-clock sample its leg starts at.
    private var systemRestartAt: Int?
    /// RMS above which a system-leg VAD frame counts as energy (≈ −46 dBFS).
    public static let systemEnergyThreshold: Float = 0.005
    static let activityHorizon: TimeInterval = 60
    /// Capture rate of every `AudioCaptureSource` (16 kHz mono).
    public static let sampleRate: Double = 16_000

    public init(mic: any AudioCaptureSource, system: any AudioCaptureSource,
                micVAD: any VADProtocol, systemVAD: any VADProtocol,
                aec: any EchoCanceller = NLMSEchoCanceller(), options: Options = Options(),
                mode: MeetingMode = .videoCall) {
        self.mic = mic; self.system = system; self.aec = aec; self.options = options; self.mode = mode
        micLeg = Leg(channel: .mic, vad: micVAD, options: options)
        systemLeg = Leg(channel: .system, vad: systemVAD, options: options)
        mic.sink = { [weak self] buf in self?.push(.mic, Array(buf)) }
        system.sink = { [weak self] buf in self?.push(.system, Array(buf)) }
    }

    private func push(_ channel: MeetingChannel, _ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        if channel == .mic { rawMic.append(contentsOf: samples) } else { rawSystem.append(contentsOf: samples) }
        delivered[channel, default: 0] += samples.count
    }

    public func start() async throws {
        await micLeg.vad.reset(); await systemLeg.vad.reset()
        aec.reset()
        if mode.legs.capturesSystem {
            try system.start()   // reference first so the mic never leads it
            systemStarted = true
        }
        try mic.start()
        isRunning = true
    }

    /// V5 M4 — the user changed the mode mid-meeting. Turning system audio on restarts its leg at
    /// the microphone's clock so both legs stay on one timeline; turning it off stops
    /// the system source and flushes what its chunker held at the next drain.
    public func setMode(_ next: MeetingMode) throws {
        lock.lock()
        let previous = mode
        mode = next
        let wantsSystem = next.legs.capturesSystem, hadSystem = previous.legs.capturesSystem
        if wantsSystem && !hadSystem {
            // The system leg restarts at the mic's processed clock; the mic audio still pending
            // (heard before the switch) is matched by silence so the two pending buffers align.
            systemRestartAt = micTaken
            rawSystem = [Float](repeating: 0, count: rawMic.count)
            systemFlushPending = false
        }
        if !wantsSystem && hadSystem { systemFlushPending = true }
        let running = isRunning
        lock.unlock()
        guard running else { return }
        if wantsSystem && !systemStarted {
            if !hadSystem { aec.reset() }
            do {
                try system.start()
            } catch {
                // System audio refused: stay on the microphone alone rather than stall waiting for it.
                lock.withLock { mode = previous.legs.capturesSystem ? .inPerson : previous; systemRestartAt = nil; rawSystem.removeAll() }
                throw error
            }
            systemStarted = true
        } else if !wantsSystem && systemStarted {
            system.stop()
            systemStarted = false
        }
    }

    /// Process everything that has arrived. AEC runs only over the time-aligned prefix both legs
    /// have; `final` forces the remainder through (mic tail without reference = passthrough).
    public func drain(final: Bool = false) async throws -> [MeetingChunk] {
        let (micBlock, refBlock, legs, flushSystem, restartAt) = take(final: final)
        var out: [MeetingChunk] = []
        if let restartAt { out += await restart(systemLeg, at: restartAt) }
        if let recording, !micBlock.isEmpty || !refBlock.isEmpty {
            recording.record(mic: micBlock, system: legs.capturesSystem || flushSystem ? refBlock : nil)
        }
        // System first, so its energy spans exist when the mic chunks of the same block are emitted.
        if !refBlock.isEmpty { out += try await feed(systemLeg, refBlock) }
        if flushSystem { flushLeg(systemLeg, into: &out) }
        if !micBlock.isEmpty {
            let cleaned = legs.cancelsEcho && !refBlock.isEmpty ? aec.process(mic: micBlock, reference: refBlock) : micBlock
            out += try await feed(micLeg, cleaned)
        }
        if final {
            // System first again: its tail's energy is known before the mic's last chunk.
            for leg in [systemLeg, micLeg] { flushLeg(leg, into: &out) }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func take(final: Bool) -> ([Float], [Float], MeetingLegConfig, Bool, Int?) {
        lock.lock(); defer { lock.unlock() }
        let legs = mode.legs
        let flush = systemFlushPending
        systemFlushPending = false
        let restartAt = systemRestartAt
        systemRestartAt = nil
        // Without a system leg the microphone drains on its own; whatever the system leg still held
        // from before a switch goes through once.
        let aligned = legs.capturesSystem ? min(rawMic.count, rawSystem.count) : rawMic.count
        let micBlock = Array(rawMic.prefix(final ? rawMic.count : aligned))
        if !legs.capturesSystem && !flush && !rawSystem.isEmpty {
            // A source that keeps pushing while its leg is off (a silent reference): not part of the
            // meeting, dropped.
            rawSystem.removeAll()
        }
        let refCount = legs.capturesSystem ? (final ? rawSystem.count : aligned) : rawSystem.count
        let refBlock = Array(rawSystem.prefix(refCount))
        rawMic.removeFirst(micBlock.count); rawSystem.removeFirst(refBlock.count)
        micTaken += micBlock.count
        return (micBlock, refBlock, legs, flush, restartAt)
    }

    /// A leg opened (again) mid-meeting: fresh VAD and chunker whose clock starts at `sample`.
    private func restart(_ leg: Leg, at sample: Int) async -> [MeetingChunk] {
        var out: [MeetingChunk] = []
        flushLeg(leg, into: &out)   // whatever it held from before it was switched off
        await leg.vad.reset()
        leg.chunker.reset()
        leg.vadCarry.removeAll()
        leg.inSpeech = false; leg.speechSeen = false
        leg.fed = sample
        leg.timeOffset = Double(sample) / Self.sampleRate
        return out
    }

    public func stop() async throws -> [MeetingChunk] {
        mic.stop()
        if systemStarted { system.stop(); systemStarted = false }
        isRunning = false
        return try await drain(final: true)
    }

    private func flushLeg(_ leg: Leg, into out: inout [MeetingChunk]) {
        for c in leg.chunker.feed(leg.vadCarry) { emit(leg, c, into: &out) }
        leg.fed += leg.vadCarry.count
        leg.vadCarry.removeAll()
        if let c = leg.chunker.flush() { emit(leg, c, into: &out) }
    }

    /// The system leg's energy spans within `MeetingEchoVeto.window` of `range`.
    func systemActivity(near range: ClosedRange<TimeInterval>) -> [ClosedRange<TimeInterval>] {
        let lo = range.lowerBound - MeetingEchoVeto.window, hi = range.upperBound + MeetingEchoVeto.window
        return systemActivity.filter { $0.lowerBound <= hi && $0.upperBound >= lo }
    }

    private func noteSystemEnergy(_ frame: [Float], at start: Int) {
        guard !frame.isEmpty else { return }
        let rms = (frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        guard rms >= Self.systemEnergyThreshold else { return }
        let lo = Double(start) / Self.sampleRate, hi = Double(start + frame.count) / Self.sampleRate
        if let last = systemActivity.last, lo - last.upperBound <= 0.001 {
            systemActivity[systemActivity.count - 1] = last.lowerBound...hi
        } else {
            systemActivity.append(lo...hi)
        }
        let horizon = hi - Self.activityHorizon
        if let first = systemActivity.first, first.upperBound < horizon {
            systemActivity.removeAll { $0.upperBound < horizon }
        }
    }

    private func feed(_ leg: Leg, _ samples: [Float]) async throws -> [MeetingChunk] {
        var out: [MeetingChunk] = []
        // VAD in its native frame size; carry the remainder to the next call.
        leg.vadCarry.append(contentsOf: samples)
        let fs = leg.vad.frameSize
        var offset = 0
        while leg.vadCarry.count - offset >= fs {
            let frame = Array(leg.vadCarry[offset..<offset + fs])
            offset += fs
            if leg.channel == .system { noteSystemEnergy(frame, at: leg.fed) }
            leg.fed += fs
            let step = try await leg.vad.process(frame: frame)
            for c in leg.chunker.feed(frame) { emit(leg, c, into: &out) }
            if let e = step.event {
                switch e {
                case .speechStart: leg.inSpeech = true; leg.speechSeen = true
                case .speechEnd:
                    leg.inSpeech = false
                    if let c = leg.chunker.markSpeechEnd() { emit(leg, c, into: &out) }
                }
            }
        }
        leg.vadCarry.removeFirst(offset)
        return out
    }

    private func emit(_ leg: Leg, _ chunk: AudioChunk, into out: inout [MeetingChunk]) {
        let hadSpeech = leg.speechSeen || leg.inSpeech
        leg.speechSeen = leg.inSpeech
        if options.dropSilentChunks && !hadSpeech { return }
        var chunk = chunk
        if leg.timeOffset > 0 {
            chunk.range = (chunk.range.lowerBound + leg.timeOffset)...(chunk.range.upperBound + leg.timeOffset)
        }
        let activity = leg.channel == .mic ? systemActivity(near: chunk.range) : []
        out.append(MeetingChunk(channel: leg.channel, chunk: chunk, systemActivity: activity))
    }
}
