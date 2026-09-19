import Engine
import Foundation
import Shared

// S7e — Voice › Input quality: the microphone test (design §8.4, §9; V3 §9 honesty rules).
//
// The user presses Test microphone, reads one sentence, presses Stop. Between those two presses the
// microphone is open on its own capture graph, the level meter shows real levels and Spool moves
// (design §8.9: "Spool moves only during explicit microphone test"). Stop releases the microphone
// *before* anything is analysed, and the analysis runs with Spool parked. The seven states are the
// design's: idle, capturing, analyzing, result, no samples, too short, device removed — plus a start
// failure (permission, no device, busy), which the catalogue already names.
//
// Everything here is pure state. The capture is a protocol (`VoiceTestCapturing`); the live one is
// `LiveVoiceTestCapture` in `VoiceTestCapture.swift`, which no test on this toolchain can open.

// MARK: - Capture

/// What the test's capture reports, in stream order.
public enum VoiceTestCaptureEvent: Equatable, Sendable {
    /// The microphone is open. `device` is its name when the graph knows it.
    case started(device: String?)
    /// 16 kHz mono samples; `position` is seconds since the capture started.
    case audio(samples: [Float], position: TimeInterval)
    /// Input level, 0…1 (the pill's normalisation, so the two meters agree).
    case level(Float)
    /// Voice activity on the same clock as `position`.
    case vad(VADEvent)
    /// The device the test was using is gone.
    case deviceRemoved(name: String?)
    /// The capture could not start, or started and delivered nothing.
    case failed(VoiceTestCaptureFailure)
}

public enum VoiceTestCaptureFailure: Equatable, Sendable {
    /// macOS has not granted the microphone.
    case permissionDenied
    /// No input device to open.
    case noInputDevice
    /// Dictation holds the microphone; a test never takes it from a held key.
    case busy
    /// The capture reported success but not one audio block arrived (the pipeline's watchdog).
    case noAudio
    /// Anything else the HAL refused. The text is diagnostics, never the headline.
    case couldNotStart(String)
}

/// A microphone the test can open and must be able to close completely.
public protocol VoiceTestCapturing: AnyObject, Sendable {
    /// Opens the microphone for one test. Events arrive in order; the stream finishes on `release()`.
    func open() -> AsyncStream<VoiceTestCaptureEvent>
    /// Closes and tears down the capture — the microphone indicator goes off. Idempotent and safe
    /// from any thread (the window closing calls it from `deinit`).
    func release()
    /// True from `open()` until `release()`.
    var isOpen: Bool { get }
}

// MARK: - Result

/// What a finished test measured, and what to say about it.
public struct VoiceTestResult: Equatable, Sendable {
    public var quality: MicQuality
    /// Seconds of speech the voice-activity detector heard.
    public var speechSeconds: TimeInterval
    /// dBFS of the speech and of the room, when the analyzer could separate them.
    public var signalDBFS: Float?
    public var floorDBFS: Float?
    public var device: String?

    public init(quality: MicQuality, speechSeconds: TimeInterval, signalDBFS: Float? = nil,
                floorDBFS: Float? = nil, device: String? = nil) {
        self.quality = quality
        self.speechSeconds = speechSeconds
        self.signalDBFS = signalDBFS
        self.floorDBFS = floorDBFS
        self.device = device
    }

    public enum Cause: Equatable, Sendable { case clear, quiet, clipping, noise }

    /// The one thing to fix, in the order it matters: a voice that is too quiet or clipping is not
    /// fixed by a quieter room.
    public var cause: Cause {
        if quality.verdict == .good { return .clear }
        if quality.lowLevel { return .quiet }
        if quality.clipping > MicQualityAnalyzer.poorClipping { return .clipping }
        return .noise
    }

    public var headline: String {
        cause == .clear ? VoiceTestCopy.clearHeadline : RecoveryCatalog.entry(.A08).headline
    }

    public var guidance: String {
        switch cause {
        case .clear: return VoiceTestCopy.clearGuidance
        case .quiet: return VoiceTestCopy.quietGuidance
        case .clipping: return VoiceTestCopy.clippingGuidance
        case .noise: return VoiceTestCopy.noiseGuidance
        }
    }

    /// The numbers behind the verdict, in words: "3.2 s of speech · voice −24 dBFS · room −61 dBFS · 37 dB apart".
    public var measurement: String {
        var parts = [String(format: "%.1f s of speech", speechSeconds)]
        if let signalDBFS { parts.append(String(format: "voice %.0f dBFS", signalDBFS)) }
        if let floorDBFS { parts.append(String(format: "room %.0f dBFS", floorDBFS)) }
        parts.append(String(format: "%.0f dB apart", quality.snr))
        return parts.joined(separator: " · ").replacingOccurrences(of: "-", with: "−")
    }
}

// MARK: - The test

@MainActor
public final class VoiceMicrophoneTest: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        /// The microphone is open.
        case capturing
        /// The microphone is closed; the recording is being graded.
        case analyzing
        case result(VoiceTestResult)
        /// Capture opened but no audio reached VoicePlus (A05).
        case noSamples
        /// Audio arrived, but less speech than a verdict needs (A07).
        case tooShort(speechSeconds: TimeInterval)
        /// The device went away mid-test (A02).
        case deviceRemoved(name: String?)
        /// The capture could not start (P01, A01, A03, A09).
        case failed(RecoveryID)

        /// True while the microphone is (or is about to be) open.
        public var isCapturing: Bool { self == .capturing }

        /// What Spool's surface is doing (S12 `SpoolSurfacePolicy`): only capture moves it.
        var activity: SpoolSurfacePolicy.Activity {
            switch self {
            case .capturing: return .capturing
            case .analyzing: return .analyzing
            default: return .idle
            }
        }

        /// The catalogue entry a failure state renders, if it renders one.
        public var recoveryID: RecoveryID? {
            switch self {
            case .noSamples: return .A05
            case .tooShort: return .A07
            case .deviceRemoved: return .A02
            case .failed(let id): return id
            case .result(let result): return result.cause == .clear ? nil : .A08
            case .idle, .capturing, .analyzing: return nil
            }
        }
    }

    /// The sentence the user reads (the prototype's own sample dictation, lengthened to ~3 s).
    nonisolated public static let sentence = "Can we meet with Mira on Friday to go through the launch checklist?"
    /// The test stops by itself after this long, so a forgotten test cannot keep the microphone open.
    nonisolated public static let maximumSeconds: TimeInterval = 12
    /// A verdict needs this much speech (`MicQualityAnalyzer.signalWindow`); less is "too short".
    nonisolated public static let minimumSpeechSeconds: TimeInterval = MicQualityAnalyzer.signalWindow
    /// The prototype's `.test-meter` has sixteen bars.
    nonisolated public static let meterBars = 16

    @Published public private(set) var phase: Phase = .idle
    /// Latest real input level, 0…1. Zero whenever the microphone is closed.
    @Published public private(set) var level: Double = 0
    /// The last `meterBars` real levels, oldest first. All zero when no test has run — the meter
    /// never draws illustrated levels.
    @Published public private(set) var meter: [Double] = Array(repeating: 0, count: VoiceMicrophoneTest.meterBars)
    /// The device the open capture reported.
    @Published public private(set) var deviceName: String?
    /// When the current phase began (Spool's state clock).
    @Published public private(set) var phaseStartedAt = Date()

    private let capture: VoiceTestCapturing
    private let maximumSeconds: TimeInterval
    private var recording = Recording()
    /// Bumped per test; events from an earlier test are dropped.
    private var generation = 0
    private var consumer: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    public init(capture: VoiceTestCapturing, maximumSeconds: TimeInterval = VoiceMicrophoneTest.maximumSeconds) {
        self.capture = capture
        self.maximumSeconds = maximumSeconds
    }

    deinit {
        consumer?.cancel()
        deadline?.cancel()
        capture.release()
    }

    /// Whether the microphone is open right now (it is the capture's word, not the phase's).
    public var isMicrophoneOpen: Bool { capture.isOpen }

    /// Seconds of speech heard so far in this test.
    var currentSpeechSeconds: TimeInterval { recording.speechSeconds }

    // MARK: Controls

    /// Test microphone / Test again / Try again. Ignored while a test is capturing or analysing.
    public func start() {
        guard phase != .capturing, phase != .analyzing else { return }
        generation += 1
        let current = generation
        recording = Recording()
        deviceName = nil
        resetMeter()
        set(.capturing)
        let stream = capture.open()
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event, generation: current)
            }
        }
        let limit = maximumSeconds
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == current, self.phase == .capturing else { return }
            self.stop()
        }
    }

    /// Stop: the microphone is released first, then the recording is graded with Spool parked.
    public func stop() {
        guard phase == .capturing else { return }
        closeMicrophone()
        set(.analyzing)
        let current = generation
        let recorded = recording
        Task { [weak self] in
            await Task.yield()
            guard let self, self.generation == current, self.phase == .analyzing else { return }
            self.set(Self.grade(recorded))
        }
    }

    /// Leaving the screen (or the window closing): the microphone closes and nothing is graded.
    public func cancel() {
        let wasActive = phase == .capturing || phase == .analyzing
        generation += 1
        closeMicrophone()
        if wasActive { set(.idle) }
    }

    // MARK: Events

    func handle(_ event: VoiceTestCaptureEvent, generation current: Int) {
        guard current == generation, phase == .capturing else { return }
        switch event {
        case .started(let device):
            deviceName = device
        case .audio(let samples, let position):
            recording.append(samples, endingAt: position + Double(samples.count) / Double(MicQualityAnalyzer.sampleRate))
        case .level(let value):
            let clamped = Double(min(max(value, 0), 1))
            level = clamped
            meter.removeFirst()
            meter.append(clamped)
        case .vad(let vad):
            recording.note(vad)
        case .deviceRemoved(let name):
            closeMicrophone()
            set(.deviceRemoved(name: name ?? deviceName))
        case .failed(let failure):
            closeMicrophone()
            switch failure {
            case .noAudio: set(.noSamples)
            case .permissionDenied: set(.failed(.P01))
            case .noInputDevice: set(.failed(.A01))
            case .busy: set(.failed(.A09))
            case .couldNotStart: set(.failed(.A03))
            }
        }
    }

    // MARK: Grading

    /// The recording's verdict: no audio at all → no samples; less than a second of speech → too
    /// short; otherwise the live analyzer's verdict (`MicQualityAnalyzer` v2: voice against room).
    static func grade(_ recording: Recording) -> Phase {
        guard recording.sampleCount > 0 else { return .noSamples }
        let speech = recording.speechSeconds
        guard speech >= minimumSpeechSeconds else { return .tooShort(speechSeconds: speech) }
        let analyzer = recording.analyzer
        guard let quality = analyzer.result ?? analyzer.flush() else { return .tooShort(speechSeconds: speech) }
        let measured = analyzer.measurement
        return .result(VoiceTestResult(quality: quality, speechSeconds: speech,
                                       signalDBFS: measured?.signalDBFS, floorDBFS: measured?.floorDBFS,
                                       device: recording.device))
    }

    // MARK: Internals

    private func closeMicrophone() {
        deadline?.cancel()
        deadline = nil
        consumer?.cancel()
        consumer = nil
        capture.release()
        level = 0
        recording.device = deviceName
    }

    private func resetMeter() {
        level = 0
        meter = Array(repeating: 0, count: Self.meterBars)
    }

    private func set(_ next: Phase) {
        phase = next
        phaseStartedAt = Date()
    }

    /// One test's audio, as the analyzer and the VAD saw it.
    struct Recording {
        let analyzer = MicQualityAnalyzer()
        private(set) var sampleCount = 0
        private(set) var position: TimeInterval = 0
        private(set) var closedSpeech: TimeInterval = 0
        private(set) var openSpeech: TimeInterval?
        var device: String?

        mutating func append(_ samples: [Float], endingAt end: TimeInterval) {
            guard !samples.isEmpty else { return }
            sampleCount += samples.count
            position = max(position, end)
            analyzer.feed(samples)
        }

        mutating func note(_ event: VADEvent) {
            analyzer.note(event)
            switch event {
            case .speechStart(let at):
                if openSpeech == nil { openSpeech = at }
            case .speechEnd(let at):
                if let start = openSpeech { closedSpeech += max(0, at - start) }
                openSpeech = nil
            }
        }

        /// Closed segments plus a segment still open when the microphone closed.
        var speechSeconds: TimeInterval {
            closedSpeech + (openSpeech.map { max(0, position - $0) } ?? 0)
        }
    }
}

// MARK: - Copy

/// Every sentence the test says. Failure headlines and actions are the S9 catalogue's (design §10);
/// the consequence lines are test-specific, because a test never types anything and has no words
/// to recover ("Test-specific recovery", design §9).
public enum VoiceTestCopy {
    public static let rowTitle = "Input quality"
    public static let rowDetail = "Test your voice before a long dictation."
    public static let test = "Test microphone"
    public static let stop = "Stop"
    public static let testAgain = "Test again"
    public static let sentenceEyebrow = "Test sentence"

    public static let idle = "Press Test microphone, then read the sentence aloud."
    public static let idleMeter = "The meter shows real levels only while a test has the microphone open."
    public static func capturing(device: String?) -> String {
        "Listening\(device.map { " on \($0)" } ?? "")… Read the sentence, then press Stop."
    }
    public static let analyzing = "Checking the recording. The microphone is closed."

    public static let clearHeadline = "Clear input"
    public static let clearGuidance = "Your microphone is ready for long dictation."
    public static let quietGuidance = "Your voice is very quiet. Move closer to the microphone, or raise its input level in System Settings › Sound."
    public static let clippingGuidance = "Your voice is clipping. Move back a little, or lower the input level in System Settings › Sound."
    public static let noiseGuidance = "The room is close to your voice. Try a quieter spot or a headset microphone."

    public static let noSamplesDetail = RecoveryCatalog.entry(.A05).consequence
    public static func tooShortDetail(speechSeconds: TimeInterval) -> String {
        String(format: "We heard %.1f s of speech. Read the whole sentence, then press Stop.", speechSeconds)
    }
    public static func deviceRemovedDetail(name: String?) -> String {
        "\(name ?? "The microphone") went away during the test. The test stopped and the microphone was released."
    }

    /// "Hold dictation remains if possible" (design §9): said only when it is true.
    public static let holdUnaffected = "Hold-to-talk doesn't depend on this test."
    public static let holdSwitches = "Hold-to-talk switches to the next available microphone."
}
