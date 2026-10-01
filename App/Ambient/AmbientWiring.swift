import Actions
import Engine
import Foundation
import Pipeline
import Shared

// R8.1 / R8.2 — the composition seam. One place that builds ambient capture, and one place that
// attaches it.
//
// V5 L3: ambient listens on the always-on capture (`listener(...)`, a recorder on O1's broadcaster),
// with the speaker verdict computed from each segment's samples. The older `LatchRuntime.onTranscript`
// seam (`attach(to:)`) is kept for the latch runtime's own tests; both go through `process(...)`, which
// is not a `LatchDelivering` and carries no destination. Since V5 L2 a kept utterance also goes to
// the `AmbientDecisionPipeline` (arbiter → `AmbientGuarantees`), which is the only way ambient speech
// can become a Note or — in Listen & act, from the user's voice, in the act band — a capability.
//
// Retention is enforced here too, at the two moments a user would notice it not being: when the
// store is built (app launch) and periodically while entries are being written. Opening the Timeline
// sweeps as well (`AmbientTranscriptStore.rows(matching:)`), but a Mac where the window is never
// opened must still honour the seven days.

/// Builds ambient capture from the app's dependencies, and attaches it to the latch runtime.
public enum AmbientWiring {
    /// The Timeline's store, with retention already swept once. Call at launch.
    ///
    /// The sweep is deliberately on this path and not in `init`: a store built by a test with a
    /// frozen clock should not delete anything it was not asked to, and the composition root should
    /// enforce retention loudly rather than as a side effect of allocation.
    /// `root` exists so a test can exercise this path without reading — or sweeping — the user's real
    /// transcript directory.
    public static func store(database: AppDatabase?, settings: (any SettingsStore)?,
                             root: URL = AmbientTranscriptStore.defaultRoot()) -> AmbientTranscriptStore {
        let store = AmbientTranscriptStore(meetings: MeetingStore(root: root), database: database,
                                          retention: { AmbientRetentionPolicy.fromSettings(settings) })
        if let result = try? store.sweepExpired(), !result.isEmpty {
            Log.app.notice("ambient: retention swept at launch (\(result.entriesDeleted) entries)")
        }
        return store
    }

    /// The gate, read fresh from settings every time so turning ambient off stops capture at once
    /// rather than at the next relaunch.
    public static func gate(settings: (any SettingsStore)?, filter: SpeakerFilter) -> AmbientCaptureGate {
        AmbientCaptureGate(isEnabled: AmbientCaptureSettings.isEnabled(settings),
                           capturesEverySpeaker: AmbientCaptureSettings.capturesEverySpeaker(settings),
                           filter: filter)
    }

    /// The gate when the filter's owner may already be gone (a weakly-captured container at
    /// shutdown). A missing filter cannot mean "capture freely": it yields a gate that is off, so
    /// the failure mode is keeping nothing rather than keeping everything.
    public static func gate(settings: (any SettingsStore)?, filter: SpeakerFilter?) -> AmbientCaptureGate {
        guard let filter else {
            return AmbientCaptureGate(isEnabled: false, capturesEverySpeaker: false,
                                      filter: SpeakerFilter(isOn: false, gate: SpeakerGate(profile: nil),
                                                            canIdentify: false))
        }
        return gate(settings: settings, filter: filter)
    }

    /// V5 L3 — one heard ambient segment through the gate, into the Timeline, then (kept only) to the
    /// decision pipeline with the verdict computed from its samples. The one path both the listener
    /// and the legacy latch seam use, so the two can never disagree about what is kept.
    @discardableResult
    public static func process(_ heard: AmbientHeard,
                               sink: any AmbientTranscriptSink,
                               gate: AmbientCaptureGate,
                               decisions: AmbientDecisionPipeline?,
                               forwardsVerdict: Bool = true,
                               onDecision: ((AmbientCaptureDecision) -> Void)? = nil) -> AmbientCaptureDecision {
        if forwardsVerdict { decisions?.heard(heard.verdict, at: heard.capturedAt) }   // O5 other-voice signal
        let decision = gate.decide(text: heard.text, verdict: heard.verdict, at: heard.capturedAt,
                                   duration: heard.duration, confidence: heard.confidence)
        switch decision {
        case .keep(let entry):
            do { try sink.store(entry) }
            catch { Log.app.error("ambient: entry \(heard.id) not stored: \(error)") }
            // V5 L2/L4 — a kept utterance is decided (Layer 1 on every ambient utterance) and routed
            // only as `AmbientGuarantees` allow, with this utterance's own speaker verdict.
            let end = entry.capturedAt.addingTimeInterval(max(0, entry.duration))
            decisions?.enqueue(entry.text, utteranceID: heard.id, range: entry.capturedAt...end,
                               verdict: forwardsVerdict ? heard.verdict : nil)
        case .discard(let reason):
            Log.app.notice("ambient: segment \(heard.id) discarded — \(reason.rawValue)")
        }
        onDecision?(decision)
        return decision
    }

    /// V5 L3 — the production listener: a recorder on the one capture graph (O1), ASR only on closed
    /// speech segments, the speaker verdict from each segment's samples, then `process`.
    ///
    /// `gate`, `transcribe` and `verdict` are closures because all three change while the app runs
    /// (the mode, a model landing after launch, enrollment and the embedder's weights).
    public static func listener(audio: any AmbientAudioAttaching,
                                sink: any AmbientTranscriptSink,
                                gate: @escaping () -> AmbientCaptureGate,
                                claimed: @escaping () -> Bool = { false },
                                transcribe: @escaping () -> AmbientListener.Transcribe?,
                                verdict: @escaping AmbientListener.Verdict,
                                decisions: AmbientDecisionPipeline?,
                                onDecision: ((AmbientCaptureDecision) -> Void)? = nil) -> AmbientListener {
        let box = UncheckedBox((sink, gate, decisions, onDecision))
        return AmbientListener(audio: audio, listens: { gate().isEnabled }, claimed: claimed,
                               transcribe: transcribe, verdict: verdict) { heard in
            let (sink, gate, decisions, onDecision) = box.value
            process(heard, sink: sink, gate: gate(), decisions: decisions, onDecision: onDecision)
        }
    }

    /// The production verdict: `SpeakerGate.verdict(for:embedder:)` on the segment's samples, run only
    /// when it can mean something — an identifying embedder and an enrolled profile. Otherwise
    /// `.unknown` without embedding (the gate then discards honestly unless every speaker is kept).
    public static func verdict(filter: @escaping () -> SpeakerFilter?,
                               embedder: @escaping () -> (any SpeakerEmbedder)?) -> AmbientListener.Verdict {
        let box = UncheckedBox((filter, embedder))
        return { samples in
            let (filter, embedder) = box.value
            guard let f = filter(), f.canIdentify, f.gate.profile != nil, let e = embedder() else { return .unknown }
            return f.gate.verdict(for: samples, embedder: e)
        }
    }

    /// Connects a latch runtime's ambient transcript seam to the gate and the store.
    ///
    /// Legacy (pre-L3) path: the seam carries text and a SegmentID but no audio, so the verdict comes
    /// from `verdict`. Production uses `listener(...)` on the shared capture instead; nothing in the app
    /// sets `LatchRuntime.source = .ambient` any more.
    public static func attach(to runtime: LatchRuntime,
                              sink: any AmbientTranscriptSink,
                              gate: @escaping () -> AmbientCaptureGate,
                              verdict: (() -> SpeakerGate.Verdict)? = nil,
                              now: @escaping () -> Date = { Date() },
                              decisions: AmbientDecisionPipeline? = nil,
                              onDecision: ((AmbientCaptureDecision) -> Void)? = nil) {
        runtime.onTranscript = { text, segment in
            let heard = AmbientHeard(id: "ambient-\(segment.sessionID.uuidString)-\(segment.index)", text: text,
                                     verdict: verdict?() ?? .unknown, capturedAt: now(), duration: 0)
            // No samples here: the decision pipeline keeps its own verdict unless one was given.
            process(heard, sink: sink, gate: gate(), decisions: decisions, forwardsVerdict: verdict != nil,
                    onDecision: onDecision)
        }
    }

    /// V5 L2/L4 — the ambient decision pipeline: mode → arbiter (built asynchronously: registering
    /// the decision model with `ModelResidency` is async; until it is ready utterances are only
    /// recorded) → `AmbientGuarantees` → Notes. Since L3 each utterance carries its own speaker verdict
    /// (`verdict` here is only the fallback). Delivery: `AmbientActDelivery.shared` (V5 CU7 — `.act`
    /// to the act session; other owners only once a lane attaches `next`).
    @MainActor
    public static func decisionPipeline(settings: (any SettingsStore)?, actParser: ActIntentParser?,
                                        mode: AmbientModeController,
                                        verdict: @escaping () -> SpeakerGate.Verdict = { .unknown },
                                        context: @escaping (String) -> DecisionState = { DecisionState(utterance: $0) })
        -> AmbientDecisionPipeline {
        let box = ArbiterBox()
        Task { box.set(await ArbiterWiring.make(settings: settings, actParser: actParser)) }
        let pipeline = AmbientDecisionPipeline(mode: mode, arbiter: { box.get() }, verdict: verdict, context: context)
        // V5 CU7 — `.act` deliveries reach the act session (attached by the app delegate).
        pipeline.delivery = AmbientActDelivery.shared
        pipeline.note = { [weak mode] text, decision in
            // The guarantees already decided this is a note; Notes only needs the source tag.
            let band = AmbientBand.note
            let listenAndNote = mode?.mode == .listenAndNote
            Task { @MainActor in
                NotesWiring.router?.route(text, signals: NotesRouteSignals(ambientBand: band, listenAndNote: listenAndNote,
                                                                           arbiterChoseNote: true))
            }
            return true
        }
        return pipeline
    }
}

/// V5 O5 — the production state for one ambient utterance: frontmost app, the focused field's
/// `FieldRole` (read through the same provider the lander uses), and whether a meeting is recording.
/// History and "another voice in the last 10 s" are added by `AmbientDecisionPipeline`. Lip activity
/// and prosody stay nil on the ambient path (camera only in a lip-reading mode, L5; the ambient
/// segmenter computes no directed-speech features).
public enum AmbientDecisionContext {
    public static func make(frontmostApp: @escaping () -> String?,
                            field: @escaping (String?) -> FieldContext?,
                            meetingActive: @escaping () -> Bool) -> (String) -> DecisionState {
        { text in
            let app = frontmostApp()
            let role = field(app).map(FieldRole.classify)
            let focused = role.map { $0 != .unknown } ?? false
            return DecisionState(utterance: text, frontmostApp: app,
                                 fieldRole: focused ? role?.rawValue : nil,
                                 textFieldFocused: focused, meetingActive: meetingActive())
        }
    }
}

/// Lets non-Sendable composition values ride in a `@Sendable` closure; they are only read.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Holds the arbiter once it is built.
final class ArbiterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var arbiter: IntentArbiter?
    func set(_ a: IntentArbiter) { lock.withLock { arbiter = a } }
    func get() -> IntentArbiter? { lock.withLock { arbiter } }
}
