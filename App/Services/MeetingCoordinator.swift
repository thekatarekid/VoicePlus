import AppKit
import Engine
import Foundation
import Shared
import UserNotifications

/// Calendar access as the coordinator needs it, split into a *status* query that can never prompt
/// and the one call that can. Injectable so a test can prove that a launch with meeting capture
/// off issues no authorization request at all.
public protocol MeetingCalendarAuthorizing: AnyObject {
    /// Pure status read. Must never show a dialog.
    var isAuthorized: Bool { get }
    /// May show the Calendar dialog. Only ever reachable from the user's opt-in.
    func requestAccess() async -> Bool
    /// Empty unless already authorized; must never prompt.
    func meetings(around now: Date) -> [CalendarMeeting]
}

extension EventKitCalendarSignal: MeetingCalendarAuthorizing {}

/// Notification authorization, injectable for the same reason.
public protocol MeetingNotificationAuthorizing: AnyObject {
    /// May show the notification dialog. Only called once the user has opted in *and* a meeting
    /// they accepted has actually produced notes to deliver.
    func requestAuthorization() async -> Bool
}

public final class SystemMeetingNotificationAuthorizer: MeetingNotificationAuthorizing {
    public init() {}
    public func requestAuthorization() async -> Bool { await MeetingNotifier.requestAuthorization() }
}

/// P5.5 integration — drives the pure `MeetingDetector` state machine with live signals
/// (camera-in-use, EventKit calendar, ticks), renders its effects (notch prompt with
/// Join&Record / Record / Ignore), runs a `MeetingSession` while recording, and hands the
/// finished record (diarized transcript + local notes) to the notification glue.
///
/// **Meeting capture is opt-in.** Until the user turns it on, `startMonitoring()` is inert: no
/// camera monitor, no tick timer, and — the point — no Calendar, Reminders or Notification
/// authorization request. Before this gate existed, every launch called `calendar.requestAccess()`
/// unconditionally from `AppDelegate`, so a user who had never heard of meeting capture got
/// Calendar and Reminders dialogs out of nowhere on first run. When the feature *is* on, launch
/// still only ever reads *status*; the request happens at the moment of opting in.
public final class MeetingCoordinator: UtteranceTagRecording, @unchecked Sendable {
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
    private let calendar: any MeetingCalendarAuthorizing
    private let notifications: any MeetingNotificationAuthorizing
    private let settings: (any SettingsStore)?
    private var tickTimer: Timer?
    private let lock = NSLock()

    public init(store: MeetingStore = MeetingStore(),
                detector: MeetingDetector = MeetingDetector(),
                calendar: any MeetingCalendarAuthorizing = EventKitCalendarSignal(),
                notifications: any MeetingNotificationAuthorizing = SystemMeetingNotificationAuthorizer(),
                settings: (any SettingsStore)? = nil) {
        self.store = store
        self.detector = detector
        self.calendar = calendar
        self.notifications = notifications
        self.settings = settings
    }

    /// The opt-in. Absent a settings store (tests, headless runs) meeting capture is off.
    public var isMeetingCaptureEnabled: Bool {
        settings?.bool(SettingsKeys.meetingCaptureEnabled) ?? false
    }

    /// Turning meeting capture on is the *only* path to a Calendar dialog. Turning it off stops
    /// every live signal again; it cannot un-grant TCC, but it does stop us using it.
    @discardableResult
    public func setMeetingCaptureEnabled(_ enabled: Bool) async -> Bool {
        settings?.set(enabled, for: SettingsKeys.meetingCaptureEnabled)
        guard enabled else {
            stopMonitoring()
            Log.app.info("meeting capture: disabled by the user")
            return false
        }
        let granted = calendar.isAuthorized ? true : await calendar.requestAccess()
        Log.app.info("meeting capture: enabled by the user, calendar granted=\(granted)")
        startMonitoring()
        return granted
    }

    /// Live signals: camera monitor + calendar poll + 30 s ticks. Inert unless the user opted in,
    /// and even then it only ever *reads* calendar authorization — never requests it.
    public func startMonitoring() {
        guard isMeetingCaptureEnabled else {
            Log.app.info("meeting capture: off (opt-in), monitoring not started — no permission requested")
            return
        }
        guard tickTimer == nil else { return }
        camera.onChange = { [weak self] inUse in self?.apply(inUse ? .cameraStarted : .cameraStopped) }
        camera.start()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Status-only: an unauthorized calendar contributes an empty list, and the detector
            // falls back to the camera signal. Nothing here can raise a dialog.
            self.apply(.calendar(self.calendar.isAuthorized ? self.calendar.meetings(around: self.clock()) : []))
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

    /// V5 O2 — the meeting is a recorder: a capability's claim on an utterance (dictation during the
    /// meeting, a note, a command) labels the span the meeting already transcribed. No session → no-op.
    public func record(_ tag: UtteranceTag) {
        guard let running = currentSession() else { return }
        Task { await running.tag(tag) }
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
            // "The first time they accept a meeting prompt" — a recording the user chose has now
            // produced notes, so asking to deliver them is the user's own action. Never at launch.
            if isMeetingCaptureEnabled { _ = await notifications.requestAuthorization() }
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
///
/// Authorization is a *separate* call from delivery on purpose: `post` used to request it inline,
/// which made the dialog a side effect of anything that reached this code. Only
/// `MeetingCoordinator.finishSession()` — after the user opted in and accepted a meeting prompt —
/// calls `requestAuthorization()`.
public enum MeetingNotifier {
    public static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public static func requestAuthorization() async -> Bool {
        guard canNotify else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    /// Delivers only. If authorization was never granted the notification simply does not appear —
    /// this call never prompts.
    public static func post(_ record: MeetingRecord) {
        let summary = record.notes?.summary.first ?? "Notes are ready."
        guard canNotify else {
            Log.app.info("meeting notes ready (no bundle, notification skipped): \(record.title) — \(summary)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Meeting notes: \(record.title)"
        content.body = summary
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "meeting-\(record.id)", content: content, trigger: nil))
    }
}
