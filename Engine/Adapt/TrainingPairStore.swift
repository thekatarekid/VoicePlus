import Foundation
import Shared

/// One (audio-span, corrected-text) training pair. Audio is stored as a WAV clip next to the
/// pair (under `AppPaths`), never uploaded.
public struct TrainingPair: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var utteranceID: String
    public var createdAt: Date
    public var original: String
    public var corrected: String
    public var audioStart: Double
    public var audioEnd: Double
    /// "voiceRepair", "keyboardEdit", "dualPath", "postDictationEdit", "trainByVoice"
    public var source: String
    /// Relative clip file name inside the store's clips directory, if audio was available.
    public var clipFile: String?

    public var audioRange: ClosedRange<TimeInterval> { audioStart...max(audioStart, audioEnd) }

    public init(id: String = UUID().uuidString, utteranceID: String, createdAt: Date = Date(), original: String,
                corrected: String, audioRange: ClosedRange<TimeInterval>, source: String, clipFile: String? = nil) {
        self.id = id; self.utteranceID = utteranceID; self.createdAt = createdAt
        self.original = original; self.corrected = corrected
        self.audioStart = audioRange.lowerBound; self.audioEnd = audioRange.upperBound
        self.source = source; self.clipFile = clipFile
    }
}

/// Gives the store access to the utterance audio buffer so it can cut clips. The live
/// implementation wraps the capture ring; tests use an in-memory dictionary.
public protocol UtteranceAudioProvider: Sendable {
    var sampleRate: Int { get }
    /// Mono samples for `range` (seconds from utterance start), or nil if the buffer is gone.
    func samples(utteranceID: String, range: ClosedRange<TimeInterval>) -> [Float]?
}

public struct InMemoryUtteranceAudio: UtteranceAudioProvider {
    public let sampleRate: Int
    public var utterances: [String: [Float]]
    public init(sampleRate: Int = 16_000, utterances: [String: [Float]] = [:]) {
        self.sampleRate = sampleRate; self.utterances = utterances
    }
    public func samples(utteranceID: String, range: ClosedRange<TimeInterval>) -> [Float]? {
        guard let all = utterances[utteranceID] else { return nil }
        let lo = max(0, Int(range.lowerBound * Double(sampleRate)))
        let hi = min(all.count, Int(range.upperBound * Double(sampleRate)))
        guard lo < hi else { return nil }
        return Array(all[lo..<hi])
    }
}

/// Append-only JSONL store of training pairs + WAV clips, on device under
/// `AppPaths.supportDirectory()/Adapt`. Thread-safe.
public final class TrainingPairStore: @unchecked Sendable {
    public let root: URL
    public var clipsDirectory: URL { root.appendingPathComponent("clips", isDirectory: true) }
    private var pairsFile: URL { root.appendingPathComponent("pairs.jsonl") }
    private let audio: UtteranceAudioProvider?
    private let lock = NSLock()
    private var cache: [TrainingPair]

    public static func defaultRoot() -> URL { AppPaths.supportDirectory().appendingPathComponent("Adapt", isDirectory: true) }

    public init(root: URL = TrainingPairStore.defaultRoot(), audio: UtteranceAudioProvider? = nil) throws {
        self.root = root; self.audio = audio
        try FileManager.default.createDirectory(at: root.appendingPathComponent("clips", isDirectory: true), withIntermediateDirectories: true)
        cache = []
        if let data = try? Data(contentsOf: root.appendingPathComponent("pairs.jsonl")) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
                if let p = try? dec.decode(TrainingPair.self, from: Data(line)) { cache.append(p) }
            }
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
    public func all() -> [TrainingPair] { lock.lock(); defer { lock.unlock() }; return cache }
    public func pairs(since: Date) -> [TrainingPair] { all().filter { $0.createdAt >= since } }

    /// Appends a pair, cutting the clip from the utterance buffer when available.
    @discardableResult
    public func add(_ pair: TrainingPair) throws -> TrainingPair {
        var p = pair
        let trimmed = p.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != p.original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return p }
        if p.clipFile == nil, let audio, let s = audio.samples(utteranceID: p.utteranceID, range: p.audioRange) {
            let name = "\(p.id).wav"
            try WAVFile(sampleRate: audio.sampleRate, samples: s).write(to: clipsDirectory.appendingPathComponent(name))
            p.clipFile = name
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var line = try enc.encode(p); line.append(UInt8(ascii: "\n"))
        lock.lock(); defer { lock.unlock() }
        if let h = try? FileHandle(forWritingTo: pairsFile) { try h.seekToEnd(); try h.write(contentsOf: line); try h.close() }
        else { try line.write(to: pairsFile) }
        cache.append(p)
        return p
    }

    /// Repair / dual-path correction events map 1:1 to pairs.
    @discardableResult
    public func ingest(_ c: CorrectionRecord) throws -> TrainingPair {
        try add(TrainingPair(utteranceID: c.utteranceID, createdAt: c.createdAt, original: c.original, corrected: c.corrected,
                             audioRange: c.audioStart...c.audioEnd, source: c.source))
    }

    /// Post-dictation edit: word-diffs the injected spans against what the user left in the
    /// field and records one pair per replaced run, with the audio range of the replaced spans.
    @discardableResult
    public func ingestEdit(utteranceID: String, spans: [TranscriptSpan], editedText: String, at: Date = Date()) throws -> [TrainingPair] {
        var out: [TrainingPair] = []
        for run in WordDiff.replacedRuns(original: spans.map(\.text), edited: editedText.split(whereSeparator: \.isWhitespace).map(String.init)) {
            let covered = spans[run.originalRange]
            guard let lo = covered.map(\.audioRange.lowerBound).min(), let hi = covered.map(\.audioRange.upperBound).max() else { continue }
            out.append(try add(TrainingPair(utteranceID: utteranceID, createdAt: at, original: covered.map(\.text).joined(separator: " "),
                                            corrected: run.replacement, audioRange: lo...hi, source: "postDictationEdit")))
        }
        return out
    }

    public func clipURL(for pair: TrainingPair) -> URL? { pair.clipFile.map { clipsDirectory.appendingPathComponent($0) } }

    /// Deletes every pair and clip (Data Panel "forget my training data").
    public func eraseAll() throws {
        lock.lock(); defer { lock.unlock() }
        cache = []
        try? FileManager.default.removeItem(at: pairsFile)
        try? FileManager.default.removeItem(at: clipsDirectory)
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }
}

/// Word-level diff (Levenshtein backtrace) that groups substituted / inserted / deleted words
/// into replaced runs against the original word indices.
public enum WordDiff {
    public struct Run: Equatable, Sendable {
        public var originalRange: Range<Int>
        public var replacement: String
    }

    public static func replacedRuns(original a: [String], edited b: [String]) -> [Run] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n { for j in 1...m {
                let same = a[i - 1].lowercased() == b[j - 1].lowercased()
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (same ? 0 : 1))
            } }
        }
        // Backtrace into ops: (origIndex?, editedWord?)
        var ops: [(Int?, String?)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1].lowercased() == b[j - 1].lowercased(), d[i][j] == d[i - 1][j - 1] { ops.append((i - 1, b[j - 1])); i -= 1; j -= 1 }
            else if i > 0, j > 0, d[i][j] == d[i - 1][j - 1] + 1 { ops.append((i - 1, b[j - 1])); i -= 1; j -= 1 }
            else if i > 0, d[i][j] == d[i - 1][j] + 1 { ops.append((i - 1, nil)); i -= 1 }
            else { ops.append((nil, b[j - 1])); j -= 1 }
        }
        ops.reverse()
        var runs: [Run] = []
        var cur: (lo: Int, hi: Int, words: [String])?
        func flush() { if let c = cur, c.hi > c.lo { runs.append(Run(originalRange: c.lo..<c.hi, replacement: c.words.joined(separator: " "))) }; cur = nil }
        var cursor = 0
        for (oi, w) in ops {
            let isMatch = oi != nil && w != nil && a[oi!].lowercased() == w!.lowercased()
            if isMatch { flush(); cursor = oi! + 1; continue }
            if cur == nil { cur = (oi ?? cursor, oi ?? cursor, []) }
            if let oi { cur!.hi = oi + 1; cursor = oi + 1 }
            if let w { cur!.words.append(w) }
        }
        flush()
        return runs.filter { !$0.replacement.isEmpty }
    }
}
