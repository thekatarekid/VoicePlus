import Foundation
import Testing
import Shared
@testable import Engine

/// J1 (V4.52) — recordings retention from the `recordings.retain` setting (V5 F3: a legacy count,
/// applied only when one is stored — unset means no count limit; age + disk cap govern, see
/// `RecordingStoreF3Tests`), the folder size reported beside the switch, and the manifest's `corpus` label.
@Suite("Recording retention (V4.52)")
struct RecordingRetentionTests {

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-ret-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "vp.ret.\(UUID().uuidString)")!
    }

    /// Writes `count` recordings one second apart through the real `finish()` — which is where
    /// pruning happens — and returns the stamps written, oldest first.
    @discardableResult
    static func record(_ count: Int, with recorder: UtteranceRecorder, clock: FakeClock) throws -> [String] {
        let block = [Float](repeating: 0.2, count: 160)
        var stamps: [String] = []
        for _ in 0..<count {
            recorder.begin(device: nil, profile: .raw)
            block.withUnsafeBufferPointer { recorder.appendRaw($0) }
            recorder.appendProcessed(block)
            let url = try #require(try recorder.finish())
            stamps.append(UtteranceRecorder.stamp(of: url))
            clock.advance()
        }
        return stamps
    }

    final class FakeClock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        func advance() { now.addTimeInterval(1) }
    }

    static func stamps(in dir: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(UtteranceRecorder.stamp(of:)))
    }

    // MARK: the setting

    @Test func unsetMeansNoCountLimit() {
        let d = Self.defaults()
        #expect(UtteranceRecorder.retention(d) == UtteranceRecorder.keepAll)
        #expect(UtteranceRecorder.defaultRetainedUtterances == 0)
        #expect(UtteranceRecorder.retainKey == "recordings.retain")
    }

    @Test func storedValuesRoundTripIncludingKeepAll() {
        let d = Self.defaults()
        UtteranceRecorder.setRetention(0, d)
        #expect(UtteranceRecorder.retention(d) == UtteranceRecorder.keepAll)
        #expect(d.string(forKey: UtteranceRecorder.retainKey) == "0", "stored as the string SettingsStore reads")
        UtteranceRecorder.setRetention(250, d)
        #expect(UtteranceRecorder.retention(d) == 250)
        UtteranceRecorder.setRetention(-3, d)
        #expect(UtteranceRecorder.retention(d) == 0, "a negative count is not a retention")
    }

    @Test func parsingAcceptsNumbersAndStringsAndFallsBackOnGarbage() {
        #expect(UtteranceRecorder.parseRetention(nil) == 0)
        #expect(UtteranceRecorder.parseRetention("0") == 0)
        #expect(UtteranceRecorder.parseRetention(" 40 ") == 40)
        #expect(UtteranceRecorder.parseRetention(40) == 40)
        #expect(UtteranceRecorder.parseRetention("all") == 0)
        #expect(UtteranceRecorder.parseRetention("-1") == 0)
        #expect(UtteranceRecorder.parseRetention(-1) == 0)
        let d = Self.defaults()
        d.set(30, forKey: UtteranceRecorder.retainKey)        // an integer write (e.g. `defaults write -int`)
        #expect(UtteranceRecorder.retention(d) == 30)
    }

    @Test func theRecorderReadsTheSettingAtEverySave() {
        let d = Self.defaults()
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = UtteranceRecorder(directory: dir, defaults: d)
        #expect(recorder.retention == 0)
        UtteranceRecorder.setRetention(100, d)
        #expect(recorder.retention == 100, "no relaunch: the next save uses the new value")
    }

    // MARK: pruning

    @Test func prunesToAStoredHundred() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let d = Self.defaults()
        UtteranceRecorder.setRetention(100, d)
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        let written = try Self.record(103, with: recorder, clock: clock)

        let kept = try Self.stamps(in: dir)
        #expect(kept.count == 100)
        #expect(kept == Set(written.suffix(100)), "the three oldest go, the newest hundred stay")
        #expect(!kept.contains(written[0]) && !kept.contains(written[2]))
        // Whole utterances: each survivor still has its raw, processed and sidecar files.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 300)
    }

    @Test func exactlyOneHundredIsNotPruned() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let d = Self.defaults()
        UtteranceRecorder.setRetention(100, d)
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        let written = try Self.record(100, with: recorder, clock: clock)
        #expect(try Self.stamps(in: dir) == Set(written))
    }

    @Test func keepAllNeverPrunes() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.defaults()
        UtteranceRecorder.setRetention(UtteranceRecorder.keepAll, d)
        let clock = FakeClock()
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        let written = try Self.record(130, with: recorder, clock: clock)
        #expect(try Self.stamps(in: dir) == Set(written), "past 100, nothing is deleted when keeping all")

        // An explicit prune at 0 is also a no-op.
        recorder.prune(keeping: 0)
        UtteranceRecorder.prune(in: dir, keeping: UtteranceRecorder.keepAll)
        #expect(try Self.stamps(in: dir).count == 130)
    }

    @Test func switchingBackFromKeepAllPrunesAtTheNextSave() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.defaults()
        UtteranceRecorder.setRetention(0, d)
        let clock = FakeClock()
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        try Self.record(12, with: recorder, clock: clock)
        UtteranceRecorder.setRetention(5, d)
        let last = try Self.record(1, with: recorder, clock: clock)
        let kept = try Self.stamps(in: dir)
        #expect(kept.count == 5)
        #expect(kept.contains(last[0]))
    }

    @Test func pruningAndUsageIgnoreFilesTheRecorderDidNotWrite() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("0000-notes.txt")
        let script = dir.appendingPathComponent("script.json")
        try Data("mine".utf8).write(to: notes)
        try Data("{}".utf8).write(to: script)
        let clock = FakeClock()
        let recorder = UtteranceRecorder(directory: dir, defaults: Self.defaults(), now: { clock.now })
        try Self.record(4, with: recorder, clock: clock)
        recorder.prune(keeping: 1)
        #expect(FileManager.default.fileExists(atPath: notes.path))
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(recorder.usage().utterances == 1)
    }

    // MARK: folder size

    @Test func usageReportsWholeUtterancesAndTheirBytes() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(UtteranceRecorder.usage(of: dir) == .empty)
        #expect(UtteranceRecorder.usage(of: dir.appendingPathComponent("missing")) == .empty)

        let clock = FakeClock()
        let recorder = UtteranceRecorder(directory: dir, defaults: Self.defaults(), now: { clock.now })
        try Self.record(3, with: recorder, clock: clock)

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let expected = try files.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        let usage = recorder.usage()
        #expect(usage.utterances == 3, "three files per utterance count once")
        #expect(usage.bytes == expected)
        #expect(usage.bytes > 0)
        #expect(UtteranceRecorder.usage(of: dir) == usage)
    }

    @Test func formattedSizeUsesFinderUnits() {
        let usage = UtteranceRecorder.FolderUsage(utterances: 100, bytes: 104_857_600)
        #expect(usage.formattedSize == ByteCountFormatter.string(fromByteCount: 104_857_600, countStyle: .file))
        #expect(usage.formattedSize.contains("MB"))
    }

    // MARK: corpus label

    @Test func theManifestCarriesTheCorpusLabelInForceAtSave() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Self.defaults()
        let clock = FakeClock()
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func manifest(_ stamp: String) throws -> UtteranceRecorder.Manifest {
            try decoder.decode(UtteranceRecorder.Manifest.self,
                               from: Data(contentsOf: dir.appendingPathComponent("\(stamp).json")))
        }

        UtteranceRecorder.setCorpusLabel("  tv-on  ", d)
        let tagged = try Self.record(1, with: recorder, clock: clock)
        #expect(try manifest(tagged[0]).corpus == "tv-on")

        UtteranceRecorder.setCorpusLabel("   ", d)
        #expect(d.object(forKey: UtteranceRecorder.corpusKey) == nil, "a blank label clears the key")
        let untagged = try Self.record(1, with: recorder, clock: clock)
        #expect(try manifest(untagged[0]).corpus == nil)
        let json = try String(contentsOf: dir.appendingPathComponent("\(untagged[0]).json"), encoding: .utf8)
        #expect(!json.contains("\"corpus\""), "untagged sidecars omit the key")
    }

    /// Sidecars written before V4.52 have no `corpus` key and must still decode — the replay
    /// harness and the real-room corpus read hundreds of them.
    @Test func olderManifestsWithoutCorpusStillDecode() throws {
        let legacy = """
        {"aec":"off","captureGraph":null,"deviceName":"MacBook Pro Microphone","deviceSampleRate":48000,
         "deviceUID":"BuiltIn","inputChannels":1,"noiseSuppression":false,"noiseSuppressionStrength":0,
         "processedPeakdBFS":-6,"processedRMSdBFS":-20,"rawPeakdBFS":-6,"rawRMSdBFS":-20,
         "recordedAt":"2026-09-08T23:14:55Z","seconds":1.5,"transport":"builtIn"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(UtteranceRecorder.Manifest.self, from: Data(legacy.utf8))
        #expect(m.corpus == nil)
        #expect(m.deviceName == "MacBook Pro Microphone")
    }

    @Test func stampShapeIsWhatFinishWrites() {
        let stamp = UtteranceRecorder.stampFormatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(UtteranceRecorder.isStamp(Substring(stamp)))
        #expect(UtteranceRecorder.isRecordingFile(URL(fileURLWithPath: "/r/\(stamp)-raw.wav")))
        #expect(UtteranceRecorder.isRecordingFile(URL(fileURLWithPath: "/r/\(stamp)-processed.wav")))
        #expect(UtteranceRecorder.isRecordingFile(URL(fileURLWithPath: "/r/\(stamp).json")))
        #expect(!UtteranceRecorder.isRecordingFile(URL(fileURLWithPath: "/r/tv-only-1.wav")))
        #expect(!UtteranceRecorder.isRecordingFile(URL(fileURLWithPath: "/r/\(stamp).txt")))
    }
}
