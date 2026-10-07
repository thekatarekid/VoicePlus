import Foundation
import Shared
import Testing
@testable import Pipeline

// Context Writer stage, transcribe mode: skip rules, the reserved UNCHANGED reply, deadline,
// per-change guard wiring, mapping back onto spans (audio / confidence / provenance kept, an
// uncertain span that changed is flagged and keeps what was heard as an alternate).

final class ScriptedWriter: WriterGenerating, @unchecked Sendable {
    let reply: @Sendable (String, String) async throws -> String
    private let lock = NSLock()
    private var seen: [(system: String, user: String)] = []
    var calls: [(system: String, user: String)] { lock.withLock { seen } }

    init(_ reply: @escaping @Sendable (String, String) async throws -> String) { self.reply = reply }
    convenience init(reply text: String) { self.init { _, _ in text } }

    func write(system: String, user: String, context: StageContext) async throws -> String {
        lock.withLock { seen.append((system, user)) }
        return try await reply(system, user)
    }
}

final class WriterOutcomeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [WriterOutcome] = []
    var all: [WriterOutcome] { lock.withLock { items } }
    var codes: [String] { all.map(\.code) }
    func add(_ o: WriterOutcome) { lock.withLock { items.append(o) } }
}

@Suite struct ContextWriterStageTests {
    static let stub = WriterGuardTests.stub

    static func spans(_ words: [(String, Float)], alts: [Int: [String]] = [:]) -> [TranscriptSpan] {
        words.enumerated().map { i, w in
            TranscriptSpan(text: w.0, confidence: w.1, audioRange: Double(i)...Double(i) + 0.9,
                           alternates: (alts[i] ?? []).map { Alternate(text: $0, score: 0.3, source: .beam) },
                           provenance: [.asr])
        }
    }

    static func packet(_ spans: [TranscriptSpan], profile: String = "chat.message", mode: WriterMode = .transcribe,
                       vocabulary: [ContextPacket.VocabularyMatch] = [], screenTerms: [String] = [],
                       secure: Bool = false) -> ContextPacket {
        let words = spans.map { ContextPacket.HeardWord(text: $0.text, confidence: $0.confidence, alternates: $0.alternates.map(\.text)) }
        return ContextPacket(mode: mode, destination: .init(profileID: profile, appName: "Slack", surfaceKind: "chat"),
                             screenTerms: screenTerms, vocabulary: vocabulary,
                             heard: .init(raw: spans.renderedText, words: words), isSecure: secure)
    }

    static func context(_ packet: ContextPacket?, register: Utterance.Register = .chat, extra: [String: String] = [:]) -> StageContext {
        var c = StageContext(register: register, extra: extra)
        packet?.write(into: &c)
        return c
    }

    static func stage(_ gen: ScriptedWriter?, deadline: TimeInterval = 2.5, log: WriterOutcomeLog? = nil,
                      trace: TurnTraceRecorder? = nil) -> ContextWriterStage {
        ContextWriterStage(generator: gen, deadline: deadline, outputGuard: { WriterGuard(phonetic: stub) },
                           observer: { log?.add($0) }, trace: trace)
    }

    static let id = ContextWriterStage.stageID

    // MARK: Landing corrections

    @Test func soundAlikeOnUncertainSpanLands() async throws {
        let s = Self.spans([("Queen", 0.3), ("four", 0.9), ("B", 0.9), ("is", 0.9), ("fast", 0.9)])
        let gen = ScriptedWriter(reply: "Qwen 4B is fast.")
        let log = WriterOutcomeLog()
        let out = try await Self.stage(gen, log: log).process(s, context: Self.context(Self.packet(s)))
        #expect(out.renderedText == "Qwen 4B is fast.")
        #expect(out.map(\.text) == ["Qwen", "4B", "", "is", "fast."])
        #expect(log.codes == ["accepted"])
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
        #expect(out.map(\.audioRange) == s.map(\.audioRange))
        #expect(out.map(\.confidence) == s.map(\.confidence))
        #expect(out.allSatisfy { $0.provenance == [.asr, Self.id] })
        // The changed uncertain span is flagged and keeps what was heard; the confident number is not.
        #expect(out[0].needsRepair)
        #expect(out[0].alternates.first == Alternate(text: "Queen", score: 0, source: .repair))
        #expect(!out[1].needsRepair)
        #expect(out[1].alternates.first == Alternate(text: "four", score: 0, source: .repair))
        // The prompt carried the heard text with the uncertain word marked.
        #expect(gen.calls.count == 1)
        #expect(gen.calls[0].user.contains("⟦Queen⟧ four B is fast"))
        #expect(gen.calls[0].system.contains("Chat message"))
    }

    @Test func unsupportedChangeRevertsWhileTheSoundAlikeStays() async throws {
        let s = Self.spans([("Queen", 0.3), ("four", 0.9), ("B", 0.9), ("in", 0.9), ("polishing", 0.3), ("mode", 0.9)])
        let log = WriterOutcomeLog()
        let out = try await Self.stage(ScriptedWriter(reply: "Qwen 4B in Polish in chosen apps"), log: log)
            .process(s, context: Self.context(Self.packet(s)))
        #expect(out.renderedText == "Qwen 4B in polishing mode")
        #expect(log.codes == ["partiallyReverted:1"])
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
        #expect(!out[4].needsRepair)
        #expect(out[4].alternates.isEmpty)
    }

    @Test func vocabularyTermThroughItsSpokenForm() async throws {
        let s = Self.spans([("A", 0.9), ("sixtien", 0.3), ("z", 0.9), ("backed", 0.9), ("it", 0.9)])
        let vocab = [ContextPacket.VocabularyMatch(term: "a16z", spokenForm: "a sixteen z", heard: "sixtien", score: 0.8, source: "dictionary")]
        let log = WriterOutcomeLog()
        let out = try await Self.stage(ScriptedWriter(reply: "a16z backed it."), log: log)
            .process(s, context: Self.context(Self.packet(s, vocabulary: vocab)))
        #expect(out.renderedText == "a16z backed it.")
        #expect(out.map(\.text) == ["a16z", "", "", "backed", "it."])
        #expect(log.codes == ["accepted"])
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
        #expect(out[1].needsRepair)          // the uncertain word the term absorbed
        #expect(!out[0].needsRepair)         // the confident "A" only changed shape
    }

    @Test func fillersAndSelfCorrectionsLand() async throws {
        let s = Self.spans([("um", 0.9), ("let's", 0.9), ("meet", 0.9), ("thursday", 0.9), ("no", 0.9), ("friday", 0.9), ("at", 0.9), ("noon", 0.9)])
        let log = WriterOutcomeLog()
        let out = try await Self.stage(ScriptedWriter(reply: "Let's meet Friday at noon."), log: log)
            .process(s, context: Self.context(Self.packet(s)))
        #expect(out.renderedText == "Let's meet Friday at noon.")
        #expect(log.codes == ["accepted"])
        #expect(ConfidenceContract.verify(input: s, output: out).isEmpty)
        #expect(out[0].text.isEmpty && out[3].text.isEmpty && out[4].text.isEmpty)
    }

    @Test func alternatesLetAnUncertainSpanChange() async throws {
        let s = Self.spans([("send", 0.9), ("the", 0.9), ("desk", 0.3)], alts: [2: ["deck", "disk"]])
        let out = try await Self.stage(ScriptedWriter(reply: "Send the deck.")).process(s, context: Self.context(Self.packet(s)))
        #expect(out.renderedText == "Send the deck.")
        #expect(out[2].needsRepair)
        #expect(out[2].alternates.map(\.text) == ["desk", "deck", "disk"])
    }

    // MARK: Untouched paths

    @Test func confidentContentWordsNeverChange() async throws {
        let s = Self.spans([("send", 0.9), ("the", 0.9), ("deck", 0.9)])
        let log = WriterOutcomeLog()
        let out = try await Self.stage(ScriptedWriter(reply: "send the desk"), log: log).process(s, context: Self.context(Self.packet(s)))
        #expect(out.map(\.text) == s.map(\.text))
        #expect(log.codes == ["rejected:everyChangeReverted"])
        #expect(out.allSatisfy { $0.provenance == [.asr, Self.id] && !$0.needsRepair })
    }

    @Test func unchangedReplyAndVerbatimEchoAreUntouched() async throws {
        let s = Self.spans([("see", 0.9), ("you", 0.9), ("Friday.", 0.9)])
        for reply in ["UNCHANGED", "unchanged\n", "see you Friday.", "⟦see⟧ you Friday."] {
            let log = WriterOutcomeLog()
            let out = try await Self.stage(ScriptedWriter(reply: reply), log: log).process(s, context: Self.context(Self.packet(s)))
            #expect(out.map(\.text) == s.map(\.text), "\(reply)")
            #expect(log.codes == ["unchanged"], "\(reply)")
            #expect(out.allSatisfy { $0.provenance == [.asr, Self.id] })
        }
    }

    @Test func answersAreRejected() async throws {
        let s = Self.spans([("what", 0.9), ("time", 0.9), ("is", 0.9), ("it", 0.9)])
        let log = WriterOutcomeLog()
        let out = try await Self.stage(ScriptedWriter(reply: "Sure, here is the corrected text: What time is it?"), log: log)
            .process(s, context: Self.context(Self.packet(s)))
        #expect(out.map(\.text) == s.map(\.text))
        #expect(log.codes == ["rejected:assistantPreamble"])
        let answered = WriterOutcomeLog()
        _ = try await Self.stage(ScriptedWriter(reply: "It is 3 pm right now, according to the clock on your screen and the calendar entry."), log: answered)
            .process(s, context: Self.context(Self.packet(s)))
        #expect(answered.codes == ["rejected:mostlyReverted"])
    }

    @Test func timeoutAndErrorLeaveTheSpansAlone() async throws {
        let s = Self.spans([("hello", 0.9), ("there", 0.3)])
        let slow = ScriptedWriter { _, _ in try await Task.sleep(nanoseconds: 800_000_000); return "Hello there." }
        let log = WriterOutcomeLog()
        let out = try await Self.stage(slow, deadline: 0.05, log: log).process(s, context: Self.context(Self.packet(s)))
        #expect(out.map(\.text) == ["hello", "there"])
        #expect(log.codes == ["timeout"])
        #expect(out.allSatisfy { $0.provenance == [.asr, Self.id] })

        struct Down: Error {}
        let failing = ScriptedWriter { _, _ in throw Down() }
        let log2 = WriterOutcomeLog()
        let out2 = try await Self.stage(failing, log: log2).process(s, context: Self.context(Self.packet(s)))
        #expect(out2.map(\.text) == ["hello", "there"])
        #expect(log2.codes == ["failed:Down"])
    }

    @Test func keepEdgesRestoresCaseAndTerminalPunctuation() async throws {
        let s = Self.spans([("we", 0.9), ("agreed", 0.9), ("on", 0.9), ("twenty", 0.9), ("five", 0.9)])
        let log = WriterOutcomeLog()
        let ctx = Self.context(Self.packet(s), extra: [ContextWriterStage.keepEdgesKey: "true"])
        let out = try await Self.stage(ScriptedWriter(reply: "We agreed on 25."), log: log).process(s, context: ctx)
        #expect(out.renderedText == "we agreed on 25")
        #expect(log.codes == ["accepted"])
    }

    // MARK: Skip rules — the generator is never called

    @Test func skipRules() async throws {
        let s = Self.spans([("ls", 0.9), ("minus", 0.9), ("la", 0.9)])
        let p = Self.packet(s)
        let cases: [(String, ContextPacket?, StageContext)] = [
            ("noPacket", nil, Self.context(nil)),
            ("mode", nil, Self.context(Self.packet(s, mode: .instruct))),
            ("secure", nil, Self.context(Self.packet(s, secure: true))),
            ("secure", nil, Self.context(Self.packet(s, profile: "secure"))),
            ("verbatim", nil, Self.context(p, extra: [ContextWriterStage.skipKey: "true"])),
            ("verbatimProfile", nil, Self.context(Self.packet(s, profile: "shell"), register: .terminal)),
            ("verbatimProfile", nil, Self.context(Self.packet(s, profile: "code.body"), register: .code)),
            ("empty", nil, Self.context(Self.packet(Self.spans([("", 0.9)])))),
        ]
        for (code, _, ctx) in cases {
            let gen = ScriptedWriter(reply: "ls -la")
            let log = WriterOutcomeLog()
            let input = code == "empty" ? Self.spans([("", 0.9)]) : s
            let out = try await Self.stage(gen, log: log).process(input, context: ctx)
            #expect(log.codes == ["skipped:\(code)"], "\(code)")
            #expect(gen.calls.isEmpty, "\(code)")
            #expect(out.map(\.text) == input.map(\.text), "\(code)")
            #expect(out.allSatisfy { $0.provenance == [.asr, Self.id] }, "\(code)")
        }
        // A shell profile in a prose register (a chat about commands) is not verbatim.
        let gen = ScriptedWriter(reply: "ls -la")
        let log = WriterOutcomeLog()
        _ = try await Self.stage(gen, log: log).process(s, context: Self.context(Self.packet(s, profile: "shell"), register: .chat))
        #expect(gen.calls.count == 1)
        // No generator: skipped before anything is read.
        let none = WriterOutcomeLog()
        _ = try await Self.stage(nil, log: none).process(s, context: Self.context(p))
        #expect(none.codes == ["skipped:noModel"])
    }

    // MARK: Trace hook

    @Test func outcomeCodeLandsAsTheTraceNote() async throws {
        let recorder = TurnTraceRecorder(capacity: 3)
        let s = Self.spans([("Queen", 0.3), ("four", 0.9), ("B", 0.9)])
        let ctx = Self.context(Self.packet(s))
        recorder.begin(input: s.renderedText, context: ctx)
        let stage = Self.stage(ScriptedWriter(reply: "Qwen 4B"), trace: recorder)
        let out = try await stage.process(s, context: ctx)
        recorder.record(stage: stage.id, before: s.renderedText, after: out.renderedText)
        let step = try #require(recorder.latest?.steps.last)
        #expect(step.stage == Self.id)
        #expect(step.note == "accepted")
        #expect(step.before == "Queen four B" && step.after == "Qwen 4B")
    }
}
