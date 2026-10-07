import Engine
import Foundation
import Pipeline
import Shared

// MARK: - Context Writer latency · sentence speculation, App half (plan §4.2)
//
// During a hold, the engine's segment stream carries the streaming recogniser's preview text and
// its end-of-utterance marks (`SegmentEvent.preview` / `.endOfUtterance`). Each time a sentence
// closes in the preview, the words since the last close become a chunk and are written in the
// background with the turn's packet (built at key-down; the integrator connects `packetProvider`)
// and the chunks already written before it as EARLIER. Results go into `cache`, which
// `ContextWriterStage.speculation` reads after key-up: the leading chunks that match the final
// heard text are not sent again (`WriterSpeculationCache`).
//
// Rules:
// - Hold (and tap-to-talk) only: a latched session never speculates (`beginTurn(latched:)`, and
//   entering latch cancels the turn). Nothing runs without a packet, a generator, transcribe mode,
//   or for a secure / verbatim destination.
// - One chain per turn: chunk n waits for chunk n-1 (it needs that text as EARLIER); a failed chunk
//   ends the turn's speculation (later chunks could never be leading).
// - The preview may revise its last words, never what was already chunked; if it does, the turn
//   stops speculating (a chunk could no longer be told apart).
// - Counts and reason codes only in the log, never text (Q13). Screen text inside the packet is data
//   for the prompt, never instructions (the prompt says so; `WriterPrompt` sanitises it).
//
// Hit rate, measured (2026-10-07, the owner's 93 recordings ≥ 1 s in Application Support, replayed
// through the real preview and final models by `WriterSpeculationReplayTests`): with the shipping
// EOU 120M preview, 1 % of heard words were reused (12 sentences closed before key-up, 2 matched the
// final pass; the stream's word error rate is the cause). With the polling final-model preview
// (`previewBackend` flag), 15 % overall and 22 % on holds of 6 s or more (8 of 21 long holds). A
// sentence is reused only when preview and final agree word for word (case and punctuation aside)
// and the final text ends a sentence there. Every miss costs one background call, nothing at key-up.

public final class WriterSpeculator: @unchecked Sendable {

    /// Read by `ContextWriterStage.speculation` (the integrator passes this cache to the stage).
    public let cache: WriterSpeculationCache
    /// The turn's packet as built at key-down (heard still empty). Nil → no speculation this turn.
    public var packetProvider: (@Sendable () -> ContextPacket?)?
    /// The same backend the stage calls (cloud or local).
    public var generator: (any WriterGenerating)?
    /// Correction on for the destination app (the integrator reads the setting).
    public var isEnabled: @Sendable () -> Bool = { true }
    /// Optional phonetic matches for a chunk's words (the packet builder's matcher).
    public var vocabulary: (any VocabularyMatching)?
    public var resolveProfile: @Sendable (String) -> DestinationProfile = { Pipeline.DestinationProfiles.resolve(profileID: $0) }
    /// A chunk shorter than this (normalised words) waits and joins the next sentence.
    public var minimumWords = 3
    /// Upper bound on chunks per turn (a very long hold stops speculating, it never queues forever).
    public var maximumChunks = 24
    /// Wall-clock budget for one speculative call.
    public var callDeadline: TimeInterval = 6

    /// Profiles whose text lands verbatim (the stage skips them in a terminal / code register).
    static let verbatimProfiles: Set<String> = ["shell", "code.body"]
    static let log = Log(category: "app.writer")

    private let lock = NSLock()
    private var turn: Turn?
    private var turnCounter = 0
    private weak var segments: SegmentSessionEngine?
    private var events: Task<Void, Never>?

    private struct Turn {
        var id: Int
        var segment: SegmentID?
        var preview = ""
        /// Preview words already chunked, and their normalised pieces (to detect a revision).
        var closedWords = 0
        var closedPieces: [String] = []
        var chunks = 0
        var last: Task<String?, Never>?
        var written = WrittenSoFar()
        var stopped: String?
        var accepting = true
        var plan: Plan?
    }

    /// What every chunk of a turn shares, resolved at its first chunk.
    private struct Plan: @unchecked Sendable {
        var packet: ContextPacket
        var profile: DestinationProfile
        var prefixKey: String
        var generator: any WriterGenerating
    }

    public init(cache: WriterSpeculationCache = WriterSpeculationCache()) {
        self.cache = cache
    }

    deinit { events?.cancel() }

    // MARK: Turn edges (DictationCoordinator)

    /// Key-down of a hold (or tap-to-talk). `segments` is the engine's segment stream, re-read every
    /// turn so an engine swap is followed.
    public func beginTurn(segments: SegmentSessionEngine?, latched: Bool) {
        finishTurn(reason: "superseded")
        cache.endTurn()
        cache.beginTurn()
        guard !latched, isEnabled(), generator != nil, packetProvider != nil, let segments else { return }
        attach(segments)
        lock.withLock {
            turnCounter += 1
            turn = Turn(id: turnCounter)
        }
    }

    /// Key-up: no new chunks. Running calls continue; the stage waits for the ones it can use.
    public func endTurn() {
        finishTurn(reason: nil)
        cache.endTurn()
    }

    /// The turn was cancelled or became latched: nothing it started is needed.
    public func cancelTurn() {
        finishTurn(reason: "cancelled")
        cache.cancelPending()
    }

    private func finishTurn(reason: String?) {
        guard let ended = lock.withLock({ () -> Turn? in
            defer { turn = nil }
            return turn
        }) else { return }
        let why = ended.stopped ?? reason ?? "keyUp"
        Self.log.info("speculator: turn \(ended.id) chunks=\(ended.chunks) end=\(why)")
    }

    // MARK: Segment stream

    private func attach(_ engine: SegmentSessionEngine) {
        let same = lock.withLock { segments === engine && events != nil }
        if same { return }
        events?.cancel()
        lock.withLock { segments = engine }
        let stream = engine.segmentEvents()
        events = Task.detached(priority: .utility) { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
    }

    /// Internal for tests (a scripted stream drives it directly).
    func handle(_ event: SegmentEvent) {
        switch event {
        case .preview(let segment, let spans):
            let sentenceEnd: Int? = lock.withLock {
                guard var t = turn, t.accepting, t.segment == nil || t.segment == segment else { return nil }
                t.segment = segment
                t.preview = spans.map(\.text).joined(separator: " ")
                turn = t
                return Self.closedSentenceEnd(t)
            }
            // A preview that punctuates (the polling final-model backend) closes a sentence once a
            // word follows its full stop; the EOU stream has no punctuation and closes on its marks.
            if let sentenceEnd { closeChunk(segment: segment, upTo: sentenceEnd) }
        case .endOfUtterance(let segment):
            closeChunk(segment: segment, upTo: nil)
        case .closed:
            lock.withLock { turn?.accepting = false }
        case .opened, .rejected:
            break
        }
    }

    // MARK: Chunks

    /// Words through the last sentence end (after the chunked part) that another word follows.
    private static func closedSentenceEnd(_ t: Turn) -> Int? {
        let words = t.preview.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words.count - 1 > t.closedWords else { return nil }
        for j in stride(from: words.count - 2, through: t.closedWords, by: -1)
        where WriterSpeculation.endsSentence(String(words[j])) {
            return j + 1
        }
        return nil
    }

    /// `upTo`: close only the first `upTo` preview words (a punctuated sentence end); nil closes all.
    private func closeChunk(segment: SegmentID, upTo limit: Int?) {
        // Is there a chunk to close? The plan (packet, profile, key) is resolved outside the lock —
        // it calls the integrator's packet provider — and only once a chunk is really ready.
        let probe: (turn: Int, hasPlan: Bool)? = lock.withLock {
            guard var t = turn, t.segment == nil || t.segment == segment else { return nil }
            let ready = nextChunk(&t, limit: limit) != nil
            turn = t
            return ready ? (t.id, t.plan != nil) : nil
        }
        guard let probe else { return }
        let fresh = probe.hasPlan ? nil : makePlan()
        let launch: (chunk: String, plan: Plan, previous: Task<String?, Never>?, written: WrittenSoFar)? = lock.withLock {
            guard var t = turn, t.id == probe.turn else { return nil }
            defer { turn = t }
            if t.plan == nil {
                switch fresh {
                case .success(let plan)?: t.plan = plan
                case .failure(let why)?: t.stopped = why.code; return nil
                case nil: return nil
                }
            }
            guard let plan = t.plan, let next = nextChunk(&t, limit: limit) else { return nil }
            t.closedWords = next.words
            t.closedPieces += next.pieces
            t.chunks += 1
            return (next.chunk, plan, t.last, t.written)
        }
        guard let launch else { return }
        let task = speculate(chunk: launch.chunk, plan: launch.plan, after: launch.previous, written: launch.written)
        lock.withLock { if turn?.id == probe.turn { turn?.last = task } }
        if !cache.add(prefixKey: launch.plan.prefixKey, heard: launch.chunk, task: task) { task.cancel() }
    }

    /// The words the preview added since the last chunk, when they make a chunk. Marks the turn
    /// stopped when the preview revised what was already chunked or the chunk cap is reached.
    private func nextChunk(_ t: inout Turn, limit: Int?) -> (chunk: String, pieces: [String], words: Int)? {
        guard t.accepting, t.stopped == nil else { return nil }
        let all = t.preview.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = Array(all.prefix(limit ?? all.count))
        guard words.count > t.closedWords else { return nil }
        // The streaming preview may revise its newest words, never what was already chunked.
        guard WriterSpeculation.normalized(words[..<t.closedWords].joined(separator: " ")) == t.closedPieces else {
            t.stopped = "revised"
            return nil
        }
        let chunkWords = words[t.closedWords...]
        let pieces = WriterSpeculation.normalized(chunkWords.joined(separator: " "))
        guard pieces.count >= minimumWords else { return nil }   // too short: joins the next sentence
        guard t.chunks < maximumChunks else {
            t.stopped = "maxChunks"
            return nil
        }
        return (chunkWords.joined(separator: " "), pieces, words.count)
    }

    private struct Skip: Error { let code: String }


    /// The turn's packet, profile, key and backend, or why this turn cannot speculate.
    private func makePlan() -> Result<Plan, Skip> {
        guard let generator else { return .failure(Skip(code: "noModel")) }
        guard let packet = packetProvider?() else { return .failure(Skip(code: "noPacket")) }
        guard packet.mode == .transcribe else { return .failure(Skip(code: "mode")) }
        let profile = resolveProfile(packet.destination.profileID)
        if packet.isSecure || profile.isSecure { return .failure(Skip(code: "secure")) }
        if Self.verbatimProfiles.contains(profile.id) { return .failure(Skip(code: "verbatimProfile")) }
        // The key never depends on what was heard (or on EARLIER): render with an empty chunk.
        let parts = WriterPrompt.renderParts(packet: WriterSpeculation.chunkPacket(packet, chunk: ""), profile: profile)
        let key = WriterSpeculation.prefixKey(system: parts.system, stablePrefix: parts.stablePrefix)
        return .success(Plan(packet: packet, profile: profile, prefixKey: key, generator: generator))
    }

    /// One chunk's background call, chained after the previous chunk (whose text is EARLIER).
    private func speculate(chunk: String, plan: Plan, after previous: Task<String?, Never>?,
                           written: WrittenSoFar) -> Task<String?, Never> {
        let vocabulary = self.vocabulary, deadline = callDeadline
        return Task.detached(priority: .utility) {
            if let previous, await previous.value == nil { return nil }
            guard !Task.isCancelled else { return nil }
            let heard = WriterSpeculation.chunkPacket(plan.packet, chunk: chunk).heard
            let matches = vocabulary?.matches(heard: heard, limit: 30) ?? []
            let packet = WriterSpeculation.chunkPacket(plan.packet, chunk: chunk, vocabulary: matches)
            let earlier = written.text
            let parts = WriterPrompt.renderParts(packet: packet, profile: plan.profile, core: nil, budget: .default,
                                                 earlier: earlier.isEmpty ? nil : earlier)
            var stageContext = StageContext()
            packet.write(into: &stageContext)
            stageContext.extra[WriterSpeculation.speculativeKey] = "true"
            let context = stageContext
            let reply = await Self.bounded(deadline) {
                try await plan.generator.write(system: parts.system, user: parts.stablePrefix + parts.tail, context: context)
            }
            guard let reply, !Task.isCancelled else { return nil }
            let cleaned = WriterSpeculation.cleanedReply(reply)
            guard !cleaned.isEmpty else { return nil }
            // EARLIER for the next chunk: what this one will land as (the chunk itself when unchanged).
            written.append(WriterSpeculation.isUnchanged(cleaned) ? chunk : cleaned)
            return cleaned
        }
    }

    /// `op`'s value, or nil on error or after `seconds`. Does not wait for a slow `op`: it is
    /// cancelled and left to wind down (a cancelled turn cancels it too).
    static func bounded(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> String) async -> String? {
        let work = CancellableWork()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let once = FirstPast()
                work.start(Task {
                    let value = try? await op()
                    if once.take() { continuation.resume(returning: value) }
                })
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                    if once.take() {
                        work.cancel()
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            work.cancel()
        }
    }

    /// Test hook: the current turn's chunk count and stop reason.
    var currentTurn: (chunks: Int, stopped: String?)? {
        lock.withLock { turn.map { ($0.chunks, $0.stopped) } }
    }
}

/// A task that may be cancelled before it is started (the cancel then applies on start).
final class CancellableWork: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false
    func start(_ t: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in task = t; return cancelled }
        if cancelNow { t.cancel() }
    }
    func cancel() {
        let t = lock.withLock { () -> Task<Void, Never>? in cancelled = true; return task }
        t?.cancel()
    }
}

/// The text written so far in a turn, in chunk order (each chunk appends after the previous one's
/// call finished, so the order is the chain's).
final class WrittenSoFar: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    func append(_ s: String) { lock.withLock { parts.append(s) } }
    var text: String { lock.withLock { parts.joined(separator: " ") } }
}
