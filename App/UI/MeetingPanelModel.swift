import Combine
import Engine
import Foundation
import Shared

// S7c — meeting capture as one state (design §8.2, §8.9; states Q0 / Q1 / Q2). The expanded panel and
// the pill both render `MeetingCaptureState`: the pill through `pillInfo(at:)` (S2's `MeetingPillInfo`),
// the panel through `MeetingPanelContent`, whose status and detail lines *are* the pill's. Pausing in
// either place closes the same capture; nothing here can show "recording" while the microphone is shut.

/// Why capture needs the user. Each renders as a recovery-catalogue notice (X01 · Meetings), scoped to
/// the panel; none of them blocks manual recording that can still work.
public enum MeetingCaptureProblem: Equatable, Sendable {
    /// System audio was refused or lost: recording continues from the microphone alone.
    case systemAudioMissing
    /// Capture could not be opened at all; nothing was recorded.
    case couldNotStart
    /// Nothing in this build can record a meeting (no capture wired, or the mock engine).
    case unavailable
    /// Resuming after a pause failed; the meeting stays paused and what was captured is kept.
    case couldNotResume
    /// Stopping failed; the transcript saved so far stays on disk and the library offers recovery.
    case couldNotFinish

    /// The consequence line: names what is missing and what still works (X01's rule).
    public var consequence: String {
        switch self {
        case .systemAudioMissing:
            return "System audio permission is missing — recording from your microphone only."
        case .couldNotStart:
            return "The microphone couldn't be opened, so nothing was recorded. Check microphone access, then start again."
        case .unavailable:
            return "Meeting recording needs a speech model and microphone capture on this Mac. Nothing was recorded."
        case .couldNotResume:
            return "Capture couldn't restart. The meeting stays paused and everything so far is kept."
        case .couldNotFinish:
            return "The meeting couldn't be closed. Its transcript so far is saved; recover it from Meetings."
        }
    }

    /// The notice: X01's headline and action, this problem's consequence.
    public var banner: SectionBanner {
        let entry = RecoveryCatalog.entry(.X01)
        return SectionBanner(headline: entry.headline, actionTitle: entry.action, body: consequence, recoveryID: entry.id)
    }
}

/// One capture, from Start to notes. Pure value; `MeetingCaptureController` owns the live one.
public struct MeetingCaptureState: Equatable, Sendable {
    public enum Phase: String, CaseIterable, Equatable, Sendable {
        case idle, starting, recording, paused, preparingNotes
    }

    public var phase: Phase = .idle
    public var title = ""
    public var meetingID: String?
    /// When capture opened; `nil` until it has.
    public var startedAt: Date?
    /// Capture time banked by earlier recording stretches (before the last pause).
    public var accumulated: TimeInterval = 0
    /// When the current recording stretch began; `nil` unless recording.
    public var stretchStartedAt: Date?
    /// When the current pause began; `nil` unless paused.
    public var pausedAt: Date?
    public var pausedSeconds: TimeInterval = 0
    public var pauseCount = 0
    /// False once system audio was refused or lost (microphone-only capture).
    public var systemAudio = true
    /// The words captured so far, merged like `MeetingSession` merges them.
    public var utterances: [MeetingUtterance] = []
    public var problem: MeetingCaptureProblem?

    public init() {}

    /// Capture time, pauses excluded — the timer both the pill and the panel show.
    public func elapsed(at now: Date) -> TimeInterval {
        accumulated + (stretchStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Recording, paused or preparing notes: a meeting is on screen.
    public var isActive: Bool { phase == .recording || phase == .paused || phase == .preparingNotes }

    /// True while the microphone (and system audio, when available) is open.
    public var isCapturing: Bool { phase == .recording }

    /// Q0 / Q1 / Q2 for S2's pill; `nil` when no meeting is on screen.
    public func pillInfo(at now: Date) -> MeetingPillInfo? {
        let phase: MeetingPillInfo.Phase
        switch self.phase {
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .preparingNotes: phase = .preparingNotes
        case .idle, .starting: return nil
        }
        return MeetingPillInfo(phase: phase, elapsed: elapsed(at: now), capturesSystemAudio: systemAudio)
    }

    public var transcript: MeetingTranscript { MeetingTranscript(utterances: utterances) }

    /// The meeting being captured, as the library lists it before (and while) its words reach disk:
    /// title, start and the words so far, never an end. `nil` when no meeting is on screen.
    public var liveRecord: MeetingRecord? {
        guard isActive, let meetingID else { return nil }
        return MeetingRecord(id: meetingID, title: title, startedAt: startedAt ?? Date(), transcript: transcript)
    }

    /// Adds one utterance, merging it into the previous one when the same speaker continues within a
    /// second (the rule `MeetingSession.append` stores).
    public mutating func append(_ utterance: MeetingUtterance) {
        if var last = utterances.last, last.speaker == utterance.speaker,
           utterance.range.lowerBound - last.range.upperBound < 1 {
            last.text += " " + utterance.text
            last.range = last.range.lowerBound...max(last.range.upperBound, utterance.range.upperBound)
            last.confidence = min(last.confidence, utterance.confidence)
            utterances[utterances.count - 1] = last
        } else {
            utterances.append(utterance)
        }
    }
}

// MARK: - The panel's rendering

/// One explicit track indicator (design §8.2: "explicit mic/system-audio track indicators").
public struct MeetingTrackIndicator: Equatable, Identifiable, Sendable {
    public enum Track: String, Sendable { case microphone, systemAudio }
    public enum Condition: String, Equatable, Sendable {
        case recording, paused, stopped, missing

        public var word: String {
            switch self {
            case .recording: return "Recording"
            case .paused: return "Paused"
            case .stopped: return "Stopped"
            case .missing: return "Not recording"
            }
        }
    }

    public var track: Track
    public var condition: Condition

    public var id: String { track.rawValue }
    public var name: String { track == .microphone ? "Microphone" : "System audio" }
    /// Glyph and word together, so the state is never colour alone.
    public var systemImage: String {
        switch (track, condition) {
        case (.microphone, .missing): return "mic.slash"
        case (.microphone, _): return condition == .recording ? "mic.fill" : "mic"
        case (.systemAudio, .missing): return "speaker.slash"
        case (.systemAudio, _): return condition == .recording ? "speaker.wave.2.fill" : "speaker"
        }
    }
    /// "Microphone: Recording".
    public var accessibilityLabel: String { "\(name): \(condition.word)" }
}

/// The panel's controls. Pause and Stop while recording, Resume and Stop while paused (the pill's own
/// Q0 / Q1 buttons), none while notes are prepared.
public enum MeetingPanelButton: String, CaseIterable, Equatable, Sendable {
    case pause, resume, stop

    public var title: String {
        switch self {
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Stop"
        }
    }

    public var isPrimary: Bool { self == .resume }
}

/// What the expanded panel shows, derived from the same state the pill shows.
struct MeetingPanelContent: Equatable, Sendable {
    /// The pill's phase for this state; `nil` when no meeting is on screen.
    var pillPhase: MeetingPillInfo.Phase?
    /// The pill's status line ("Meeting · recording", "Meeting paused", "Preparing meeting notes").
    var status: String
    /// The pill's detail line ("Microphone only · 12:04").
    var detail: String
    /// The timer, "12:04".
    var timer: String
    var tracks: [MeetingTrackIndicator]
    /// The missing-track notice or another capture problem.
    var notice: SectionBanner?
    var buttons: [MeetingPanelButton]
    /// Spool in the header: a static compact cassette in the capture pose (S12 policy with the
    /// transcript open for reading, so it never plays beside long-form text).
    var spool: SpoolSurfacePolicy.Appearance

    static let idleStatus = "No meeting is recording"

    init(state: MeetingCaptureState, now: Date) {
        let info = state.pillInfo(at: now)
        pillPhase = info?.phase
        status = info?.headline ?? Self.idleStatus
        detail = info?.detail ?? ""
        timer = PillTimer.text(elapsed: state.elapsed(at: now))
        let mic: MeetingTrackIndicator.Condition
        switch state.phase {
        case .recording, .starting: mic = .recording
        case .paused: mic = .paused
        case .preparingNotes, .idle: mic = .stopped
        }
        let system: MeetingTrackIndicator.Condition = state.systemAudio ? mic : .missing
        tracks = [MeetingTrackIndicator(track: .microphone, condition: mic),
                  MeetingTrackIndicator(track: .systemAudio, condition: system)]
        notice = state.problem.map(\.banner)
            ?? (!state.systemAudio && state.isActive ? MeetingCaptureProblem.systemAudioMissing.banner : nil)
        switch state.phase {
        case .recording: buttons = [.pause, .stop]
        case .paused: buttons = [.resume, .stop]
        case .idle, .starting, .preparingNotes: buttons = []
        }
        let activity: SpoolSurfacePolicy.Activity
        switch state.phase {
        case .recording: activity = .capturing
        case .paused: activity = .paused
        case .preparingNotes: activity = .analyzing
        case .idle, .starting: activity = .idle
        }
        spool = SpoolSurfacePolicy.appearance(on: .meetingCapture, activity: activity, readingLongForm: true)
            ?? SpoolSurfacePolicy.Appearance(key: .ready, animates: false)
    }
}

// MARK: - Driving real capture

/// What opening capture produced.
public struct MeetingCaptureStart: Equatable, Sendable {
    public var meetingID: String
    /// False when system audio was refused and capture is microphone-only.
    public var systemAudio: Bool

    public init(meetingID: String, systemAudio: Bool) {
        self.meetingID = meetingID
        self.systemAudio = systemAudio
    }
}

/// How the meeting was paused, handed to the driver when it closes the meeting.
public struct MeetingCaptureSummary: Equatable, Sendable {
    public var pauseCount: Int
    public var pausedSeconds: TimeInterval

    public init(pauseCount: Int, pausedSeconds: TimeInterval) {
        self.pauseCount = pauseCount
        self.pausedSeconds = pausedSeconds
    }
}

/// The capture behind a manual meeting. `MeetingSessionCaptureDriver` is the live one (mic + system
/// audio into a `MeetingSession`); tests use a scripted one.
public protocol MeetingCaptureDriving: AnyObject, Sendable {
    /// Opens capture for a new meeting. `onUtterance` receives each transcribed utterance;
    /// `onSystemAudioLost` fires if system audio drops out mid-meeting (capture continues mic-only).
    func start(title: String,
               onUtterance: @escaping @Sendable (MeetingUtterance) -> Void,
               onSystemAudioLost: @escaping @Sendable () -> Void) async throws -> MeetingCaptureStart
    /// Closes the microphone and system audio; what was captured is transcribed and kept.
    func pause() async
    /// Reopens capture after a pause.
    func resume() async throws
    /// Closes capture and the meeting: notes are prepared and the record is saved. A notes failure
    /// still saves the transcript.
    func stop(_ summary: MeetingCaptureSummary) async throws -> MeetingRecord
}

/// The one live meeting capture: what the Meetings page's "Start recording", the expanded panel and the
/// pill's Q0 / Q1 / Q2 rows all act on and all show.
@MainActor
public final class MeetingCaptureController: ObservableObject {
    /// The app's capture. The composition root installs its driver and pill mirror
    /// (`MeetingCaptureWiring.install`); every window surface reads this one.
    public static let shared = MeetingCaptureController()

    @Published public private(set) var state = MeetingCaptureState()
    /// The last meeting this controller closed, so the library can open it.
    @Published public private(set) var lastFinished: MeetingRecord?

    /// Nil until the composition root wires capture: Start then explains instead of pretending.
    public var driver: (any MeetingCaptureDriving)? {
        didSet { objectWillChange.send() }
    }

    /// Receives Q0 / Q1 / Q2 for the pill on every change, and once a second while a meeting is on
    /// screen so the pill's timer advances. `nil` means "no meeting row".
    public var onPillInfo: ((MeetingPillInfo?) -> Void)?

    public var now: () -> Date = Date.init
    /// Seconds between timer pushes to the pill; 0 turns the ticker off (tests).
    public var tickInterval: TimeInterval = 1

    private var ticker: Task<Void, Never>?

    public init(driver: (any MeetingCaptureDriving)? = nil) {
        self.driver = driver
    }

    /// True when Start can open real capture.
    public var isAvailable: Bool { driver != nil }

    /// "Meeting at 14:05" — a manual meeting has no calendar title.
    public func defaultTitle() -> String {
        "Meeting at \(now().formatted(date: .omitted, time: .shortened))"
    }

    /// Opens capture for a manual meeting. Never waits on Calendar (design §8.2: no calendar never
    /// blocks manual recording). Returns false when nothing could be recorded.
    @discardableResult
    public func start(title: String? = nil) async -> Bool {
        guard state.phase == .idle else { return false }
        guard let driver else {
            state.problem = .unavailable
            publish()
            return false
        }
        var next = MeetingCaptureState()
        next.title = title ?? defaultTitle()
        next.phase = .starting
        state = next
        publish()
        do {
            let started = try await driver.start(
                title: next.title,
                onUtterance: { [weak self] utterance in
                    Task { @MainActor in self?.receive(utterance) }
                },
                onSystemAudioLost: { [weak self] in
                    Task { @MainActor in self?.systemAudioLost() }
                })
            let opened = now()
            state.meetingID = started.meetingID
            state.systemAudio = started.systemAudio
            state.phase = .recording
            state.startedAt = opened
            state.stretchStartedAt = opened
            state.problem = started.systemAudio ? nil : .systemAudioMissing
            publish()
            startTicker()
            return true
        } catch {
            Log.app.error("meeting capture: start failed: \(error)")
            var failed = MeetingCaptureState()
            failed.problem = .couldNotStart
            state = failed
            publish()
            return false
        }
    }

    /// Q1: closes capture (the microphone indicator goes off) and parks the timer.
    public func pause() async {
        guard state.phase == .recording, let driver else { return }
        let at = now()
        state.accumulated = state.elapsed(at: at)
        state.stretchStartedAt = nil
        state.pausedAt = at
        state.pauseCount += 1
        state.phase = .paused
        publish()
        await driver.pause()
    }

    /// Back to Q0. On failure the meeting stays paused and says so.
    public func resume() async {
        guard state.phase == .paused, let driver else { return }
        do {
            try await driver.resume()
            let at = now()
            if let pausedAt = state.pausedAt { state.pausedSeconds += max(0, at.timeIntervalSince(pausedAt)) }
            state.pausedAt = nil
            state.stretchStartedAt = at
            state.phase = .recording
            if state.problem == .couldNotResume { state.problem = state.systemAudio ? nil : .systemAudioMissing }
        } catch {
            Log.app.error("meeting capture: resume failed: \(error)")
            state.problem = .couldNotResume
        }
        publish()
    }

    /// Q2, then back to idle with the saved record. Returns nil when the meeting could not be closed
    /// (its transcript so far stays on disk for recovery).
    @discardableResult
    public func stop() async -> MeetingRecord? {
        guard state.phase == .recording || state.phase == .paused, let driver else { return nil }
        let at = now()
        if let pausedAt = state.pausedAt { state.pausedSeconds += max(0, at.timeIntervalSince(pausedAt)) }
        state.accumulated = state.elapsed(at: at)
        state.stretchStartedAt = nil
        state.pausedAt = nil
        state.phase = .preparingNotes
        publish()
        let summary = MeetingCaptureSummary(pauseCount: state.pauseCount, pausedSeconds: state.pausedSeconds)
        do {
            let record = try await driver.stop(summary)
            lastFinished = record
            state = MeetingCaptureState()
            stopTicker()
            publish()
            return record
        } catch {
            Log.app.error("meeting capture: stop failed: \(error)")
            var failed = MeetingCaptureState()
            failed.problem = .couldNotFinish
            state = failed
            stopTicker()
            publish()
            return nil
        }
    }

    /// Clears a problem the user has read (the notice's own dismissal; never timed). The missing-track
    /// notice stays for as long as the meeting runs without system audio.
    public func dismissProblem() {
        let keep: MeetingCaptureProblem? = (state.isActive && !state.systemAudio) ? .systemAudioMissing : nil
        guard state.problem != keep else { return }
        state.problem = keep
        publish()
    }

    /// What the pill should show now.
    public var pillInfo: MeetingPillInfo? { state.pillInfo(at: now()) }

    // MARK: Internals

    private func receive(_ utterance: MeetingUtterance) {
        guard state.phase == .recording || state.phase == .paused || state.phase == .preparingNotes else { return }
        state.append(utterance)
    }

    private func systemAudioLost() {
        guard state.isActive, state.systemAudio else { return }
        state.systemAudio = false
        state.problem = .systemAudioMissing
        publish()
    }

    private func publish() {
        onPillInfo?(state.pillInfo(at: now()))
    }

    private func startTicker() {
        stopTicker()
        guard tickInterval > 0 else { return }
        let nanoseconds = UInt64(tickInterval * 1_000_000_000)
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, !Task.isCancelled, self.state.isActive else { return }
                self.publish()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
