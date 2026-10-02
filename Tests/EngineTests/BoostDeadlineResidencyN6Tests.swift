import Foundation
import Shared
import Testing
@testable import Engine

private func tk(_ id: Int, _ text: String, _ s: Double, _ e: Double, p: Float = 0.9) -> DecodedToken {
    DecodedToken(tokenId: id, text: text, logProb: log(p), startTime: s, endTime: e)
}
private let raw = [tk(1, "▁mister", 0.0, 0.3), tk(2, "▁kot", 0.3, 0.5, p: 0.5), tk(3, "ari", 0.5, 0.7, p: 0.6),
                   tk(4, "▁will", 0.7, 0.9), tk(5, "▁join", 0.9, 1.2)]

/// A booster whose rescoring takes `delay` seconds (the 13.8 s first compile, E1F62700).
private struct SlowBooster: BoostReporting {
    let terms = ["Kothari"]
    let delay: TimeInterval
    func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? {
        await boostReport(tokens: tokens, samples: samples).outcome
    }
    func boostReport(tokens: [DecodedToken], samples: [Float]) async -> BoostReport {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let o = await ScriptedVocabularyBooster(terms: terms, rewrites: ["kotari": "Kothari"]).boost(tokens: tokens, samples: samples)
        return BoostReport(outcome: o, status: .boosted, rescoreMs: delay * 1000)
    }
    func prepare() {}
}

/// Counts every load request; never has a model ready.
private actor CountingSource: CTCBoostingModelSource {
    var runtimeCalls = 0
    var prepareCalls = 0
    var ready: (any CTCRescoring)?
    init(ready: (any CTCRescoring)? = nil) { self.ready = ready }
    func runtime() async -> CTCBoostingRuntime? { runtimeCalls += 1; return nil }
    func readyRescorer() async -> (any CTCRescoring)? {
        if let ready { return ready }
        await prepare()
        return nil
    }
    func prepare() async { prepareCalls += 1 }
}

private struct FakeRescorer: CTCRescoring {
    func rescore(tokens: [DecodedToken], samples: [Float], terms: [String]) async -> BoostOutcome? {
        await ScriptedVocabularyBooster(terms: terms, rewrites: ["kotari": "Kothari"]).boost(tokens: tokens, samples: samples)
    }
    func prepareRescorer(terms: [String]) async {}
}

@Suite("N6: booster deadline, no load in a turn, residency")
struct BoostDeadlineResidencyN6Tests {
    // MARK: deadline

    @Test func slowBoosterLandsUnboostedWithinTheDeadline() async {
        let t0 = Date()
        let step = await FluidAudioTDTDecoder.finalBoost(raw, samples: [], timeOffset: 0,
                                                         booster: SlowBooster(delay: 5), deadline: 0.3)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 1.0, "the final pass waited \(elapsed) s on a slow booster")
        #expect(step.report.status == .timedOut)
        #expect(step.tokens == raw, "past the deadline the unboosted text lands unchanged")
        #expect(step.report.outcome == nil)
    }

    @Test func productionDeadlineIsOnePointFiveSeconds() async {
        #expect(FluidAudioTDTDecoder.defaultBoostDeadline == 1.5)
        let t0 = Date()
        let step = await FluidAudioTDTDecoder.finalBoost(raw, samples: [], timeOffset: 0, booster: SlowBooster(delay: 20),
                                                         deadline: FluidAudioTDTDecoder.defaultBoostDeadline)
        #expect(Date().timeIntervalSince(t0) < 2.5)
        #expect(step.report.status == .timedOut)
    }

    @Test func fastBoosterStillBoostsAndKeepsTimeOffset() async {
        let shifted = raw.map { FluidAudioTDTDecoder.shift($0, by: 10) }
        let step = await FluidAudioTDTDecoder.finalBoost(shifted, samples: [], timeOffset: 10,
                                                         booster: SlowBooster(delay: 0.01), deadline: 1.5)
        #expect(step.tokens.renderedText == "mister Kothari will join")
        #expect(step.tokens.first?.startTime == 10)
        #expect(step.report.status == .boosted)
    }

    @Test func noBoosterIsNotApplied() async {
        let step = await FluidAudioTDTDecoder.finalBoost(raw, samples: [], timeOffset: 0, booster: nil, deadline: 1.5)
        #expect(step.report.status == .notApplied)
        #expect(step.tokens == raw)
    }

    // MARK: no model load inside a turn

    @Test func finalPassNeverLoadsTheModel() async {
        let source = CountingSource()
        let booster = CTCVocabularyBooster(terms: ["Kothari"], source: source)
        let report = await booster.boostReport(tokens: raw, samples: [0])
        #expect(report.status == .modelNotReady)
        #expect(report.outcome == nil)
        #expect(await source.runtimeCalls == 0, "the turn must not load the model")
        #expect(await source.prepareCalls == 1, "a cold model is reloaded in the background instead")
    }

    @Test func readyModelBoostsAndReportsStages() async {
        let booster = CTCVocabularyBooster(terms: ["Kothari"], source: CountingSource(ready: FakeRescorer()))
        let report = await booster.boostReport(tokens: raw, samples: [0])
        #expect(report.status == .boosted)
        #expect(report.outcome?.tokens.renderedText == "mister Kothari will join")
        #expect(report.modelWaitMs < 100)
    }

    @Test func emptyTermsSkipBoosting() async {
        let source = CountingSource(ready: FakeRescorer())
        let report = await CTCVocabularyBooster(terms: [], source: source).boostReport(tokens: raw, samples: [0])
        #expect(report.status == .notApplied)
    }

    @Test func timingRecordsRawPreBoostText() {
        let t = FinalPassTiming(recogniseMs: 210, rescoreMs: 40, totalMs: 260, boostStatus: .boosted,
                                rawPreBoostText: "mister kotari will join", finalText: "mister Kothari will join")
        #expect(t.wasBoosted)
        #expect(!t.logLine.contains("kotari"), "logs carry stage ms only, never transcript text")
        #expect(t.logLine.contains("rescore 40 ms"))
    }

    // MARK: residency (§D)

    @Test func managedSourceUsesAStableResidentKey() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip)
        let residency = ModelResidency(budgetBytes: ResidencyBudget.gib)
        let status = SpeechModelPreparation()
        let a = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false, residency: residency,
                                         prepareAtLaunch: false, status: status)
        let b = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false, residency: residency,
                                         prepareAtLaunch: false, status: status)
        #expect(a.residencyKey == "boost.parakeet-ctc-110m-coreml#app")
        #expect(a.residencyKey == b.residencyKey, "stable across rebuilt sources")
        #expect(ManagedCTCBoostingSource.residencyTier == .resident)
        // Missing model: the turn gets nil at once; the background prepare reports unavailable.
        #expect(await a.readyRescorer() == nil)
        await a.waitUntilPrepared()
        #expect(status.state == .unavailable)
        #expect(await !residency.isRegistered(a.residencyKey))
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var v: [String] = []
        func add(_ s: String) { lock.withLock { v.append(s) } }
        var all: [String] { lock.withLock { v } }
    }

    @Test func residentTierSurvivesIdleAndWarningAndLeavesFirstUnderCritical() async throws {
        let residency = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let unloads = Flag()
        await residency.register("asr.tdt", tier: .always, estimatedBytes: 500_000_000,
                                 load: {}, unload: { unloads.add("asr.tdt") })
        await residency.register("boost.ctc", tier: .resident, estimatedBytes: 200_000_000,
                                 load: {}, unload: { unloads.add("boost.ctc") })
        await residency.register("cleanup", tier: .onDemand, estimatedBytes: 300_000_000,
                                 load: {}, unload: { unloads.add("cleanup") })
        for k in ["asr.tdt", "boost.ctc", "cleanup"] { try await residency.acquire(k) }

        // Everything is "idle" with a zero timeout.
        await residency.setIdleTimeout(0)
        let idled = await residency.sweepIdle()
        #expect(idled == ["cleanup"], "the booster never idles out")
        #expect(await residency.isResident("boost.ctc"))

        try await residency.acquire("cleanup")
        await residency.handleMemoryPressure(.warning)
        #expect(await residency.isResident("boost.ctc"), "a memory warning keeps the booster")
        #expect(await !residency.isResident("cleanup"))

        await residency.handleMemoryPressure(.critical)
        #expect(await !residency.isResident("boost.ctc"), "critical pressure drops it")
        #expect(await residency.isResident("asr.tdt"), "…before the recogniser, which stays")
        #expect(unloads.all == ["cleanup", "cleanup", "boost.ctc"])
    }

    @Test func residentTierLoadsOverBudgetLikeAlways() async throws {
        let residency = ModelResidency(budgetBytes: 100)
        await residency.register("boost.ctc", tier: .resident, estimatedBytes: 200_000_000, load: {}, unload: {})
        try await residency.acquire("boost.ctc")
        #expect(await residency.isResident("boost.ctc"))
    }

    @Test func bundledCandidatesIncludeTheBoostingModel() {
        let res = URL(fileURLWithPath: "/tmp/VoicePlus.app/Contents/Resources")
        let c = BundledModelResources.candidates(resources: res)
        #expect(c[.parakeetCTC110m]?.lastPathComponent == "parakeet-ctc-110m-coreml")
        for id in ModelStack.models { #expect(c[id] != nil) }
    }
}
