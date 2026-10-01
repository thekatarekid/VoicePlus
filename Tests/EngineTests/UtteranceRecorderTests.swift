import Foundation
import Testing
import Shared
@testable import Engine

/// The opt-in raw-capture diagnostic, and the device-selection rule that keeps dictation off a
/// Bluetooth telephony mic. Both exist for the same reason: an accuracy report that cannot be
/// reproduced offline needs the real audio and an honest record of where it came from.
@Suite("Utterance recorder + narrowband input avoidance")
struct UtteranceRecorderTests {

    static func dev(_ name: String, _ t: AudioDeviceInfo.Transport, rate: Double, ch: Int = 1, uid: String? = nil) -> AudioDeviceInfo {
        AudioDeviceInfo(id: 0, uid: uid ?? name, name: name, transport: t, sampleRate: rate, inputChannels: ch)
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-rec-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "vp.rec.\(UUID().uuidString)")!
        d.removePersistentDomain(forName: d.dictionaryRepresentation().isEmpty ? "" : "")
        return d
    }

    // MARK: recorder

    /// V5 F3 — every dictation is stored: absent means on for dictation; the pre-F3 opt-in reading
    /// (`isExplicitlyEnabled`, used by non-dictation captures) stays off until the user turns it on.
    @Test func onByDefaultForDictationOffUntilAskedForOtherCaptures() {
        let d = UserDefaults(suiteName: "vp.rec.off.\(UUID().uuidString)")!
        #expect(UtteranceRecorder.isEnabled(d))
        #expect(UtteranceRecorder.isExplicitlyEnabled(d) == false)
        UtteranceRecorder.setEnabled(false, d)
        #expect(UtteranceRecorder.isEnabled(d) == false, "a stored off is off")
        UtteranceRecorder.setEnabled(true, d)
        #expect(UtteranceRecorder.isEnabled(d) && UtteranceRecorder.isExplicitlyEnabled(d))
    }

    @Test func writesRawProcessedAndAManifestThatExplainsTheRecording() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = UtteranceRecorder(directory: dir)
        let raw = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let processed = raw.map { $0 * 0.5 }

        // `.gate`, not `.default`: this asserts the manifest faithfully echoes the profile's
        // noise-suppression flag, so it needs a profile whose flag is *on*. R1.4 moved `.default`
        // to the plain tap (`noiseSuppression == false`), which would have made the assertion below
        // vacuous rather than wrong.
        recorder.begin(device: Self.dev("MacBook Pro Microphone", .builtIn, rate: 48_000),
                       profile: .gate, captureGraph: "tap=44100Hz/1ch")
        raw.withUnsafeBufferPointer { recorder.appendRaw($0) }
        recorder.appendProcessed(processed)
        let url = try #require(try recorder.finish())

        let wav = try WAVFile.read(url: url)
        #expect(wav.sampleRate == 16_000)
        #expect(wav.channels == 1)
        #expect(abs(wav.duration - 1.0) < 0.01)

        let stamp = UtteranceRecorder.stamp(of: url)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stamp)-processed.wav").path))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(UtteranceRecorder.Manifest.self,
                                          from: Data(contentsOf: dir.appendingPathComponent("\(stamp).json")))
        #expect(manifest.deviceName == "MacBook Pro Microphone")
        #expect(manifest.transport == "builtIn")
        #expect(manifest.deviceSampleRate == 48_000)
        #expect(manifest.captureGraph == "tap=44100Hz/1ch")
        #expect(manifest.noiseSuppression)
        #expect(abs(manifest.seconds - 1.0) < 0.01)
        // The processed copy is 6 dB down from raw; the manifest must show that, since that is the
        // number that says whether the acoustic chain touched the audio.
        #expect(abs(manifest.rawRMSdBFS - manifest.processedRMSdBFS - 6.02) < 0.2)
    }

    @Test func silenceOrNoUtteranceWritesNothing() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = UtteranceRecorder(directory: dir)
        #expect(try recorder.finish() == nil)        // never begun
        recorder.begin(device: nil, profile: .raw)
        #expect(try recorder.finish() == nil)        // begun, but nothing captured
        #expect((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.isEmpty ?? true)
    }

    /// A capture with no processed audio at all still has to produce a file — that is precisely the
    /// case ("the mic delivered nothing") the diagnostic exists to evidence.
    @Test func aSilentProcessedTrackStillEncodesAManifest() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = UtteranceRecorder(directory: dir)
        recorder.begin(device: nil, profile: .raw)
        [Float](repeating: 0, count: 1_600).withUnsafeBufferPointer { recorder.appendRaw($0) }
        let url = try #require(try recorder.finish())
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(UtteranceRecorder.Manifest.self,
                                          from: Data(contentsOf: dir.appendingPathComponent("\(UtteranceRecorder.stamp(of: url)).json")))
        #expect(manifest.rawRMSdBFS == UtteranceRecorder.silenceFloorDBFS)
        #expect(manifest.processedRMSdBFS == UtteranceRecorder.silenceFloorDBFS)
    }

    @Test func keepsOnlyTheMostRecentUtterancesSoItCannotGrowUnbounded() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let recorder = UtteranceRecorder(directory: dir, now: { clock })
        let block = [Float](repeating: 0.2, count: 1_600)
        for _ in 0..<5 {
            recorder.begin(device: nil, profile: .raw)
            block.withUnsafeBufferPointer { recorder.appendRaw($0) }
            _ = try recorder.finish()
            clock.addTimeInterval(1)
        }
        recorder.prune(keeping: 2)
        let stamps = Set(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map(UtteranceRecorder.stamp(of:)))
        #expect(stamps.count == 2, "retention must delete whole utterances, sidecar included")
    }

    @Test func capturesThroughTheAcousticSourceWithoutChangingWhatTheSinkReceives() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = MockCaptureSource()
        let recorder = UtteranceRecorder(directory: dir)
        let source = AcousticCaptureSource(wrapping: inner, profile: .raw, recorder: recorder)
        var delivered: [Float] = []
        source.sink = { delivered.append(contentsOf: $0) }
        try source.start()
        let tone = (0..<8_000).map { Float(sin(Double($0) * 0.03)) * 0.4 }
        inner.push(tone)
        source.stop()

        #expect(delivered.count == tone.count, "recording must not perturb the audio the pipeline sees")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let rawWAV = try #require(files.first { $0.lastPathComponent.hasSuffix("-raw.wav") })
        #expect(try WAVFile.read(url: rawWAV).samples.count == tone.count)
    }

    @Test func staysSilentWhenNoRecorderIsInstalled() throws {
        let inner = MockCaptureSource()
        let source = AcousticCaptureSource(wrapping: inner, profile: .raw, recorder: nil)
        source.recorder = nil
        var delivered = 0
        source.sink = { delivered += $0.count }
        try source.start()
        inner.push([Float](repeating: 0.1, count: 1_600))
        source.stop()
        #expect(delivered == 1_600)
    }

    /// Regression, 1.7.15. The switch used to be read once, when the engine was built at launch, so
    /// turning it *off* stopped nothing: the recorder stayed installed and kept writing a WAV pair
    /// per dictation until the app was relaunched — while the Settings copy said "Turn it off when
    /// you're done". A switch that only takes effect at the next launch is not a switch.
    @Test func turningTheSwitchOffStopsTheNextRecordingRatherThanTheNextLaunch() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inner = MockCaptureSource()
        let source = AcousticCaptureSource(wrapping: inner, profile: .raw,
                                           recorder: UtteranceRecorder(directory: dir))
        var enabled = true
        source.isRecordingEnabled = { enabled }
        let tone = (0..<1_600).map { Float(sin(Double($0) * 0.03)) * 0.4 }

        func dictate() throws {
            try source.start()
            inner.push(tone)
            source.stop()
        }
        func rawWAVs() throws -> Int {
            try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasSuffix("-raw.wav") }.count
        }

        try dictate()
        #expect(try rawWAVs() == 1, "opted in, the utterance is on disk")

        enabled = false
        try dictate()
        #expect(try rawWAVs() == 1, "switched off, the very next utterance writes nothing — no relaunch")

        enabled = true
        try dictate()
        #expect(try rawWAVs() == 2, "and switching it back on arms the next one, also without a relaunch")
    }

    // MARK: narrowband Bluetooth avoidance

    @Test func airPodsAsSystemDefaultDoNotWinOverTheBuiltInMic() {
        let p = InputSelectionPolicy(defaults: UserDefaults(suiteName: "vp.pol.\(UUID().uuidString)")!)
        let airpods = Self.dev("Aditya's AirPods Pro", .bluetooth, rate: 16_000)
        let builtIn = Self.dev("MacBook Pro Microphone", .builtIn, rate: 48_000)
        let decision = p.decide(from: [airpods, builtIn], systemDefault: airpods)
        #expect(decision.device == builtIn, "an HFP mic must not capture dictation just because macOS made it default")
        #expect(decision.avoidedNarrowbandBluetooth == airpods, "the app has to be able to say what it walked away from")
    }

    @Test func narrowbandBluetoothIsStillUsedWhenItIsTheOnlyInput() {
        let p = InputSelectionPolicy(defaults: UserDefaults(suiteName: "vp.pol.\(UUID().uuidString)")!)
        let airpods = Self.dev("AirPods", .bluetooth, rate: 8_000)
        let decision = p.decide(from: [airpods], systemDefault: airpods)
        #expect(decision.device == airpods, "avoiding a bad mic must never mean capturing nothing")
        #expect(decision.avoidedNarrowbandBluetooth == nil)
    }

    @Test func anExplicitUserChoiceOfAirPodsIsHonoured() {
        let defaults = UserDefaults(suiteName: "vp.pol.\(UUID().uuidString)")!
        let p = InputSelectionPolicy(defaults: defaults)
        let airpods = Self.dev("AirPods", .bluetooth, rate: 16_000, uid: "airpods")
        let builtIn = Self.dev("MacBook Pro Microphone", .builtIn, rate: 48_000, uid: "builtin")
        p.preferredUID = "airpods"
        #expect(p.decide(from: [airpods, builtIn], systemDefault: builtIn).device == airpods)
    }

    @Test func highQualityBluetoothKeepsItsSystemDefaultStanding() {
        let p = InputSelectionPolicy(defaults: UserDefaults(suiteName: "vp.pol.\(UUID().uuidString)")!)
        // ≥24 kHz on a Bluetooth transport is LE Audio / a proprietary wideband mode, not HFP.
        let le = Self.dev("LE Headset", .bluetooth, rate: 48_000, uid: "le")
        let builtIn = Self.dev("MacBook Pro Microphone", .builtIn, rate: 48_000, uid: "builtin")
        #expect(p.decide(from: [le, builtIn], systemDefault: le).device == le)
    }

    @Test func aWiredMicStillBeatsTheBuiltInWhenItIsTheSystemDefault() {
        let p = InputSelectionPolicy(defaults: UserDefaults(suiteName: "vp.pol.\(UUID().uuidString)")!)
        let usb = Self.dev("Scarlett Solo", .usb, rate: 48_000, uid: "usb")
        let builtIn = Self.dev("MacBook Pro Microphone", .builtIn, rate: 48_000, uid: "builtin")
        #expect(p.decide(from: [usb, builtIn], systemDefault: usb).device == usb)
    }
}

/// Minimal `AudioCaptureSource` that pushes whatever the test hands it.
final class MockCaptureSource: AudioCaptureSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    var device: AudioDeviceInfo? = AudioDeviceInfo(id: 1, uid: "mock", name: "Mock", transport: .builtIn, sampleRate: 16_000, inputChannels: 1)
    func prewarm() throws {}
    func start() throws {}
    func stop() {}
    func switchDevice(to device: AudioDeviceInfo?) throws { self.device = device }
    func push(_ samples: [Float]) { samples.withUnsafeBufferPointer { sink?($0) } }
}
