import Foundation

/// Speech start/end as seen by a VAD, in seconds from the start of the stream.
public enum VADEvent: Equatable, Sendable {
    case speechStart(at: TimeInterval)
    case speechEnd(at: TimeInterval)

    public var time: TimeInterval {
        switch self {
        case .speechStart(let t), .speechEnd(let t): return t
        }
    }
}

public struct VADStep: Equatable, Sendable {
    public var probability: Float
    public var isSpeech: Bool
    public var event: VADEvent?
    public init(probability: Float, isSpeech: Bool, event: VADEvent? = nil) {
        self.probability = probability; self.isSpeech = isSpeech; self.event = event
    }
}

/// Streaming VAD over 16 kHz mono audio. Implementations consume exactly `frameSize` samples per
/// `process` call; the pipeline re-blocks audio to fit. State lives inside the instance.
public protocol VADProtocol: AnyObject, Sendable {
    var name: String { get }
    var frameSize: Int { get }
    var sampleRate: Int { get }
    func reset() async
    func process(frame: [Float]) async throws -> VADStep
}

public extension VADProtocol {
    var sampleRate: Int { 16_000 }

    /// Offline convenience: run the whole signal and return speech spans (seconds).
    func segments(in samples: [Float]) async throws -> [ClosedRange<TimeInterval>] {
        await reset()
        var spans: [ClosedRange<TimeInterval>] = []
        var start: TimeInterval?
        var i = 0
        while i < samples.count {
            let end = min(i + frameSize, samples.count)
            var frame = Array(samples[i..<end])
            if frame.count < frameSize { frame.append(contentsOf: [Float](repeating: 0, count: frameSize - frame.count)) }
            let step = try await process(frame: frame)
            if let e = step.event {
                switch e {
                case .speechStart(let t): start = t
                case .speechEnd(let t): if let s = start { spans.append(s...max(s, t)); start = nil }
                }
            }
            i = end
        }
        if let s = start { spans.append(s...Double(samples.count) / Double(sampleRate)) }
        return spans
    }
}
