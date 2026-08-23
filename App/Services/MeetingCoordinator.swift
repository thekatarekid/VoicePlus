import AppKit
import Engine
import Foundation
import Shared
import UserNotifications

/// P5.5 integration — drives the pure `MeetingDetector` state machine with live signals
/// (camera-in-use, EventKit calendar, ticks), renders its effects (notch prompt with
/// Join&Record / Record / Ignore), runs a `MeetingSession` while recording, and hands the
/// finished record (diarized transcript + local notes) to the notification glue.
public final class MeetingCoordinator: @unchecked Sendable {
    public private(set) var detector: MeetingDetector
    public let store: MeetingStore
    /// Builds the running session for a prompt. Injectable so acceptance tests use mocks; the
    /// live factory wires DualCapture + the engine transcriber.
    public var makeSession: ((MeetingPrompt) -> MeetingSession?)?
    /// Prompt UI: non-nil = show, nil = dismiss.
    public var onPrompt: ((MeetingPrompt?) -> Void)?
    /// Recording started/stopped (status glyph, pill).
    public var onRecordingChanged: ((Bool) -> Void)?
    /// Notes arrived after the call (notification).
    public var onNotes: ((MeetingRecord) -> Void)?
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    public var clock: () -> Date = Date.init

    /// Live capture factory (mic + system audio DualCapture); nil in tests / headless runs.
    public var makeCapture: (() -> DualCapture?)?
    public private(set) var session: MeetingSession?
    private var captureTask: Task<Void, Never>?
    private let camera = CameraInUseMonitor()
    private let calendar = EventKitCalendarSignal()
    private var tickTimer: Timer?
    private let lock = NSLock()

    public init(store: MeetingStore = MeetingStore(), detector: MeetingDetector = MeetingDetector()) {
        self.store = store
        self.detector = detector
    }

    /// Live signals: camera monitor + calendar poll + 30 s ticks. Safe to skip in tests.
    public func startMonitoring() {
        camera.onChange = { [weak self] inUse in self?.apply(inUse ? .cameraStarted : .cameraStopped) }
        camera.start()
        Task { _ = await calendar.requestAccess() }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(.calendar(self.calendar.meetings()))
            self.apply(.tick)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    public func stopMonitoring() {
        camera.stop()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// One signal through the state machine; effects render immediately.
    public func apply(_ signal: MeetingSignal) {
        let effects: [MeetingEffect]
        lock.lock()
        effects = detector.apply(signal, at: clock())
        lock.unlock()
        for effect in effects { perform(effect) }
    }

    /// The prompt panel's buttons come back through here.
    public func choose(_ choice: MeetingPrompt.Choice) { apply(.userChose(choice)) }

    private func perform(_ effect: MeetingEffect) {
        switch effect {
        case .showPrompt(let prompt): onPrompt?(prompt)
        case .dismissPrompt: onPrompt?(nil)
        case .startRecording(let prompt, let join):
            if let join { openURL(join) }
            lock.lock()
            session = makeSession?(prompt)
            lock.unlock()
            startCaptureLoop()
            onRecordingChanged?(true)
            Log.app.info("meeting: recording '\(prompt.title)'")
        case .stopRecording:
            onRecordingChanged?(false)
            captureTask?.cancel()
            captureTask = nil
            Task { await self.finishSession() }
        }
    }

    /// Live drain loop: mic+system chunks every ~3 s into the session until recording stops.
    private func startCaptureLoop() {
        guard let capture = makeCapture?() else { return }
        captureTask = Task { [weak self] in
            do {
                try await capture.start()
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let chunks = try await capture.drain()
                    await self?.ingest(chunks)
                }
            } catch is CancellationError {
            } catch {
                Log.app.error("meeting capture failed: \(error)")
            }
            if let rest = try? await capture.stop() { await self?.ingest(rest) }
        }
    }

    /// Feed captured chunks into the running session (the live runner calls this on a drain loop).
    public func ingest(_ chunks: [MeetingChunk]) async {
        guard let running = currentSession() else { return }
        do { try await running.ingest(chunks) } catch { Log.app.error("meeting ingest failed: \(error)") }
    }

    private func currentSession(clearing: Bool = false) -> MeetingSession? {
        lock.lock(); defer { lock.unlock() }
        let running = session
        if clearing { session = nil }
        return running
    }

    @discardableResult
    public func finishSession() async -> MeetingRecord? {
        guard let running = currentSession(clearing: true) else { return nil }
        do {
            let record = try await running.finish(at: clock())
            onNotes?(record)
            return record
        } catch {
            Log.app.error("meeting finish failed: \(error)")
            return nil
        }
    }
}

/// Mock-engine fallback: capture still produces a diarized timeline, just without words.
public struct SilentMeetingTranscriber: MeetingTranscriber {
    public init() {}
    public func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] { [] }
}

/// `MeetingTranscriber` over the engine's final recognizer (local, same models as dictation).
public final class ProviderMeetingTranscriber: MeetingTranscriber, @unchecked Sendable {
    private let resolve: @Sendable () async throws -> any FinalRecognizer
    public init(resolve: @escaping @Sendable () async throws -> any FinalRecognizer) {
        self.resolve = resolve
    }
    public func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] {
        try await resolve().recognize(chunk.samples)
    }
}

/// Post-call notification ("notes arrive as notification"). UNUserNotificationCenter traps
/// outside a real .app bundle, so `swift run` / tests fall back to the log.
public enum MeetingNotifier {
    public static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public static func post(_ record: MeetingRecord) {
        let summary = record.notes?.summary.first ?? "Notes are ready."
        guard canNotify else {
            Log.app.info("meeting notes ready (no bundle, notification skipped): \(record.title) — \(summary)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Meeting notes: \(record.title)"
            content.body = summary
            center.add(UNNotificationRequest(identifier: "meeting-\(record.id)", content: content, trigger: nil))
        }
    }
}
