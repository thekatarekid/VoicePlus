import Foundation
import Shared

/// Which capture leg a chunk came from.
public enum MeetingChannel: String, Codable, Sendable, CaseIterable { case mic, system }

/// A VAD-bounded 3–5 s chunk from one channel, positioned on the shared meeting clock.
public struct MeetingChunk: Sendable, Equatable {
    public var channel: MeetingChannel
    public var chunk: AudioChunk
    public init(channel: MeetingChannel, chunk: AudioChunk) { self.channel = channel; self.chunk = chunk }
    public var range: ClosedRange<TimeInterval> { chunk.range }
}

/// Mic + system capture on one clock: the system leg is the AEC reference for the mic leg, then
/// each leg runs its own VAD + `Chunker` (3–5 s at speech ends, Muesli-validated).
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
        var position: TimeInterval = 0
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

    public init(mic: any AudioCaptureSource, system: any AudioCaptureSource,
                micVAD: any VADProtocol, systemVAD: any VADProtocol,
                aec: any EchoCanceller = NLMSEchoCanceller(), options: Options = Options()) {
        self.mic = mic; self.system = system; self.aec = aec; self.options = options
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
        try system.start()   // reference first so the mic never leads it
        try mic.start()
        isRunning = true
    }

    /// Process everything that has arrived. AEC runs only over the time-aligned prefix both legs
    /// have; `final` forces the remainder through (mic tail without reference = passthrough).
    public func drain(final: Bool = false) async throws -> [MeetingChunk] {
        let (micBlock, refBlock) = take(final: final)
        var out: [MeetingChunk] = []
        if !micBlock.isEmpty {
            let cleaned = aec.process(mic: micBlock, reference: refBlock)
            out += try await feed(micLeg, cleaned)
        }
        if !refBlock.isEmpty { out += try await feed(systemLeg, refBlock) }
        if final {
            for leg in [micLeg, systemLeg] {
                for c in leg.chunker.feed(leg.vadCarry) { emit(leg, c, into: &out) }
                leg.vadCarry.removeAll()
                if let c = leg.chunker.flush() { emit(leg, c, into: &out) }
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private func take(final: Bool) -> ([Float], [Float]) {
        lock.lock(); defer { lock.unlock() }
        let aligned = min(rawMic.count, rawSystem.count)
        let micBlock = Array(rawMic.prefix(final ? rawMic.count : aligned))
        let refBlock = Array(rawSystem.prefix(final ? rawSystem.count : aligned))
        rawMic.removeFirst(micBlock.count); rawSystem.removeFirst(refBlock.count)
        return (micBlock, refBlock)
    }

    public func stop() async throws -> [MeetingChunk] {
        mic.stop(); system.stop()
        isRunning = false
        return try await drain(final: true)
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
        out.append(MeetingChunk(channel: leg.channel, chunk: chunk))
    }
}
