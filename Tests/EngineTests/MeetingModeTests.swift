import Foundation
import Testing
@testable import Engine
@testable import Shared

/// V5 M1–M4 (modes, auto-pick, cross-leg echo veto) and M5 (saved recording + retention).
@Suite("V5 M1–M5 — meeting modes and saved recording")
struct MeetingModeTests {
    /// A source the test pushes into by hand.
    final class PushSource: AudioCaptureSource, @unchecked Sendable {
        var sink: ((UnsafeBufferPointer<Float>) -> Void)?
        var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
        var device: AudioDeviceInfo? { nil }
        private(set) var starts = 0
        private(set) var isRunning = false
        var failsToStart = false
        func prewarm() throws {}
        func start() throws {
            if failsToStart { throw AudioCaptureError.noInputDevice }
            starts += 1; isRunning = true
        }
        func stop() { isRunning = false }
        func switchDevice(to device: AudioDeviceInfo?) throws {}
        func push(_ samples: [Float]) { samples.withUnsafeBufferPointer { sink?($0) } }
    }

    final class AlwaysSpeech: VADProtocol, @unchecked Sendable {
        let name = "always"; let frameSize = 512
        private var started = false
        func reset() async { started = false }
        func process(frame: [Float]) async throws -> VADStep {
            defer { started = true }
            return VADStep(probability: 1, isSpeech: true, event: started ? nil : .speechStart(at: 0))
        }
    }

    final class LegLog: MeetingLegRecording, @unchecked Sendable {
        var mic = 0, system = 0, systemNil = 0
        func record(mic: [Float], system: [Float]?) {
            self.mic += mic.count
            if let system { self.system += system.count } else { systemNil += 1 }
        }
    }

    /// Every chunk says the same words: an echo pair transcribes identically on both legs.
    struct SameWordsASR: MeetingTranscriber {
        var text = "the budget for next quarter is approved"
        func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] {
            [TranscriptSpan(text: text, confidence: 0.9, audioRange: 0...chunk.duration)]
        }
    }

    static func tone(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * 16_000)).map { Float(sin(Double($0) * 0.07)) * amplitude }
    }

    static func temp() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-m1-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: M1–M3 mode → leg config

    @Test("mode → leg config: video call both legs + AEC, in person mic only, hybrid adds the echo veto")
    func modeLegConfig() {
        #expect(MeetingMode.videoCall.legs == MeetingLegConfig(capturesSystem: true, cancelsEcho: true, echoVeto: false))
        #expect(MeetingMode.inPerson.legs == MeetingLegConfig(capturesSystem: false, cancelsEcho: false, echoVeto: false))
        #expect(MeetingMode.hybrid.legs == MeetingLegConfig(capturesSystem: true, cancelsEcho: true, echoVeto: true))
        #expect(MeetingMode.inPerson.legs.channels == [.mic])
        #expect(MeetingMode.videoCall.legs.channels == [.mic, .system])
        #expect(Set(MeetingMode.allCases.map(\.label)).count == 3)
    }

    @Test("M4 auto-pick: system audio ∧ call app frontmost → video call, else in person; hybrid only by hand")
    func autoPick() {
        func pick(_ audio: Bool, _ call: Bool) -> MeetingMode {
            MeetingModePicker.pick(MeetingModeSignals(systemAudioActive: audio, callAppFrontmost: call))
        }
        #expect(pick(true, true) == .videoCall)
        #expect(pick(true, false) == .inPerson)
        #expect(pick(false, true) == .inPerson)
        #expect(pick(false, false) == .inPerson)
        #expect(MeetingModePicker.isCallAppFrontmost(bundleID: "us.zoom.xos"))
        #expect(!MeetingModePicker.isCallAppFrontmost(bundleID: "com.apple.Safari"))
        #expect(MeetingModePicker.isCallAppFrontmost(bundleID: "com.apple.Safari", detectedFromBrowser: true))
        #expect(!MeetingModePicker.isCallAppFrontmost(bundleID: nil))
    }

    @Test("in person never opens system audio; the microphone drains on its own")
    func inPersonMicOnly() async throws {
        let mic = PushSource(), sys = PushSource()
        let log = LegLog()
        let capture = DualCapture(mic: mic, system: sys, micVAD: AlwaysSpeech(), systemVAD: AlwaysSpeech(),
                                  aec: PassthroughEchoCanceller(), mode: .inPerson)
        capture.recording = log
        try await capture.start()
        #expect(sys.starts == 0, "system audio is not opened in person")
        mic.push(Self.tone(6))   // no system samples arrive at all
        let chunks = try await capture.drain()
        #expect(!chunks.isEmpty && chunks.allSatisfy { $0.channel == .mic })
        #expect(log.mic == 96_000 && log.system == 0 && log.systemNil > 0, "only the mic leg is recorded")
        _ = try await capture.stop()
    }

    @Test("switching in person → video call mid-meeting opens system audio on the same clock")
    func switchModesLive() async throws {
        let mic = PushSource(), sys = PushSource()
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = MeetingAudioRecorder(directory: dir)
        let capture = DualCapture(mic: mic, system: sys, micVAD: AlwaysSpeech(), systemVAD: AlwaysSpeech(),
                                  aec: PassthroughEchoCanceller(), mode: .inPerson)
        capture.recording = recorder
        try await capture.start()
        mic.push(Self.tone(2))
        _ = try await capture.drain()
        try capture.setMode(.videoCall)
        #expect(sys.starts == 1 && sys.isRunning)
        mic.push(Self.tone(3)); sys.push(Self.tone(3))
        let chunks = try await capture.stop()
        let system = chunks.filter { $0.channel == .system }
        #expect(!system.isEmpty)
        // The system leg's clock was padded to the mic's: its speech starts at 2 s, not 0.
        #expect(system.allSatisfy { $0.range.lowerBound >= 2 - 0.05 })
        #expect(recorder.counts.mic == 80_000 && recorder.counts.system == 80_000, "both files cover the whole meeting")
        try capture.setMode(.inPerson)
        #expect(!sys.isRunning || !capture.isRunning)
    }

    // MARK: M3 echo veto

    @Test("echo veto needs both system energy within 150 ms and duplicated words")
    func vetoRule() {
        let mic = MeetingUtterance(speaker: .you, text: "The budget is approved.", range: 10...12, confidence: 0.9)
        let sys = MeetingUtterance(speaker: .others(1), text: "the budget is approved", range: 10.1...12.1, confidence: 0.9)
        let other = MeetingUtterance(speaker: .others(1), text: "what about hiring", range: 10.1...12.1, confidence: 0.9)
        #expect(MeetingEchoVeto.vetoes(mic, systemActivity: [11.9...12.4], systemLines: [sys]))
        #expect(MeetingEchoVeto.vetoes(mic, systemActivity: [12.14...13], systemLines: [sys]), "energy 140 ms after the line")
        #expect(!MeetingEchoVeto.vetoes(mic, systemActivity: [12.2...13], systemLines: [sys]), "energy 200 ms away")
        #expect(!MeetingEchoVeto.vetoes(mic, systemActivity: [], systemLines: [sys]), "words alone: someone in the room repeating")
        #expect(!MeetingEchoVeto.vetoes(mic, systemActivity: [10...12], systemLines: [other]), "energy alone: talking over the call")
        let late = MeetingUtterance(speaker: .others(1), text: "the budget is approved", range: 20...22, confidence: 0.9)
        #expect(!MeetingEchoVeto.duplicates(mic, of: [late]), "same words much later are not an echo")
    }

    @Test("hybrid: a synthetic echo pair is transcribed once; video call keeps both legs")
    func echoPairThroughCaptureAndSession() async throws {
        for (mode, expected) in [(MeetingMode.hybrid, 1), (.videoCall, 2)] {
            let mic = PushSource(), sys = PushSource()
            let capture = DualCapture(mic: mic, system: sys, micVAD: AlwaysSpeech(), systemVAD: AlwaysSpeech(),
                                      aec: PassthroughEchoCanceller(), mode: mode)
            let root = Self.temp()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = MeetingSession(title: "Room + call", transcriber: SameWordsASR(), labeler: ChannelLabeler(),
                                         store: MeetingStore(root: root), mode: mode)
            try await capture.start()
            // The far end speaks (system leg); the room mic hears it from the speakers 40 ms later.
            let far = Self.tone(4)
            let echo = [Float](repeating: 0, count: 640) + far.prefix(far.count - 640).map { $0 * 0.4 }
            sys.push(far); mic.push(echo)
            let chunks = try await capture.stop()
            #expect(chunks.contains { $0.channel == .mic && !$0.systemActivity.isEmpty }, "mic chunk carries system energy")
            try await session.ingest(chunks)
            let rec = try await session.finish()
            #expect(rec.transcript.utterances.count == expected, "\(mode)")
            #expect(rec.mode == mode)
            if mode == .hybrid { #expect(await session.vetoedEchoes >= 1) }
        }
    }

    @Test("hybrid: a system line arriving in a later drain takes its mic echo back out")
    func lateSystemRetractsEcho() async throws {
        let root = Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(title: "Late", transcriber: SameWordsASR(), labeler: ChannelLabeler(),
                                     store: MeetingStore(root: root), mode: .hybrid)
        let box = TranscriptBox()
        await session.setHandlers(onTranscript: { box.set($0) })
        let audio = AudioChunk(samples: [Float](repeating: 0.1, count: 48_000), range: 5...8, reason: .speechEnd)
        try await session.ingest([MeetingChunk(channel: .mic, chunk: audio, systemActivity: [5...8])])
        #expect(await session.record.transcript.utterances.count == 1)
        try await session.ingest([MeetingChunk(channel: .system, chunk: AudioChunk(samples: audio.samples, range: 5.05...8.05, reason: .speechEnd))])
        let lines = await session.record.transcript.utterances
        #expect(lines.count == 1 && lines[0].speaker == .others(1), "only the call's own line remains")
        #expect(box.value?.utterances.count == 1, "the panel is told")
    }

    final class TranscriptBox: @unchecked Sendable {
        private let lock = NSLock(); private var t: MeetingTranscript?
        func set(_ v: MeetingTranscript) { lock.withLock { t = v } }
        var value: MeetingTranscript? { lock.withLock { t } }
    }

    // MARK: M14 (engine half)

    @Test("dictations switched off: dictated spans leave the saved transcript, commands stay")
    func hideDictations() async throws {
        let root = Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = MeetingSession(title: "M14", transcriber: SameWordsASR(), labeler: ChannelLabeler(), store: MeetingStore(root: root))
        await session.setKeepsDictations(false)
        let origin = await session.record.startedAt
        func chunk(_ t: TimeInterval) -> MeetingChunk {
            MeetingChunk(channel: .mic, chunk: AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), range: t...(t + 1), reason: .speechEnd))
        }
        try await session.ingest([chunk(0), chunk(5), chunk(10)])
        await session.tag(UtteranceTag(utteranceID: "d", owner: .dictate, range: origin.addingTimeInterval(5)...origin.addingTimeInterval(6)))
        await session.tag(UtteranceTag(utteranceID: "a", owner: .act, range: origin.addingTimeInterval(10)...origin.addingTimeInterval(11)))
        let rec = try await session.finish()
        #expect(rec.transcript.utterances.map(\.tag) == [nil, .act])
    }

    // MARK: M5 saved recording

    @Test("WAV per leg: readable 16 kHz files, system padded to the mic clock, found by M8's locator")
    func recorderFiles() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = MeetingAudioRecorder(directory: dir)
        rec.record(mic: Self.tone(1), system: nil)                 // in person for 1 s
        rec.record(mic: Self.tone(0.5), system: Self.tone(0.5))     // then a call
        rec.close()
        let mic = try WAVFile.read(url: rec.micURL), sys = try WAVFile.read(url: rec.systemURL)
        #expect(mic.sampleRate == 16_000 && mic.channels == 1 && mic.samples.count == 24_000)
        #expect(sys.samples.count == 24_000, "system starts silent where the mic began")
        #expect(sys.samples.prefix(16_000).allSatisfy { $0 == 0 })
        #expect(abs(mic.samples[100] - Self.tone(1)[100]) < 0.001)
        let located = try #require(MeetingRecordingAudio.locate(in: dir))
        #expect(located.legs[.mic]?.lastPathComponent == MeetingAudioRecorder.micFileName)
        #expect(located.legs[.system]?.lastPathComponent == MeetingAudioRecorder.systemFileName)
    }

    @Test("retention: 7 days expires old audio; the shared disk cap evicts the oldest; the live meeting is kept")
    func sweep() throws {
        let root = Self.temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let now = Date()
        func make(_ id: String, ageDays: Double, bytes: Int) throws -> URL {
            let dir = root.appendingPathComponent(id, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent(MeetingAudioRecorder.micFileName)
            try Data(count: bytes).write(to: f)
            try "{}".write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: f.path)
            return f
        }
        let old = try make("old", ageDays: 10, bytes: 1_000)
        let mid = try make("mid", ageDays: 3, bytes: 1_000)
        let new = try make("new", ageDays: 1, bytes: 1_000)
        let live = try make("live", ageDays: 20, bytes: 1_000)

        // Always: nothing expires; under the cap nothing goes.
        var r = MeetingRecordingSweeper.sweep(meetingsRoot: root, now: now, retentionDays: nil, diskCap: 10_000)
        #expect(r == .init(expired: 0, overCap: 0))
        // 7 days: the 10-day file goes, the live meeting's never does.
        r = MeetingRecordingSweeper.sweep(meetingsRoot: root, now: now, retentionDays: 7, diskCap: 10_000,
                                          keeping: live.deletingLastPathComponent())
        #expect(r.expired == 1 && !fm.fileExists(atPath: old.path) && fm.fileExists(atPath: live.path))
        // Shared cap: dictation recordings already use 2,500 of 4,600 → oldest meeting audio goes first.
        r = MeetingRecordingSweeper.sweep(meetingsRoot: root, now: now, retentionDays: nil, diskCap: 4_600,
                                          otherBytes: 2_500, keeping: live.deletingLastPathComponent())
        #expect(r.overCap == 1 && !fm.fileExists(atPath: mid.path) && fm.fileExists(atPath: new.path))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("mid/meeting.json").path), "transcripts are never removed")
    }
}
