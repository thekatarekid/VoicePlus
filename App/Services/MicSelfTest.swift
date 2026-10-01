import AVFoundation
import CoreAudio
import Engine
import Foundation
import Shared

/// Headless capture self-test: `VoicePlus --mic-selftest [seconds]` (default 5).
///
/// Same precedent as `--request-permission` / `--onboarding-selftest`: run the *real* thing from the
/// *real* signed bundle and read the answer out of the log, instead of inferring it from a unit test
/// that cannot touch the HAL. It builds the identical object graph `EngineFactory.make()` builds —
/// `AppCaptureGraph.makeStandalone` (`AcousticCaptureSource(wrapping: CoreAudioCaptureSource(), profile: .default)`) → `AudioPipeline`
/// → `PipelineAudioSource` — so a green run here is evidence about the shipping path, not a mock.
///
/// Every line goes to stdout *and* to `Log.app`, because `open -n -a VoicePlus.app --args
/// --mic-selftest` (the only launch that gets the bundle's TCC identity) throws stdout away:
///     log show --last 2m --predicate 'subsystem == "in.adityakatare.voiceplus"' --info --style compact
///
/// The one line that would have identified the 1.6.3 defect on sight is
/// `node.inputFormat=… node.outputFormat=…`: when those two disagree the tap never fires.
public enum MicSelfTest {
    public enum Outcome: Int32 {
        case ok = 0
        case permissionDenied = 2
        case noInputDevice = 3
        case startThrew = 4
        case formatMismatch = 5
        case startedButNoBlocks = 6
        case startedButSilent = 7
    }

    /// `--mic-selftest` or `--mic-selftest 8`. Returns the requested duration in seconds.
    public static func parseCLI(_ arguments: [String]) -> TimeInterval? {
        guard let i = arguments.firstIndex(of: "--mic-selftest") else { return nil }
        if i + 1 < arguments.count, let seconds = Double(arguments[i + 1]), seconds > 0 { return min(seconds, 120) }
        return 5
    }

    /// `--mic-selftest-uid <device uid>` forces a specific input instead of asking the policy. This
    /// is how the *pinned* path gets exercised: pinning only happens for a non-default device, and
    /// that path has its own format-sync step (`CoreAudioCaptureSource.syncClientFormat`).
    public static func parseDeviceUID(_ arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: "--mic-selftest-uid"), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// `--mic-selftest-vp` swaps `CoreAudioCaptureSource` for `VoiceProcessingCaptureSource`, so the
    /// Apple voice-processing path (its multi-channel tap and its plain-tap fallback) can be measured
    /// on real hardware. Not the shipping path — `EngineFactory` builds the plain source.
    public static func parseVoiceProcessing(_ arguments: [String]) -> Bool {
        arguments.contains("--mic-selftest-vp")
    }

    public static func run(seconds: TimeInterval, deviceUID: String? = nil, voiceProcessing: Bool = false) -> Int32 {
        emit("mic-selftest: \(PermissionDiagnostics.summary()) duration=\(Int(seconds))s")

        // 1. TCC.
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        emit("mic-selftest: AVCaptureDevice.authorizationStatus(.audio)=\(describe(auth))")
        guard auth == .authorized else {
            // Deliberately does *not* prompt: `--request-permission microphone` is the mode that
            // asks, and keeping this one read-only means it can be run repeatedly without changing
            // TCC state. `notDetermined` on a build the user has already allowed means the stored
            // row pins an older build's cdhash (tccd logs status -67050) — see Packaging/SIGNING.md.
            emit("mic-selftest: fix — run `\(PermissionDiagnostics.resetCommand(for: .microphone))`,"
                 + " then `open -n -a <VoicePlus.app> --args --request-permission microphone` and allow the prompt")
            return finish(.permissionDenied, "microphone permission is \(describe(auth)); nothing to measure")
        }

        // 2. Devices, and which one the shipping policy picks.
        let devices = AudioDeviceEnumerator.inputDevices()
        let systemDefault = AudioDeviceEnumerator.defaultInputDevice()
        guard !devices.isEmpty else { return finish(.noInputDevice, "CoreAudio reports no input devices") }
        for d in devices {
            let mark = d.uid == systemDefault?.uid ? " [system default]" : ""
            emit("mic-selftest: device id=\(d.id) name=\(d.name) uid=\(d.uid) transport=\(d.transport.rawValue) rate=\(Int(d.sampleRate)) channels=\(d.inputChannels)\(mark)")
        }
        let policy = InputSelectionPolicy()
        let forced = deviceUID.flatMap { uid in devices.first { $0.uid == uid } }
        if let uid = deviceUID, forced == nil {
            return finish(.noInputDevice, "no input device with uid \(uid)")
        }
        guard let chosen = forced ?? policy.choose(from: devices, systemDefault: systemDefault) else {
            return finish(.noInputDevice, "InputSelectionPolicy picked nothing from \(devices.count) devices")
        }
        let why = forced != nil ? "--mic-selftest-uid" : reason(for: chosen, policy: policy, systemDefault: systemDefault)
        emit("mic-selftest: chosen=\(chosen.name)#\(chosen.id) because=\(why)")

        // 3. The shipping object graph (EngineFactory.make()), or the voice-processing twin. V5 O1
        //    (§10): built by `AppCaptureGraph.makeStandalone` — the same factory the app's fallback
        //    graph uses — and read through a `Broadcaster` subscription, as every consumer is. This
        //    mode runs in its own process before any app graph exists, so it is the only HAL client.
        var options = AudioPipeline.Options()
        options.noAudioTimeout = 2.0
        let graph = AppCaptureGraph.makeStandalone(device: forced, policy: policy,
                                                   voiceProcessing: voiceProcessing, options: options)
        let core = graph.core
        let vp = graph.voiceProcessing
        let profile = RobustnessProfile.default
        let capture = graph.capture
        let pipeline = graph.pipeline
        let audio = graph.audio
        let stages = capture.chain.stages.map(\.name).joined(separator: ",")
        emit("mic-selftest: acoustic profile aec=\(profile.aec.rawValue) noiseSuppression=\(profile.noiseSuppression)"
             + " strength=\(profile.noiseSuppressionStrength) preroll=\(profile.prerollSeconds)s"
             + " stages=[\(stages.isEmpty ? "-" : stages)]")

        // 4. Watch the pipeline the way the mic-check meter does.
        let tally = Tally()
        let subscription = pipeline.subscribe()
        let events = subscription.events
        let reader = Task.detached(priority: .userInteractive) {
            for await event in events {
                switch event {
                case .started(let device):
                    emit("mic-selftest: .started device=\(device?.name ?? "nil")")
                case .level(let rms):
                    tally.level(rms)
                case .audio(let samples, _):
                    tally.audio(samples.count)
                case .captureFailed(let reason):
                    tally.fail(reason)
                    emit("mic-selftest: .captureFailed \(reason)")
                case .stopped(let total):
                    emit("mic-selftest: .stopped totalSamples=\(total)")
                    return
                default:
                    break
                }
            }
        }

        // 5. Start, and report what the graph resolved to. `start()` blocks on the HAL, so read the
        //    diagnostics after it returns — that is when the formats are final. The window is wider
        //    than production's 3 s on purpose: a slow-opening device (Continuity Camera mic) should
        //    be diagnosed here, not truncated into a generic timeout.
        audio.startTimeout = 15
        let began = Date()
        var startError: Error?
        do { try audio.start(for: .diagnostics) } catch { startError = error }
        let elapsed = Date().timeIntervalSince(began)
        emit("mic-selftest: capture graph — \(vp?.diagnostics.summary ?? core.diagnostics.summary)")
        emit("mic-selftest: start took \(String(format: "%.2f", elapsed))s (production budget: 3 s built-in, 5 s USB, 8 s Bluetooth/Continuity/virtual)"
             + " engine.isRunning=\(vp?.isRunning ?? core.isRunning)"
             + " startThrew=\(startError.map { String(describing: $0) } ?? "no")")
        if let vp {
            emit("mic-selftest: voiceProcessingActive=\(vp.voiceProcessingActive)"
                 + " fallbackTimeout=\(vp.fallbackTimeout)s didFallBackToPlainTap=\(vp.didFallBackToPlainTap)")
        }
        if let startError {
            reader.cancel()
            audio.stop(for: .diagnostics)
            switch startError as? AudioCaptureError {
            case .formatMismatch: return finish(.formatMismatch, "\(startError)")
            case .noInputDevice: return finish(.noInputDevice, "\(startError)")
            default: return finish(.startThrew, "\(startError)")
            }
        }

        // 6. One line per second while the microphone is live.
        let deadline = Date().addingTimeInterval(seconds)
        var tick = 0
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            let elapsed = seconds - deadline.timeIntervalSinceNow
            if Int(elapsed) > tick {
                tick = Int(elapsed)
                let s = tally.snapshot()
                emit("mic-selftest: t=\(tick)s levelEvents=\(s.levels) audioBlocks=\(s.blocks) samples16k=\(s.samples) peakRMS=\(fmt(s.peak))")
            }
        }

        audio.stop(for: .diagnostics)
        reader.cancel()

        // 7. Verdict.
        let s = tally.snapshot()
        let d = vp?.diagnostics ?? core.diagnostics
        let result = "RESULT blocks=\(s.blocks) levelEvents=\(s.levels) samples16k=\(s.samples)"
            + " meanRMS=\(fmt(s.mean)) peakRMS=\(fmt(s.peak)) device=\(d.deviceName)"
            + " tap=\(Int(d.tapRate))Hz/\(d.tapChannels)ch vp=\(vp?.voiceProcessingActive ?? false)"
            + " fellBackToPlainTap=\(vp?.didFallBackToPlainTap ?? false) stages=[\(stages.isEmpty ? "-" : stages)]"
        emit("mic-selftest: \(result)")
        if let failure = s.failure { return finish(.startedButNoBlocks, failure) }
        if s.blocks == 0 { return finish(.startedButNoBlocks, "capture started but not one audio block arrived") }
        if s.peak <= 0 { return finish(.startedButSilent, "\(s.blocks) blocks arrived but every sample was digital silence") }
        return finish(.ok, "audio is reaching the meter")
    }

    // MARK: helpers

    private static func finish(_ outcome: Outcome, _ note: String) -> Int32 {
        emit("mic-selftest: exit=\(outcome.rawValue) (\(outcome)) — \(note)")
        return outcome.rawValue
    }

    /// stdout for a terminal run, unified log for the `open -n -a` run that carries the bundle's
    /// TCC identity. `Log` marks every interpolation public, so nothing is redacted.
    private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
        Log.app.notice(line)
    }

    private static func fmt(_ value: Float) -> String { String(format: "%.6f", value) }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func reason(for device: AudioDeviceInfo, policy: InputSelectionPolicy, systemDefault: AudioDeviceInfo?) -> String {
        if policy.preferredUID == device.uid { return "preferredUID" }
        if policy.preference(for: device.uid) == true { return "per-device preference" }
        if device.uid == systemDefault?.uid { return "system default + transport rank (\(device.transport.rawValue))" }
        return "transport rank (\(device.transport.rawValue))"
    }

    /// Counters written from the pipeline's reader task, read from the main thread.
    private final class Tally: @unchecked Sendable {
        struct Snapshot { var levels = 0; var blocks = 0; var samples = 0; var peak: Float = 0; var mean: Float = 0; var failure: String? }
        private let lock = NSLock()
        private var levels = 0
        private var blocks = 0
        private var samples = 0
        private var peak: Float = 0
        private var sum: Float = 0
        private var failure: String?

        func level(_ rms: Float) {
            lock.lock(); defer { lock.unlock() }
            levels += 1
            sum += rms
            peak = max(peak, rms)
        }

        func audio(_ count: Int) {
            lock.lock(); defer { lock.unlock() }
            blocks += 1
            samples += count
        }

        func fail(_ reason: String) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil { failure = reason }
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            var s = Snapshot()
            s.levels = levels; s.blocks = blocks; s.samples = samples; s.peak = peak
            s.mean = levels > 0 ? sum / Float(levels) : 0
            s.failure = failure
            return s
        }
    }
}
