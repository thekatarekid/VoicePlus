import Foundation
import Shared

// V5 M5 — save the meeting recording (default Always; options 7 days / Never).
//
// One 16 kHz mono 16-bit WAV per leg in the meeting's directory: `audio-mic.wav` and, when the mode
// captures system audio, `audio-system.wav`. Both start at the meeting clock's zero, so M8's
// re-diarization (`MeetingRecordingAudio.locate`) and M18's seek read them with offset 0. The header
// is rewritten after every append, so a crash leaves a playable file with everything up to the last
// drain. Retention (`MeetingRecordingSweeper`) deletes expired meeting audio and, while the shared
// recordings budget (F3's disk cap, counted over the dictation Recordings folder *and* meeting audio)
// is exceeded, the oldest meeting audio first. Transcripts and notes are never touched.

/// A streaming 16 kHz mono PCM16 WAV file.
public final class MeetingWAVWriter: @unchecked Sendable {
    public let url: URL
    public let sampleRate: Int
    private let handle: FileHandle
    public private(set) var samplesWritten = 0

    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url; self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0, sampleRate: sampleRate))
        handle = try FileHandle(forWritingTo: url)
    }

    deinit { try? handle.close() }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clipped = max(-1, min(1, s.isFinite ? s : 0))
            var v = Int16(clipped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: pcm)
        samplesWritten += samples.count
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: samplesWritten * 2, sampleRate: sampleRate))
    }

    public func appendSilence(_ count: Int) throws {
        guard count > 0 else { return }
        try append([Float](repeating: 0, count: count))
    }

    public func close() { try? handle.close() }

    static func header(dataBytes: Int, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }
}

/// The meeting's saved audio: one WAV per leg on the meeting clock. Survives pause/resume and mode
/// changes (each `DualCapture` stretch appends to the same files); a leg that starts late, or comes
/// back after a gap, is padded with silence so it stays aligned with the microphone.
public final class MeetingAudioRecorder: MeetingLegRecording, @unchecked Sendable {
    public static let micFileName = "audio-mic.wav"
    public static let systemFileName = "audio-system.wav"

    public let directory: URL
    private var mic: MeetingWAVWriter?
    private var system: MeetingWAVWriter?
    private let lock = NSLock()
    private var failed = false

    public init(directory: URL) { self.directory = directory }

    public var micURL: URL { directory.appendingPathComponent(Self.micFileName) }
    public var systemURL: URL { directory.appendingPathComponent(Self.systemFileName) }

    /// Samples written per leg (tests, diagnostics).
    public var counts: (mic: Int, system: Int) {
        lock.withLock { (mic?.samplesWritten ?? 0, system?.samplesWritten ?? 0) }
    }

    public func record(mic micSamples: [Float], system systemSamples: [Float]?) {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        do {
            let micBefore = mic?.samplesWritten ?? 0
            if !micSamples.isEmpty {
                if mic == nil { mic = try MeetingWAVWriter(url: micURL) }
                try mic?.append(micSamples)
            }
            if let systemSamples, !systemSamples.isEmpty {
                if system == nil { system = try MeetingWAVWriter(url: systemURL) }
                // The system block starts where this mic block started.
                try system?.appendSilence(micBefore - (system?.samplesWritten ?? 0))
                try system?.append(systemSamples)
            }
        } catch {
            failed = true
            Log.engine.error("meeting recording: write failed, recording stops (transcript continues): \(error)")
        }
    }

    public func close() {
        lock.withLock { mic?.close(); system?.close(); mic = nil; system = nil }
    }
}

/// M5 retention + the disk budget shared with F3.
public enum MeetingRecordingSweeper {
    public struct Result: Equatable, Sendable {
        public var expired = 0
        public var overCap = 0
        public init(expired: Int = 0, overCap: Int = 0) { self.expired = expired; self.overCap = overCap }
    }

    /// Every meeting audio file under `meetingsRoot` (`<id>/audio*.{wav,m4a,caf}`).
    public static func audioFiles(in meetingsRoot: URL, fileManager: FileManager = .default) -> [(url: URL, bytes: Int64, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let dirs = (try? fileManager.contentsOfDirectory(at: meetingsRoot, includingPropertiesForKeys: nil)) ?? []
        var out: [(URL, Int64, Date)] = []
        for dir in dirs {
            let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
            for f in files where f.lastPathComponent.hasPrefix("audio")
                && MeetingRecordingAudio.audioExtensions.contains(f.pathExtension.lowercased()) {
                let v = try? f.resourceValues(forKeys: Set(keys))
                out.append((f, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast))
            }
        }
        return out.map { (url: $0.0, bytes: $0.1, modified: $0.2) }
    }

    /// - `retentionDays`: nil = keep forever; > 0 = delete meeting audio last written longer ago.
    /// - `diskCap`: the shared recordings budget; `otherBytes` is what dictation recordings already use.
    /// - `keeping`: a meeting directory never touched (the one recording now).
    @discardableResult
    public static func sweep(meetingsRoot: URL, now: Date, retentionDays: Int?, diskCap: Int64,
                             otherBytes: Int64 = 0, keeping: URL? = nil,
                             fileManager: FileManager = .default) -> Result {
        var result = Result()
        let keep = keeping?.standardizedFileURL.path
        func protected(_ url: URL) -> Bool { url.deletingLastPathComponent().standardizedFileURL.path == keep }
        var files = audioFiles(in: meetingsRoot, fileManager: fileManager)
        if let days = retentionDays, days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for f in files where f.modified < cutoff && !protected(f.url) {
                if (try? fileManager.removeItem(at: f.url)) != nil { result.expired += 1 }
            }
            files.removeAll { $0.modified < cutoff && !protected($0.url) }
        }
        var total = otherBytes + files.reduce(Int64(0)) { $0 + $1.bytes }
        guard diskCap > 0, total > diskCap else { return result }
        for f in files.sorted(by: { $0.modified < $1.modified }) where total > diskCap && !protected(f.url) {
            if (try? fileManager.removeItem(at: f.url)) != nil {
                total -= f.bytes
                result.overCap += 1
            }
        }
        if result.overCap > 0 { Log.engine.notice("meeting recordings: \(result.overCap) file(s) removed over the recordings disk cap") }
        return result
    }
}
