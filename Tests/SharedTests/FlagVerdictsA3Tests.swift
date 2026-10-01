import Testing
@testable import Shared

/// A3 — every flag V5 §X20 found switched off carries a verdict and a written kill criterion.
@Suite("Flag verdicts (A3)")
struct FlagVerdictsA3Tests {
    @Test func x20ListsTheRemainingFlags() {
        // V5 A1/B1 deleted `contextBiasing` (replaced by CTC boosting); five remain.
        #expect(FeatureFlag.x20.map(\.id) == ["dualPath", "cloudASR", "directedSpeech", "previewBackend", "qwenRefinement"])
        for f in FeatureFlag.x20 { #expect(FeatureFlag.all.contains(f), "\(f.id) is a known flag") }
    }

    @Test func eachHasAVerdictAndAKillCriterion() {
        for f in FeatureFlag.x20 {
            #expect(f.description.contains("Verdict (A3)"), "\(f.id)")
            #expect(f.description.contains("Kill:") || f.description.contains("delete"), "\(f.id)")
        }
    }

    @Test func noVerdictFlipsADefaultWithoutMeasurement() {
        // V1 public-set numbers are not in yet; every X20 flag stays off until they are.
        for f in FeatureFlag.x20 { #expect(!f.defaultOn, "\(f.id)") }
    }
}
