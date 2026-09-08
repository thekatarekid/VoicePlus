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
    public private(set) var lastMicQuality: MicQuality?
    public private(set) var handsFree = false
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

    public init(engine: any EngineProtocol, database: AppDatabase?, pill: PillPanelController) {
        self.engine = engine
        self.database = database
        self.pill = pill
        pill.model.bind(engineState: engine.statePublisher, audioLevel: capturedLevels.eraseToAnyPublisher())
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

    deinit { eventTask?.cancel() }

    /// Drive the pill waveform straight from the capture pipeline's `.level(rms:)` channel — the
    /// same signal the onboarding mic meter uses, so the two agree. Replaces the engine-level
    /// subscription so a bar is never pushed twice for the same audio.
    public func bindWaveform(to audio: PipelineAudioSource) {
        levelSource?.cancel()
        levelSource = nil
        audio.onLevel = { [capturedLevels] level in capturedLevels.send(level) }
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { cancel() }
    }

    public func handle(_ action: HotkeyStateMachine.Action) {
        guard !paused else { return }
        switch action {
        case .startCapture: start()
        case .finalize: finalize()
        case .cancelCapture: cancel()
        case .enterHandsFree:
            handsFree = true
            pill.model.handsFree = true
        }
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
        startedAt = Date()
        onPrepare?()
        enqueue { [weak self] in await self?.beginSession() }
    }

    private func beginSession() async {
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
        sessionLock.withLock { sessionHeld = false }
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
        handsFree = false
        pill.model.handsFree = false
        // Taken here, on the key-release turn, not inside the queued work: the point of the snapshot
        // is what was focused when the user let go.
        let focus = focusSnapshot?()
        let started = startedAt
        enqueue { [weak self] in await self?.endSession(focus: focus, startedAt: started) }
    }

    private func endSession(focus: FocusSnapshot?, startedAt started: Date) async {
        // Queued behind this utterance's own `start()`, so "nothing held" now means exactly one
        // thing: capture never opened. The key was released during warm-up, or the start failed.
        // Cancel anyway — teardown is unconditional — and land nothing.
        guard takeSession() else {
            await engine.cancel()
            return
        }
        // No recognizer on this machine: let the engine wind down its notice, but never route
        // anything to the lander/injector. There is no user speech to land.
        if engineIsUnavailable {
            _ = try? await engine.stop()
            return
        }
        do {
            let spans = try await engine.stop()
            if let lander {
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
        } catch {
            Log.app.error("engine stop failed: \(error)")
            // A `stop()` that threw says nothing about whether capture is still open. Never leave
            // that to chance: this is the path that used to leak a live microphone.
            await engine.cancel()
        }
    }

    public func cancel() {
        handsFree = false
        pill.model.handsFree = false
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
        let heard = spans.joinedText
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
        let text = spans.joinedText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if let database {
            let record = DictationRecord(startedAt: startedAt, endedAt: Date(), register: "unknown", route: "dictate",
                                         appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                         rawText: text, finalText: text,
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
