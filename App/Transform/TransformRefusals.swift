import Pipeline
import Providers

// H14 — the on-device route's refusals reach the executor as `TransformError.refused(message)`:
// the edit stops with a plain message instead of falling to the rules (or truncating the text).
extension LocalLLMBudget.Refusal: TransformRefusing {
    public var refusalMessage: String { message }
}

extension LocalLLMRefusal: TransformRefusing {
    public var refusalMessage: String { message }
}
