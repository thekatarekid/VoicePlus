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
    }

    /// Records the engine's last final pass against `turn` in `store` (no-op without either).
    static func record(engine: EngineProtocol, turn: TurnID, store: TurnStore? = TurnStore.current) {
        guard let store, let timing = timing(of: engine) else { return }
        store.setExtras(turn) { apply(timing, to: &$0) }
    }
}
