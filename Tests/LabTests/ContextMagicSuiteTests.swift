import Foundation
import Testing
import Shared
@testable import Lab

/// Context Writer plan §10.1 — the `context-magic` suite: manifest, bake-off scorer parity, report
/// math and gates, skipped-not-dropped cases, CLI registration.
@Suite struct ContextMagicSuiteTests {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("context-magic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func packet(_ heard: String) -> ContextPacket {
        ContextPacket(destination: .init(profileID: "ai.chat"), heard: .init(raw: heard))
    }

    static func makeCase(_ id: String, kind: ContextMagicCase.Kind, heard: String, recording: String? = nil, wav: String? = nil,
                         expect: ContextMagicCase.Expectation) -> ContextMagicCase {
        ContextMagicCase(id: id, kind: kind, recording: recording, wav: wav, heard: heard, packet: packet(heard), expect: expect)
    }

    // MARK: manifest

    @Test func manifestLoadsTheBakeoffCases() throws {
        let suite = try ContextMagicSuite.load()
        let cases = suite.manifest.cases
        #expect(suite.manifest.suite == "context-magic")
        #expect(cases.count == 24)
        #expect(cases.filter { $0.kind == .fix }.count == 16)
        #expect(cases.filter { $0.kind == .control }.count == 8)
        #expect(Set(cases.map(\.id)).count == 24)
        for c in cases {
            #expect(!c.packet.heard.raw.isEmpty, Comment(rawValue: c.id))
            #expect(c.heard == c.packet.heard.raw, Comment(rawValue: c.id))
            #expect(c.packet.mode == .transcribe)
            #expect(!c.packet.destination.profileID.isEmpty)
            #expect(!c.packet.heard.raw.contains("[["), Comment(rawValue: "marks must be words, not text: \(c.id)"))
            // A control is either `unchanged` or a contains/not-contains control; a fix always has must_contain.
            if c.kind == .fix { #expect(!c.expect.mustContain.isEmpty, Comment(rawValue: c.id)) }
            #expect(c.kind == .control || !c.expect.unchanged)
        }
        let a16z = try #require(cases.first { $0.id == "a16z-codex" })
        #expect(a16z.recording == "2026-10-06-233509-411")
        #expect(a16z.packet.heard.words.map(\.isUncertain) == [true, true, true])
        #expect(a16z.packet.destination.appBundleID == "com.openai.codex")
        let qwen = try #require(cases.first { $0.id == "qwen4b-boosted" })
        #expect(qwen.packet.screenTerms.contains("Qwen3.5-4B"))
        #expect(qwen.packet.heard.words.first { $0.text == "Code" }?.alternates == ["mode"])
        #expect(qwen.packet.heard.words.first { $0.text == "models" }?.alternates == ["model as well"])
        let thread = try #require(cases.first { $0.id == "a16z-thread" })
        #expect(thread.packet.textBefore.hasPrefix("Make a list"))
        let noAudio = try #require(cases.first { $0.id == "selfcorrect" })
        #expect(!noAudio.namesAudio && noAudio.heardText.contains("Kothari"))
        #expect(cases.first { $0.id == "ctrl-icon" }?.expect.unchanged == true)
    }

    @Test func expectationDecodesWithDefaults() throws {
        let json = #"{"must_contain": ["a16z"]}"#
        let e = try JSONDecoder().decode(ContextMagicCase.Expectation.self, from: Data(json.utf8))
        #expect(e == .init(mustContain: ["a16z"], mustNotContain: [], unchanged: false))
    }

    // MARK: scorer parity with tools/correction-bakeoff/bakeoff.py (values computed with the Python)

    @Test func normalizeMatchesBakeoffNorm() {
        #expect(ContextMagicScorer.normalize("[[A]] [[sixtien]] [[z]].") == "a sixtien z")
        // Whitespace is collapsed before punctuation is stripped: the dash leaves a double space, as in Python.
        #expect(ContextMagicScorer.normalize("  Let's   use E — it's \"fine\"! ") == "lets use e  its fine")
    }

    @Test func scorerMatchesBakeoffOnSixExamples() {
        typealias E = ContextMagicCase.Expectation
        let question = E(unchanged: true)
        let heardQ = "Can you also find out how Google News works?"
        #expect(ContextMagicScorer.score(question, heard: heardQ, output: "can you also find out how google news works") == .init(ok: true, why: ""))
        #expect(ContextMagicScorer.score(E(unchanged: true), heard: "Start implementing the plan.", output: "Start implementing the plan now.")
                == .init(ok: false, why: "changed a clean dictation"))
        let a16z = E(mustContain: ["a16z"], mustNotContain: ["sixt"])
        #expect(ContextMagicScorer.score(a16z, heard: "A sixtien z.", output: "a16z.") == .init(ok: true, why: ""))
        #expect(ContextMagicScorer.score(a16z, heard: "A sixtien z.", output: "A sixteen Z") == .init(ok: false, why: "missing 'a16z'"))
        let email = E(mustContain: ["Thanks for the call yesterday", "term sheet", "Friday"], mustNotContain: [" um ", " uh ", "Hi Rahul"])
        let heardE = "thanks for the call yesterday um so we are good to go with the term sheet uh can you send the final version by friday"
        #expect(ContextMagicScorer.score(email, heard: heardE, output: "Hi Rahul, thanks for the call yesterday um so we are good to go with the term sheet, can you send the final version by Friday")
                == .init(ok: false, why: "still has ' um '"))
        let articles = E(mustContain: ["editorial, reporting, opinion"], mustNotContain: ["Sure,", "Here is", "Here's"])
        #expect(ContextMagicScorer.score(articles, heard: "x", output: "Sure, here it is: Make sure you are marking editorial, reporting, opinion, analysis.")
                == .init(ok: false, why: "still has 'Sure,'"))
        #expect(ContextMagicScorer.score(E(mustContain: ["final"], mustNotContain: ["*dial"]), heard: "Invest *dial", output: "Invest final") == .init(ok: true, why: ""))
        #expect(ContextMagicScorer.score(E(unchanged: true), heard: "the code review is done", output: "the Codecov review is done")
                == .init(ok: false, why: "changed a clean dictation"))
    }

    // MARK: report math and gates

    static func result(_ id: String, _ kind: ContextMagicCase.Kind, _ status: ContextMagicResult.Status, ms: Double = 0) -> ContextMagicResult {
        ContextMagicResult(id: id, kind: kind, status: status, ms: ms)
    }

    static func report(_ results: [ContextMagicResult], tier: ContextMagicReport.Tier = .cloud, budget: Double? = nil) -> ContextMagicReport {
        ContextMagicReport(writer: "t", tier: tier, budgetMs: budget ?? tier.budgetMs, textOnly: true, startedAt: Date(), finishedAt: Date(), results: results)
    }

    @Test func reportCountsPercentilesAndGates() {
        let r = Self.report([
            .init(id: "f1", kind: .fix, status: .pass, ms: 100), .init(id: "f2", kind: .fix, status: .pass, ms: 200),
            .init(id: "f3", kind: .fix, status: .pass, ms: 300), .init(id: "f4", kind: .fix, status: .pass, ms: 400),
            .init(id: "f5", kind: .fix, status: .fail, why: "missing 'x'", ms: 900),
            .init(id: "f6", kind: .fix, status: .skipped, why: "missing recording"),
            .init(id: "c1", kind: .control, status: .pass, ms: 150), .init(id: "c2", kind: .control, status: .pass, ms: 250),
        ])
        #expect(r.fixesPassed == 4 && r.fixesAttempted == 5 && r.fixRate == 0.8)
        #expect(r.controlsKept == 2 && r.controlsAttempted == 2 && r.skipped == 1 && r.errors == 0)
        // Latencies: 100 150 200 250 300 400 900 → nearest-rank p50 = 250, p90 = 900.
        #expect(r.p50Ms == 250 && r.p90Ms == 900)
        #expect(r.gates == .init(fixes: true, controls: true, latency: true) && r.passed)
        #expect(r.summaryLine == "fixes 4/5 (80 %) · controls kept 2/2 · skipped 1 · errors 0 · added p50 250 ms · p90 900 ms")
        let md = r.markdown()
        #expect(md.contains("**PASS** (1 skipped: audio not on this Mac)"))
        #expect(md.contains("| f6 | fix | text | SKIPPED | — |  | missing recording |"))
        #expect(md.contains("| f5 | fix | text | FAIL | 900 ms |  | missing 'x' |"))
    }

    @Test func gatesFailOnEachAxis() {
        let base: [ContextMagicResult] = [
            .init(id: "f1", kind: .fix, status: .pass, ms: 100), .init(id: "f2", kind: .fix, status: .pass, ms: 100),
            .init(id: "f3", kind: .fix, status: .pass, ms: 100), .init(id: "f4", kind: .fix, status: .pass, ms: 100),
            .init(id: "f5", kind: .fix, status: .pass, ms: 100), .init(id: "c1", kind: .control, status: .pass, ms: 100),
        ]
        #expect(Self.report(base).passed)
        var fixes = base; fixes[0].status = .fail; fixes[1].status = .error          // 3/5 = 60 %
        #expect(Self.report(fixes).gates == .init(fixes: false, controls: true, latency: true))
        #expect(Self.report(fixes).errors == 1 && Self.report(fixes).latencies.count == 5)
        var controls = base; controls[5].status = .fail
        #expect(Self.report(controls).gates == .init(fixes: true, controls: false, latency: true))
        var slow = base; for i in slow.indices { slow[i].ms = 500 }
        #expect(Self.report(slow).gates == .init(fixes: true, controls: true, latency: false))
        #expect(Self.report(slow, tier: .local).gates.latency, "600 ms local budget")
        #expect(Self.report(slow, budget: 450).gates.latency == false)
        // Nothing attempted: every gate fails rather than passing vacuously.
        let empty = Self.report([.init(id: "f1", kind: .fix, status: .skipped), .init(id: "c1", kind: .control, status: .skipped)])
        #expect(empty.gates == .init(fixes: false, controls: false, latency: false) && empty.skipped == 2)
        #expect(ContextMagicReport.Tier.cloud.budgetMs == 400 && ContextMagicReport.Tier.local.budgetMs == 600)
    }

    @Test func reportRoundTripsAsJSON() throws {
        let r = Self.report([.init(id: "f1", kind: .fix, status: .pass, ms: 12.5, input: "audio")])
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(ContextMagicReport.self, from: Data(try r.json().utf8))
        #expect(back.results == r.results && back.tier == .cloud && back.budgetMs == 400)
    }

    // MARK: resolution — skipped, never dropped

    @Test func missingRecordingIsSkippedAndCountedNotDropped() async throws {
        let recordings = try Self.tempDir()
        try Data([0]).write(to: recordings.appendingPathComponent("2026-10-06-230656-611-raw.wav"))
        let manifest = ContextMagicManifest(cases: [
            Self.makeCase("gone", kind: .fix, heard: "till face two", recording: "2026-10-06-999999-000", expect: .init(mustContain: ["phase"])),
            Self.makeCase("here", kind: .fix, heard: "till face two", recording: "2026-10-06-230656-611", expect: .init(mustContain: ["phase"])),
            Self.makeCase("wav-gone", kind: .control, heard: "ok", wav: "nope/missing.wav", expect: .init(unchanged: true)),
            Self.makeCase("text", kind: .control, heard: "ok", expect: .init(unchanged: true)),
        ])
        let suite = ContextMagicSuite(manifest: manifest, fixturesDirectory: AppPaths.fixturesDirectory(), recordingsDirectory: recordings)

        #expect(suite.resolve(manifest.cases[0], textOnly: false) == .skipped("missing recording 2026-10-06-999999-000 in \(recordings.path)"))
        #expect(suite.resolve(manifest.cases[1], textOnly: false) == .audio(recordings.appendingPathComponent("2026-10-06-230656-611-raw.wav")))
        #expect(suite.resolve(manifest.cases[2], textOnly: false) == .skipped("missing Fixtures/audio/nope/missing.wav"))
        #expect(suite.resolve(manifest.cases[3], textOnly: false) == .text)
        #expect(suite.resolve(manifest.cases[0], textOnly: true) == .text)

        let report = await suite.run(writer: EchoContextMagicRunner(), writerName: "echo")
        #expect(report.results.map(\.id) == ["gone", "here", "wav-gone", "text"])
        #expect(report.results.map(\.status) == [.skipped, .fail, .skipped, .pass])
        #expect(report.results.map(\.input) == ["text", "audio", "text", "text"])
        #expect(report.results[0].why.hasPrefix("missing recording 2026-10-06-999999-000"))
        #expect(report.skipped == 2 && report.fixesAttempted == 1 && report.controlsAttempted == 1)
        #expect(report.markdown().contains("| gone | fix | text | SKIPPED |"))

        let textOnly = await suite.run(writer: EchoContextMagicRunner(), writerName: "echo", textOnly: true)
        #expect(textOnly.skipped == 0 && textOnly.results.map(\.status) == [.fail, .fail, .pass, .pass])
    }

    @Test func processedClipIsPreferredOverRaw() throws {
        let recordings = try Self.tempDir()
        try Data([0]).write(to: recordings.appendingPathComponent("s-raw.wav"))
        try Data([0]).write(to: recordings.appendingPathComponent("s-processed.wav"))
        let c = Self.makeCase("s", kind: .fix, heard: "x", recording: "s", expect: .init(mustContain: ["y"]))
        let suite = ContextMagicSuite(manifest: .init(cases: [c]), fixturesDirectory: nil, recordingsDirectory: recordings)
        #expect(suite.audioURL(for: c) == recordings.appendingPathComponent("s-processed.wav"))
        let wav = Self.makeCase("w", kind: .fix, heard: "x", wav: "clean/clean_01_samantha.wav", expect: .init(mustContain: ["y"]))
        let real = ContextMagicSuite(manifest: .init(cases: [wav]), fixturesDirectory: AppPaths.fixturesDirectory(), recordingsDirectory: recordings)
        #expect(real.audioURL(for: wav)?.lastPathComponent == "clean_01_samantha.wav")
    }

    @Test func writerErrorsAreCountedAsFailures() async throws {
        struct Boom: ContextMagicRunning {
            func run(_ input: ContextMagicInput) async throws -> (text: String, ms: Double) { throw LabError.badArguments("boom") }
        }
        let suite = ContextMagicSuite(manifest: .init(cases: [Self.makeCase("f", kind: .fix, heard: "x", expect: .init(mustContain: ["y"]))]),
                                      fixturesDirectory: nil, recordingsDirectory: try Self.tempDir())
        let report = await suite.run(writer: Boom(), writerName: "boom")
        #expect(report.results[0].status == .error && report.results[0].why.contains("boom"))
        #expect(report.errors == 1 && report.fixesAttempted == 1 && report.fixesPassed == 0 && report.latencies.isEmpty)
    }

    // MARK: CLI

    @Test func cliRunsTheSuiteWithTheEchoWriter() async throws {
        let listed = await LabCLI.main(["suites"])
        #expect(listed.text.split(separator: "\n").contains("context-magic"))

        let md = await LabCLI.main(["run", "--suites", "context-magic", "--text-only"])
        #expect(md.exitCode == 0, Comment(rawValue: md.text))
        #expect(md.text.hasPrefix("# Lab report — context-magic"))
        #expect(md.text.contains("fixes 0/16 (0 %) · controls kept 8/8 · skipped 0 · errors 0"))
        #expect(md.text.contains("| controls | 100 % | 8/8 | PASS |") && md.text.contains("| fixes | ≥ 80 % | 0 % (0/16) | FAIL |"))
        #expect(md.text.contains("**FAIL**"))
        let report = try #require(md.contextMagic)
        #expect(report.results.count == 24 && report.writer == "echo" && report.tier == .cloud)
        #expect(report.results.first { $0.id == "ctrl-instruction" }?.status == .pass, "echoing an injection keeps 'ignore' and never writes the poem")

        let gated = await LabCLI.main(["run", "--suites", "context-magic", "--text-only", "--gate"])
        #expect(gated.exitCode == 1)

        let dir = try Self.tempDir()
        let outFile = dir.appendingPathComponent("cm.json").path
        let js = await LabCLI.main(["run", "--suites", "context-magic", "--text-only", "--tier", "local", "--format", "json", "--out", outFile])
        #expect(js.exitCode == 0)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(ContextMagicReport.self, from: Data(contentsOf: URL(fileURLWithPath: outFile)))
        #expect(decoded.budgetMs == 600 && decoded.textOnly && decoded.results.count == 24)
    }

    @Test func cliRejectsBadArguments() async {
        let mixed = await LabCLI.main(["run", "--suites", "clean,context-magic"])
        #expect(mixed.exitCode == 2 && mixed.text.contains("runs on its own"))
        let writer = await LabCLI.main(["run", "--suites", "context-magic", "--writer", "ghost"])
        #expect(writer.exitCode == 2 && writer.text.contains("unknown writer") && writer.text.contains("ghost") && writer.text.contains("echo"))
        let tier = await LabCLI.main(["run", "--suites", "context-magic", "--tier", "edge"])
        #expect(tier.exitCode == 2 && tier.text.contains("--tier cloud|local"))
        let budget = await LabCLI.main(["run", "--suites", "context-magic", "--budget-ms", "-1"])
        #expect(budget.exitCode == 2 && budget.text.contains("--budget-ms"))
        let registered = await LabCLI.main(["run", "--suites", "context-magic", "--writer", "custom", "--text-only"],
                                           registry: LabRegistry(contextMagicWriters: ["custom": { EchoContextMagicRunner() }]))
        #expect(registered.exitCode == 0 && registered.contextMagic?.writer == "custom")
    }
}
