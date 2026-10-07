import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

// Context Writer latency (plan §4.2) — the App half of sentence speculation: chunks close on the
// preview's end-of-utterance marks, short ones join the next sentence, chunk n carries chunk n-1's
// text as EARLIER, nothing runs without a packet / for a secure destination / in latch, a revised
// preview stops the turn, and what it wrote is what the stage reuses.

private final class SegmentFeed: SegmentSessionEngine, @unchecked Sendable {
    let broadcaster = SegmentEventBroadcaster()
    func segmentEvents() -> AsyncStream<SegmentEvent> { broadcaster.subscribe() }
    func closeSegmentAtEndpoint() async -> SegmentID? { nil }
}

private final class RecordingWriter: WriterGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(system: String, user: String, speculative: Bool)] = []
    let reply: @Sendable (String) -> String
    init(_ reply: @escaping @Sendable (String) -> String) { self.reply = reply }
    var calls: [(system: String, user: String, speculative: Bool)] { lock.withLock { seen } }
    func write(system: String, user: String, context: StageContext) async throws -> String {
        lock.withLock { seen.append((system, user, context.extra[WriterSpeculation.speculativeKey] == "true")) }
        let heard = user.split(separator: "\n").first { $0.hasPrefix("HEARD: ") }.map { String($0.dropFirst(7)) } ?? ""
        return reply(heard)
    }
}

/// "sending the deck now" → "Sending the deck now." (what a writer would do with a preview chunk).
private let sentence: @Sendable (String) -> String = { heard in
    guard let first = heard.first else { return heard }
    return first.uppercased() + heard.dropFirst() + "."
}

private func packet(secure: Bool = false) -> ContextPacket {
    ContextPacket(destination: .init(profileID: secure ? "secure" : "chat.message", appName: "Slack",
                                     surfaceKind: "chatComposer"),
                  textBefore: "sounds good,", heard: .init(raw: ""), isSecure: secure)
}

private let segment = SegmentID(sessionID: UUID(), index: 0)

private func preview(_ text: String) -> SegmentEvent {
    .preview(segment: segment, spans: [TranscriptSpan(text: text, confidence: 0.5, audioRange: 0...0,
                                                                                provenance: [.asr], stability: .provisional)])
}
private let eou = SegmentEvent.endOfUtterance(segment: segment)

private func speculator(_ writer: RecordingWriter, packet: ContextPacket? = packet()) -> (WriterSpeculator, SegmentFeed) {
    let s = WriterSpeculator()
    s.generator = writer
    s.packetProvider = { packet }
    let feed = SegmentFeed()
    return (s, feed)
}

/// Waits (bounded) until `condition` holds.
private func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@Suite struct WriterSpeculatorTests {

    @Test func sentencesCloseOnEndOfUtteranceAndChainEarlier() async {
        let writer = RecordingWriter(sentence)
        let (s, feed) = speculator(writer)
        s.beginTurn(segments: feed, latched: false)
        s.handle(preview("sending the deck"))
        s.handle(preview("sending the deck now"))
        s.handle(eou)
        s.handle(preview("sending the deck now ok"))
        s.handle(eou)                                   // "ok": too short, joins the next sentence
        s.handle(preview("sending the deck now ok call me after lunch"))
        s.handle(eou)
        await eventually { writer.calls.count == 2 }
        #expect(writer.calls.count == 2)
        #expect(writer.calls.allSatisfy { $0.speculative })
        #expect(writer.calls[0].user.contains("HEARD: sending the deck now"))
        #expect(!writer.calls[0].user.contains("EARLIER"))
        #expect(writer.calls[1].user.contains("HEARD: ok call me after lunch"))
        #expect(writer.calls[1].user.contains("): Sending the deck now."))
        #expect(s.currentTurn?.chunks == 2)
        s.endTurn()
    }

    @Test func whatItWroteIsWhatTheStageReuses() async throws {
        let writer = RecordingWriter(sentence)
        let p = packet()
        let (s, feed) = speculator(writer, packet: p)
        s.beginTurn(segments: feed, latched: false)
        s.handle(preview("sending the deck now"))
        s.handle(eou)
        s.handle(preview("sending the deck now call me after"))
        s.endTurn()                                      // key-up: the last sentence never closed
        await eventually { s.cache.currentCounts.ready == 1 }

        let words = ["Sending", "the", "deck", "now.", "Call", "me", "after", "lunch."]
        let spans = words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 0.9, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
        }
        var final = p
        final.heard = .init(raw: words.joined(separator: " "), words: words.map { .init(text: $0, confidence: 0.9) })
        var ctx = StageContext(register: .chat)
        final.write(into: &ctx)
        let stageWriter = RecordingWriter { _ in "Call me after lunch." }
        var stage = ContextWriterStage(generator: stageWriter)
        stage.speculation = s.cache
        let out = try await stage.process(spans, context: ctx)
        #expect(out.renderedText == "Sending the deck now. Call me after lunch.")
        #expect(stageWriter.calls.count == 1)
        #expect(stageWriter.calls[0].user.contains("HEARD: Call me after lunch."))
        #expect(s.cache.currentCounts.lastUse?.call == .tail)
    }

    @Test func nothingRunsWithoutAPacketOrForASecureField() async {
        for p in [nil, packet(secure: true)] as [ContextPacket?] {
            let writer = RecordingWriter(sentence)
            let (s, feed) = speculator(writer, packet: p)
            s.beginTurn(segments: feed, latched: false)
            s.handle(preview("my password is hunter two"))
            s.handle(eou)
            try? await Task.sleep(nanoseconds: 30_000_000)
            #expect(writer.calls.isEmpty)
            #expect(s.currentTurn?.stopped == (p == nil ? "noPacket" : "secure"))
        }
    }

    @Test func latchNeverSpeculatesAndEnteringLatchCancels() async {
        let writer = RecordingWriter(sentence)
        let (s, feed) = speculator(writer)
        s.beginTurn(segments: feed, latched: true)
        #expect(s.currentTurn == nil)
        s.handle(preview("sending the deck now"))
        s.handle(eou)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(writer.calls.isEmpty)
        s.beginTurn(segments: feed, latched: false)
        s.cancelTurn()
        #expect(s.currentTurn == nil)
    }

    @Test func aRevisedPreviewStopsTheTurn() async {
        let writer = RecordingWriter(sentence)
        let (s, feed) = speculator(writer)
        s.beginTurn(segments: feed, latched: false)
        s.handle(preview("sending the deck now"))
        s.handle(eou)
        s.handle(preview("sending the desk now and then more words"))
        s.handle(eou)
        await eventually { writer.calls.count >= 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(writer.calls.count == 1)
        #expect(s.currentTurn?.stopped == "revised")
    }

    @Test func boundedCallGivesUpAndCancels() async {
        let t0 = Date()
        let value = await WriterSpeculator.bounded(0.05) {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            return "late"
        }
        #expect(value == nil)
        // Far below the 20 s operation (gave up, did not wait for it); loose enough for a loaded
        // full-suite run, where the cooperative pool can take seconds to schedule the timeout.
        #expect(Date().timeIntervalSince(t0) < 8)
    }
}

extension WriterSpeculatorTests {
    @Test func aPunctuatingPreviewClosesSentencesWithoutEOU() async {
        // The polling final-model preview writes full stops: a sentence closes once a word follows.
        let writer = RecordingWriter(sentence)
        let (s, feed) = speculator(writer)
        s.beginTurn(segments: feed, latched: false)
        s.handle(preview("Sending the deck now."))          // no following word yet: still open
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(writer.calls.isEmpty)
        s.handle(preview("Sending the deck now. Call me"))
        await eventually { writer.calls.count == 1 }
        #expect(writer.calls.first?.user.contains("HEARD: Sending the deck now.") == true)
        #expect(writer.calls.first?.user.contains("Call me") == false)
        s.endTurn()
    }
}

// MARK: - Opt-in: the hit rate on the owner's recordings (real preview + final models)
//
// `VOICEPLUS_SPECULATION_REPLAY=1 swift test --filter WriterSpeculationReplay`. Each recording in
// Application Support/VoicePlus/Recordings (`*-processed.wav`) is fed to the shipping preview
// backend in 100 ms blocks (as `RealEngine` feeds live capture) while the real `WriterSpeculator`
// chunks it; the final TDT pass is then matched against what was speculated, exactly as the stage
// does. Counts only are printed, never text. Models come from the installed app bundle.

private final class EchoWriter: WriterGenerating, @unchecked Sendable {
    func write(system: String, user: String, context: StageContext) async throws -> String { "UNCHANGED" }
}

@Suite(.serialized) struct WriterSpeculationReplayTests {
    static let enabled = ProcessInfo.processInfo.environment["VOICEPLUS_SPECULATION_REPLAY"] != nil

    struct Tally {
        var utterances = 0, withChunks = 0, chunks = 0, wordsHeard = 0, wordsCovered = 0
        var none = 0, tail = 0, full = 0
        mutating func add(chunks c: Int, heard: Int, covered: Int) {
            utterances += 1; chunks += c; wordsHeard += heard; wordsCovered += covered
            if c > 0 { withChunks += 1 }
            if covered == 0 { full += 1 } else if covered >= heard { none += 1 } else { tail += 1 }
        }
        func line(_ label: String) -> String {
            let pct = wordsHeard == 0 ? 0 : Int((Double(wordsCovered) / Double(wordsHeard) * 100).rounded())
            return "speculation replay [\(label)]: utterances \(utterances), with a closed sentence \(withChunks), chunks \(chunks); "
                + "calls none \(none) / tail \(tail) / full \(full); words reused \(wordsCovered)/\(wordsHeard) (\(pct) %)"
        }
    }

    @Test(.enabled(if: WriterSpeculationReplayTests.enabled))
    func hitRateOnRecordings() async throws {
        let resources = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICEPLUS_APP_RESOURCES"]
                            ?? "/Applications/VoicePlus.app/Contents/Resources")
        var caches = ModelManager.defaultExternalCaches()
        for (id, url) in BundledModelResources.candidates(resources: resources) { caches[id, default: []].insert(url, at: 0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vp-spec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(root: root, externalCaches: caches, maintenance: .skip, residency: nil)
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        let dir = AppPaths.supportDirectory().appendingPathComponent("Recordings")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("-processed.wav") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let backends: [PreviewBackend] = ProcessInfo.processInfo.environment["VOICEPLUS_SPECULATION_POLLING"] != nil
            ? [.eouStreaming120m, .pollingFinal] : [.eouStreaming120m]
        for backend in backends {
            guard let recognizer = await RecognizerFactory.makePreview(manager: manager, final: final, backend: backend) else {
                print("speculation replay: no \(backend.displayName) preview on this Mac"); continue
            }
            var all = Tally(), long = Tally()
            for url in files {
                guard let wav = try? WAVFile.read(url: url), wav.sampleRate == 16_000, wav.samples.count >= 16_000 else { continue }
                let finalWords = try await final.recognize(wav.samples).map(\.text).filter { !$0.isEmpty }
                guard !finalWords.isEmpty else { continue }
                let p = packet()
                let s = WriterSpeculator()
                s.generator = EchoWriter()
                s.packetProvider = { p }
                s.beginTurn(segments: SegmentFeed(), latched: false)
                await recognizer.reset()
                var last = ""
                var i = 0
                while i < wav.samples.count {
                    let end = min(i + 1_600, wav.samples.count)
                    let text = try await recognizer.feed(Array(wav.samples[i..<end]))
                    if text != last, !text.isEmpty { s.handle(preview(text)); last = text }
                    if let marks = recognizer as? EndOfUtteranceReporting, await marks.takeEndOfUtterance() { s.handle(eou) }
                    i = end
                }
                let chunks = s.currentTurn?.chunks ?? 0
                s.endTurn()
                await eventually { s.cache.currentCounts.ready + s.cache.currentCounts.failed >= chunks }
                let parts = WriterPrompt.renderParts(packet: p, profile: Pipeline.DestinationProfiles.resolve(profileID: "chat.message"))
                let key = WriterSpeculation.prefixKey(system: parts.system, stablePrefix: parts.stablePrefix)
                let hit = await s.cache.leadingHit(prefixKey: key, heard: finalWords)
                all.add(chunks: chunks, heard: finalWords.count, covered: hit?.words ?? 0)
                if wav.samples.count >= 6 * 16_000 { long.add(chunks: chunks, heard: finalWords.count, covered: hit?.words ?? 0) }
            }
            print(all.line("\(backend.displayName), all ≥ 1 s"))
            print(long.line("\(backend.displayName), ≥ 6 s"))
        }
    }
}
