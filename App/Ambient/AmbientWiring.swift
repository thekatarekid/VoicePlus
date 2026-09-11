import Engine
import Foundation
import Shared

// R8.1 / R8.2 — the composition seam. One place that builds ambient capture, and one place that
// attaches it.
//
// `LatchRuntime` already has the hole this fills: `onTranscript` is documented there as "Ambient
// transcript sink (V3 §8: into the Timeline, never typed). Set by the ambient item." This is the
// ambient item. Note what the seam is *not*: it is not a `LatchDelivering`, it carries no
// destination, and `LatchRuntime.run` reaches it by returning **before** delivery is consulted. The
// only thing this wiring can do with ambient speech is store it.
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

    /// Connects a latch runtime's ambient transcript seam to the gate and the store.
    ///
    /// `gate` and `verdict` are closures, not values: both depend on state that changes while the app
    /// runs (the switch, enrollment, whether the embedding weights loaded). `onDecision` exists for
    /// the pill and the Timeline's "why is this empty?" line — it is told what happened, and is given
    /// no way to act on it.
    public static func attach(to runtime: LatchRuntime,
                              sink: any AmbientTranscriptSink,
                              gate: @escaping () -> AmbientCaptureGate,
                              verdict: @escaping () -> SpeakerGate.Verdict = { .unknown },
                              now: @escaping () -> Date = { Date() },
                              onDecision: ((AmbientCaptureDecision) -> Void)? = nil) {
        runtime.onTranscript = { text, segment in
            let decision = gate().decide(text: text, verdict: verdict(), at: now())
            switch decision {
            case .keep(let entry):
                do { try sink.store(entry) }
                catch { Log.app.error("ambient: entry \(segment) not stored: \(error)") }
            case .discard(let reason):
                Log.app.notice("ambient: segment \(segment) discarded — \(reason.rawValue)")
            }
            onDecision?(decision)
        }
    }
}
