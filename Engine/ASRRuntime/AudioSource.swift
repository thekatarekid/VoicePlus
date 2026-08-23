import AVFoundation
import Foundation

/// Minimal push-style audio contract the ASR runtime consumes (P1.3). Structurally identical to
/// P1.2's `AudioCaptureSource` (`sink`/`start`/`stop`) so P1.12 can bridge with a one-line
/// adapter; kept separate so this module never depends on capture hardware code.
public protocol AudioSource: AnyObject, Sendable {
    /// Receives 16 kHz mono Float samples from any thread. Set before `start()`.
    var sink: ((UnsafeBufferPointer<Float>) -> Void)? { get set }
    func prewarm() throws
    func start() throws
    func stop()
}

public enum AudioSourceError: Error, Equatable {
    case unreadable(String)
}

/// Replays an in-memory sample buffer (optionally in real time). Used by tests and the Lab.
public final class SampleAudioSource: AudioSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public let samples: [Float]
    public let blockSize: Int
    public let realtime: Bool
    public var onFinished: (@Sendable () -> Void)?
    private var worker: Thread?
    private let stopped = NSLock()
    private var shouldStop = false

    public init(samples: [Float], blockDuration: TimeInterval = 0.05, realtime: Bool = false) {
        self.samples = samples
        self.blockSize = max(1, Int(blockDuration * 16_000))
        self.realtime = realtime
    }

    /// Reads any AVFoundation-readable file and resamples to 16 kHz mono.
    public convenience init(url: URL, blockDuration: TimeInterval = 0.05, realtime: Bool = false) throws {
        self.init(samples: try Self.load16k(url: url), blockDuration: blockDuration, realtime: realtime)
    }

    public static func load16k(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioSourceError.unreadable(url.lastPathComponent)
        }
        let inCap = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: max(inCap, 1)) else {
            throw AudioSourceError.unreadable(url.lastPathComponent)
        }
        try file.read(into: inBuf)
        let ratio = 16_000 / file.processingFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else {
            throw AudioSourceError.unreadable(url.lastPathComponent)
        }
        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        if let err { throw AudioSourceError.unreadable("\(url.lastPathComponent): \(err.localizedDescription)") }
        guard let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
    }

    public func prewarm() throws {}

    public func start() throws {
        stopped.lock(); shouldStop = false; stopped.unlock()
        let t = Thread { [self] in
            var i = 0
            while i < samples.count {
                stopped.lock(); let stop = shouldStop; stopped.unlock()
                if stop { return }
                let end = min(i + blockSize, samples.count)
                samples[i..<end].withUnsafeBufferPointer { sink?($0) }
                if realtime { Thread.sleep(forTimeInterval: Double(end - i) / 16_000) }
                i = end
            }
            onFinished?()
        }
        t.name = "voiceplus.sampleaudio"
        worker = t
        t.start()
    }

    public func stop() {
        stopped.lock(); shouldStop = true; stopped.unlock()
        worker = nil
    }
}
