import Engine
import Foundation
import Shared

// S7c — the live capture behind a manual meeting: the composition root's own session and capture
// factories (`MeetingCoordinator.makeSession` / `makeCapture`: the engine's recognizer, microphone +
// system audio through `DualCapture`), driven with Pause and Resume, which the detector-driven path
// does not have. Pause really closes both legs; Resume opens a fresh capture and continues the meeting
// clock where it stopped, so transcript timestamps never restart at 00:00.
//
// System audio is optional (design §8.2): when the system leg refuses to open, or its watchdog gives
// up mid-meeting, capture continues from the microphone alone and the controller shows the
// missing-track notice. Hardware paths (process tap, SCStream, TCC) are untested here.

public final class MeetingSessionCaptureDriver: MeetingCaptureDriving, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// No session factory: capture is not wired in this build.
        case noSession
        /// No capture factory result: the mock engine, or no audio hardware.
        case noCapture
        case notRunning
    }

    private let makeSession: (MeetingPrompt) -> MeetingSession?
    private let makeCapture: () -> DualCapture?
    /// Builds a microphone-only capture around a microphone source. Injectable for tests.
    private let makeMicrophoneOnly: (any AudioCaptureSource) -> DualCapture
    private let files: MeetingFilesStore
    private let lock = NSLock()

    private var session: MeetingSession?
    private var capture: DualCapture?
    private var loop: Task<Void, Never>?
    /// The meeting clock at the start of the current stretch (seconds of audio captured before it).
    private var offset: TimeInterval = 0
    private var systemAudio = true
    private var onSystemAudioLost: (@Sendable () -> Void)?

    /// Time between drains of captured audio into the session.
    public var drainInterval: TimeInterval = 3
    /// The capture sample rate (`AudioCaptureSource` delivers 16 kHz mono).
    public var sampleRate: Double = 16_000

    /// The live driver over the composition root's meeting factories.
    public convenience init(coordinator: MeetingCoordinator) {
        self.init(makeSession: { [weak coordinator] prompt in coordinator?.makeSession?(prompt) },
                  makeCapture: { [weak coordinator] in coordinator?.makeCapture?() },
                  store: coordinator.store)
    }

    public init(makeSession: @escaping (MeetingPrompt) -> MeetingSession?,
                makeCapture: @escaping () -> DualCapture?,
                makeMicrophoneOnly: ((any AudioCaptureSource) -> DualCapture)? = nil,
                store: MeetingStore) {
        self.makeSession = makeSession
        self.makeCapture = makeCapture
        self.makeMicrophoneOnly = makeMicrophoneOnly ?? { microphone in
            let tee = MicrophoneOnlySource(microphone: microphone)
            return DualCapture(mic: tee, system: tee.reference, micVAD: EnergyVAD(), systemVAD: EnergyVAD())
        }
        self.files = MeetingFilesStore(store: store)
    }

    // MARK: MeetingCaptureDriving

    public func start(title: String,
                      onUtterance: @escaping @Sendable (MeetingUtterance) -> Void,
                      onSystemAudioLost: @escaping @Sendable () -> Void) async throws -> MeetingCaptureStart {
        let prompt = MeetingPrompt(id: "manual:\(UUID().uuidString)", title: title, reason: .camera, event: nil)
        guard let session = makeSession(prompt) else { throw Failure.noSession }
        guard let capture = makeCapture() else { throw Failure.noCapture }
        await session.setHandlers(onUtterance: onUtterance)
        let (running, withSystemAudio) = try await open(capture)
        let id = await session.record.id
        lock.withLock {
            self.session = session
            self.capture = running
            self.offset = 0
            self.systemAudio = withSystemAudio
            self.onSystemAudioLost = onSystemAudioLost
        }
        watchSystemAudio(of: running)
        startLoop(running)
        Log.app.info("meeting: manual recording started (system audio \(withSystemAudio ? "on" : "missing"))")
        return MeetingCaptureStart(meetingID: id, systemAudio: withSystemAudio)
    }

    public func pause() async {
        await closeStretch()
        Log.app.info("meeting: paused, capture closed")
    }

    public func resume() async throws {
        guard lock.withLock({ session != nil && capture == nil }) else { throw Failure.notRunning }
        let wantsSystemAudio = lock.withLock { systemAudio }
        let running: DualCapture
        if wantsSystemAudio, let fresh = makeCapture() {
            let (opened, withSystemAudio) = try await open(fresh)
            running = opened
            if !withSystemAudio { markSystemAudioLost() }
        } else if let fresh = makeCapture() {
            running = makeMicrophoneOnly(fresh.mic)
            try await running.start()
        } else {
            throw Failure.noCapture
        }
        lock.withLock { capture = running }
        watchSystemAudio(of: running)
        startLoop(running)
        Log.app.info("meeting: resumed")
    }

    public func stop(_ summary: MeetingCaptureSummary) async throws -> MeetingRecord {
        await closeStretch()
        guard let session = lock.withLock({ () -> MeetingSession? in
            let running = self.session
            self.session = nil
            return running
        }) else { throw Failure.notRunning }
        var facts = MeetingCaptureFacts(systemAudioCaptured: lock.withLock { systemAudio },
                                        pauseCount: summary.pauseCount, pausedSeconds: summary.pausedSeconds)
        let record: MeetingRecord
        do {
            record = try await session.finish(at: Date())
        } catch {
            // Notes failed: the transcript is still the user's. Close and save it without notes.
            Log.app.error("meeting: notes failed, keeping the transcript: \(error)")
            var kept = await session.record
            if kept.endedAt == nil { kept.endedAt = Date() }
            kept.notes = nil
            try files.store.save(kept)
            facts.notesFailure = "\(error)"
            record = kept
        }
        try? files.save(facts, for: record.id)
        return record
    }

    // MARK: Capture legs

    /// Opens both legs; when the system leg refuses (permission, no tap), retries microphone-only.
    private func open(_ capture: DualCapture) async throws -> (DualCapture, Bool) {
        do {
            try await capture.start()
            if let system = capture.system as? SystemAudioRecorder, system.stage == .failed {
                _ = try? await capture.stop()
                let fallback = makeMicrophoneOnly(capture.mic)
                try await fallback.start()
                return (fallback, false)
            }
            return (capture, true)
        } catch {
            Log.app.error("meeting: system audio unavailable, recording the microphone only: \(error)")
            capture.mic.stop()
            capture.system.stop()
            let fallback = makeMicrophoneOnly(capture.mic)
            try await fallback.start()
            return (fallback, false)
        }
    }

    /// A system leg whose watchdog gives up mid-meeting is swapped for microphone-only capture.
    private func watchSystemAudio(of capture: DualCapture) {
        guard let system = capture.system as? SystemAudioRecorder else { return }
        system.onStageChanged = { [weak self] stage in
            guard stage == .failed else { return }
            Task { await self?.switchToMicrophoneOnly(from: capture) }
        }
    }

    private func switchToMicrophoneOnly(from failed: DualCapture) async {
        guard lock.withLock({ capture === failed }) else { return }
        await closeStretch()
        let fallback = makeMicrophoneOnly(failed.mic)
        do {
            try await fallback.start()
            lock.withLock { capture = fallback }
            startLoop(fallback)
        } catch {
            Log.app.error("meeting: microphone-only restart failed: \(error)")
        }
        markSystemAudioLost()
    }

    private func markSystemAudioLost() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard systemAudio else { return nil }
            systemAudio = false
            return onSystemAudioLost
        }
        notify?()
    }

    private func startLoop(_ capture: DualCapture) {
        let interval = UInt64(max(0.05, drainInterval) * 1_000_000_000)
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                guard let chunks = try? await capture.drain() else { continue }
                await self.ingest(chunks)
            }
        }
        lock.withLock { loop = task }
    }

    /// Stops the drain loop, closes both legs, transcribes what was left and advances the clock.
    private func closeStretch() async {
        let (task, running) = lock.withLock { () -> (Task<Void, Never>?, DualCapture?) in
            let pair = (loop, capture)
            loop = nil
            capture = nil
            return pair
        }
        task?.cancel()
        await task?.value
        guard let running else { return }
        if let system = running.system as? SystemAudioRecorder { system.onStageChanged = nil }
        let rest = (try? await running.stop()) ?? []
        await ingest(rest)
        let captured = Double(running.delivered[.mic] ?? 0) / sampleRate
        lock.withLock { offset += captured }
    }

    private func ingest(_ chunks: [MeetingChunk]) async {
        guard !chunks.isEmpty else { return }
        let (session, offset) = lock.withLock { (self.session, self.offset) }
        guard let session else { return }
        do {
            try await session.ingest(Self.shift(chunks, by: offset))
        } catch {
            Log.app.error("meeting ingest failed: \(error)")
        }
    }

    /// Chunks of a later stretch start at 0; place them on the meeting clock.
    static func shift(_ chunks: [MeetingChunk], by offset: TimeInterval) -> [MeetingChunk] {
        guard offset > 0 else { return chunks }
        return chunks.map { chunk in
            let range = (chunk.range.lowerBound + offset)...(chunk.range.upperBound + offset)
            return MeetingChunk(channel: chunk.channel,
                                chunk: AudioChunk(samples: chunk.chunk.samples, range: range, reason: chunk.chunk.reason))
        }
    }
}

// MARK: - Microphone-only capture

/// The microphone leg of a microphone-only meeting. `DualCapture` aligns the microphone with a
/// system-audio reference before it drains; this source feeds an equal run of silence to `reference`
/// for every microphone buffer, so the microphone drains on time and echo cancellation passes it
/// through unchanged.
final class MicrophoneOnlySource: AudioCaptureSource, @unchecked Sendable {
    let microphone: any AudioCaptureSource
    let reference = SilentReferenceSource()
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?

    init(microphone: any AudioCaptureSource) { self.microphone = microphone }

    var device: AudioDeviceInfo? { microphone.device }
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)? {
        get { microphone.onDeviceChanged }
        set { microphone.onDeviceChanged = newValue }
    }

    func prewarm() throws { try microphone.prewarm() }

    func start() throws {
        let reference = self.reference
        microphone.sink = { [weak self] buffer in
            self?.sink?(buffer)
            reference.emitSilence(count: buffer.count)
        }
        try microphone.start()
    }

    func stop() { microphone.stop() }
    func switchDevice(to device: AudioDeviceInfo?) throws { try microphone.switchDevice(to: device) }
    func release(reason: CaptureReleaseReason) { microphone.release(reason: reason) }
}

/// The silent "system audio" of a microphone-only meeting.
final class SilentReferenceSource: AudioCaptureSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    var device: AudioDeviceInfo? { nil }

    func prewarm() throws {}
    func start() throws {}
    func stop() {}
    func switchDevice(to device: AudioDeviceInfo?) throws {}

    func emitSilence(count: Int) {
        guard count > 0 else { return }
        let zeros = [Float](repeating: 0, count: count)
        zeros.withUnsafeBufferPointer { sink?($0) }
    }
}
