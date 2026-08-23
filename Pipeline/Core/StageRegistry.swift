import Shared

/// Registry of built-in pipeline stages. Parallel agents: append ONE line to `builtIn`
/// for your stage and re-read the file before editing.
public enum StageRegistry {
    public static let builtIn: [any PipelineStage] = [
        ProseListFormatter(),
        EmailFormatter(),
        ChatFormatter(),
        CodeFormatter(),
    ]

    /// All registered stages, in registration order (used by `PipelineRunner.standard`).
    public static func allStages() -> [any PipelineStage] { builtIn }

    public static func stage(for id: StageID) -> (any PipelineStage)? {
        builtIn.first { $0.id == id }
    }

    /// Formatter stage for a destination register, if one is registered.
    public static func formatter(for register: Utterance.Register) -> (any PipelineStage)? {
        let id: StageID
        switch register {
        case .email: id = .formatterEmail
        case .chat: id = .formatterChat
        case .code: id = .formatterCode
        case .prose, .list: id = .formatterProse
        case .terminal: id = .formatterTerminal
        case .unknown: id = .formatterProse
        }
        return stage(for: id)
    }
}

/// Name used by `PipelineRunner` (P1.7 T9/T10).
public typealias PipelineStageRegistry = StageRegistry
