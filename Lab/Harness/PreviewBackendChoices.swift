import Foundation
import Shared

/// R1.5 — the two preview candidates as Lab configurations.
///
/// The preview is what the user watches while speaking, and the two candidates trade accuracy
/// against how soon the first word appears: the Parakeet Realtime **EOU 120M** stream (today's
/// default) and **polling the final TDT model** over the accumulated buffer. Both stay in the build;
/// the `previewBackend` flag picks one, and these choices let the panel and
/// `lab compare --flag previewBackend` run either.
///
/// The panel offers them unselected, so the default run stays the biasing comparison it has always
/// been. The scores here come from the Lab's own transcribers — the real preview latency and WER
/// numbers behind the decision come from `previewCandidateComparison` in `EngineTests`, which needs
/// the model weights and the real-room WAVs and so cannot live in this target.
public extension LabConfigChoice {

    /// One row per candidate: flag off (EOU stream, the measured default) and flag on (polling).
    static func previewBackendChoices(transcriber: String = "perfect",
                                      stages: [String] = [],
                                      selected: Bool = false) -> [LabConfigChoice] {
        [
            LabConfigChoice(config: LabConfig(name: "preview EOU 120M", transcriber: transcriber, stages: stages,
                                              flags: [FeatureFlag.previewBackend.id: false]), selected: selected),
            LabConfigChoice(config: LabConfig(name: "preview polling final", transcriber: transcriber, stages: stages,
                                              flags: [FeatureFlag.previewBackend.id: true]), selected: selected),
        ]
    }
}
