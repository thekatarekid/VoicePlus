import AppKit
import Combine
import Engine
import Foundation
import Injection
import Shared

/// Wires hotkey actions → engine, engine events → pill, finals → `UtteranceLander`
/// (pipeline → repair/injection → history). Without a lander (shell-only tests) text lands on
/// the pasteboard + history as it did before P1.12.
public final class DictationCoordinator {
    public let engine: any EngineProtocol
    public let database: AppDatabase?
    public let pill: PillPanelController
    public var onFinal: (([TranscriptSpan]) -> Void)?
    /// Full landing path (P1.12). Nil → pasteboard fallback.
    public var lander: UtteranceLander?
    /// Called on hotkey-down before capture (bias-list refresh).
    public var onPrepare: (() -> Void)?
    /// Focus snapshot source; taken at key release so injection can abort on focus churn.
    public var focusSnapshot: (() -> FocusSnapshot?)?
    public var onLanded: ((LandingResult) -> Void)?
    /// W3H — Privacy's "Save dictation history" (`DictationHistoryGate`), read per landing: off keeps
    /// the shell path's text out of `dictation_history`.
    public var recordsHistory: () -> Bool = { true }
    public private(set) var lastMicQuality: MicQuality?
    /// R3.1 — **latched** (V3 §4.3/§4.7): the double-tap mode where capture continues across
    /// endpoints.
    ///
    /// Nothing in the session-teardown path clears this any more. `finalize()` used to, which is
    /// exactly why latch never worked (V3 §2.3): the first finalize of a latched session — and in a
    /// latched session finalizes happen *per segment*, not per session — dropped the user out of the
    /// mode they had explicitly asked for. The mode now changes only on an explicit gesture
    /// (`handle(.enterLatch)`, `handle(.finalize)`, `endLatch()`) or on an event that must end
    /// capture outright (hard mute, lock/sleep).
    public private(set) var latched = false
    public private(set) var paused = false
    /// Reported when `engine.start()` could not open a session. The app uses it to reset the hotkey
    /// gesture, so a key that is still physically down does not leave the recogniser "capturing".
    public var onStartFailure: ((Error) -> Void)?
    private var eventTask: Task<Void, Never>?
    private var startedAt = Date()

    // MARK: Session ownership
    //
    // One flag, one owner, one queue. Every engine call this class makes runs on `chain`, in the
    // order the user made the gesture, and every path that can leave the engine holding capture ends
    // in a `cancel()`. Before 1.7.4 `start()`, `finalize()` and `cancel()` each spawned an
    // independent `Task`, so a key released during warm-up ran `stop()` *before* its own `start()`
    // finished: the stop threw `notListening` (swallowed), the start then succeeded, and the engine
    // was left recording with nobody left to stop it. That is the wedge behind "VoicePlus is already
    // recording." and the hotkey that goes dead after a handful of presses.
    private let sessionLock = NSLock()
    /// True between a `start()` that opened capture and the `finalize()`/`cancel()` that releases it.
    private var sessionHeld = false
    private var chain: Task<Void, Never>?
    private var queued = 0
    private var completed = 0

    /// Longest a `preflight` may delay capture. `AppContainer.refreshEngineIfNeeded()` does disk
    /// lookups and can rebuild a recogniser; it sits directly in the hotkey path, so it is bounded
    /// here rather than trusted. A preflight that overruns is abandoned, not waited on — the
    /// utterance still starts.
    public var preflightTimeout: TimeInterval = 2

    /// Is an utterance in flight, as far as this coordinator is concerned? Test/diagnostic hook.
    public var isSessionHeld: Bool { sessionLock.withLock { sessionHeld } }

    /// Runs every queued engine operation to completion. Tests only.
    public func settle() async {
        while true {
            let (task, done) = sessionLock.withLock { (chain, completed >= queued) }
            if done { return }
            await task?.value
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        sessionLock.lock()
        let previous = chain
        queued += 1
        let task = Task { [weak self] in
            await previous?.value
            await work()
            if let self { self.sessionLock.withLock { self.completed += 1 } }
        }
        chain = task
        sessionLock.unlock()
    }

    /// Claims the held session, if there is one, and clears it. The claim is taken exactly once, so
    /// a `finalize()` and a `cancel()` racing the same utterance cannot both stop the engine.
    private func takeSession() -> Bool {
        sessionLock.withLock {
            let held = sessionHeld
            sessionHeld = false
            return held
        }
    }

    /// The engine underneath was replaced. `SwappableEngine.swap` already cancelled whatever the
    /// outgoing engine was doing, so the claim is void — dropping it here is what stops a swap
    /// mid-utterance from leaving a session held against an engine that no longer exists.
    public func engineWasSwapped() {
        sessionLock.withLock { sessionHeld = false }
    }
    /// The pill's waveform feed. `bind(engineState:)` alone left `audioLevel` nil, so the only
    /// levels the pill ever saw came from `EngineState.listening(level:)` — which stops the instant
    /// a preview arrives, freezing the waveform mid-utterance.
    private let capturedLevels = PassthroughSubject<Float, Never>()
    private var levelSource: AnyCancellable?

    // MARK: S3 — the turn controller

    /// S3 — every hold goes key-down snapshot → capture → finishing → final preview → one insert,
    /// through this controller; `endSession` hands it the final pass instead of landing directly.
    /// Nil → the pre-S3 direct landing (shell-only tests, headless tools).
    public var turns: TurnController? {
        get { sessionLock.withLock { _turns } }
        set {
            sessionLock.withLock { _turns = newValue }
            newValue?.onLanded = { [weak self] result in self?.onLanded?(result) }
            // FX2 — chained, not replaced: `TurnWiring`'s own turn-end handler (Escape, deixis) stays.
            let previousEnd = newValue?.onTurnEnded
            newValue?.onTurnEnded = { [weak self] id, stage in
                previousEnd?(id, stage)
                self?.turnEnds.send(stage)
            }
        }
    }
    private var _turns: TurnController?

    // MARK: FX2 — the presence chin's feed

    /// FX2 — every engine state, **unfiltered**. The pill is bound to what the turn controller
    /// admits (S3); the presence chin must not be. After key-up the controller drops `.finalizing`,
    /// `.landed` and `.idle`, so a chin fed the admitted stream last heard `.previewing` and sat on
    /// "Working…" until the next press. The chin stands down while the pill shows, so these states
    /// only matter once the pill has gone — by which time the engine has said it is at rest.
    public var engineStates: AnyPublisher<EngineState, Never> { engine.statePublisher }
    /// FX2 — a turn ended (landed, held, failed, cancelled, empty…), with its final stage: whatever
    /// the engine feed last said, a finished turn is not work in progress.
    public var turnEnded: AnyPublisher<TurnStage, Never> { turnEnds.eraseToAnyPublisher() }
    private let turnEnds = PassthroughSubject<TurnStage, Never>()
    /// The capture turn this coordinator opened (hold, or the latched session's).
    private var turnID: TurnID?
    /// The press the controller refused (K04): its key-up must do nothing.
    private var refusedPress = false
    private var partialWords: AnyCancellable?
    private var voiceActivity: Task<Void, Never>?

    /// The current capture turn, for tests and diagnostics.
    public var currentTurn: TurnID? { sessionLock.withLock { turnID } }

    public init(engine: any EngineProtocol, database: AppDatabase?, pill: PillPanelController) {
        self.engine = engine
        self.database = database
        self.pill = pill
        // S3 — while a turn owns the pill (finishing, preview, inserting, a Cancelled row) the
        // engine's own states would contradict it; the controller decides which get through.
        let states = engine.statePublisher
        let admitted = states.filter { [weak self] state in self?.turns?.admitsEngineState(state) ?? true }
        pill.model.bind(engineState: admitted.eraseToAnyPublisher(), audioLevel: capturedLevels.eraseToAnyPublisher())
        partialWords = states.sink { [weak self] state in
            if case .previewing(let text) = state { self?.turns?.notePartial(text) }
        }
        // Engines that publish levels for the whole utterance drive the waveform directly; the mock
        // engine (VOICEPLUS_FIXTURE) publishes none and keeps falling back to `.listening(level:)`.
        if let publishing = engine as? AudioLevelPublishing {
            levelSource = publishing.audioLevels.sink { [capturedLevels] level in capturedLevels.send(level) }
        }
        // A model landing (or being deleted) mid-utterance replaces the engine underneath us.
        // `SwappableEngine.swap` cancels the outgoing engine; this drops our claim on it, so the
        // next press starts a clean session instead of trying to release one that no longer exists.
        if let swappable = engine as? SwappableEngine {
            let previous = swappable.onSwap
            swappable.onSwap = { [weak self] engine in
                previous?(engine)
                self?.engineWasSwapped()
            }
        }
        eventTask = Task { [weak self] in
            for await event in engine.events() {
                guard let self else { return }
                if case .micQuality(let q) = event { await MainActor.run { self.lastMicQuality = q } }
            }
        }
    }

    deinit {
        eventTask?.cancel()
        voiceActivity?.cancel()
    }

    /// Drive the pill waveform straight from the capture pipeline's `.level(rms:)` channel — the
    /// same signal the onboarding mic meter uses, so the two agree. Replaces the engine-level
    /// subscription so a bar is never pushed twice for the same audio.
    public func bindWaveform(to audio: PipelineAudioSource) {
        levelSource?.cancel()
        levelSource = nil
        audio.onLevel = { [capturedLevels] level in capturedLevels.send(level) }
        // The capture watchdogs had no consumer at all on the dictation path: `AudioPipeline` has
        // emitted `.captureFailed` since 1.6.4 and `PipelineAudioSource` has forwarded it to
        // `onCaptureFailure`, but nothing in the app ever assigned that closure — so a capture that
        // opened and delivered nothing logged one line and showed the user "Listening · quiet".
        // Bound here, beside the level channel, because this is the one method called at launch and
        // again after every engine swap, so it always tracks the live pipeline.
        audio.onCaptureFailure = { [weak self, weak audio] reason in
            Task { @MainActor in self?.noteCaptureSilent(reason, source: audio) }
        }
        // B1 — the same pipeline is what the latch listens to (VAD, endpoints, stream position).
        // The app binds here at launch and after every engine swap, so this is always the live one.
        latchAudio = audio
        if latched { onLatchAudioChanged?() }
        // S3 — the VAD tells the turn when the room went quiet (C2 "Listening · quiet"). Its own
        // subscription to the pipeline's broadcast, so the latch's `onVAD` stays the latch's.
        voiceActivity?.cancel()
        let events = audio.pipeline.events()
        voiceActivity = Task.detached(priority: .utility) { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard case .vad(let vad) = event else { continue }
                if case .speechStart = vad { self?.turns?.noteVoiceActivity(speech: true) }
                else { self?.turns?.noteVoiceActivity(speech: false) }
            }
        }
    }

    // MARK: Latch feed and timer (B1, B4)

    /// B1 — the capture pipeline a latched session endpoints on. Held weakly: the container owns it.
    public private(set) weak var latchAudio: PipelineAudioSource?
    /// B1 — the pipeline changed under a running latch (engine swap); the session coordinator
    /// moves the latch onto the new one.
    public var onLatchAudioChanged: (() -> Void)?
    /// B4 — the latch timer as last published by `LatchRuntime`.
    public private(set) var latchElapsed: TimeInterval = 0

    /// B4 — `LatchRuntime` publishes elapsed latch time; the pill shows it as the design's timer
    /// (`PillState.latched(elapsed:)`). Outside latch there is no timer to show.
    public func noteLatchElapsed(_ elapsed: TimeInterval) {
        guard latched else { return }
        latchElapsed = elapsed
        // S3 — a segment's final preview (or its write) owns the pill until it resolves.
        guard !(turns?.isGateBusy ?? false) else { return }
        pill.model.present(.latched(elapsed: elapsed))
    }

    /// Hard mute (V3 §4.4) and anything else that closes the microphone for good. Pausing ends the
    /// latch: the mode promises "listening continues", and a paused coordinator cannot keep that
    /// promise. Unpausing never resumes — the user starts the next session themselves.
    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            endLatch()
            cancel()
        }
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        guard !paused else { return }
        switch action {
        case .startCapture: start()
        case .finalize:
            // The gesture layer owns the mode, not the teardown path. A `.finalize` that arrives
            // while latched *is* the single tap that stops (V3 §4.3), so it leaves latch; a
            // `finalize()` called for any other reason (a segment, a guided landing, a swap) does
            // not touch the mode.
            if latched { endLatch() }
            finalize()
        case .cancelCapture: cancel()
        case .enterLatch:
            latched = true
            pill.model.latched = true
            turns?.noteLatched(true)
            onLatchChanged?(true)
        }
    }

    /// Called whenever the latch mode changes, so the session coordinator and the surfaces agree
    /// without either of them polling.
    public var onLatchChanged: ((Bool) -> Void)?

    /// Leaves latch without ending the session. Capture, if open, is unaffected — the caller
    /// decides whether to `finalize()` (stop and land) or `cancel()` (stop and land nothing).
    public func endLatch() {
        guard latched else { return }
        latched = false
        pill.model.latched = false
        onLatchChanged?(false)
    }

    /// A capture that opened and will never deliver anything usable: no blocks at all, or nothing
    /// but digital silence (a muted input, a microphone grant macOS is silencing us for, a tap an
    /// `AVAudioEngine` configuration change detached). The turn ends with the catalogue's A05 row,
    /// the session is torn down, and the kept capture graph is **released** rather than left paused.
    ///
    /// That last part is the half that makes the failure stop repeating. V4.7 keeps the graph
    /// between turns and a warm resume is one `engine.start()` — no enumeration, no format sync, no
    /// tap re-install — so once a graph has gone silent, every later press resumed the same dead
    /// graph until the ten-minute idle release. Releasing it here means the next press builds a cold
    /// one and can succeed.
    @MainActor
    public func noteCaptureSilent(_ reason: String, source: PipelineAudioSource?) {
        Log.app.error("dictation: capture opened and stayed silent — \(reason)")
        turns?.captureSilent()
        // Latch must end here, and `cancel()` deliberately will not do it (a cancelled utterance
        // inside a latched session is not the user asking to leave the mode). This is one of the
        // paths that *must*: the mode promises "listening continues", and the capture it was
        // listening to is about to be released. Without this the pill kept its latch dress and the
        // runtime stayed connected to a dead pipeline — "Listening" for ever again, by another
        // route. Nothing is lost by ending it: the watchdog only fires on a capture in which no
        // non-zero sample has *ever* arrived, so there is no dictation in it to lose.
        endLatch()
        cancel()
        guard let graph = source?.pipeline.source else { return }
        DispatchQueue.global(qos: .userInitiated).async { graph.release(reason: .silent) }
    }

    public func noteMicQuality(_ quality: MicQuality) {
        lastMicQuality = quality
        if quality.verdict != .good { pill.model.apply(.warning(quality)) }
    }

    /// Runs before capture starts. `AppContainer.refreshEngineIfNeeded()` lives here, so a model
    /// that landed (or was deleted) since the last utterance is picked up without a relaunch even
    /// if no download callback fired.
    public var preflight: (() async -> Void)?

    public func start() {
        // S3 — key down is a turn: snapshot the destination and show "Starting…" now, before
        // capture opens. A key repeat is not a second turn, and a press while the previous turn is
        // still finishing, previewing or inserting does not steal it (K04).
        let turn: TurnID?
        if let turns {
            switch turns.keyDown(latched: latched) {
            case .began(let id):
                sessionLock.withLock { turnID = id; refusedPress = false }
                turn = id
            case .repeated:
                return
            case .busy:
                sessionLock.withLock { refusedPress = true }
                return
            }
        } else {
            turn = nil
        }
        startedAt = Date()
        onPrepare?()
        enqueue { [weak self] in await self?.beginSession(turn: turn) }
    }

    private func beginSession(turn: TurnID? = nil) async {
        await openSession()
        guard let turn, let turns else { return }
        if isSessionHeld {
            turns.captureOpened(turn)
        } else {
            // BUG B — a start that never opened capture says so in the pill, in the catalogue's own
            // words for *this* failure (A03 when nothing recognises it). Until now the turn ended
            // and its "Starting microphone…" row was retracted, which — because a pill row suppresses
            // the presence chin — is how a press could end with no surface on screen at all.
            turns.captureFailed(turn, reason: startFailureID())
        }
    }

    /// The catalogue id of the last `engine.start()` failure, consumed once. `.A03` ("Couldn’t start
    /// this microphone · Nothing was recorded.") when the start failed without an error we can map —
    /// the honest reading of "capture is not open and nobody threw".
    private func startFailureID() -> RecoveryID {
        let error = sessionLock.withLock { () -> Error? in
            defer { startFailure = nil }
            return startFailure
        }
        guard let error else { return .A03 }
        return RecoveryCatalog.recoveryID(for: error)
    }
    private var startFailure: Error?

    private func openSession() async {
        // A session still held here belongs to an utterance that never ended (a swallowed error, a
        // torn-down window, another owner of the same engine). Release it instead of refusing every
        // start from now on: a wedged state must be able to clear itself.
        if takeSession() {
            Log.app.notice("dictation: releasing a session left over from the previous utterance")
            await engine.cancel()
        }
        await runPreflight()
        do {
            try await engine.start(prewarm: true)
            sessionLock.withLock { sessionHeld = true }
        } catch EngineError.alreadyListening {
            // Someone else — onboarding's dictation test, the act stack, "train by voice" — left the
            // shared engine recording. One forced teardown and one retry, so the user gets dictation
            // back on the *next* press rather than on the next launch.
            Log.app.notice("dictation: engine was still recording; tearing it down and retrying")
            await engine.cancel()
            do {
                try await engine.start(prewarm: true)
                sessionLock.withLock { sessionHeld = true }
            } catch {
                await failStart(error)
            }
        } catch {
            await failStart(error)
        }
    }

    /// Capture never opened. Tear the engine down unconditionally (a `start()` that threw part-way
    /// may still hold the microphone) and tell the app, so the gesture recogniser can reset.
    private func failStart(_ error: Error) async {
        Log.app.error("engine start failed: \(error)")
        await engine.cancel()
        sessionLock.withLock { sessionHeld = false; startFailure = error }
        // Capture never opened, so there is no latched session to be in. Leaving `latched` set here
        // would put the gesture recogniser (which the app resets on this callback) and the
        // coordinator into two different modes.
        await MainActor.run { self.endLatch() }
        let report = onStartFailure
        if let report { await MainActor.run { report(error) } }
    }

    /// Bounded so a slow or hung preflight cannot hold the utterance — or everything queued behind
    /// it — indefinitely.
    private func runPreflight() async {
        guard let preflight else { return }
        let timeout = max(0, preflightTimeout)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = FirstPast()
            Task {
                await preflight()
                if once.take() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.take() {
                    Log.app.notice("dictation: preflight overran \(timeout)s; starting capture anyway")
                    continuation.resume()
                }
            }
        }
    }

    /// True when the engine cannot recognise speech at all (`UnavailableEngine`). Nothing is ever
    /// landed or injected in that case — there is no transcript, only a notice.
    /// Asked through `EngineAvailabilityReporting`, not by class identity: the engine handed in is
    /// normally a `SwappableEngine`, whose answer changes when a model is installed at runtime.
    public var engineIsUnavailable: Bool { (engine as? EngineAvailabilityReporting)?.isUnavailable ?? false }

    public func finalize() {
        // R3.1: the line that used to sit here — the one clearing `latched` — is *the* reason latch
        // did not exist (V3 §2.3). Ending one session must not end the mode; see `endLatch()`.
        //
        // Taken here, on the key-release turn, not inside the queued work: the point of the snapshot
        // is what was focused when the user let go.
        let focus = focusSnapshot?()
        let started = startedAt
        // S3 — key up: the turn goes to `finishing` now (microphone closing, nothing written). A
        // duplicate key-up, or the key-up of a press the controller refused, does nothing at all.
        var turn: TurnID?
        if let turns {
            let (id, refused) = sessionLock.withLock { () -> (TurnID?, Bool) in
                defer { refusedPress = false }
                return (turnID, refusedPress)
            }
            if refused { return }
            if let id {
                sessionLock.withLock { if turnID == id { turnID = nil } }
                guard turns.keyUp(id) else {
                    // The turn already ended (Escape, an interruption): nothing lands from it.
                    // Capture must still close if anything left it open.
                    enqueue { [weak self] in
                        guard let self, self.takeSession() else { return }
                        await self.engine.cancel()
                    }
                    return
                }
                turn = id
            }
        }
        let finishing = turn
        enqueue { [weak self] in await self?.endSession(focus: focus, startedAt: started, turn: finishing) }
    }

    /// The reason the engine gave for its last `stop()` (V4.21/V4.22): a silent hold or a dropped
    /// hallucination is A06 "No speech detected", not an empty landing.
    private var lastStopReason: EngineStopReason? {
        let underlying = (engine as? SwappableEngine)?.current ?? engine
        return (underlying as? EngineStopReporting)?.lastStopReason
    }

    private func endSession(focus: FocusSnapshot?, startedAt started: Date, turn: TurnID? = nil) async {
        // Queued behind this utterance's own `start()`, so "nothing held" now means exactly one
        // thing: capture never opened. The key was released during warm-up, or the start failed.
        // Cancel anyway — teardown is unconditional — and land nothing.
        guard takeSession() else {
            await engine.cancel()
            if let turn { turns?.nothingCaptured(turn) }
            return
        }
        // No recognizer on this machine: let the engine wind down its notice, but never route
        // anything to the lander/injector. There is no user speech to land.
        if engineIsUnavailable {
            _ = try? await engine.stop()
            if let turn { turns?.nothingCaptured(turn) }
            return
        }
        do {
            let spans = try await engine.stop()
            if let turn, let turns {
                // S3 — the controller formats the final payload, previews it for its dwell,
                // revalidates the destination and inserts it once; `onLanded` follows from there.
                await turns.finalize(turn, spans: spans, stopReason: lastStopReason)
                await MainActor.run { self.onFinal?(spans) }
            } else if let lander {
                let result = await lander.land(spans, startedAt: started, focus: focus)
                await MainActor.run {
                    self.onFinal?(spans)
                    self.onLanded?(result)
                }
            } else {
                await MainActor.run { self.land(spans) }
            }
        } catch EngineError.notListening {
            // Tap released before the engine finished prewarming — nothing to land.
            if let turn { turns?.nothingCaptured(turn) }
        } catch {
            Log.app.error("engine stop failed: \(error)")
            if let turn { turns?.finishFailed(turn, error: error) }
            // A `stop()` that threw says nothing about whether capture is still open. Never leave
            // that to chance: this is the path that used to leak a live microphone.
            await engine.cancel()
        }
    }

    /// Aborts capture without landing anything. Deliberately leaves `latched` alone: a cancelled
    /// utterance inside a latched session (a stray tap, a swap, a preflight failure) is not the user
    /// asking to leave latch. The paths that *must* end the mode — hard mute, lock/sleep, an
    /// explicit stop — call `endLatch()` themselves (`SessionCoordinator`).
    public func cancel() {
        // S3 — the capture turn ends quietly (a too-short tap is not news; Escape shows its own
        // "Cancelled"). A turn already past key-up is not capture any more: it is left to finish.
        if let turns, let id = sessionLock.withLock({ () -> TurnID? in
            let id = turnID
            turnID = nil
            refusedPress = false
            return id
        }) {
            turns.captureCancelled(id)
        }
        enqueue { [weak self] in
            guard let self else { return }
            _ = self.takeSession()
            await self.engine.cancel()
        }
    }

    /// Lands one utterance that was produced outside the hotkey path — today only the onboarding
    /// dictation test — through the *same* pipeline → injection → history route, and reports whether
    /// the text was really typed.
    ///
    /// Onboarding needs this to tell "It landed" from "Heard you". Until 1.6.6 its dictation button
    /// bypassed `UtteranceLander` entirely, so no `Injector` ever ran and "It landed. You're set."
    /// could not have been true on any machine, with any audio. `LandingResult.landed` is
    /// `injection?.succeeded ?? false` — the signal was there, nothing read it.
    ///
    /// Never writes to the pasteboard: a test the user ran to see whether dictation works should not
    /// silently replace what they had copied.
    public func guidedLanding(_ spans: [TranscriptSpan], startedAt: Date = Date()) async -> GuidedLanding {
        // D4 (V4.13): what onboarding shows is rendered text — a blanked span leaves no stray space.
        let heard = spans.renderedText
        // Same rule as `finalize()`, stated in both places rather than in one. This is the second
        // way spans reach `UtteranceLander`, and it must not be the way a fabricated utterance gets
        // typed just because it did not come in through the hotkey.
        guard !engineIsUnavailable else { return GuidedLanding(text: "", injected: false) }
        guard let lander else { return GuidedLanding(text: heard, injected: false) }
        let focus = focusSnapshot?()
        let result = await lander.land(spans, startedAt: startedAt, focus: focus)
        let app = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName }
        return GuidedLanding(text: result.text.isEmpty ? heard : result.text,
                             injected: result.landed, appName: app)
    }

    private func land(_ spans: [TranscriptSpan]) {
        // D4 (V4.13): the copied and recorded text is rendered text, never the raw join (empty spans
        // would leave double or leading spaces); the raw join stays in the record's `rawText`.
        let text = spans.renderedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let database, recordsHistory() {
            let record = DictationRecord(startedAt: startedAt, endedAt: Date(), register: "unknown", route: "dictate",
                                         appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                         rawText: spans.joinedText, finalText: text,
                                         spansJSON: String(decoding: (try? JSONEncoder().encode(spans)) ?? Data("[]".utf8), as: UTF8.self))
            do { try database.insert(record) } catch { Log.db.error("history insert failed: \(error)") }
        }
        Log.app.info("landed \(spans.count) spans (\(text.count) chars)")
        onFinal?(spans)
    }
}

/// One-shot gate: the first of two racing tasks to call `take()` gets true, the other false.
/// Used to resume a continuation exactly once when a bounded wait is raced against its timeout.
final class FirstPast: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func take() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}
