import Shared

/// Registry of built-in pipeline stages. Parallel agents: append ONE line to `builtIn`
/// for your stage and re-read the file before editing.
public enum StageRegistry {
    public static let builtIn: [any PipelineStage] = [
        GatekeeperStage(), // always first; PipelineRunner runs it separately and filters it out of the stage list
        ProsodyPunctuationStage(), // V5 K8 — pauses/pitch → . , ? before the formatters; off until the LibriSpeech-PC gate
        ProseListFormatter(),
        EmailFormatter(),
        ChatFormatter(),
        CodeFormatter(),
        TerminalFormatter(),
        TextReplacementStage(), CasingStage(), TransliterationStage(), // V5 P1/P3/P6 — after ITN (formatters), before cleanup/style; P6 is inert until LANG sets its target
        EntityProtectingStage(StyleStage()), // P1.7 T7 — runs after formatters (style is the last pass, Bet 8); V5 P5 never lowercases a likely entity
        ScriptOutputStage(), // V5 LANG2/G3 — the output script, last of all (IndicXlit/P6 transliteration, danda only for Devanagari); inert until LANG sets it
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
