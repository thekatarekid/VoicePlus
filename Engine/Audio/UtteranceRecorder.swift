import Foundation
import Shared

/// Opt-in local capture of one utterance's audio, so a dictation that came out wrong can be
/// replayed through the fixture harness instead of argued about.
///
/// Why this exists. Every accuracy investigation up to 1.7.12 measured synthetic `say` fixtures and
/// found the model, the decoder, the acoustic chain, the biaser, the 44.1 kHz resample and the
/// absolute input level all clean — while the owner's real microphone still produced ~55 % WER on a
/// pangram. That gap cannot be closed by more offline sweeps: nobody has the audio that failed. This
/// records it.
///
/// Two files per utterance, both 16 kHz mono:
///   * `<stamp>-raw.wav`       — exactly what the capture source delivered, before any DSP.
///   * `<stamp>-processed.wav` — what the recognizer was actually handed, after the acoustic chain.
/// Comparing the two attributes any damage to the chain or clears it in one listen. A `<stamp>.json`
/// sidecar records the device, its transport and rate, the capture graph and the profile, because a
/// WAV with no provenance answers half the question.
///
/// Privacy. Off by default, opt-in, local only. Nothing is uploaded, nothing is logged but the path,
/// and only the most recent `retainedUtterances` are kept so it cannot quietly grow. Recordings live
/// in `~/Library/Application Support/VoicePlus/Recordings` and are deleted by removing that folder.
public final class UtteranceRecorder: @unchecked Sendable {
    /// `UserDefaults` switch. Absent means off — this is never on unless a user turned it on.
    public static let defaultsKey = "diagnostics.saveUtteranceAudio"
    /// How many utterances are kept. Older ones are deleted whenever a new one lands.
    public static let retainedUtterances = 20
    /// Hard ceiling per utterance, so a locked-on dictation cannot grow the buffer without bound.
    public static let maxSeconds: Double = 180

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    public static func directory() -> URL {
        AppPaths.supportDirectory().appendingPathComponent("Recordings", isDirectory: true)
    }

    /// What the sidecar carries. Everything a replay needs to be interpreted.
    public struct Manifest: Codable, Equatable, Sendable {
        public var recordedAt: Date
        public var deviceName: String
        public var deviceUID: String
        public var transport: String
        /// The device's nominal input rate — 8000/16000 here means a Bluetooth HFP link.
        public var deviceSampleRate: Double
        public var inputChannels: Int
        /// `AudioCaptureDiagnostics.summary` when the source can supply one: tap rate, pin, formats.
        public var captureGraph: String?
        public var noiseSuppression: Bool
        public var noiseSuppressionStrength: Float
        public var aec: String
        public var seconds: Double
        public var rawRMSdBFS: Double
        public var rawPeakdBFS: Double
        public var processedRMSdBFS: Double
        public var processedPeakdBFS: Double
    }

    private let directory: URL
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var raw: [Float] = []
    private var processed: [Float] = []
    private var recording = false
    private var device: AudioDeviceInfo?
    private var profile: RobustnessProfile = .default
    private var captureGraph: String?
    private let sampleCap = Int(maxSeconds * 16_000)

    public init(directory: URL = UtteranceRecorder.directory(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// Arms the recorder for one utterance. Cheap and safe to call when disabled — it just doesn't arm.
    public func begin(device: AudioDeviceInfo?, profile: RobustnessProfile, captureGraph: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        raw.removeAll(keepingCapacity: true)
        processed.removeAll(keepingCapacity: true)
        self.device = device
        self.profile = profile
        self.captureGraph = captureGraph
        recording = true
    }

    /// Called from the audio thread. Bounded append under a lock, same as the pre-roll buffer.
    public func appendRaw(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock(); defer { lock.unlock() }
        guard recording, raw.count < sampleCap else { return }
        raw.append(contentsOf: samples)
    }

    public func appendProcessed(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard recording, processed.count < sampleCap else { return }
        processed.append(contentsOf: samples)
    }

    /// Writes the pair plus the sidecar and prunes old ones. Returns the raw WAV's URL, or nil when
    /// nothing was captured. Call off the audio thread — `AcousticCaptureSource.stop()` does.
    @discardableResult
    public func finish() throws -> URL? {
        lock.lock()
        guard recording else { lock.unlock(); return nil }
        recording = false
        let rawSamples = raw, processedSamples = processed
        let device = self.device, profile = self.profile, graph = self.captureGraph
        raw.removeAll(keepingCapacity: false)
        processed.removeAll(keepingCapacity: false)
        lock.unlock()

        guard !rawSamples.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.stampFormatter.string(from: now())
        let rawURL = directory.appendingPathComponent("\(stamp)-raw.wav")
        try WAVFile(sampleRate: 16_000, channels: 1, samples: rawSamples).write(to: rawURL)
        if !processedSamples.isEmpty {
            try WAVFile(sampleRate: 16_000, channels: 1, samples: processedSamples)
                .write(to: directory.appendingPathComponent("\(stamp)-processed.wav"))
        }
        let manifest = Manifest(
            recordedAt: now(),
            deviceName: device?.name ?? "unknown",
            deviceUID: device?.uid ?? "unknown",
            transport: device?.transport.rawValue ?? "unknown",
            deviceSampleRate: device?.sampleRate ?? 0,
            inputChannels: device?.inputChannels ?? 0,
            captureGraph: graph,
            noiseSuppression: profile.noiseSuppression,
            noiseSuppressionStrength: profile.noiseSuppressionStrength,
            aec: profile.aec.rawValue,
            seconds: Double(rawSamples.count) / 16_000,
            rawRMSdBFS: Self.rmsDBFS(rawSamples),
            rawPeakdBFS: Self.peakDBFS(rawSamples),
            processedRMSdBFS: Self.rmsDBFS(processedSamples),
            processedPeakdBFS: Self.peakDBFS(processedSamples))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("\(stamp).json"))

        prune()
        Log.engine.notice("audio: saved utterance recording (diagnostics are ON) — \(rawURL.path)")
        return rawURL
    }

    /// Keeps the newest `retainedUtterances` stamps and deletes every file belonging to the rest.
    public func prune(keeping limit: Int = UtteranceRecorder.retainedUtterances) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let stamps = Set(files.map { Self.stamp(of: $0) }).sorted(by: >)
        guard stamps.count > limit else { return }
        let doomed = Set(stamps.dropFirst(limit))
        for file in files where doomed.contains(Self.stamp(of: file)) { try? fm.removeItem(at: file) }
    }

    /// The stamp shared by an utterance's three files (`2026-09-08-231455-123-raw.wav` → the date part).
    public static func stamp(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        for suffix in ["-raw", "-processed"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// Digital silence is `-inf` dBFS, and JSON has no way to write that — encoding one would throw
    /// and take the whole recording with it, exactly when a silent capture is the thing worth
    /// keeping. Floored at −200 dBFS, which no real signal reaches.
    public static let silenceFloorDBFS: Double = -200

    public static func rmsDBFS(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return silenceFloorDBFS }
        let mean = s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)
        return mean > 0 ? max(20 * log10(sqrt(mean)), silenceFloorDBFS) : silenceFloorDBFS
    }

    public static func peakDBFS(_ s: [Float]) -> Double {
        let peak = s.reduce(0.0) { max($0, abs(Double($1))) }
        return peak > 0 ? max(20 * log10(peak), silenceFloorDBFS) : silenceFloorDBFS
    }
}
