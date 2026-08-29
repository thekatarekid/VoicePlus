import Foundation
import Testing
import Shared
@testable import Providers

func stubBinary(_ name: String, script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

@Suite struct CLIAdapterTests {
    @Test func detectsBinaryInSearchPath() throws {
        let bin = try stubBinary("claude", script: "cat")
        let found = CLIDetector(searchPaths: ["/nonexistent", bin.deletingLastPathComponent().path]).detectAll()
        #expect(found.count == 1 && found[0].binary == bin && found[0].tool == .claude)
        #expect(CLIDetector(searchPaths: ["/nonexistent"]).detectAll().isEmpty)
        #expect(found[0].displayName.contains("Uses your existing subscription"))
        #expect(found[0].costClass == .subscription && found[0].capabilities == [.pipeline])
    }

    /// P1.12 T5: relative / empty PATH entries must never resolve a CLI against the working directory.
    @Test func relativeAndEmptyPathEntriesAreIgnored() throws {
        let bin = try stubBinary("codex", script: "cat")
        let dir = bin.deletingLastPathComponent()
        FileManager.default.changeCurrentDirectoryPath(dir.path)
        #expect(CLIDetector(searchPaths: ["", ".", "bin", "../\(dir.lastPathComponent)"]).detectAll().isEmpty)
        #expect(CLIDetector(searchPaths: ["/tmp/../\(dir.path)"]).detectAll().isEmpty)
        #expect(CLIDetector(searchPaths: [dir.path, dir.path]).searchPaths == [dir.path])
        #expect(CLIDetector(searchPaths: [dir.path]).detectAll().map(\.tool) == [.codex])
        #expect(CLIDetector(searchPaths: [dir.path]).locate(CLITool(name: "../codex", arguments: [], promptOnStdin: true)) == nil)
    }

    @Test func stdinPromptRoundTripsAndEnvIsSandboxed() async throws {
        // Echoes stdin back upper-cased, and fails if a secret leaked into env.
        let bin = try stubBinary("claude", script: #"[ -z "$LEAKED_SECRET" ] || exit 9; [ "$1" = "-p" ] || exit 8; tr a-z A-Z"#)
        setenv("LEAKED_SECRET", "hunter2", 1)
        let p = CLIAdapterProvider(tool: .claude, binary: bin, timeout: 5)
        let out = try await p.generate(prompt: "hello ⟦kothari⟧ there", system: "", stage: .style)
        #expect(out.text == "HELLO ⟦KOTHARI⟧ THERE")
        #expect(out.host == "cli:claude")
        try await assertConformance(p)
    }

    @Test func argumentPromptForCodex() async throws {
        let bin = try stubBinary("codex", script: #"[ "$1" = "exec" ] || exit 8; printf '%s' "$3""#)
        let p = CLIAdapterProvider(tool: .codex, binary: bin, timeout: 5)
        let out = try await p.generate(prompt: "Hello kothari there", system: "", stage: .style)
        #expect(out.text == "Hello kothari there")
    }

    @Test func nonZeroExitIsUnavailable() async throws {
        let bin = try stubBinary("claude", script: "echo nope >&2; exit 3")
        let p = CLIAdapterProvider(tool: .claude, binary: bin, timeout: 5)
        await #expect(throws: ProviderError.unavailable("claude exit 3: nope\n")) { _ = try await p.generate(prompt: "x", system: "", stage: .style) }
    }

    @Test func timeoutKillsSubprocess() async throws {
        // The subprocess sleeps far longer than the bar below, so "returned before the sleep could
        // have finished" is what the elapsed check proves — not that the 0.3 s timeout is accurate
        // to the wall clock, which a loaded parallel run makes meaningless (this read 19.3 s
        // against a 15 s bar while taking 0.318 s in isolation).
        let bin = try stubBinary("claude", script: "sleep 120")
        let p = CLIAdapterProvider(tool: .claude, binary: bin, timeout: 0.3)
        let t0 = Date()
        await #expect(throws: ProviderError.timeout) { _ = try await p.generate(prompt: "x", system: "", stage: .style) }
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 60, "timed out after \(elapsed)s — the 120 s subprocess was awaited, not killed")
    }
}

@Suite struct RoutingTests {
    @Test func autoPrefersLocalThenCloudThenRulesFallback() {
        let cloud = FlakyProvider()
        let local = LocalServerProvider(info: LocalServerInfo(kind: .ollama, baseURL: LocalServerKind.ollama.defaultBaseURL, models: ["m"]))
        let t = RoutingTable(providers: [cloud, local], logger: InMemoryNetworkLogger())
        #expect(t.chain(for: .style).map(\.id) == ["local.ollama", "mock.flaky", "local.rules"])
        t.setChoice(.provider("mock.flaky"), for: .style)
        #expect(t.chain(for: .style).map(\.id) == ["mock.flaky", "local.ollama", "local.rules"])
        t.setChoice(.localOnly, for: .style)
        #expect(t.chain(for: .style).map(\.id) == ["local.ollama", "local.rules"])
        // Gatekeeper is always local regardless of choice.
        t.setChoice(.provider("mock.flaky"), for: .gatekeeper)
        #expect(t.chain(for: .gatekeeper).map(\.id) == ["local.ollama", "local.rules"])
    }

    @Test func pinnedProviderCompletesAndIsLogged() async throws {
        let log = InMemoryNetworkLogger()
        let t = RoutingTable(providers: [FlakyProvider()], logger: log)
        t.setChoice(.provider("mock.flaky"), for: .style)
        let r = try await t.complete(stage: .style, spans: sampleSpans, context: StageContext(), purpose: "style rewrite")
        #expect(r.provider == "mock.flaky")
        #expect(r.completion.spans.map(\.text) == ["Hello there", "kothari", ""])
        let rec = try #require(log.records.first)
        #expect(rec.stage == "style" && rec.provider == "mock.flaky" && rec.host == "mock.example")
        #expect(rec.bytesOut == 10 && rec.bytesIn == 20 && rec.purpose == "style rewrite")
        #expect(abs(rec.timestamp.timeIntervalSinceNow) < 5)
    }

    /// Chaos: the remote provider dies mid-call → local rules still complete the stage.
    @Test func chaosRemoteThrowsMidCallLocalCompletes() async throws {
        let log = InMemoryNetworkLogger()
        let dead = FlakyProvider(error: .http(502, "upstream died"))
        let t = RoutingTable(providers: [dead], logger: log)
        t.setChoice(.provider("mock.flaky"), for: .style)
        let r = try await t.complete(stage: .style, spans: sampleSpans, context: StageContext(register: .chat))
        #expect(r.provider == "local.rules")
        #expect(r.completion.spans.map(\.text) == ["Hello", "kothari", "there."])
        #expect(ConfidenceContract.verify(input: sampleSpans, output: r.completion.spans) == [])
        #expect(r.attempts.count == 2 && r.attempts[0].1 == .http(502, "upstream died") && r.attempts[1].1 == nil)
        // The failed remote attempt is still visible in the Data Panel.
        #expect(log.records.count == 1 && log.records[0].purpose.contains("failed"))
    }

    @Test func chaosRemoteTimeoutViaStubbedHTTP() async throws {
        StubURLProtocol.register(host: "api.openai.com") { _ in (503, Data("down".utf8), [:]) }
        let c = OpenAICompatibleClient(endpoint: .openAI, model: "m", secrets: InMemorySecretStore([SecretKey.apiKey("api.openai"): "k"]), session: StubURLProtocol.session(), timeout: 1)
        let t = RoutingTable(providers: [c], logger: InMemoryNetworkLogger())
        let r = try await t.complete(stage: .formatterEmail, spans: sampleSpans, context: StageContext(register: .email))
        #expect(r.provider == "local.rules")
    }

    @Test func unavailableProvidersAreSkippedWithoutLogging() async throws {
        let log = InMemoryNetworkLogger()
        let t = RoutingTable(providers: [FlakyProvider(available: false)], logger: log)
        let r = try await t.complete(stage: .style, spans: sampleSpans, context: StageContext())
        #expect(r.provider == "local.rules" && log.records.isEmpty)
    }

    @Test func localProvidersAreNeverLogged() async throws {
        let log = InMemoryNetworkLogger()
        let t = RoutingTable(providers: [], logger: log)
        _ = try await t.complete(stage: .style, spans: sampleSpans, context: StageContext())
        #expect(log.records.isEmpty)
    }

    @Test func networkLogCompletenessInAppDatabase() async throws {
        let db = try AppDatabase.inMemory()
        let t = RoutingTable(providers: [FlakyProvider()], logger: DatabaseNetworkLogger(db: db))
        for stage in [StageID.style, .formatterEmail, .repair] {
            t.setChoice(.provider("mock.flaky"), for: stage)
            _ = try await t.complete(stage: stage, spans: sampleSpans, context: StageContext(), purpose: "p-\(stage)")
        }
        let rows = try db.networkLog()
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.stage)) == ["style", "formatter.email", "repair"])
        for r in rows {
            #expect(r.provider == "mock.flaky" && r.bytesOut == 10 && r.bytesIn == 20 && r.purpose == "p-\(r.stage)" && !r.host.isEmpty)
        }
        #expect(try db.bytesEgressed(since: .distantPast) == 30)
    }

    @Test func routedStageIsAPipelineStage() async throws {
        let stage = RoutedStage(id: .style, table: RoutingTable(providers: [], logger: InMemoryNetworkLogger()))
        let out = try await stage.process(sampleSpans, context: StageContext())
        #expect(out.allSatisfy { $0.provenance.last == .style })
    }

    @Test func discoveryAlwaysIncludesRulesAndRespectsCloudASRFlag() async {
        StubURLProtocol.register(host: "*") { _ in (404, Data(), [:]) }
        let a = await ProviderDiscovery.discover(secrets: InMemorySecretStore(), session: StubURLProtocol.session(), flags: .inMemory())
        #expect(a.contains { $0.id == "local.rules" } && !a.contains { $0.id == "cloud.asr" })
        let b = await ProviderDiscovery.discover(secrets: InMemorySecretStore([SecretKey.apiKey("api.groq"): "k"]), session: StubURLProtocol.session(), flags: .inMemory(["cloudASR": true]))
        #expect(b.contains { $0.id == "cloud.asr" } && b.contains { $0.id == "api.groq" })
    }
}
