import Testing
import Foundation
import Engine
import Shared
@testable import VoicePlusApp

/// N6 verify — the final pass's stage ms and pre-boost raw text reach the turn_records extras.
@Suite struct FinalPassTimingRecorderN6Tests {
    @Test func appliesStageMsAndPreBoostText() {
        let timing = FinalPassTiming(recogniseMs: 212.4, alternativesMs: 30, modelWaitMs: 0.2, rescoreMs: 1500.6,
                                     totalMs: 1745, boostStatus: .timedOut, rawPreBoostText: "ship to kubernetes",
                                     finalText: "ship to kubernetes")
        var extras = TurnRecordExtras()
        FinalPassTimingRecorder.apply(timing, to: &extras)
        #expect(extras.preBoostRawText == "ship to kubernetes")
        #expect(extras.stageMs?[FinalPassTimingRecorder.recogniseStage] == 212)
        #expect(extras.stageMs?[FinalPassTimingRecorder.rescoreStage] == 1501)
        #expect(extras.stageMs?[FinalPassTimingRecorder.modelWaitStage] == 0)
        #expect(extras.stageMs?[FinalPassTimingRecorder.totalStage] == 1745)
    }

    @Test func explicitStagesSurviveResolution() {
        var extras = TurnRecordExtras()
        FinalPassTimingRecorder.apply(FinalPassTiming(recogniseMs: 100, totalMs: 120, boostStatus: .boosted,
                                                      rawPreBoostText: "a", finalText: "b"), to: &extras)
        let resolved = extras.resolved(for: TurnRecord(turnID: TurnID(), finalText: "b"))
        #expect(resolved.stageMs?[FinalPassTimingRecorder.recogniseStage] == 100)
        #expect(resolved.preBoostRawText == "a")
    }
}
