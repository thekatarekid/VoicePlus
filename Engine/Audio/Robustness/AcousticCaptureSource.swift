import Foundation
import Shared

/// Wraps any `AudioCaptureSource` and runs the sample-level acoustic chain (neural AEC slot →
/// noise suppression) on its output before the pipeline's ring buffer. Also implements the
/// Bluetooth pre-roll: on `prewarm()` the inner source is *started* into a private buffer so a
/// slow-opening transport (SCO) is already streaming when the user begins talking; `start()`
/// flushes the last `profile.prerollSeconds` of that buffer to the sink first.
///
/// Drop-in: `AudioPipeline(source: AcousticCaptureSource(wrapping: inner, profile: p), ...)`.
public final class AcousticCaptureSource: AudioCaptureSource, CaptureGraphDescribing, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    public var device: AudioDeviceInfo? { inner.device }
    public let inner: any AudioCaptureSource
    /// The wrapped source's own view of the graph it resolved to, when it has one. Forwarded so a
    /// caller (and the recorder's manifest) never has to guess which concrete source is inside.
    public var diagnostics: AudioCaptureDiagnostics {
        (inner as? any CaptureGraphDescribing)?.diagnostics ?? AudioCaptureDiagnostics()
    }
    /// What echo cancellation is **actually** running, as opposed to what the profile asks for.
    ///
    /// The graph is the authority: Apple voice processing lives in the capture unit
    /// (`VoiceProcessingCaptureSource`), so a profile that names it while a plain tap is wrapped is
    /// simply wrong — and that contradiction is exactly what the twenty real-room manifests
    /// recorded (`aec=appleVoiceProcessing` beside `vp=false`). Reported into the manifest, so a
    /// replay reads the truth. Falls back to the profile when the source cannot describe itself.
    public var effectiveAEC: RobustnessProfile.AECMode {
        guard let describing = inner as? any CaptureGraphDescribing else { return profile.aec }
        if describing.diagnostics.voiceProcessing { return .appleVoiceProcessing }
        // A neural slot only counts when a backend is actually plugged in and processing.
        if profile.aec == .neural, chain.stages.contains(where: { $0.isAvailable && $0.name.hasSuffix("-aec") }) {
            return .neural
        }
        return .off
    }
    public private(set) var profile: RobustnessProfile
    public let chain: AcousticChain
    /// Assessment of the current device (transport / SCO rate), computed at prewarm.
    public private(set) var bluetooth: BluetoothInputAssessment?
    /// Samples kept from the preroll and flushed at `start()` (for tests / Lab).
    public private(set) var prerollFlushed = 0
    /// Opt-in local capture of this utterance's audio, raw and processed. Allocated but disarmed
    /// unless the user has switched diagnostics on; see `UtteranceRecorder`. Injectable so tests
    /// need no `UserDefaults`.
    public var recorder: UtteranceRecorder?
    /// Whether the diagnostic is armed for the *next* utterance, re-read at every `start()` rather
    /// than decided once at construction.
    ///
    /// Until 1.7.15 the switch was read a single time, when the engine was built at launch. Turning
    /// the toggle **off** therefore did not stop anything: the recorder stayed installed and went on
    /// writing a WAV pair per dictation until the app was relaunched — while the Settings copy said
    /// "Turn it off when you're done". Turning it *on* was equally inert. The predicate is cheap
    /// (one `UserDefaults` read per utterance, off the audio thread), so it is read per utterance
    /// and the toggle means what it says.
    public var isRecordingEnabled: () -> Bool = { UtteranceRecorder.isEnabled() }

    private let lock = NSLock()
    private var preroll: [Float] = []
    private var prerolling = false
    private var live = false
    private let prerollCapacity: Int

    public init(wrapping inner: any AudioCaptureSource, profile: RobustnessProfile = .default,
                aec: (any AcousticStage)? = nil, recorder: UtteranceRecorder? = nil) {
        self.inner = inner
        self.profile = profile
        self.chain = AcousticChain(profile: profile, aec: aec)
        self.prerollCapacity = Int(profile.prerollSeconds * 16_000)
        // An explicitly injected recorder is the caller's own intent (tests, Lab) and records
        // unconditionally. Otherwise one is allocated unarmed — two empty buffers, no directory, no
        // file — and `start()` decides per utterance whether to arm it.
        self.recorder = recorder ?? UtteranceRecorder()
        if recorder != nil { self.isRecordingEnabled = { true } }
        inner.sink = { [weak self] buf in self?.ingest(buf) }
        inner.onDeviceChanged = { [weak self] old, new in
            guard let self else { return }
            self.bluetooth = BluetoothInputDetector.assess(new)
            self.chain.reset()
            // The pre-roll holds audio from the microphone that just went away. Flushing it into
            // the utterance that starts on the *new* device would splice one room onto another —
            // and after an unplug it is the old device's last, often clipped, buffers. Drop it: a
            // route change is a clean slate for everything the wrapper is holding.
            self.lock.lock(); self.preroll.removeAll(keepingCapacity: true); self.lock.unlock()
            self.onDeviceChanged?(old, new)
        }
    }

    /// Opens the device and, when the profile asks for pre-roll, begins capturing into the
    /// pre-roll buffer immediately (the "AirPods first word never clipped" guarantee).
    public func prewarm() throws {
        try inner.prewarm()
        bluetooth = BluetoothInputDetector.assess(inner.device)
        lock.lock(); let needStart = prerollCapacity > 0 && !prerolling && !live; if needStart { prerolling = true }; lock.unlock()
        guard needStart else { return }
        do {
            try inner.start()
        } catch {
            // The wedge this guard exists for. `prerolling` is set *before* the inner source is
            // started, and it used to stay set when that start threw — a device unplugged between
            // hotkey-down and hotkey-up is the ordinary way in. The next `start()` then saw
            // `wasPrerolling == true`, concluded the inner source was already streaming, and never
            // called `inner.start()`: capture announced itself, delivered zero blocks, and the
            // no-audio watchdog reported "no sound is reaching VoicePlus" for the rest of the
            // session. Unwinding the flag keeps a failed prewarm retryable.
            lock.lock(); prerolling = false; preroll.removeAll(keepingCapacity: true); lock.unlock()
            throw error
        }
    }

    public func start() throws {
        try prewarm()
        lock.lock()
        let wasPrerolling = prerolling
        prerolling = false
        live = true
        let held = preroll
        preroll.removeAll(keepingCapacity: true)
        lock.unlock()
        // Arm before the pre-roll is flushed, so the recording contains the same first words the
        // recognizer gets. A recording that starts a syllable late is worse than none. Disarmed
        // means `begin()` is never called, so `finish()` returns nil and nothing touches the disk.
        if isRecordingEnabled() {
            // Manifest and graph must agree: the profile supplies the gate settings, the graph
            // supplies the echo-cancellation fact. `(inner as? CoreAudioCaptureSource)` used to be
            // the only cast here, so a voice-processing run recorded no graph line at all.
            var recorded = profile
            recorded.aec = effectiveAEC
            let describing = inner as? any CaptureGraphDescribing
            recorder?.begin(device: inner.device, profile: recorded,
                            captureGraph: describing?.diagnostics.summary)
        }
        if !held.isEmpty {
            held.withUnsafeBufferPointer { recorder?.appendRaw($0) }
        }
        if !held.isEmpty {
            prerollFlushed += held.count
            deliver(chain.process(held))
        }
        if !wasPrerolling { try inner.start() }
    }

    public func stop() {
        inner.stop()
        // Everything the wrapper holds between utterances is cleared here, so a sleep/wake (which
        // arrives as stop-then-start) cannot leak the pre-sleep tail into the next dictation.
        lock.lock(); live = false; prerolling = false; preroll.removeAll(); prerollFlushed = 0; lock.unlock()
        let tail = chain.flush()
        if !tail.isEmpty { deliver(tail) }
        chain.reset()
        // Off the audio thread by construction: `stop()` is called by the pipeline, not the tap.
        do { try recorder?.finish() } catch { Log.engine.error("audio: could not save the utterance recording: \(error)") }
    }

    public func switchDevice(to device: AudioDeviceInfo?) throws { try inner.switchDevice(to: device) }

    // MARK: internals

    private func ingest(_ buf: UnsafeBufferPointer<Float>) {
        lock.lock()
        if prerolling && !live {
            preroll.append(contentsOf: buf)
            if preroll.count > prerollCapacity { preroll.removeFirst(preroll.count - prerollCapacity) }
            lock.unlock()
            return
        }
        lock.unlock()
        recorder?.appendRaw(buf)
        let out = chain.process(Array(buf))
        deliver(out)
    }

    private func deliver(_ samples: [Float]) {
        recorder?.appendProcessed(samples)
        guard !samples.isEmpty, let sink else { return }
        samples.withUnsafeBufferPointer { sink($0) }
    }
}
