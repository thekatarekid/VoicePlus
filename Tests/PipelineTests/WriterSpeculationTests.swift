import Foundation
import Shared
import Testing
@testable import Pipeline

// Context Writer latency (plan §4.2) — sentence speculation: the cache's matching (normalised words,
// sentence boundaries, leading chunks only), stitching through `ContextWriterStage`, the full-call
// fallback on a mismatch, and invalidation when anything in the stable prefix changed.

private let chat = DestinationProfiles.resolve(profileID: "chat.message")

/// "Sending the deck now. Call me after lunch." as the final pass wrote it, one span per word.
private func spans(_ text: String = "Sending the deck now. Call me after lunch.") -> [TranscriptSpan] {
    text.split(separator: " ").enumerated().map { i, w in
        TranscriptSpan(text: String(w), confidence: 0.9, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
    }
}

private func packet(_ s: [TranscriptSpan], textBefore: String = "sounds good,") -> ContextPacket {
    let words = s.map { ContextPacket.HeardWord(text: $0.text, confidence: $0.confidence) }
    return ContextPacket(destination: .init(profileID: "chat.message", appName: "Slack", surfaceKind: "chatComposer",
                                            fields: ["channel": "#eng"]),
                         textBefore: textBefore, thread: [.init(author: "Rahul", text: "deck before standup?")],
                         heard: .init(raw: s.renderedText, words: words))
}

/// The key the speculator computes at key-down (no heard text yet).
private func key(_ p: ContextPacket) -> String {
    let parts = WriterPrompt.renderParts(packet: WriterSpeculation.chunkPacket(p, chunk: ""), profile: chat)
    return WriterSpeculation.prefixKey(system: parts.system, stablePrefix: parts.stablePrefix)
}

private func context(_ p: ContextPacket) -> StageContext {
    var c = StageContext(register: .chat)
    p.write(into: &c)
    return c
}

private func stage(_ gen: ScriptedWriter, cache: WriterSpeculationCache) -> ContextWriterStage {
    var s = ContextWriterStage(generator: gen, outputGuard: { WriterGuard(phonetic: WriterGuardTests.stub) })
    s.speculation = cache
    return s
}

/// A speculative call that records whether it was cancelled.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite struct WriterSpeculationTests {

    // MARK: Normalisation and keys

    @Test func normalisationIgnoresCasePunctuationAndHyphens() {
        #expect(WriterSpeculation.normalized("Follow-up, don’t! It's 5:30.") == ["follow", "up", "don't", "it's", "5", "30"])
        #expect(WriterSpeculation.normalized("follow up dont") != WriterSpeculation.normalized("follow-up don't"))
        #expect(WriterSpeculation.normalized("  ...  ") == [])
    }

    @Test func sentenceEnds() {
        for w in ["now.", "really?", "go!", "wait…", "\"done.\"", "(ok.)"] { #expect(WriterSpeculation.endsSentence(w), Comment(rawValue: w)) }
        for w in ["now", "now,", "e.g", "Mr", "\""] { #expect(!WriterSpeculation.endsSentence(w), Comment(rawValue: w)) }
    }

    @Test func prefixKeyFollowsTheStablePrefixOnly() {
        let p = packet(spans())
        var heardChanged = p
        heardChanged.heard = .init(raw: "other words")
        heardChanged.vocabulary = [.init(term: "Deck", spokenForm: "deck", heard: "deck", score: 0.5, source: "screen")]
        #expect(key(p) == key(heardChanged))
        // The stage's key (from the final packet) is the speculator's (from the key-down packet).
        let final = WriterPrompt.renderParts(packet: p, profile: chat)
        #expect(WriterSpeculation.prefixKey(system: final.system, stablePrefix: final.stablePrefix) == key(p))
        #expect(key(packet(spans(), textBefore: "different")) != key(p))
        var persona = p
        persona.persona = "Terse."
        #expect(key(persona) != key(p))
    }

    // MARK: Matching

    @Test func leadingChunksMatchOnSentenceBoundariesOnly() async {
        let cache = WriterSpeculationCache()
        let p = packet(spans())
        let heard = WriterSpeculation.heardWords(p.heard)
        cache.store(prefixKey: key(p), heard: "sending the deck now", written: "Sending the deck now.")
        let hit = await cache.leadingHit(prefixKey: key(p), heard: heard)
        #expect(hit == WriterSpeculationHit(words: 4, written: "Sending the deck now.", chunks: 1))

        // A chunk that stops where the final text does not end a sentence is not used.
        let mid = WriterSpeculationCache()
        mid.store(prefixKey: key(p), heard: "sending the deck", written: "Sending the deck")
        #expect(await mid.leadingHit(prefixKey: key(p), heard: heard) == nil)

        // Only leading chunks: a cached second sentence alone is no hit.
        let second = WriterSpeculationCache()
        second.store(prefixKey: key(p), heard: "call me after lunch", written: "Call me after lunch.")
        #expect(await second.leadingHit(prefixKey: key(p), heard: heard) == nil)

        // Two chunks in a row cover everything; a chunk may span two final sentences.
        let both = WriterSpeculationCache()
        both.store(prefixKey: key(p), heard: "sending the deck now", written: "Sending the deck now.")
        both.store(prefixKey: key(p), heard: "call me after lunch", written: "Call me after lunch.")
        #expect(await both.leadingHit(prefixKey: key(p), heard: heard)?.words == 8)
        let spanning = WriterSpeculationCache()
        spanning.store(prefixKey: key(p), heard: "sending the deck now call me after lunch", written: "Sending it. Call me.")
        #expect(await spanning.leadingHit(prefixKey: key(p), heard: heard) == WriterSpeculationHit(words: 8, written: "Sending it. Call me.", chunks: 1))
    }

    @Test func aChunkMustEndOnAWordBoundary() async {
        let cache = WriterSpeculationCache()
        // "follow-up" is one heard word: a chunk ending at "follow" splits it.
        cache.store(prefixKey: "k", heard: "send the follow", written: "Send the follow")
        #expect(await cache.leadingHit(prefixKey: "k", heard: ["Send", "the", "follow-up.", "Thanks."]) == nil)
        cache.store(prefixKey: "k", heard: "send the follow up", written: "Send the follow-up.")
        #expect(await cache.leadingHit(prefixKey: "k", heard: ["Send", "the", "follow-up.", "Thanks."])?.words == 3)
    }

    @Test func unchangedChunkLandsTheFinalPassWords() async {
        let cache = WriterSpeculationCache()
        cache.store(prefixKey: "k", heard: "sending the deck now", written: "UNCHANGED")
        let hit = await cache.leadingHit(prefixKey: "k", heard: ["Sending", "the", "deck", "now.", "Bye."])
        #expect(hit?.written == "Sending the deck now.")
    }

    @Test func pendingMatchIsAwaitedAndUnusedPendingIsCancelled() async {
        let cache = WriterSpeculationCache()
        let unusedCancelled = Flag()
        let used = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return "Sending the deck now."
        }
        let unused = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { unusedCancelled.set() }
            return "Something else."
        }
        #expect(cache.add(prefixKey: "k", heard: "sending the deck now", task: used))
        #expect(cache.add(prefixKey: "k", heard: "something else entirely", task: unused))
        #expect(!cache.add(prefixKey: "k", heard: "Sending the deck, now", task: used))   // same chunk, normalised
        let hit = await cache.leadingHit(prefixKey: "k", heard: ["Sending", "the", "deck", "now.", "Call", "me."])
        #expect(hit?.written == "Sending the deck now." && hit?.words == 4)
        _ = await unused.value
        #expect(unusedCancelled.isSet)
        #expect(cache.currentCounts.cancelled == 1)
    }

    @Test func failedChunkIsNoHitAndTurnsExpire() async {
        let cache = WriterSpeculationCache()
        let failed = Task<String?, Never> { nil }
        cache.add(prefixKey: "k", heard: "sending the deck now", task: failed)
        _ = await failed.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(await cache.leadingHit(prefixKey: "k", heard: ["Sending", "the", "deck", "now."]) == nil)
        // Entries survive one new turn (a stage still finishing reads them), not two.
        cache.store(prefixKey: "k", heard: "call me after lunch", written: "Call me after lunch.")
        cache.beginTurn()
        #expect(await cache.leadingHit(prefixKey: "k", heard: ["Call", "me", "after", "lunch."]) != nil)
        cache.beginTurn()
        #expect(await cache.leadingHit(prefixKey: "k", heard: ["Call", "me", "after", "lunch."]) == nil)
    }

    @Test func tailPacketKeepsOnlyTheTail() {
        var p = packet(spans())
        p.heard.boosted = "Sending the Deck now. Call me after lunch."
        p.vocabulary = [.init(term: "Lunch Co", spokenForm: "lunch co", heard: "lunch", score: 0.4, source: "contact"),
                        .init(term: "Dek", spokenForm: "dek", heard: "deck", score: 0.9, source: "screen")]
        let tail = WriterSpeculation.tailPacket(p, droppingFirst: 4)
        #expect(tail.heard.raw == "Call me after lunch.")
        #expect(tail.heard.words.map(\.text) == ["Call", "me", "after", "lunch."])
        #expect(tail.heard.boosted == nil)
        #expect(tail.vocabulary.map(\.term) == ["Lunch Co"])
        #expect(tail.destination == p.destination && tail.textBefore == p.textBefore && tail.thread == p.thread)
    }

    // MARK: Through the stage

    @Test func leadingHitSendsOnlyTheTailAndStitches() async throws {
        let s = spans()
        let p = packet(s)
        let cache = WriterSpeculationCache()
        cache.store(prefixKey: key(p), heard: "sending the deck now", written: "Sending the deck now.")
        let gen = ScriptedWriter(reply: "Call me after lunch.")
        let out = try await stage(gen, cache: cache).process(s, context: context(p))
        #expect(out.renderedText == "Sending the deck now. Call me after lunch.")
        #expect(gen.calls.count == 1)
        let user = gen.calls[0].user
        #expect(user.contains("HEARD: Call me after lunch."))
        #expect(!user.contains("HEARD: Sending"))
        #expect(user.contains("EARLIER (") && user.contains("): Sending the deck now."))
        // The tail call starts with the same bytes as the full call (the KV prefix cache reuses them).
        let full = WriterPrompt.renderParts(packet: p, profile: chat)
        #expect(gen.calls[0].system == full.system && user.hasPrefix(full.stablePrefix))
        #expect(cache.currentCounts.lastUse == WriterSpeculationUse(call: .tail, chunksUsed: 1, wordsCovered: 4, wordsHeard: 8))
    }

    @Test func everythingCachedMeansNoCall() async throws {
        let s = spans()
        let p = packet(s)
        let cache = WriterSpeculationCache()
        cache.store(prefixKey: key(p), heard: "sending the deck now", written: "Sending the deck now.")
        cache.store(prefixKey: key(p), heard: "call me after lunch", written: "Call me after lunch.")
        let gen = ScriptedWriter(reply: "should not be called")
        let out = try await stage(gen, cache: cache).process(s, context: context(p))
        #expect(gen.calls.isEmpty)
        #expect(out.renderedText == "Sending the deck now. Call me after lunch.")
        #expect(cache.currentCounts.lastUse?.call == WriterSpeculationUse.Call.none)
    }

    @Test func mismatchFallsBackToOneFullCall() async throws {
        let s = spans()
        let p = packet(s)
        let cache = WriterSpeculationCache()
        // The preview heard "desk", the final pass "deck": no reuse, today's full call.
        cache.store(prefixKey: key(p), heard: "sending the desk now", written: "Sending the desk now.")
        let gen = ScriptedWriter(reply: "Sending the deck now. Call me after lunch.")
        let out = try await stage(gen, cache: cache).process(s, context: context(p))
        #expect(out.renderedText == "Sending the deck now. Call me after lunch.")
        #expect(gen.calls.count == 1)
        #expect(gen.calls[0].user == WriterPrompt.render(packet: p, profile: chat).user)
        #expect(!gen.calls[0].user.contains("EARLIER"))
        #expect(cache.currentCounts.lastUse?.call == .full)
    }

    @Test func aChangedStablePrefixInvalidatesTheCache() async throws {
        let s = spans()
        let atKeyDown = packet(s, textBefore: "sounds good,")
        let cache = WriterSpeculationCache()
        cache.store(prefixKey: key(atKeyDown), heard: "sending the deck now", written: "Sending the deck now.")
        // The field's text changed before the final call: the speculative sentence was written
        // for another context, so it is not reused.
        let final = packet(s, textBefore: "never mind,")
        let gen = ScriptedWriter(reply: "Sending the deck now. Call me after lunch.")
        _ = try await stage(gen, cache: cache).process(s, context: context(final))
        #expect(gen.calls.count == 1 && !gen.calls[0].user.contains("EARLIER"))
        #expect(cache.currentCounts.lastUse?.call == .full)
    }

    @Test func unchangedTailReplyKeepsTheHeardTail() async throws {
        let s = spans()
        let p = packet(s)
        let cache = WriterSpeculationCache()
        cache.store(prefixKey: key(p), heard: "sending the deck now", written: "Sending the deck now.")
        let out = try await stage(ScriptedWriter(reply: "UNCHANGED"), cache: cache).process(s, context: context(p))
        #expect(out.renderedText == "Sending the deck now. Call me after lunch.")
    }

    @Test func withoutSpeculationTheStageIsUnchanged() async throws {
        let s = spans()
        let p = packet(s)
        let gen = ScriptedWriter(reply: "Sending the deck now. Call me after lunch.")
        let plain = ContextWriterStage(generator: gen, outputGuard: { WriterGuard(phonetic: WriterGuardTests.stub) })
        _ = try await plain.process(s, context: context(p))
        #expect(gen.calls.count == 1 && gen.calls[0].user == WriterPrompt.render(packet: p, profile: chat).user)
    }

    @Test func speculativeChunkPromptSharesTheFinalPrefix() {
        // What the App's speculator sends for a preview chunk: the turn's packet with the chunk as
        // HEARD (lowercase, no punctuation: the preview's own text), earlier chunks as EARLIER.
        let p = packet(spans())
        let chunk = WriterSpeculation.chunkPacket(p, chunk: "call me after lunch")
        #expect(chunk.heard.raw == "call me after lunch" && chunk.heard.words.allSatisfy { !$0.isUncertain })
        let parts = WriterPrompt.renderParts(packet: chunk, profile: chat, core: nil, budget: .default, earlier: "Sending the deck now.")
        let final = WriterPrompt.renderParts(packet: p, profile: chat)
        #expect(parts.system == final.system && parts.stablePrefix == final.stablePrefix)
        #expect(parts.tail.contains("HEARD: call me after lunch"))
    }
}

extension WriterSpeculationTests {
    @Test func aLookupNeverCancelsAHoldStillBeingSpoken() async {
        // Turn 1's stage runs after turn 2's key-down: turn 2's running call is left alone.
        let cache = WriterSpeculationCache()
        cache.beginTurn()
        cache.store(prefixKey: "k", heard: "sending the deck now", written: "Sending the deck now.")
        cache.endTurn()
        cache.beginTurn()
        let cancelled = Flag()
        let next = Task<String?, Never> {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { cancelled.set() }
            return "Next turn."
        }
        cache.add(prefixKey: "k", heard: "a different sentence entirely", task: next)
        #expect(await cache.leadingHit(prefixKey: "k", heard: ["Sending", "the", "deck", "now."])?.words == 4)
        _ = await next.value
        #expect(!cancelled.isSet)
    }
}
