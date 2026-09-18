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
/// Privacy. Off by default, opt-in, local only. Nothing is uploaded, nothing is logged but the path
/// and the folder's size, and only the most recent `retainedUtterances` are kept (V4.52: 100 by
/// default, or every one when the owner picks "Keep all") so it cannot quietly grow unseen — the
/// folder's size is reported (`usage()`) beside the switch. Recordings live in
/// `~/Library/Application Support/VoicePlus/Recordings` and are deleted by removing that folder.
public final class UtteranceRecorder: @unchecked Sendable {
    /// `UserDefaults` switch. Absent means off — this is never on unless a user turned it on.
    public static let defaultsKey = "diagnostics.saveUtteranceAudio"
    /// V4.52 — how many utterances are kept; older ones are deleted whenever a new one lands.
    /// `SettingsKeys.recordingsRetain` in the app aliases this key. Stored as a decimal string (the
    /// `SettingsStore` carries strings), read on every save so a change applies to the next one.
    public static let retainKey = "recordings.retain"
    /// What an unset or unreadable `retainKey` means: a corpus session of ~100 lines fits unpruned.
    public static let defaultRetainedUtterances = 100
    /// The stored value for "Keep all": nothing is ever pruned.
    public static let keepAll = 0
    /// V4.52 — the label a corpus pass is tagged with (set from Settings › Privacy), written into
    /// every manifest saved while it is set. Absent or blank means untagged.
    public static let corpusKey = "recordings.corpus"

    /// The retention in force, read from `UserDefaults.standard`. `keepAll` (0) means keep every one.
    public static var retainedUtterances: Int { retention() }
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

    // MARK: retention + corpus label (V4.52)

    /// The stored retention: `defaultRetainedUtterances` when unset or unreadable, `keepAll` (0)
    /// for "Keep all", otherwise the number of newest utterances kept.
    public static func retention(_ defaults: UserDefaults = .standard) -> Int {
        parseRetention(defaults.object(forKey: retainKey))
    }

    /// Writes the retention as a decimal string, the form `SettingsStore.string` reads back.
    /// A negative count is not a retention; it stores the default instead.
    public static func setRetention(_ count: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(String(count < 0 ? defaultRetainedUtterances : count), forKey: retainKey)
    }

    /// One parser for every reader (this class and the app's `SettingsStore` path): a number or a
    /// decimal string ≥ 0 is taken as is; anything else — absent, negative, garbage — is the default.
    public static func parseRetention(_ stored: Any?) -> Int {
        let value: Int?
        switch stored {
        case let n as NSNumber: value = n.intValue
        case let s as String: value = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: value = nil
        }
        guard let value, value >= 0 else { return defaultRetainedUtterances }
        return value
    }

    /// The corpus label in force, or nil when none is set.
    public static func corpusLabel(_ defaults: UserDefaults = .standard) -> String? {
        normalizedCorpusLabel(defaults.string(forKey: corpusKey))
    }

    /// Setting nil or a blank label removes it, so later recordings go untagged.
    public static func setCorpusLabel(_ label: String?, _ defaults: UserDefaults = .standard) {
        if let label = normalizedCorpusLabel(label) {
            defaults.set(label, forKey: corpusKey)
        } else {
            defaults.removeObject(forKey: corpusKey)
        }
    }

    /// Trimmed; blank is no label.
    public static func normalizedCorpusLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: folder usage

    /// What the Recordings folder holds, for the "N recordings · 12.4 MB" line beside the switch.
    public struct FolderUsage: Equatable, Sendable {
        /// Whole utterances (a raw/processed/sidecar triple counts once).
        public var utterances: Int
        /// Bytes on disk across every recording file.
        public var bytes: Int64

        public init(utterances: Int, bytes: Int64) {
            self.utterances = utterances
            self.bytes = bytes
        }

        public static let empty = FolderUsage(utterances: 0, bytes: 0)

        /// "12.4 MB", in the Finder's units.
        public var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// Counts and sizes only files the recorder wrote (`<stamp>-raw.wav`, `<stamp>-processed.wav`,
    /// `<stamp>.json`); anything else in the folder is neither counted nor ever pruned.
    public static func usage(of directory: URL = UtteranceRecorder.directory()) -> FolderUsage {
        let files = recordingFiles(in: directory, keys: [.fileSizeKey])
        guard !files.isEmpty else { return .empty }
        // Logical size, as the Finder's "Size" column reports it (not blocks allocated).
        let bytes = files.reduce(Int64(0)) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return FolderUsage(utterances: Set(files.map { stamp(of: $0) }).count, bytes: bytes)
    }

    /// Keeps the newest `limit` utterances in `directory` and deletes every file of the rest.
    /// `keepAll` (0) — or any limit not below the count — deletes nothing.
    public static func prune(in directory: URL, keeping limit: Int) {
        guard limit > keepAll else { return }
        let files = recordingFiles(in: directory)
        let stamps = Set(files.map { stamp(of: $0) }).sorted(by: >)
        guard stamps.count > limit else { return }
        let doomed = Set(stamps.dropFirst(limit))
        let fm = FileManager.default
        for file in files where doomed.contains(stamp(of: file)) { try? fm.removeItem(at: file) }
    }

    /// Files named by `finish()`. The stamp sorts chronologically as a string, which is what makes
    /// "newest" a plain descending sort.
    static func recordingFiles(in directory: URL, keys: [URLResourceKey]? = nil) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return files.filter(isRecordingFile)
    }

    static func isRecordingFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let body: Substring
        if name.hasSuffix("-raw.wav") { body = name.dropLast("-raw.wav".count) }
        else if name.hasSuffix("-processed.wav") { body = name.dropLast("-processed.wav".count) }
        else if name.hasSuffix(".json") { body = name.dropLast(".json".count) }
        else { return false }
        return isStamp(body)
    }

    /// `yyyy-MM-dd-HHmmss-SSS`, the shape `stampFormatter` writes.
    static func isStamp(_ s: Substring) -> Bool {
        let shape = Array("dddd-dd-dd-dddddd-ddd")
        let chars = Array(s)
        guard chars.count == shape.count else { return false }
        for (c, want) in zip(chars, shape) {
            if want == "d" ? !(c.isASCII && c.isNumber) : c != want { return false }
        }
        return true
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
        /// V4.52 — the corpus pass this utterance belongs to (`corpusKey` at save time), so passes
        /// are told apart by tag rather than by folder. Absent from older sidecars; they decode as nil.
        public var corpus: String? = nil
    }

    private let directory: URL
    /// Where the retention and the corpus label are read, at every save.
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var raw: [Float] = []
    private var processed: [Float] = []
    private var recording = false
    private var device: AudioDeviceInfo?
    private var profile: RobustnessProfile = .default
    private var captureGraph: String?
    private let sampleCap = Int(maxSeconds * 16_000)

    public init(directory: URL = UtteranceRecorder.directory(), defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.defaults = defaults
        self.now = now
    }

    /// The retention this recorder prunes to — the setting, read now.
    public var retention: Int { Self.retention(defaults) }

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
            processedPeakdBFS: Self.peakDBFS(processedSamples),
            corpus: Self.corpusLabel(defaults))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("\(stamp).json"))

        let limit = retention
        prune(keeping: limit)
        let kept = usage()
        Log.engine.notice("audio: saved utterance recording (diagnostics are ON) — \(rawURL.path) · \(kept.utterances) kept, \(kept.formattedSize), retention \(limit == Self.keepAll ? "all" : String(limit))")
        return rawURL
    }

    /// Keeps the newest `limit` stamps (the setting when nil) and deletes every file belonging to
    /// the rest. `keepAll` (0) deletes nothing.
    public func prune(keeping limit: Int? = nil) {
        Self.prune(in: directory, keeping: limit ?? retention)
    }

    /// This recorder's folder, counted and sized.
    public func usage() -> FolderUsage { Self.usage(of: directory) }

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
