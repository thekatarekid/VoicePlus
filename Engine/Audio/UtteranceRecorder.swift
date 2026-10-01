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
/// V5 F3 — **every dictation is stored** (owner decision, V5 §F3 / X17): the switch defaults to on
/// for the dictation capture graph (`CaptureGraphPlan`), and the sidecar also carries the turn's
/// transcript, final text and target app (`annotateLatest`). Retention is by age — 7 / 30 / 90 days
/// or forever, default 30 (`retentionDaysKey`) — under a disk cap, default 2 GB (`diskCapKey`), with
/// the least-recently-used utterances deleted first (`sweep`). Recordings are never synced: the sync
/// payload has no audio field (`SyncPayload.audit()`), and there is no Sync option for them yet.
///
/// Privacy. Local only. Nothing is uploaded, nothing is logged but the path and the folder's size.
/// Turning the switch off stops the next recording. Other captures (the Voice test, the mic self-test,
/// onboarding) record only when the user explicitly turned the switch on (`isExplicitlyEnabled`).
/// Recordings live in `~/Library/Application Support/VoicePlus/Recordings` and are deleted by
/// removing that folder.
public final class UtteranceRecorder: @unchecked Sendable {
    /// `UserDefaults` switch. V5 F3: absent means **on** for dictation; `false` stored means off.
    public static let defaultsKey = "diagnostics.saveUtteranceAudio"
    /// V4.52 — a legacy *count* retention, now honoured only when one is explicitly stored (F3 made
    /// age + disk cap the retention). `SettingsKeys.recordingsRetain` in the app aliases this key.
    /// Stored as a decimal string, read on every save so a change applies to the next one.
    public static let retainKey = "recordings.retain"
    /// What an unset or unreadable `retainKey` means. V5 F3: no count limit (`keepAll`); age and the
    /// disk cap govern.
    public static let defaultRetainedUtterances = 0
    /// The stored value for "Keep all": nothing is ever pruned.
    public static let keepAll = 0
    /// V4.52 — the label a corpus pass is tagged with (set from Settings › Privacy), written into
    /// every manifest saved while it is set. Absent or blank means untagged.
    public static let corpusKey = "recordings.corpus"

    /// The retention in force, read from `UserDefaults.standard`. `keepAll` (0) means keep every one.
    public static var retainedUtterances: Int { retention() }
    /// Hard ceiling per utterance, so a locked-on dictation cannot grow the buffer without bound.
    public static let maxSeconds: Double = 180

    /// V5 F3 — the dictation switch: on unless the user stored `false`.
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
    }

    /// The pre-F3 opt-in reading: on only when the user stored `true`. Captures other than dictation
    /// (Voice test, mic self-test, onboarding) record only then.
    public static func isExplicitlyEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    // MARK: age retention + disk cap (V5 F3)

    /// Days a recording is kept; `0` = forever. Stored as a decimal string.
    public static let retentionDaysKey = "recordings.retentionDays"
    public static let defaultRetentionDays = 30
    public static let forever = 0
    /// The choices Settings › Privacy offers, in order.
    public static let retentionDayChoices = [7, 30, 90, forever]

    /// Disk cap in bytes for the whole Recordings folder. Stored as a decimal string.
    public static let diskCapKey = "recordings.diskCapBytes"
    public static let gigabyte: Int64 = 1_000_000_000
    public static let defaultDiskCapBytes: Int64 = 2 * gigabyte
    /// The caps Settings › Privacy offers.
    public static let diskCapChoices: [Int64] = [1, 2, 5, 10].map { $0 * gigabyte }

    public static func retentionDays(_ defaults: UserDefaults = .standard) -> Int {
        parseRetentionDays(defaults.object(forKey: retentionDaysKey))
    }

    public static func setRetentionDays(_ days: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(String(days < 0 ? defaultRetentionDays : days), forKey: retentionDaysKey)
    }

    /// A number or decimal string ≥ 0; anything else (absent, negative, garbage) is 30.
    public static func parseRetentionDays(_ stored: Any?) -> Int {
        guard let v = parseInt(stored), v >= 0 else { return defaultRetentionDays }
        return v
    }

    public static func diskCapBytes(_ defaults: UserDefaults = .standard) -> Int64 {
        parseDiskCap(defaults.object(forKey: diskCapKey))
    }

    public static func setDiskCapBytes(_ bytes: Int64, _ defaults: UserDefaults = .standard) {
        defaults.set(String(bytes <= 0 ? defaultDiskCapBytes : bytes), forKey: diskCapKey)
    }

    /// A positive number or decimal string; anything else is 2 GB. There is no "no cap".
    public static func parseDiskCap(_ stored: Any?) -> Int64 {
        let value: Int64?
        switch stored {
        case let n as NSNumber: value = n.int64Value
        case let s as String: value = Int64(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: value = nil
        }
        guard let value, value > 0 else { return defaultDiskCapBytes }
        return value
    }

    private static func parseInt(_ stored: Any?) -> Int? {
        switch stored {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// What one `sweep` deleted, in whole utterances.
    public struct SweepResult: Equatable, Sendable {
        public var expired: Int
        public var overCap: Int
        public init(expired: Int = 0, overCap: Int = 0) { self.expired = expired; self.overCap = overCap }
    }

    /// Deletes every utterance older than `retentionDays` (by its stamp; `forever` keeps all), then,
    /// while the folder is over `diskCap`, the least-recently-used utterance (latest modification of
    /// any of its files — `annotate`/`markUsed` touch it). `keeping` is never deleted (the one just
    /// saved). Files the recorder did not write are neither counted nor deleted.
    @discardableResult
    public static func sweep(in directory: URL, now: Date, retentionDays: Int, diskCap: Int64,
                             keeping: String? = nil) -> SweepResult {
        let fm = FileManager.default
        let files = recordingFiles(in: directory, keys: [.fileSizeKey, .contentModificationDateKey])
        var groups: [String: [URL]] = [:]
        for f in files { groups[stamp(of: f), default: []].append(f) }
        var result = SweepResult()
        if retentionDays > forever {
            let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
            for (s, urls) in groups where s != keeping {
                guard let date = stampFormatter.date(from: s), date < cutoff else { continue }
                for u in urls { try? fm.removeItem(at: u) }
                groups[s] = nil
                result.expired += 1
            }
        }
        struct Entry { var stamp: String; var bytes: Int64; var lastUsed: Date }
        var entries = groups.map { s, urls -> Entry in
            var bytes: Int64 = 0
            var last = stampFormatter.date(from: s) ?? .distantPast
            for u in urls {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, m > last { last = m }
            }
            return Entry(stamp: s, bytes: bytes, lastUsed: last)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > diskCap else { return result }
        entries.sort { ($0.lastUsed, $0.stamp) < ($1.lastUsed, $1.stamp) }
        for e in entries where total > diskCap && e.stamp != keeping {
            for u in groups[e.stamp] ?? [] { try? fm.removeItem(at: u) }
            total -= e.bytes
            result.overCap += 1
        }
        return result
    }

    /// LRU touch: the utterance was used (replayed, exported, made a training pair).
    public static func markUsed(stamp: String, in directory: URL = UtteranceRecorder.directory(), at date: Date = Date()) {
        for u in recordingFiles(in: directory) where self.stamp(of: u) == stamp {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
    }

    // MARK: transcript, final text, app (V5 F3)

    /// Writes the turn's transcript, final text and target app into `stamp`'s sidecar (which also
    /// marks it used). False when the sidecar is missing or unreadable.
    @discardableResult
    public static func annotate(stamp: String, in directory: URL = UtteranceRecorder.directory(),
                                transcript: String?, finalText: String?, appBundleID: String?) -> Bool {
        let url = directory.appendingPathComponent("\(stamp).json")
        guard let data = try? Data(contentsOf: url), var m = try? decoder.decode(Manifest.self, from: data) else { return false }
        m.transcript = transcript
        m.finalText = finalText
        m.appBundleID = appBundleID
        guard let out = try? encoder.encode(m) else { return false }
        do { try out.write(to: url, options: .atomic) } catch { return false }
        return true
    }

    /// Annotates the newest recording that has no final text yet and was saved within `window` of
    /// `now` — the one the turn that just landed captured (capture stops, `finish()` saves, the text
    /// lands). Returns its stamp, or nil when none qualifies (recording off, or already annotated).
    @discardableResult
    public static func annotateLatest(in directory: URL = UtteranceRecorder.directory(), now: Date = Date(),
                                      window: TimeInterval = 300, transcript: String?, finalText: String?,
                                      appBundleID: String?) -> String? {
        let stamps = Set(recordingFiles(in: directory).filter { $0.pathExtension == "json" }.map { stamp(of: $0) })
        for s in stamps.sorted(by: >).prefix(5) {
            let url = directory.appendingPathComponent("\(s).json")
            guard let data = try? Data(contentsOf: url), let m = try? decoder.decode(Manifest.self, from: data) else { continue }
            guard m.finalText == nil else { return nil }       // the newest is already this or an older turn's
            guard abs(now.timeIntervalSince(m.recordedAt)) <= window else { return nil }
            return annotate(stamp: s, in: directory, transcript: transcript, finalText: finalText,
                            appBundleID: appBundleID) ? s : nil
        }
        return nil
    }

    /// V5 F3 — a turn refused for a secure (password) field keeps nothing: deletes the newest
    /// recording that has no final text yet and was saved within `window` of `now` (that turn's raw +
    /// processed WAV and sidecar). Returns its stamp, or nil when none qualifies.
    @discardableResult
    public static func discardLatest(in directory: URL = UtteranceRecorder.directory(), now: Date = Date(),
                                     window: TimeInterval = 300) -> String? {
        let files = recordingFiles(in: directory)
        let stamps = Set(files.filter { $0.pathExtension == "json" }.map { stamp(of: $0) })
        guard let s = stamps.sorted(by: >).first else { return nil }
        let url = directory.appendingPathComponent("\(s).json")
        guard let data = try? Data(contentsOf: url), let m = try? decoder.decode(Manifest.self, from: data),
              m.finalText == nil, abs(now.timeIntervalSince(m.recordedAt)) <= window else { return nil }
        for u in files where stamp(of: u) == s { try? FileManager.default.removeItem(at: u) }
        return s
    }

    /// Where a secure-field refusal goes: installed with `installLandingAnnotator`; nil in tests.
    public static var onSecureRefusal: (@Sendable () -> Void)? {
        get { landedLock.withLock { _onSecureRefusal } }
        set { landedLock.withLock { _onSecureRefusal = newValue } }
    }
    nonisolated(unsafe) private static var _onSecureRefusal: (@Sendable () -> Void)?

    /// Called by the lander when a turn is refused for a secure field: its recording is deleted.
    public static func noteSecureRefusal() { onSecureRefusal?() }

    /// Where a landed turn's text goes: installed by `EngineFactory` for the real dictation stack
    /// (`annotateLatest` on the Recordings folder, off the caller's thread); nil — tests, mock
    /// engines — means nothing is written.
    public static var onLanded: (@Sendable (_ transcript: String?, _ finalText: String?, _ appBundleID: String?) -> Void)? {
        get { landedLock.withLock { _onLanded } }
        set { landedLock.withLock { _onLanded = newValue } }
    }
    nonisolated(unsafe) private static var _onLanded: (@Sendable (String?, String?, String?) -> Void)?
    private static let landedLock = NSLock()

    /// Called by the lander for every landed or held turn.
    public static func noteLanded(transcript: String?, finalText: String?, appBundleID: String?) {
        onLanded?(transcript, finalText, appBundleID)
    }

    /// The real stack's `onLanded`: annotate the turn's recording on a utility queue.
    public static func installLandingAnnotator(directory: URL = UtteranceRecorder.directory()) {
        onLanded = { transcript, finalText, app in
            DispatchQueue.global(qos: .utility).async {
                annotateLatest(in: directory, transcript: transcript, finalText: finalText, appBundleID: app)
            }
        }
        onSecureRefusal = {
            DispatchQueue.global(qos: .utility).async { discardLatest(in: directory) }
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

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
        /// V5 F3 — the recognizer's transcript, the text that landed and the app it landed in,
        /// written after the turn lands (`annotateLatest`). Absent from older sidecars.
        public var transcript: String? = nil
        public var finalText: String? = nil
        public var appBundleID: String? = nil
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
        try Self.encoder.encode(manifest).write(to: directory.appendingPathComponent("\(stamp).json"))

        let limit = retention
        prune(keeping: limit)
        let days = Self.retentionDays(defaults), cap = Self.diskCapBytes(defaults)
        let swept = Self.sweep(in: directory, now: now(), retentionDays: days, diskCap: cap, keeping: stamp)
        let kept = usage()
        Log.engine.notice("audio: saved utterance recording — \(rawURL.path) · \(kept.utterances) kept, \(kept.formattedSize); retention \(days == Self.forever ? "forever" : "\(days) d"), cap \(ByteCountFormatter.string(fromByteCount: cap, countStyle: .file)); swept \(swept.expired) expired, \(swept.overCap) over cap")
        return rawURL
    }

    /// Keeps the newest `limit` stamps (the setting when nil) and deletes every file belonging to
    /// the rest. `keepAll` (0) deletes nothing.
    public func prune(keeping limit: Int? = nil) {
        Self.prune(in: directory, keeping: limit ?? retention)
    }

    /// V5 F3 — the age + disk-cap sweep with this recorder's settings (the app runs it at launch too).
    @discardableResult
    public func sweep() -> SweepResult {
        Self.sweep(in: directory, now: now(), retentionDays: Self.retentionDays(defaults),
                   diskCap: Self.diskCapBytes(defaults))
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
