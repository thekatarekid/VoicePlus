import Foundation

// MARK: - Context Writer latency · the local prompt-prefix cache (plan §4.1)
//
// The writer's prompt is `system + stable prefix` (everything the packet builder knew at key-down)
// followed by a short per-utterance tail (`WriterPrompt.renderParts`). Prefilling ~900 tokens again
// for every call is most of a local call's cost, so `LlamaCppEngine` keeps what is already in its
// KV memory and only decodes what changed:
//
//   seq 0 (working)    — the last call's tokens (prompt + generated), in order;
//   seq 1 (checkpoint) — a prefix kept for reuse: the prewarmed `system + stable prefix`, or the
//                        system turn of the last prompt. In a unified KV cache the copy shares cells.
//
// For a new prompt, in order of preference:
//   extend   — working is a prefix of the prompt: decode only the rest;
//   trim     — working shares a prefix: cut the diverging tail (`llama_memory_seq_rm`) and decode
//              from there. Recurrent and hybrid models (Qwen3.5 is Gated DeltaNet + attention)
//              cannot cut a sequence part-way; the memory says no and nothing changes;
//   restore  — the checkpoint is a prefix of the prompt: copy it to working, decode the rest;
//   cold     — clear working, decode everything.
// At least one prompt token is always decoded for a generation (its logits seed sampling).
//
// The bookkeeping lives here, apart from llama, so tests drive it with a scripted memory (divergence
// math, invalidation on unload). Token ids are `Int32` (`llama_token`). Nothing here sees text.

/// What `PromptPrefixCache` needs from the KV memory. The real one is llama's memory over seq 0 and
/// seq 1 (`LlamaCppEngine`); tests script it.
public protocol PromptPrefixMemory: AnyObject {
    /// Removes positions `[from, ∞)` of the working sequence. False when the memory cannot cut a
    /// sequence part-way (recurrent state); nothing is changed then.
    func trimWorking(from position: Int) -> Bool
    /// Empties the working sequence (always possible).
    func clearWorking()
    /// The checkpoint becomes a copy of the working sequence.
    func saveCheckpoint()
    /// The working sequence becomes a copy of the checkpoint.
    func restoreCheckpoint()
    func clearCheckpoint()
    /// Empties everything (a failed decode, a reloaded model).
    func clearAll()
    /// Decodes `tokens` appended to the working sequence. Throws on a decode failure.
    func decode(_ tokens: ArraySlice<Int32>) throws
    /// Positions the working sequence holds, as the memory sees it (a consistency check).
    func workingLength() -> Int
}

public struct PromptPrefixCache: Sendable, Equatable {
    /// How the last `prepare` reused memory. `reused` tokens were not decoded again.
    public enum Reuse: Equatable, Sendable {
        case cold
        case extend(reused: Int)
        case trim(reused: Int)
        case restore(reused: Int)

        public var reused: Int {
            switch self {
            case .cold: return 0
            case .extend(let n), .trim(let n), .restore(let n): return n
            }
        }
        /// Reason code for logs (counts only, never text).
        public var code: String {
            switch self {
            case .cold: return "cold"
            case .extend: return "extend"
            case .trim: return "trim"
            case .restore: return "restore"
            }
        }
    }

    /// The decode stopped between two chunks because `interrupt` threw; what was decoded is kept.
    public struct Interrupted: Error, Equatable {}

    /// Tokens in the working sequence (seq 0), in order.
    public private(set) var working: [Int32] = []
    /// Tokens in the checkpoint sequence (seq 1).
    public private(set) var checkpoint: [Int32] = []
    /// Leading working positions whose cells are the checkpoint's own (copied, not decoded twice).
    public private(set) var shared = 0

    public init() {}

    /// Cells in use: the checkpoint plus the part of working it does not share.
    public var occupied: Int { checkpoint.count + working.count - shared }

    /// Length of the common prefix of `a` and `b`.
    public static func commonPrefix(_ a: [Int32], _ b: [Int32]) -> Int {
        var i = 0
        let n = min(a.count, b.count)
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    /// Brings the working sequence to exactly `tokens`, decoded, reusing what memory holds.
    ///
    /// - `needsLogits`: a generation must decode at least the last prompt token; a prewarm need not.
    /// - `checkpointAt`: save the checkpoint at this position on the way (the end of the prewarmed
    ///   prefix, or the end of the system turn), unless the checkpoint already covers it.
    /// - `reserve`: cells to keep free after the prompt (the generated tokens). A checkpoint that the
    ///   prompt does not use is dropped when it would not leave room.
    /// - `interrupt`: called before every chunk; throwing stops the prefill with what was decoded kept.
    @discardableResult
    public mutating func prepare(_ tokens: [Int32], needsLogits: Bool, memory: PromptPrefixMemory, chunk: Int,
                                 checkpointAt: Int?, reserve: Int = 0, capacity: Int = .max,
                                 interrupt: () throws -> Void = {}) throws -> Reuse {
        if memory.workingLength() != working.count {
            // Memory and bookkeeping disagree (should not happen): start over rather than decode
            // at the wrong positions.
            invalidate(memory)
        }
        let maxReuse = max(0, needsLogits ? tokens.count - 1 : tokens.count)
        var reuse = Reuse.cold

        let w = min(Self.commonPrefix(working, tokens), maxReuse)
        let usable = !checkpoint.isEmpty && checkpoint.count <= maxReuse
            && Self.commonPrefix(checkpoint, tokens) == checkpoint.count
        let c = usable ? checkpoint.count : 0
        func restore() {
            memory.restoreCheckpoint()
            working = checkpoint
            shared = checkpoint.count
            reuse = .restore(reused: c)
        }
        if w > 0, w == working.count, w >= c {
            reuse = .extend(reused: w)
        } else if c > w {
            restore()
        } else if w > 0, memory.trimWorking(from: w) {
            working.removeSubrange(w...)
            shared = min(shared, w)
            reuse = .trim(reused: w)
        } else if c > 0 {
            restore()
        } else if !working.isEmpty {
            memory.clearWorking()
            working = []
            shared = 0
        }

        // Room: a checkpoint this prompt does not build on is the first thing to go.
        let toDecode = tokens.count - working.count
        if checkpoint.count - shared + working.count + toDecode + reserve > capacity, shared == 0, !checkpoint.isEmpty {
            memory.clearCheckpoint()
            checkpoint = []
        }

        // Where to save a checkpoint on the way: only when the decode crosses that position and the
        // checkpoint does not already hold this prompt's prefix up to there.
        var saveAt: Int?
        if let p = checkpointAt, p > working.count, p <= tokens.count {
            let covers = !checkpoint.isEmpty && Self.commonPrefix(checkpoint, tokens) == checkpoint.count
                && checkpoint.count >= p
            if !covers { saveAt = p }
        }

        let step = max(1, chunk)
        while working.count < tokens.count {
            try interrupt()
            var end = min(working.count + step, tokens.count)
            if let p = saveAt, p > working.count, p < end { end = p }
            do {
                try memory.decode(tokens[working.count..<end])
            } catch {
                invalidate(memory)
                throw error
            }
            working.append(contentsOf: tokens[working.count..<end])
            if let p = saveAt, working.count == p {
                memory.saveCheckpoint()
                checkpoint = working
                shared = working.count
                saveAt = nil
            }
        }
        return reuse
    }

    /// Records tokens decoded outside `prepare` (the generated ones), in order.
    public mutating func appendDecoded(_ tokens: [Int32]) {
        working.append(contentsOf: tokens)
    }

    /// Forgets everything and empties the memory (a failed decode).
    public mutating func invalidate(_ memory: PromptPrefixMemory) {
        memory.clearAll()
        reset()
    }

    /// Forgets everything without touching memory (the context was freed or is new).
    public mutating func reset() {
        working = []
        checkpoint = []
        shared = 0
    }
}
