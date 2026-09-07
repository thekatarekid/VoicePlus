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
    private var eventTask: Task<Void, Never>?
    private var startedAt = Date()
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

    public func start() {
        startedAt = Date()
        onPrepare?()
        Task {
            do { try await engine.start(prewarm: true) } catch {
                Log.app.error("engine start failed: \(error)")
            }
        }
    }

    /// True when the engine cannot recognise speech at all (`UnavailableEngine`). Nothing is ever
    /// landed or injected in that case — there is no transcript, only a notice.
    public var engineIsUnavailable: Bool { engine is UnavailableEngine }

    public func finalize() {
        handsFree = false
        pill.model.handsFree = false
        // No recognizer on this machine: let the engine wind down its notice, but never route
        // anything to the lander/injector. There is no user speech to land.
        if engineIsUnavailable {
            Task { _ = try? await engine.stop() }
            return
        }
        let focus = focusSnapshot?()
        let started = startedAt
        Task {
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
            }
        }
    }

    public func cancel() {
        handsFree = false
        pill.model.handsFree = false
        Task { await engine.cancel() }
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
