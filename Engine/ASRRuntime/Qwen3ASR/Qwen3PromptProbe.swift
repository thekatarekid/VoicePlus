// VoicePlus original (task R5.1). A diagnosis harness for the Qwen3-ASR prompt.
//
// The port hands the model one prompt and prints one string, and when the string comes back in the
// wrong script there is nothing in between to look at. This type is that middle: it loads the
// weights once and runs a named prompt variant, returning the prompt ids, the *raw* generated ids
// (header and all) and the decoded text, so the failure can be attributed to a specific part of
// the prompt instead of guessed at.
//
// Kept out of the ported files so the port stays a faithful copy.
import CoreML
import Foundation

struct Qwen3PromptProbe {
    let manager: Qwen3AsrManager
    let tokenizer: Qwen3ContextTokenizer
    let vocabulary: [Int: String]

    static func load(folder: URL, computeUnits: MLComputeUnits = .all) async throws -> Qwen3PromptProbe {
        let manager = Qwen3AsrManager()
        try await manager.loadModels(from: folder, computeUnits: computeUnits)
        let tokenizer = try Qwen3ContextTokenizer(
            vocabularyFile: folder.appendingPathComponent("vocab.json")
        )
        return Qwen3PromptProbe(
            manager: manager, tokenizer: tokenizer, vocabulary: await manager.vocabularyTable
        )
    }

    func encode(_ text: String) -> [Int32] { tokenizer.encode(text, limit: 256) }

    struct Result {
        var text: String
        var prompt: [Int32]
        var generated: [Int]
    }

    /// Run one prompt variant. `systemText` rides in the system message; `taskLanguage` uses the
    /// port's own hard-coded task table; `assistantPrefix` is written into the assistant turn
    /// before generation starts (forced decoder ids).
    func run(
        samples: [Float],
        systemText: String = "",
        taskLanguage: Qwen3AsrConfig.Language? = nil,
        assistantPrefix: [Int32] = [],
        maxNewTokens: Int = 128
    ) async throws -> Result {
        let text = try await manager.transcribe(
            audioSamples: samples,
            language: taskLanguage,
            contextTokens: systemText.isEmpty ? [] : encode(systemText),
            assistantPrefixTokens: assistantPrefix,
            maxNewTokens: maxNewTokens
        )
        return Result(
            text: text,
            prompt: await manager.lastPromptTokenIds,
            generated: await manager.lastGeneratedTokenIds
        )
    }

    /// `id:piece` for each id, with specials (no vocabulary entry) shown as `id:<special>`.
    func describe(_ ids: [Int]) -> String {
        ids.map { id in
            if let piece = vocabulary[id] { return "\(id):\(piece)" }
            return "\(id):<special>"
        }.joined(separator: " ")
    }

    func describe(_ ids: [Int32]) -> String { describe(ids.map(Int.init)) }
}
