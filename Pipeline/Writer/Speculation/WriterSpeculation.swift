import Foundation
import Shared

// MARK: - Context Writer latency · sentence speculation (plan §4.2)
//
// While the user is still holding the key, every sentence the streaming recogniser closes (its EOU
// marks) is corrected in the background with the turn's packet and the sentences already written
// before it (`App/Services/WriterSpeculator`). After key-up, `ContextWriterStage` asks this cache for
// the *leading* sentences of the final heard text: those that match are not sent again; only the
// uncached tail goes to the model, with the cached sentences given as EARLIER context, and the two
// are stitched. No hit (or a mismatch anywhere before the tail) is exactly today's one full call.
//
// Keys are (prefix key, normalised words). The prefix key hashes `system + stablePrefix`
// (`WriterPrompt.renderParts`): if anything the model reads besides the heard text changed between
// the speculative call and the final one (a new destination, a refreshed thread), nothing matches.
// The words are normalised (case, punctuation, apostrophes) because the streaming preview model
// writes lowercase without punctuation while the final pass writes both; everything else must be the
// same word for word. A cached sentence is used only where the final text ends a sentence (or ends),
// so a stitched answer never joins two halves of one sentence.
//
// What can differ, honestly: the preview recogniser is a smaller streaming model, so its words are
// not always the final pass's words; each such sentence (and everything after it) is a miss and
// costs nothing but the background call. Measured on the owner's recordings: 1 % of words reused
// with the EOU 120M preview, 22 % on long holds with the polling final-model preview (see
// `App/Services/WriterSpeculator`). The speculative call also sees no per-word confidences or
// decoder alternates (the preview has none); the final call for a miss does.
//
// Nothing here logs text: hit / miss counts and reason codes only.

/// The leading part of a dictation already written by speculative calls.
public struct WriterSpeculationHit: Sendable, Equatable {
    /// Heard words covered, counted in `WriterSpeculation.heardWords(_:)` units, from the start.
    public var words: Int
    /// The written text for those words, chunks joined in order.
    public var written: String
    /// Cached chunks used.
    public var chunks: Int

    public init(words: Int, written: String, chunks: Int) {
        self.words = words
        self.written = written
        self.chunks = chunks
    }
}

/// How the stage used speculation for one utterance (reason codes and counts only).
public struct WriterSpeculationUse: Sendable, Equatable {
    public enum Call: String, Sendable, Equatable {
        /// Every heard word was cached: no model call.
        case none
        /// Only the uncached tail went to the model.
        case tail
        /// No usable leading chunk: one full call.
        case full
    }
    public var call: Call
    public var chunksUsed: Int
    public var wordsCovered: Int
    public var wordsHeard: Int

    public init(call: Call, chunksUsed: Int, wordsCovered: Int, wordsHeard: Int) {
        self.call = call
        self.chunksUsed = chunksUsed
        self.wordsCovered = wordsCovered
        self.wordsHeard = wordsHeard
    }
}

/// The stage's view of the speculation cache (`ContextWriterStage.speculation`).
public protocol WriterSpeculating: Sendable {
    /// The cached leading chunks for these heard words under this prefix key, or nil. Waits for a
    /// matching chunk whose speculative call is still running (the caller's deadline race bounds
    /// the wait); chunks that cannot be used are cancelled.
    func leadingHit(prefixKey: String, heard: [String]) async -> WriterSpeculationHit?
    /// What the stage did with it, for the per-turn counts.
    func noteUse(_ use: WriterSpeculationUse)
}

public enum WriterSpeculation {

    /// `StageContext.extra` key set to "true" on a speculative call's context, so a backend wrapper
    /// can tell it from the final call (logging, priority).
    public static let speculativeKey = "writer.speculative"

    /// The heard words the stage matches against: the packet's per-word list, or the raw text split
    /// on whitespace when the builder sent no words.
    public static func heardWords(_ heard: ContextPacket.Heard) -> [String] {
        heard.words.isEmpty ? heard.raw.split(whereSeparator: \.isWhitespace).map(String.init) : heard.words.map(\.text)
    }

    /// Lowercased word pieces with punctuation removed: letters, digits and inner apostrophes kept;
    /// any other character separates (so "follow-up" and "follow up" agree). Curly apostrophes are
    /// straight.
    public static func normalized(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if ch == "'" || ch == "\u{2019}" || ch == "\u{2018}" {
                current.append("'")
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// True when the word closes a sentence (`.`, `?`, `!`, `…`, optionally followed by a quote or
    /// bracket).
    public static func endsSentence(_ word: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "»"]
        guard let last = word.last(where: { !closers.contains($0) }) else { return false }
        return last == "." || last == "?" || last == "!" || last == "…"
    }

    /// The prefix key: a 64-bit FNV-1a of `system`, a separator and `stablePrefix`, in hex, with the
    /// lengths (a collision would also have to match both lengths).
    public static func prefixKey(system: String, stablePrefix: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
            for b in bytes { hash ^= UInt64(b); hash &*= 0x100000001b3 }
        }
        mix(system.utf8)
        mix([0x1E])
        mix(stablePrefix.utf8)
        return String(hash, radix: 16) + "-\(system.utf8.count)-\(stablePrefix.utf8.count)"
    }

    /// A model reply as the stage reads it: uncertainty marks removed, trimmed.
    public static func cleanedReply(_ reply: String) -> String {
        CleanupGuard.unmark(reply).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the reply is the reserved "keep the heard text" answer.
    public static func isUnchanged(_ reply: String) -> Bool {
        cleanedReply(reply).caseInsensitiveCompare(WriterPrompt.unchangedToken) == .orderedSame
    }

    /// The packet for a speculative call on one preview chunk: the chunk is HEARD (no confidences or
    /// alternates: the preview recogniser has none), with the vocabulary matched against it. Every
    /// key-down field is the turn's own, so the stable prefix (and the prefix key) is the final call's.
    public static func chunkPacket(_ packet: ContextPacket, chunk: String,
                                   vocabulary: [ContextPacket.VocabularyMatch] = []) -> ContextPacket {
        var p = packet
        let words = chunk.split(whereSeparator: \.isWhitespace).map { ContextPacket.HeardWord(text: String($0), confidence: 1) }
        p.heard = ContextPacket.Heard(raw: words.map(\.text).joined(separator: " "), words: words)
        p.vocabulary = vocabulary
        return p
    }

    /// `head` and `tail` joined by one space (either may be empty).
    public static func stitch(_ head: String, _ tail: String) -> String {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return t }
        if t.isEmpty { return h }
        return h + " " + t
    }

    /// The packet for the uncached tail: the heard words after the first `covered`, the raw text
    /// rebuilt from them, the booster's whole-utterance evidence dropped (it cannot be split), and
    /// only the vocabulary matches whose heard words occur in the tail.
    public static func tailPacket(_ packet: ContextPacket, droppingFirst covered: Int) -> ContextPacket {
        var p = packet
        let all = heardWords(packet.heard)
        let n = min(max(0, covered), all.count)
        let rest = Array(all[n...])
        let words = packet.heard.words.isEmpty ? [] : Array(packet.heard.words[n...])
        p.heard = ContextPacket.Heard(raw: rest.joined(separator: " "), words: words, boosted: nil)
        let tail = normalized(rest.joined(separator: " "))
        p.vocabulary = packet.vocabulary.filter { m in
            let h = normalized(m.heard)
            return !h.isEmpty && contains(tail, h)
        }
        return p
    }

    static func contains(_ words: [String], _ run: [String]) -> Bool {
        guard run.count <= words.count else { return false }
        for i in 0...(words.count - run.count) where Array(words[i..<i + run.count]) == run { return true }
        return false
    }

    // MARK: Matching

    /// One chunk the matcher may use at a position: its normalised words and its key.
    struct Candidate {
        var key: String
        var words: [String]
    }

    /// Leading chunks of `heard` (in order) whose normalised words match a candidate exactly and end
    /// where the heard text ends a sentence (or ends). Returns, per matched chunk, the key and the
    /// heard-word range it covers. Longest candidate first at each position.
    static func leadingMatches(heard: [String], candidates: [Candidate]) -> [(key: String, range: Range<Int>)] {
        // Normalised pieces with the heard word each came from.
        var pieces: [String] = []
        var owner: [Int] = []
        for (i, word) in heard.enumerated() {
            for piece in normalized(word) {
                pieces.append(piece)
                owner.append(i)
            }
        }
        let sorted = candidates.filter { !$0.words.isEmpty }.sorted { $0.words.count > $1.words.count }
        var out: [(key: String, range: Range<Int>)] = []
        var at = 0          // piece index
        var wordAt = 0      // heard-word index the next chunk starts at
        while at < pieces.count {
            var matched: (Candidate, Int)?
            for c in sorted where at + c.words.count <= pieces.count {
                guard Array(pieces[at..<at + c.words.count]) == c.words else { continue }
                let end = at + c.words.count
                // The chunk must end on a heard-word boundary…
                if end < pieces.count, owner[end] == owner[end - 1] { continue }
                // …and cover the punctuation-only words that follow it.
                let lastWord = owner[end - 1]
                let wordEnd = end < pieces.count ? owner[end] : heard.count
                // …where the heard text ends a sentence, or ends.
                let closes = wordEnd == heard.count || (lastWord..<wordEnd).contains { endsSentence(heard[$0]) }
                guard closes else { continue }
                matched = (c, wordEnd)
                break
            }
            guard let (c, wordEnd) = matched else { break }
            out.append((c.key, wordAt..<wordEnd))
            at += c.words.count
            wordAt = wordEnd
        }
        return out
    }
}

/// The per-turn speculation cache, shared by the App's speculator (writes) and the stage (reads).
/// Thread-safe; entries are tasks so the stage can wait for a matching call still running.
public final class WriterSpeculationCache: WriterSpeculating, @unchecked Sendable {

    /// Per-turn counts, for the turn's log line (no text).
    public struct Counts: Sendable, Equatable {
        public var chunks = 0
        public var ready = 0
        public var failed = 0
        public var cancelled = 0
        public var lastUse: WriterSpeculationUse?
        public init() {}
    }

    private enum State {
        case pending(Task<String?, Never>)
        case ready(String)
        case failed
    }
    private struct Entry {
        var prefixKey: String
        var words: [String]
        var state: State
        var turn: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var turn = 0
    /// The newest turn whose key went up: only its (and older) unused calls may be cancelled by a
    /// lookup, never those of a hold that is still being spoken.
    private var lastEnded = 0
    private var counts = Counts()
    private let log = Log(category: "pipeline.writer")

    public init() {}

    static func key(prefixKey: String, words: [String]) -> String {
        prefixKey + "|" + words.joined(separator: " ")
    }

    /// A new dictation: entries older than the previous turn are dropped (and cancelled), the
    /// counts restart. The previous turn's entries stay until the next `beginTurn`, so a stage
    /// still finishing that turn can read them.
    public func beginTurn() {
        let stale: [Task<String?, Never>] = lock.withLock {
            turn += 1
            counts = Counts()
            let old = entries.filter { $0.value.turn < turn - 1 }
            for key in old.keys { entries[key] = nil }
            return old.values.compactMap { if case .pending(let t) = $0.state { return t } else { return nil } }
        }
        stale.forEach { $0.cancel() }
    }

    /// Key-up: this turn takes no new chunks; a lookup may now cancel what it cannot use.
    public func endTurn() {
        lock.withLock { lastEnded = turn }
    }

    /// Cancels this turn's running speculative calls (the turn was cancelled or left hold mode).
    public func cancelPending() {
        let running: [Task<String?, Never>] = lock.withLock {
            var out: [Task<String?, Never>] = []
            for (key, e) in entries where e.turn == turn {
                if case .pending(let t) = e.state { out.append(t); entries[key]?.state = .failed; counts.cancelled += 1 }
            }
            return out
        }
        running.forEach { $0.cancel() }
    }

    /// Registers a speculative call for `heard` (the chunk's text). The task's value is the written
    /// text, the reserved `UNCHANGED`, or nil on failure. Returns false when that chunk is already
    /// cached under this prefix (the task is then not kept; the caller should cancel it).
    @discardableResult
    public func add(prefixKey: String, heard: String, task: Task<String?, Never>) -> Bool {
        let words = WriterSpeculation.normalized(heard)
        guard !words.isEmpty else { return false }
        let key = Self.key(prefixKey: prefixKey, words: words)
        let added: Bool = lock.withLock {
            if let existing = entries[key] {
                guard case .failed = existing.state else { return false }
            }
            entries[key] = Entry(prefixKey: prefixKey, words: words, state: .pending(task), turn: turn)
            counts.chunks += 1
            return true
        }
        guard added else { return false }
        Task { [weak self] in
            let value = await task.value
            self?.settle(key: key, task: task, value: value)
        }
        return true
    }

    /// Stores a finished chunk directly (tests, or a caller that already has the text).
    public func store(prefixKey: String, heard: String, written: String) {
        let words = WriterSpeculation.normalized(heard)
        guard !words.isEmpty else { return }
        lock.withLock {
            entries[Self.key(prefixKey: prefixKey, words: words)] = Entry(prefixKey: prefixKey, words: words,
                                                                           state: .ready(written), turn: turn)
            counts.chunks += 1
            counts.ready += 1
        }
    }

    private func settle(key: String, task: Task<String?, Never>, value: String?) {
        lock.withLock {
            guard let e = entries[key], case .pending(let t) = e.state, t == task else { return }
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entries[key]?.state = .ready(value)
                if e.turn == turn { counts.ready += 1 }
            } else {
                entries[key]?.state = .failed
                if e.turn == turn { counts.failed += 1 }
            }
        }
    }

    public var currentCounts: Counts { lock.withLock { counts } }

    // MARK: WriterSpeculating

    public func leadingHit(prefixKey: String, heard: [String]) async -> WriterSpeculationHit? {
        let (matches, states, unused): ([(key: String, range: Range<Int>)], [String: State], [Task<String?, Never>]) = lock.withLock {
            let candidates = entries.filter { $0.value.prefixKey == prefixKey }
                .map { WriterSpeculation.Candidate(key: $0.key, words: $0.value.words) }
            let matches = WriterSpeculation.leadingMatches(heard: heard, candidates: candidates)
            let used = Set(matches.map(\.key))
            var states: [String: State] = [:]
            for m in matches { states[m.key] = entries[m.key]?.state }
            // Running calls this utterance will never use: stop them (a local engine runs one call
            // at a time, and the final call is about to queue).
            var unused: [Task<String?, Never>] = []
            for (key, e) in entries where !used.contains(key) && e.turn <= lastEnded {
                if case .pending(let t) = e.state { unused.append(t); entries[key]?.state = .failed; counts.cancelled += 1 }
            }
            return (matches, states, unused)
        }
        unused.forEach { $0.cancel() }
        var written: [String] = []
        var covered = 0
        for m in matches {
            var text: String?
            switch states[m.key] {
            case .ready(let t)?: text = t
            case .pending(let task)?: text = await task.value
            case .failed?, nil: text = nil
            }
            guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { break }
            // The model kept that sentence as heard: the final pass's own words (cased, punctuated)
            // are better than the preview's.
            if t.caseInsensitiveCompare(WriterPrompt.unchangedToken) == .orderedSame {
                written.append(heard[m.range].joined(separator: " "))
            } else {
                written.append(t)
            }
            covered = m.range.upperBound
        }
        guard !written.isEmpty else { return nil }
        return WriterSpeculationHit(words: covered, written: written.joined(separator: " "), chunks: written.count)
    }

    public func noteUse(_ use: WriterSpeculationUse) {
        let c: Counts = lock.withLock { counts.lastUse = use; return counts }
        guard c.chunks > 0 || use.call != .full else { return }   // nothing was speculated this turn
        log.info("speculation: chunks=\(c.chunks) ready=\(c.ready) failed=\(c.failed) cancelled=\(c.cancelled) "
                 + "used=\(use.chunksUsed) words=\(use.wordsCovered)/\(use.wordsHeard) call=\(use.call.rawValue)")
    }
}
