import Foundation
import Testing
import Shared
@testable import Engine

/// V5 F3 — store all dictation audio: raw + processed WAV with transcript, final text and app;
/// retention 7/30/90 days/forever (default 30), disk cap (default 2 GB, LRU delete).
@Suite("Recording store (V5 F3)")
struct RecordingStoreF3Tests {
    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-f3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaults() -> UserDefaults { UserDefaults(suiteName: "vp.f3.\(UUID().uuidString)")! }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
    }

    /// One utterance of `seconds` through `finish()`; returns its stamp.
    @discardableResult
    static func record(_ recorder: UtteranceRecorder, seconds: Double = 0.1) throws -> String {
        let block = [Float](repeating: 0.2, count: Int(seconds * 16_000))
        recorder.begin(device: nil, profile: .raw)
        block.withUnsafeBufferPointer { recorder.appendRaw($0) }
        recorder.appendProcessed(block)
        return UtteranceRecorder.stamp(of: try #require(try recorder.finish()))
    }

    static func stamps(_ dir: URL) -> Set<String> {
        Set(UtteranceRecorder.recordingFiles(in: dir).map(UtteranceRecorder.stamp(of:)))
    }

    // MARK: settings

    @Test func defaultsAreThirtyDaysAndTwoGigabytes() {
        let d = Self.defaults()
        #expect(UtteranceRecorder.retentionDays(d) == 30)
        #expect(UtteranceRecorder.diskCapBytes(d) == 2_000_000_000)
        #expect(UtteranceRecorder.retentionDayChoices == [7, 30, 90, 0])
        UtteranceRecorder.setRetentionDays(UtteranceRecorder.forever, d)
        #expect(UtteranceRecorder.retentionDays(d) == 0)
        #expect(d.string(forKey: UtteranceRecorder.retentionDaysKey) == "0", "stored as the string SettingsStore reads")
        UtteranceRecorder.setRetentionDays(-4, d)
        #expect(UtteranceRecorder.retentionDays(d) == 30)
        UtteranceRecorder.setDiskCapBytes(5 * UtteranceRecorder.gigabyte, d)
        #expect(UtteranceRecorder.diskCapBytes(d) == 5_000_000_000)
        #expect(UtteranceRecorder.parseDiskCap("0") == UtteranceRecorder.defaultDiskCapBytes, "there is no unlimited")
        #expect(UtteranceRecorder.parseDiskCap("junk") == UtteranceRecorder.defaultDiskCapBytes)
        #expect(UtteranceRecorder.parseRetentionDays(" 90 ") == 90)
    }

    // MARK: retention sweep

    @Test func sweepDeletesWholeUtterancesOlderThanTheRetention() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let d = Self.defaults()
        UtteranceRecorder.setRetentionDays(UtteranceRecorder.forever, d)   // write without sweeping
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        let old = try Self.record(recorder)                   // day 0
        clock.now.addTimeInterval(20 * 86_400)
        let mid = try Self.record(recorder)                   // day 20
        clock.now.addTimeInterval(15 * 86_400)
        let new = try Self.record(recorder)                   // day 35
        #expect(Self.stamps(dir) == [old, mid, new], "forever keeps all")

        UtteranceRecorder.setRetentionDays(30, d)
        let r = recorder.sweep()
        #expect(r == .init(expired: 1, overCap: 0))
        #expect(Self.stamps(dir) == [mid, new])
        #expect(UtteranceRecorder.recordingFiles(in: dir).count == 6, "raw, processed and sidecar of each survivor")

        UtteranceRecorder.setRetentionDays(7, d)
        recorder.sweep()
        #expect(Self.stamps(dir) == [new])
    }

    @Test func everySaveSweepsButNeverTheOneJustSaved() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let d = Self.defaults()
        UtteranceRecorder.setRetentionDays(7, d)
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        try Self.record(recorder)
        clock.now.addTimeInterval(8 * 86_400)
        let latest = try Self.record(recorder)
        #expect(Self.stamps(dir) == [latest])
    }

    @Test func sweepIgnoresFilesTheRecorderDidNotWrite() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = dir.appendingPathComponent("notes.txt")
        try Data(repeating: 1, count: 10_000).write(to: foreign)
        UtteranceRecorder.sweep(in: dir, now: Date(), retentionDays: 7, diskCap: 1)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: disk cap

    @Test func capDeletesLeastRecentlyUsedFirst() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let d = Self.defaults()
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        var stamps: [String] = []
        for _ in 0..<4 {
            stamps.append(try Self.record(recorder, seconds: 1))   // ~64 KB raw + ~64 KB processed
            clock.now.addTimeInterval(60)
        }
        let each = UtteranceRecorder.usage(of: dir).bytes / 4
        // Oldest recording was replayed just now: it is the most recently *used*.
        let base = clock.now
        for (i, s) in stamps.enumerated() {
            UtteranceRecorder.markUsed(stamp: s, in: dir, at: base.addingTimeInterval(Double(i)))
        }
        UtteranceRecorder.markUsed(stamp: stamps[0], in: dir, at: base.addingTimeInterval(100))
        let r = UtteranceRecorder.sweep(in: dir, now: clock.now, retentionDays: 30, diskCap: each * 2 + each / 2)
        #expect(r.overCap == 2)
        #expect(Self.stamps(dir) == [stamps[0], stamps[3]], "the two least recently used go: \(Self.stamps(dir))")
        #expect(UtteranceRecorder.usage(of: dir).bytes <= each * 2 + each / 2)
    }

    @Test func capAppliesAtSaveAndKeepsTheNewest() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let d = Self.defaults()
        let recorder = UtteranceRecorder(directory: dir, defaults: d, now: { clock.now })
        for _ in 0..<3 { try Self.record(recorder, seconds: 1); clock.now.addTimeInterval(60) }
        let each = UtteranceRecorder.usage(of: dir).bytes / 3
        UtteranceRecorder.setDiskCapBytes(each, d)          // room for one
        let newest = try Self.record(recorder, seconds: 1)
        #expect(Self.stamps(dir) == [newest])
    }

    // MARK: transcript, final text, app

    @Test func annotateLatestWritesTranscriptFinalTextAndApp() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let recorder = UtteranceRecorder(directory: dir, defaults: Self.defaults(), now: { clock.now })
        let first = try Self.record(recorder)
        clock.now.addTimeInterval(30)
        let second = try Self.record(recorder)
        let s = UtteranceRecorder.annotateLatest(in: dir, now: clock.now.addingTimeInterval(2),
                                                 transcript: "send it to kotari", finalText: "Send it to Kothari.",
                                                 appBundleID: "com.apple.mail")
        #expect(s == second)
        let m = try Self.manifest(second, dir)
        #expect(m.transcript == "send it to kotari" && m.finalText == "Send it to Kothari." && m.appBundleID == "com.apple.mail")
        #expect(try Self.manifest(first, dir).finalText == nil)
        // The newest is annotated: a second landing does not overwrite it or reach back to an older one.
        #expect(UtteranceRecorder.annotateLatest(in: dir, now: clock.now, transcript: "x", finalText: "y", appBundleID: nil) == nil)
        #expect(try Self.manifest(second, dir).finalText == "Send it to Kothari.")
        // Too long after the save (recording off for that turn): nothing is annotated.
        clock.now.addTimeInterval(60)
        let third = try Self.record(recorder)
        #expect(UtteranceRecorder.annotateLatest(in: dir, now: clock.now.addingTimeInterval(600),
                                                 transcript: "a", finalText: "b", appBundleID: nil) == nil)
        #expect(try Self.manifest(third, dir).finalText == nil)
    }

    @Test func secureFieldRefusalDeletesThatTurnsRecording() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock()
        let recorder = UtteranceRecorder(directory: dir, defaults: Self.defaults(), now: { clock.now })
        let first = try Self.record(recorder)
        #expect(UtteranceRecorder.annotateLatest(in: dir, now: clock.now, transcript: "a", finalText: "A.", appBundleID: nil) == first)
        clock.now.addTimeInterval(30)
        let secret = try Self.record(recorder)
        #expect(UtteranceRecorder.discardLatest(in: dir, now: clock.now.addingTimeInterval(1)) == secret)
        #expect(Self.stamps(dir) == [first], "raw, processed and sidecar of the refused turn are gone; older kept")
        // An already-annotated newest recording is a landed turn, never deleted.
        #expect(UtteranceRecorder.discardLatest(in: dir, now: clock.now) == nil)
        #expect(Self.stamps(dir) == [first])
        #expect(UtteranceRecorder.onSecureRefusal == nil, "tests and mock engines never delete")
        UtteranceRecorder.noteSecureRefusal()   // no-op, no crash
    }

    @Test func landingHookIsOffUntilTheRealStackInstallsIt() throws {
        #expect(UtteranceRecorder.onLanded == nil, "tests and mock engines never write")
        UtteranceRecorder.noteLanded(transcript: "a", finalText: "b", appBundleID: nil)   // no-op, no crash
    }

    @Test func olderSidecarsWithoutTextStillDecode() throws {
        let json = #"{"recordedAt":"2026-09-08T23:14:55Z","deviceName":"m","deviceUID":"u","transport":"builtIn","deviceSampleRate":48000,"inputChannels":1,"noiseSuppression":false,"noiseSuppressionStrength":0,"aec":"off","seconds":1,"rawRMSdBFS":-30,"rawPeakdBFS":-10,"processedRMSdBFS":-30,"processedPeakdBFS":-10}"#
        let m = try UtteranceRecorder.decoder.decode(UtteranceRecorder.Manifest.self, from: Data(json.utf8))
        #expect(m.transcript == nil && m.finalText == nil && m.appBundleID == nil)
    }

    // MARK: which captures record

    @Test func dictationGraphRecordsByDefaultOtherCapturesDoNot() {
        let plan = CaptureGraphPlan.plan(for: .off)
        let dictation = plan.makeCaptureSource(plainTap: { MockCaptureSource() }, voiceProcessing: { MockCaptureSource() })
        let voiceTest = AcousticCaptureSource(wrapping: MockCaptureSource(), profile: .default)
        let d = UserDefaults.standard
        let stored = d.object(forKey: UtteranceRecorder.defaultsKey)
        // Whatever the machine's switch says, the dictation graph follows `isEnabled` (default on) and
        // a plain wrapper follows the explicit opt-in.
        #expect(dictation.isRecordingEnabled() == UtteranceRecorder.isEnabled(d))
        #expect(voiceTest.isRecordingEnabled() == UtteranceRecorder.isExplicitlyEnabled(d))
        if stored == nil {
            #expect(dictation.isRecordingEnabled() && !voiceTest.isRecordingEnabled())
        }
    }

    static func manifest(_ stamp: String, _ dir: URL) throws -> UtteranceRecorder.Manifest {
        try UtteranceRecorder.decoder.decode(UtteranceRecorder.Manifest.self,
                                             from: Data(contentsOf: dir.appendingPathComponent("\(stamp).json")))
    }
}
