import Foundation
import Shared
import Testing
@testable import Pipeline

// MARK: - Doubles

/// A `SpanRefining` with no model behind it and every axis under the test's control: what it
/// returns, how long it pretends to think, whether it throws, and whether it polices its own
/// deadline the way `Qwen3RefinementSession` does.
///
/// R5.1's `MockRefinementSession` lives in `Engine`, which `PipelineTests` cannot import (the
/// `Pipeline` target does not depend on `Engine`), so the double is local — which is the point of
/// the protocol seam. No weights are involved anywhere in this file.
struct ControllableRefiner: SpanRefining {
    var text: String = "refined text"
    /// Simulated model time, slept in a cancellable way.
    var work: Duration = .zero
    var failure: (any Error & Sendable)?
    /// When true the double throws its own deadline error instead of letting the stage's watchdog
    /// fire — the real session does this, and the stage must fall back either way.
    var enforcesOwnDeadline = false
    /// Runs just before the double returns: how a test makes text become committed *during* a pass.
    var whileRunning: (@Sendable () -> Void)?
    let seen = CallLog()

    struct OwnDeadlineExceeded: Error {}

    func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        seen.record(sampleCount: samples.count, context: context, deadline: deadline)
        if let failure { throw failure }
        if work > .zero {
            if enforcesOwnDeadline, work > deadline {
                try await Task.sleep(for: deadline)
                throw OwnDeadlineExceeded()
            }
            try await Task.sleep(for: work)
        }
        try Task.checkCancellation()
        whileRunning?()
        return [TranscriptSpan(text: text, confidence: 0,
                               audioRange: 0...(Double(samples.count) / 16_000),
                               provenance: [.refine])]
    }
}

/// What the refiner was handed. A class so the struct double can stay `Sendable`.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(sampleCount: Int, context: String, deadline: Duration)] = []

    func record(sampleCount: Int, context: String, deadline: Duration) {
        lock.lock(); defer { lock.unlock() }
        calls.append((sampleCount, context, deadline))
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var last: (sampleCount: Int, context: String, deadline: Duration)? {
        lock.lock(); defer { lock.unlock() }; return calls.last
    }
}

final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RefineReport] = []

    func add(_ report: RefineReport) { lock.lock(); items.append(report); lock.unlock() }
    var all: [RefineReport] { lock.lock(); defer { lock.unlock() }; return items }
    var outcomes: [RefineOutcome] { all.map(\.outcome) }
    var last: RefineReport? { all.last }
}

final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - Tests

/// R5.2 — the refinement stage. Every test drives a controllable double; nothing here loads a
/// model, and nothing here depends on the Qwen port being correct.
@Suite struct RefineStageTests {

    static let pcm = [Float](repeating: 0.01, count: 16_000) // 1 s of 16 kHz mono

    /// One span per word, contiguous ranges, `[.asr]` provenance.
    static func spans(_ text: String, confidence: Float = 0.9,
                      stability: Stability = .final) -> [TranscriptSpan] {
        let words = text.split(separator: " ")
        let step = 1.0 / Double(max(words.count, 1))
        return words.enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence,
                           audioRange: Double(i) * step...Double(i + 1) * step,
                           provenance: [.asr], stability: stability)
        }
    }

    static func stage(_ refiner: ControllableRefiner,
                      deadline: Duration = .seconds(2),
                      backlog: RefinementBacklog? = nil,
                      contextText: String = "",
                      stabilityAtApply: RefineStage.StabilityProbe? = nil,
                      reports: ReportBox? = nil,
                      samples: [Float] = RefineStageTests.pcm) -> RefineStage {
        var observer: RefineStage.Observer?
        if let reports { observer = { report in reports.add(report) } }
        return RefineStage(refiner: refiner, samples: samples, deadline: deadline, backlog: backlog,
                           contextText: contextText, stabilityAtApply: stabilityAtApply,
                           observer: observer)
    }

    /// The whole stage contract in one place: nothing is dropped, nothing is invented.
    static func assertContract(_ input: [TranscriptSpan], _ output: [TranscriptSpan]) {
        let violations = ConfidenceContract.verify(input: input, output: output)
        #expect(violations.isEmpty, "\(violations.joined(separator: "; "))")
        #expect(output.count == input.count, "one output span per input span")
        for (before, after) in zip(input, output) {
            #expect(after.audioRange == before.audioRange, "audioRange survives")
            #expect(after.confidence == before.confidence, "confidence field survives")
            #expect(after.alternates == before.alternates, "alternates survive")
            #expect(after.stability == before.stability, "stability is not moved by this stage")
            #expect(Array(after.provenance.prefix(before.provenance.count)) == before.provenance,
                    "earlier provenance survives, in order")
            #expect(after.provenance.count > before.provenance.count, "the stage appends provenance")
            #expect(after.provenance.last == .refine, "provenance.last names the pass")
            #expect(after.wasRefined, "provenance names the refinement pass")
        }
    }

    // MARK: budgets

    @Test func deadlineAndBacklogComeFromTheBudgetTable() {
        // V3 §10.2: final segment p95 ≤ 1500 ms; earlier segments backlog ≤ 2, else commit pass-1.
        #expect(RefineStage.finalSegmentDeadline == .milliseconds(1500))
        #expect(RefinementClock.milliseconds(RefineStage.finalSegmentDeadline) == 1500)
        #expect(RefineStage.maxBacklogSegments == 2)
        #expect(RefinementBacklog.defaultLimit == 2)
        #expect(StageID.refine.rawValue == "refine.qwen3")
    }

    // MARK: in-place replacement + contract

    @Test func replacesTextInPlaceAndKeepsEverythingElse() async throws {
        let input = [TranscriptSpan(text: "team fuel h e", confidence: 0.82, audioRange: 0.9...1.7,
                                   alternates: [Alternate(text: "TeamViewer", score: 0.4, source: .beam)],
                                   provenance: [.asr])]
        let reports = ReportBox()
        let out = try await Self.stage(ControllableRefiner(text: "TeamViewer AG"), reports: reports)
            .process(input, context: StageContext(register: .prose))
        Self.assertContract(input, out)
        #expect(out.joinedText == "TeamViewer AG")
        #expect(reports.outcomes == [.refined])
        #expect(reports.last?.rewrittenSpans == 1)
    }

    @Test func agreementWithPassOneIsReportedAsUnchanged() async throws {
        let input = Self.spans("send the deck to priya")
        let reports = ReportBox()
        let out = try await Self.stage(ControllableRefiner(text: "send the deck to priya"), reports: reports)
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.map(\.text) == input.map(\.text))
        #expect(reports.outcomes == [.unchanged])
        #expect(out.allSatisfy { !$0.refinedConfidenceUnavailable })
    }

    /// Every path through the stage — including all four "keep pass-1" paths — has to satisfy the
    /// same contract. Commit 96d801d exists because two stages returned their input untouched on
    /// their quiet paths and `ContractEnforcingStage` then discarded their output.
    @Test func everyOutcomeSatisfiesTheContract() async throws {
        let input = Self.spans("the quick brown fox jumps")
        var cases: [(String, RefineStage, StageContext)] = []
        cases.append(("refined", Self.stage(ControllableRefiner(text: "the quick brown fox jumped")), StageContext()))
        cases.append(("disabled", Self.stage(ControllableRefiner()),
                      StageContext(extra: [RefineStage.enabledKey: "false"])))
        cases.append(("noAudio", Self.stage(ControllableRefiner(), samples: []), StageContext()))
        cases.append(("timedOut", Self.stage(ControllableRefiner(work: .seconds(30)), deadline: .milliseconds(20)),
                      StageContext()))
        cases.append(("failed", Self.stage(ControllableRefiner(failure: ControllableRefiner.OwnDeadlineExceeded())),
                      StageContext()))
        cases.append(("emptyResult", Self.stage(ControllableRefiner(text: "   ")), StageContext()))
        cases.append(("late", Self.stage(ControllableRefiner(text: "different words entirely here now"),
                                         stabilityAtApply: { _ in .committed }), StageContext()))
        let full = RefinementBacklog(limit: 1)
        #expect(await full.admit())
        cases.append(("backlogFull", Self.stage(ControllableRefiner(), backlog: full), StageContext()))

        for (label, stage, context) in cases {
            let out = try await stage.process(input, context: context)
            let violations = ConfidenceContract.verify(input: input, output: out)
            #expect(violations.isEmpty, "\(label): \(violations.joined(separator: "; "))")
            #expect(out.allSatisfy { $0.provenance.last == .refine }, "\(label): provenance names the pass")
        }
    }

    @Test func refinedOutputSurvivesTheEnforcingWrapper() async throws {
        let input = Self.spans("meet me at for thirty")
        let sink = CollectingLabSink()
        let wrapped = ContractEnforcingStage(Self.stage(ControllableRefiner(text: "meet me at four thirty")),
                                            policy: .fallbackToInput, sink: sink)
        let out = try await wrapped.process(input, context: StageContext(register: .prose))
        #expect(out.joinedText == "meet me at four thirty", "no violation, so no fallback to input")
        #expect(sink.all.first?.contractViolations.isEmpty == true)
    }

    // MARK: deadline

    @Test func timeoutFallsBackToPassOneText() async throws {
        let input = Self.spans("the deadline is hard")
        let reports = ReportBox()
        let refiner = ControllableRefiner(text: "never arrives", work: .seconds(30))
        let out = try await Self.stage(refiner, deadline: .milliseconds(30), reports: reports)
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "the deadline is hard", "pass-1 text stands")
        #expect(reports.outcomes == [.timedOut])
        #expect(reports.last?.deadlineMs == 30)
        #expect(out.allSatisfy { !$0.refinedConfidenceUnavailable })
    }

    @Test func stageWatchdogFiresEvenIfTheSessionIgnoresItsDeadline() async throws {
        // The double is handed a 25 ms deadline and sleeps 5 s regardless. The stage's own
        // watchdog is what has to return, well inside a second.
        let input = Self.spans("one two three")
        let reports = ReportBox()
        let started = ContinuousClock.now
        let out = try await Self.stage(ControllableRefiner(text: "x", work: .seconds(5)),
                                      deadline: .milliseconds(25), reports: reports)
            .process(input, context: StageContext())
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(1), "the stage did not wait for the session")
        #expect(out.joinedText == "one two three")
        #expect(reports.outcomes == [.timedOut])
    }

    @Test func aSessionThatPolicesItsOwnDeadlineAlsoFallsBackToPassOne() async throws {
        let input = Self.spans("one two three")
        let reports = ReportBox()
        let refiner = ControllableRefiner(text: "four five six", work: .seconds(30),
                                         enforcesOwnDeadline: true)
        let out = try await Self.stage(refiner, deadline: .milliseconds(30), reports: reports)
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "one two three")
        #expect(reports.last?.outcome == .timedOut)
    }

    @Test func aSessionThatThrowsKeepsPassOneAndDoesNotThrowOnward() async throws {
        let input = Self.spans("keep my words")
        let reports = ReportBox()
        struct Boom: Error {}
        let out = try await Self.stage(ControllableRefiner(failure: Boom()), reports: reports)
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "keep my words")
        #expect(reports.outcomes == [.failed])
    }

    @Test func theSessionIsHandedTheDeadlineTheAudioAndTheContextPrompt() async throws {
        let refiner = ControllableRefiner(text: "with context")
        let stage = Self.stage(refiner, deadline: .milliseconds(900), contextText: "fallback prompt")
        _ = try await stage.process(Self.spans("a b"),
                                    context: StageContext(extra: [RefineStage.contextKey: "Priya Kothari TeamViewer"]))
        #expect(refiner.seen.last?.context == "Priya Kothari TeamViewer", "extra overrides the stage default")
        #expect(refiner.seen.last?.deadline == .milliseconds(900))
        #expect(refiner.seen.last?.sampleCount == Self.pcm.count)

        let fallback = ControllableRefiner(text: "with context")
        _ = try await Self.stage(fallback, contextText: "fallback prompt")
            .process(Self.spans("a b"), context: StageContext())
        #expect(fallback.seen.last?.context == "fallback prompt")
    }

    // MARK: backlog

    @Test func backlogBeyondTheBoundCommitsPassOneWithoutQueueing() async throws {
        let backlog = RefinementBacklog(limit: RefinementBacklog.defaultLimit)
        #expect(await backlog.admit())
        #expect(await backlog.admit())
        #expect(await backlog.depth == 2)

        let input = Self.spans("third segment in a row")
        let reports = ReportBox()
        let refiner = ControllableRefiner(text: "would have been refined", work: .seconds(30))
        let started = ContinuousClock.now
        let out = try await Self.stage(refiner, backlog: backlog, reports: reports)
            .process(input, context: StageContext())
        let elapsed = started.duration(to: .now)

        #expect(out.joinedText == "third segment in a row", "pass-1 is committed, not queued")
        #expect(reports.outcomes == [.backlogFull])
        #expect(elapsed < .milliseconds(500), "a rejected segment does not wait for anything")
        #expect(refiner.seen.count == 0, "the session was never called")
        #expect(await backlog.rejectedCount == 1)
        Self.assertContract(input, out)
    }

    @Test func inFlightSegmentsOccupyTheBacklogAndTheThirdIsRejected() async throws {
        let backlog = RefinementBacklog(limit: 2)
        let slow = ControllableRefiner(text: "slow refinement here", work: .milliseconds(400))
        let reports = ReportBox()
        let input = Self.spans("a b c")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    _ = try? await Self.stage(slow, backlog: backlog, reports: reports)
                        .process(input, context: StageContext())
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(80))
                let out = try? await Self.stage(ControllableRefiner(text: "third"), backlog: backlog,
                                                reports: reports)
                    .process(input, context: StageContext())
                #expect(out?.joinedText == "a b c", "the third segment keeps pass-1 text")
            }
            await group.waitForAll()
        }
        #expect(reports.outcomes.filter { $0 == .backlogFull }.count == 1)
        #expect(reports.outcomes.filter { $0 == .refined }.count == 2)
        #expect(await backlog.depth == 0, "slots are given back")
    }

    @Test func backlogAdmitsAgainAfterASlotIsReleased() async throws {
        let backlog = RefinementBacklog(limit: 2)
        #expect(await backlog.admit())
        #expect(await backlog.admit())
        #expect(await backlog.admit() == false)
        await backlog.release()
        #expect(await backlog.admit())
        #expect(await backlog.admittedCount == 3)
        #expect(await backlog.rejectedCount == 1)
        await backlog.release()
        await backlog.release()
        await backlog.release()
        #expect(await backlog.depth == 0, "release never goes negative")
    }

    // MARK: committed text

    @Test func aCommittedSpanIsNeverRewritten() async throws {
        let input = Self.spans("already in the field", stability: .committed)
        let reports = ReportBox()
        let refiner = ControllableRefiner(text: "totally different words now")
        let out = try await Self.stage(refiner, reports: reports).process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "already in the field")
        #expect(out.allSatisfy { $0.stability == .committed })
        #expect(reports.outcomes == [.alreadyCommitted])
        #expect(refiner.seen.count == 0, "no pass is even started for delivered text")
    }

    @Test func oneCommittedSpanDropsTheWholeSegmentsRefinement() async throws {
        var input = Self.spans("half of this landed")
        input[1].stability = .committed
        let out = try await Self.stage(ControllableRefiner(text: "none of this lands"))
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "half of this landed")
    }

    @Test func aLateResultDoesNotOverwriteCommittedText() async throws {
        // The text is committed *while* the pass runs — the real race. The probe is how the stage
        // re-reads that, and `stabilized(_:)` being forward-only is why there is nothing to undo.
        let committed = Latch()
        let refiner = ControllableRefiner(text: "the late refinement", work: .milliseconds(20),
                                          whileRunning: { committed.set() })
        let reports = ReportBox()
        let input = Self.spans("the first pass text")
        let out = try await Self.stage(refiner, stabilityAtApply: { _ in committed.isSet ? .committed : .final },
                                       reports: reports)
            .process(input, context: StageContext())

        Self.assertContract(input, out)
        #expect(out.joinedText == "the first pass text", "the delivered words stand")
        #expect(reports.outcomes == [.lateResultDropped])
        #expect(out.allSatisfy { !$0.refinedConfidenceUnavailable })
        // Forward-only stability: there is no expressible downgrade, and the stage does not move it.
        #expect(out.allSatisfy { $0.stability == .final })
        #expect(input[0].stabilized(.provisional).stability == .final, "a downgrade is a no-op")
    }

    @Test func anOnTimeResultStillLandsWhenNothingWasCommitted() async throws {
        let input = Self.spans("the first pass text", stability: .provisional)
        let out = try await Self.stage(ControllableRefiner(text: "the refined pass text"),
                                       stabilityAtApply: { _ in .provisional })
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "the refined pass text")
        #expect(out.allSatisfy { $0.isProvisional }, "the stage does not settle text")
    }

    // MARK: word timing

    @Test func refinedWordsAreRealignedOverThePassOneAudioMap() async throws {
        // 2.0 s of audio in three spans: 1.0 s, 0.5 s, 0.5 s → a 8-word refinement splits 4/2/2.
        let input = [
            TranscriptSpan(text: "one two three four", confidence: 0.9, audioRange: 0...1.0, provenance: [.asr]),
            TranscriptSpan(text: "five six", confidence: 0.9, audioRange: 1.0...1.5, provenance: [.asr]),
            TranscriptSpan(text: "seven eight", confidence: 0.9, audioRange: 1.5...2.0, provenance: [.asr]),
        ]
        let out = try await Self.stage(ControllableRefiner(text: "ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT"))
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.map(\.text) == ["ONE TWO THREE FOUR", "FIVE SIX", "SEVEN EIGHT"])
        #expect(out.map(\.audioRange) == input.map(\.audioRange), "re-alignment never moves audio")
    }

    @Test func aWordCountThatDoesNotDivideEvenlyStaysInOrderAndKeepsEveryRange() async throws {
        let input = Self.spans("a b c d")   // four equal 0.25 s spans
        let out = try await Self.stage(ControllableRefiner(text: "w x y z zz"))
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText.split(separator: " ").map(String.init) == ["w", "x", "y", "z", "zz"],
                "word order is preserved across the segment")
        #expect(out.map(\.audioRange) == input.map(\.audioRange))
    }

    @Test func fewerRefinedWordsThanSpansLeavesTailSpansEmptyButPresent() async throws {
        let input = Self.spans("one two three four five")
        let out = try await Self.stage(ControllableRefiner(text: "two words")).process(input, context: StageContext())
        Self.assertContract(input, out)          // no audioRange is dropped
        #expect(out.filter { !$0.text.isEmpty }.map(\.text) == ["two", "words"])
        #expect(out.count == 5)
    }

    @Test func allocationIsProportionalMinimalAndTotal() {
        #expect(RefinedWordAlignment.allocate(wordCount: 10, durations: [1.0, 1.0]) == [5, 5])
        #expect(RefinedWordAlignment.allocate(wordCount: 10, durations: [3.0, 1.0]).reduce(0, +) == 10)
        #expect(RefinedWordAlignment.allocate(wordCount: 10, durations: [3.0, 1.0]) == [8, 2])
        #expect(RefinedWordAlignment.allocate(wordCount: 3, durations: [1.0, 1.0, 1.0]) == [1, 1, 1])
        // A span too short for a proportional share still gets a word before anyone gets a second.
        let lopsided = RefinedWordAlignment.allocate(wordCount: 3, durations: [10.0, 0.05, 0.05])
        #expect(lopsided == [1, 1, 1])
        #expect(RefinedWordAlignment.allocate(wordCount: 10, durations: [10.0, 0.05, 0.05]) == [8, 1, 1])
        // Zero-length spans: equal split, nothing divided by zero.
        #expect(RefinedWordAlignment.allocate(wordCount: 4, durations: [0, 0]) == [2, 2])
        #expect(RefinedWordAlignment.allocate(wordCount: 0, durations: [1.0, 1.0]) == [0, 0])
        #expect(RefinedWordAlignment.allocate(wordCount: 5, durations: []).isEmpty)
        #expect(RefinedWordAlignment.allocate(wordCount: 2, durations: [1.0, 1.0, 1.0]).reduce(0, +) == 2)
    }

    // MARK: confidence

    /// V3 §5.3: "never attach old confidence to different words … mark unavailable confidence
    /// explicitly". The number is preserved because `ConfidenceContract` treats any change to it as
    /// a dropped-confidence violation and because 0 would read as "the recognizer was unsure" —
    /// the *claim* is withdrawn in provenance instead, which is machine-readable and not silent.
    @Test func changedWordsMarkTheOldConfidenceUnavailable() async throws {
        let input = [TranscriptSpan(text: "for thirty", confidence: 0.77, audioRange: 0...0.8, provenance: [.asr])]
        let out = try await Self.stage(ControllableRefiner(text: "four thirty")).process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out[0].text == "four thirty")
        #expect(out[0].refinedConfidenceUnavailable)
        #expect(out[0].provenance == [.asr, .refineConfidenceUnavailable, .refine])
        #expect(out[0].confidence == 0.77, "the field is preserved; the claim about it is not")
    }

    @Test func unchangedWordsKeepTheirConfidenceClaim() async throws {
        let input = [TranscriptSpan(text: "four thirty", confidence: 0.77, audioRange: 0...0.8, provenance: [.asr])]
        let out = try await Self.stage(ControllableRefiner(text: "four thirty")).process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(!out[0].refinedConfidenceUnavailable)
        #expect(out[0].provenance == [.asr, .refine])
        #expect(out[0].confidence == 0.77)
    }

    /// A second *recognition* pass is what low pass-1 confidence is supposed to trigger (V3 §5.3),
    /// so the rewrite stands — but Bet 9 means it must not be presented as settled text.
    @Test func aRewrittenLowConfidenceSpanIsFlaggedForRepair() async throws {
        let input = [
            TranscriptSpan(text: "conference call with", confidence: 0.93, audioRange: 0...0.9, provenance: [.asr]),
            TranscriptSpan(text: "team fuel h e", confidence: 0.21, audioRange: 0.9...1.8, provenance: [.asr]),
        ]
        let out = try await Self.stage(ControllableRefiner(text: "conference call with TeamViewer AG"))
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out[1].text != input[1].text, "the pass is allowed to fix what pass 1 was unsure about")
        #expect(out[1].needsRepair, "a rewritten low-confidence span is flagged, not settled (Bet 9)")
        #expect(out[1].refinedConfidenceUnavailable)
        #expect(!out[0].needsRepair)
    }

    @Test func aLowConfidenceSpanThePassAgreesWithIsNotFlagged() async throws {
        let input = [TranscriptSpan(text: "kothari", confidence: 0.1, audioRange: 0...0.4, provenance: [.asr])]
        let out = try await Self.stage(ControllableRefiner(text: "kothari")).process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(!out[0].needsRepair)
    }

    // MARK: quiet paths

    @Test func emptyInputIsReturnedUntouched() async throws {
        let out = try await Self.stage(ControllableRefiner()).process([], context: StageContext())
        #expect(out.isEmpty)
    }

    @Test func theStageAppliesToEveryRegister() async throws {
        let input = Self.spans("register independent")
        for register in Utterance.Register.allCases {
            let stage = Self.stage(ControllableRefiner(text: "register independent output"))
            #expect(StageApplicability.applies(stage, to: register))
            let out = try await stage.process(input, context: StageContext(register: register))
            #expect(out.joinedText == "register independent output", "\(register)")
        }
    }

    @Test func aDisabledRunStillRecordsThatItLooked() async throws {
        let input = Self.spans("gate says no")
        let refiner = ControllableRefiner(text: "would refine")
        let reports = ReportBox()
        let out = try await Self.stage(refiner, reports: reports)
            .process(input, context: StageContext(extra: [RefineStage.enabledKey: "false"]))
        Self.assertContract(input, out)
        #expect(out.joinedText == "gate says no")
        #expect(refiner.seen.count == 0)
        #expect(reports.outcomes == [.disabled])
    }

    @Test func noAudioMeansNoPass() async throws {
        let input = Self.spans("nothing to hear")
        let refiner = ControllableRefiner()
        let reports = ReportBox()
        let out = try await Self.stage(refiner, reports: reports, samples: [])
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "nothing to hear")
        #expect(refiner.seen.count == 0)
        #expect(reports.outcomes == [.noAudio])
    }

    @Test func anEmptyRefinementIsNotAllowedToEraseTheText() async throws {
        let input = Self.spans("do not vanish")
        let reports = ReportBox()
        let out = try await Self.stage(ControllableRefiner(text: "  \n "), reports: reports)
            .process(input, context: StageContext())
        Self.assertContract(input, out)
        #expect(out.joinedText == "do not vanish")
        #expect(reports.outcomes == [.emptyResult])
    }

    @Test func outcomesSayWhetherPassOneIsWhatTheCallerHas() {
        for outcome in RefineOutcome.allCases where outcome != .refined {
            #expect(outcome.keptPassOne, "\(outcome)")
        }
        #expect(!RefineOutcome.refined.keptPassOne)
    }
}
