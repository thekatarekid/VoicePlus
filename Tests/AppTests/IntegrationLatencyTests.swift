import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// P1.12 T1 — key-release → text landed budget: ≤ 700 ms p50, ≤ 1200 ms p95 (10 s utterance),
/// pipeline-only ≤ 250 ms. MockEngine stands in for the decoder (its final pass is instant, so
/// what is measured is everything *after* ASR: pipeline → gatekeeper → formatter → style →
/// injection through the mock system). The real decoder's final-pass time is reported
/// separately by the golden test / DECISIONS.md.
@Suite("P1.12 — end-to-end latency budget")
struct IntegrationLatencyTests {
    /// ~10 s of speech: 30 spans, email register, with a couple of low-confidence words.
    static func tenSecondFixture() -> TranscriptFixture {
        let words = """
        hi priya thanks for the update on the migration let's sync with the platform team tomorrow \
        morning um I think we should move the cutover to thursday new line also can you loop in \
        marcus from security before we finalize the rollout plan period thanks so much
        """.split(separator: " ").map(String.init)
        var spans: [TranscriptFixture.ScriptedSpan] = []
        let step = 10.0 / Double(words.count)
        for (i, w) in words.enumerated() {
            let conf: Float = (w == "priya" || w == "marcus") ? 0.42 : 0.95
            spans.append(.init(text: w, confidence: conf, audioStart: Double(i) * step, audioEnd: Double(i + 1) * step,
                               alternates: conf < 0.5 ? [Alternate(text: w.capitalized, score: 0.4, source: .beam)] : [],
                               delayMs: Int(step * 1000)))
        }
        return TranscriptFixture(name: "latency_10s", register: .email, spans: spans)
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    static func makeLander(system: MockSystemAccess, database: AppDatabase? = nil) -> UtteranceLander {
        UtteranceLander(pipeline: PipelineRunner.standard(), injector: TextInjector(system: system),
                        system: system, repair: nil, flags: .inMemory(), database: database)
    }

    @Test func tenSecondUtteranceLandsWithinBudgetOver20Runs() async throws {
        let engine = MockEngine(fixture: Self.tenSecondFixture(), delayScale: 0)
        let system = MockSystemAccess()
        let lander = Self.makeLander(system: system, database: try AppDatabase.inMemory())
        var endToEnd: [Double] = []
        var pipelineOnly: [Double] = []

        // Warm-up run (gatekeeper corpus, formatter tables) is excluded — the app prewarms on hotkey-down.
        try await engine.start(prewarm: true)
        _ = await lander.land(try await engine.stop(), startedAt: Date(), focus: system.frontmostApp())

        for _ in 0..<20 {
            try await engine.start(prewarm: true)
            let release = Date()                       // key release
            let spans = try await engine.stop()        // final decoder pass (instant in mock)
            let result = await lander.land(spans, startedAt: release, focus: system.frontmostApp())
            endToEnd.append(Date().timeIntervalSince(release) * 1000)
            pipelineOnly.append(result.pipelineMs)
            #expect(result.landed, "text must land: \(String(describing: result.injection))")
            #expect(result.register == .prose, "TextEdit focus → prose register")
        }
        let p50 = Self.percentile(endToEnd, 0.5), p95 = Self.percentile(endToEnd, 0.95)
        let pp50 = Self.percentile(pipelineOnly, 0.5)
        print("latency: end-to-end p50=\(Int(p50))ms p95=\(Int(p95))ms; pipeline p50=\(Int(pp50))ms p95=\(Int(Self.percentile(pipelineOnly, 0.95)))ms")
        #expect(p50 <= 700, "p50 \(p50) ms over 700 ms budget")
        #expect(p95 <= 1200, "p95 \(p95) ms over 1200 ms budget")
        #expect(pp50 <= 250, "pipeline p50 \(pp50) ms over 250 ms budget")
        #expect(system.field.value.contains("Priya") || system.field.value.contains("priya"))
    }

    @Test func landingRecordsHistoryAndRoutesByRegister() async throws {
        let db = try AppDatabase.inMemory()
        let system = MockSystemAccess()
        let lander = Self.makeLander(system: system, database: db)
        let spans = [TranscriptSpan(text: "hello world", confidence: 0.9, audioRange: 0...1, provenance: [.asr])]
        let result = await lander.land(spans, startedAt: Date(), focus: system.frontmostApp())
        #expect(result.landed)
        #expect(result.route == .dictate)
        let rows = try db.recentDictations(limit: 5)
        #expect(rows.count == 1)
        #expect(rows.first?.id == result.utteranceID.uuidString)
        #expect(rows.first?.appBundleID == "com.apple.TextEdit")
    }

    @Test func emptyUtteranceLandsNothing() async throws {
        let system = MockSystemAccess()
        let lander = Self.makeLander(system: system)
        let result = await lander.land([], startedAt: Date(), focus: system.frontmostApp())
        #expect(result.injection == nil)
        #expect(system.field.value.isEmpty)
    }
}
