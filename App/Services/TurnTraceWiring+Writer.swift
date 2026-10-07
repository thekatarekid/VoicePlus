import Foundation
import Pipeline
import Shared

// Context Writer — "Why did it write that?" for the writer. `TurnTraceWiring.traced` records every
// stage's before → after (the writer's row is titled "Context Writer", `StageDiff.title`); this adds
// the writer's outcome code (`accepted`, `partiallyReverted:n`, `timeout`, `skipped:…`) as the row's
// note. A run with Correction off passes through the gate untouched and notes nothing.
extension TurnTraceWiring {
    /// `stages` with every writer gate's stage noting its outcome on `recorder`.
    public static func tracingWriter(_ stages: [any PipelineStage], recorder: TurnTraceRecorder = .shared) -> [any PipelineStage] {
        stages.map { stage in
            guard var gate = stage as? WriterGateStage else { return stage }
            gate.inner.trace = recorder
            return gate
        }
    }
}
