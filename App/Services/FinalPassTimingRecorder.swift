import Foundation
import Engine
import Shared

/// N6 — writes the engine's last final pass (per-stage ms, boost status, pre-boost raw text) into the
/// turn's `turn_records` extras, so a slow or wrong turn can be read back from one row (C6).
/// Text stays in the local database only; nothing is logged or sent anywhere.
enum FinalPassTimingRecorder {
    static let recogniseStage = "asr_recognise"
    static let alternativesStage = "asr_alternatives"
    static let modelWaitStage = "boost_model_wait"
    static let rescoreStage = "boost_rescore"
    static let totalStage = "asr_final_total"
    /// H20 — the booster's term count for the turn (0: no booster / empty list).
    static let boostTermsKey = "boost_terms"
    /// H20 — the boost status, stored through the existing `setStage` setter as a one-hot key
    /// (`boost_status_<status>` = 1), so `extras_json` says *why* a turn was not rescored
    /// (`notApplied` vs `modelNotReady` vs `timedOut` vs `unchanged` vs `boosted`).
    static let boostStatusPrefix = "boost_status_"
    static func boostStatusKey(_ status: BoostReport.Status) -> String { boostStatusPrefix + status.rawValue }

    /// Reads the stored boost status back (nil when none was recorded).
    static func boostStatus(in extras: TurnRecordExtras) -> BoostReport.Status? {
        guard let stages = extras.stageMs else { return nil }
        return stages.keys.lazy.filter { $0.hasPrefix(boostStatusPrefix) }
            .compactMap { BoostReport.Status(rawValue: String($0.dropFirst(boostStatusPrefix.count))) }.first
    }

    /// The timing reported by `engine` (unwrapping a swappable engine), if any.
    static func timing(of engine: EngineProtocol) -> FinalPassTiming? {
        let underlying = (engine as? SwappableEngine)?.current ?? engine
        return (underlying as? FinalPassTimingReporting)?.lastFinalPassTiming
    }

    /// Applies `timing` to `extras` (explicit stage values; pre-boost text only when boosting ran).
    static func apply(_ timing: FinalPassTiming, to extras: inout TurnRecordExtras) {
        func ms(_ v: Double) -> Int { Int(v.rounded()) }
        extras.setStage(recogniseStage, ms: ms(timing.recogniseMs))
        extras.setStage(alternativesStage, ms: ms(timing.alternativesMs))
        extras.setStage(modelWaitStage, ms: ms(timing.modelWaitMs))
        extras.setStage(rescoreStage, ms: ms(timing.rescoreMs))
        extras.setStage(totalStage, ms: ms(timing.totalMs))
        extras.preBoostRawText = timing.rawPreBoostText
        if var stages = extras.stageMs {   // one status per turn: drop any earlier pass's status key
            for k in stages.keys where k.hasPrefix(boostStatusPrefix) { stages[k] = nil }
            extras.stageMs = stages
        }
        extras.setStage(boostStatusKey(timing.boostStatus), ms: 1)
        extras.setStage(boostTermsKey, ms: timing.boostTermCount)
    }

    /// Records the engine's last final pass against `turn` in `store` (no-op without either).
    /// H21 — also writes the turn's context-read facts (`context`): nodes, interrupted flag,
    /// per-source candidate counts.
    static func record(engine: EngineProtocol, turn: TurnID, store: TurnStore? = TurnStore.current,
                       context: TurnContextDiagnostics? = .shared) {
        guard let store else { return }
        let timing = timing(of: engine)
        let entry = context?.current
        guard timing != nil || (entry.map { $0.stats != nil || $0.turnCandidateCounts != nil } ?? false) else { return }
        if let timing, timing.boostStatus != .boosted && timing.boostStatus != .unchanged {
            Log.engine.notice("boost: turn not rescored — \(timing.boostStatus.rawValue), \(timing.boostTermCount) terms")
        }
        store.setExtras(turn) { extras in
            if let timing { apply(timing, to: &extras) }
            if let entry { TurnContextDiagnostics.apply(entry, to: &extras) }
        }
    }
}
