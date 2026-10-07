import Engine
import Foundation
import Injection
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// Context Writer wave 2 — the app wiring: Correction's tier per run (Automatic / explicit / per-app,
/// key and model availability), the writer at cleanup's position with cleanup stepping aside only
/// while the writer handles the run, the landing events (started / finished with changed words),
/// the packet the lander writes (pre-boost heard), C1 on every landing and the undo hook, the
/// booster's scope-down and the key-down prewarm. Scripted backends only: no network, no model.
@Suite("Context Writer wiring")
struct WriterWiringTests {
    typealias S = ContextCorrectionSettings

    // MARK: Doubles

    /// A backend that answers from a script and counts calls and prewarms.
    final class ScriptedBackend: WriterBackend, @unchecked Sendable {
        private let lock = NSLock()
        private let reply: @Sendable (String) -> String
        private(set) var calls = 0
        private(set) var prewarms = 0
        private(set) var packetPrewarms: [ContextPacket] = []
        private(set) var lastUser = ""
        init(_ reply: @escaping @Sendable (String) -> String) { self.reply = reply }
        func write(system: String, user: String, context: StageContext) async throws -> String {
            lock.withLock { calls += 1; lastUser = user }
            return reply(user)
        }
        func prewarm() async { lock.withLock { prewarms += 1 } }
        func prewarm(packet: ContextPacket) async { lock.withLock { packetPrewarms.append(packet) } }
        var callCount: Int { lock.withLock { calls } }
        var prewarmCount: Int { lock.withLock { prewarms } }
        var packetPrewarmCount: Int { lock.withLock { packetPrewarms.count } }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [WriterLandingEvent] = []
        func add(_ e: WriterLandingEvent) { lock.withLock { items.append(e) } }
        var all: [WriterLandingEvent] { lock.withLock { items } }
    }

    /// Records the context the chain ran with (the packet the lander wrote).
    final class ContextProbe: PipelineStage, @unchecked Sendable {
        let id: StageID = "test.probe"
        private let lock = NSLock()
        private var seen: StageContext?
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
            lock.withLock { seen = context }
            return spans
        }
        var context: StageContext? { lock.withLock { seen } }
    }

    static let qwen = LocalLLMCatalog.qwen35_4B

    static func wiring(_ store: SettingsStore = InMemorySettingsStore(), key: Bool = true, local: Bool = false,
                       cloud: ScriptedBackend = ScriptedBackend { $0 }, localBackend: ScriptedBackend = ScriptedBackend { $0 },
                       events: WriterLandingEvents = WriterLandingEvents(), learner: RedictationLearner? = nil) -> WriterWiring {
        WriterWiring(settings: store, events: events, learner: learner,
                     hasCloudKey: { key }, localModel: { local ? qwen : nil },
                     makeCloud: { _ in cloud }, makeLocal: { _ in localBackend }, queue: nil)
    }

    static func words(_ text: String, uncertain: [String: [String]] = [:]) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            let word = String(w)
            let alts = (uncertain[word] ?? []).enumerated().map { Alternate(text: $1, score: 1 - Float($0) * 0.1, source: .beam) }
            return TranscriptSpan(text: word, confidence: uncertain[word] == nil ? 0.95 : 0.3,
                                  audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3), alternates: alts, provenance: [.asr])
        }
    }

    static func mock(app: String = "com.apple.Notes") -> MockSystemAccess {
        let mock = MockSystemAccess(frontmost: FocusSnapshot(pid: 4242, bundleID: app, appName: "Notes", elementToken: "el-1"))
        mock.field = MockSystemAccess.Field(role: "AXTextArea")
        return mock
    }

    /// A lander whose chain is `stages`, its context step the writer's (as `AppContainer` wires it).
    static func lander(_ wiring: WriterWiring, stages: [any PipelineStage], system: MockSystemAccess = mock()) -> UtteranceLander {
        let lander = UtteranceLander(pipeline: PipelineRunner(stages: stages), injector: TextInjector(system: system),
                                     system: system, repair: nil, flags: .inMemory(), database: nil)
        lander.contextAugmenter = { spans, ctx in wiring.augment(spans, ctx) }
        lander.writerFinished = { id, ctx, spans, text in wiring.finishLanding(id: id, context: ctx, finalSpans: spans, text: text) }
        lander.onInjected = { wiring.observeLanded($0) }
        return lander
    }

    // MARK: Mode resolution

    @Test func automaticResolvesCloudThenLocalThenOff() {
        let store = InMemorySettingsStore()
        #expect(S.choice(store) == .automatic && S.chosenMode(store) == nil)
        func resolved(key: Bool, local: Bool, app: String? = nil) -> S.Mode {
            S.resolvedMode(for: app, store: store, availability: .init(hasCloudKey: key, hasLocalModel: local))
        }
        #expect(resolved(key: true, local: true) == .cloud)
        #expect(resolved(key: true, local: false) == .cloud)
        #expect(resolved(key: false, local: true) == .local)
        #expect(resolved(key: false, local: false) == .off)
        #expect(S.automaticMode(.none) == .off)
        // The wiring reads the same per run.
        #expect(Self.wiring(store, key: true).backend(for: "com.a") == .cloud)
        #expect(Self.wiring(store, key: false, local: true).backend(for: "com.a") == .local)
        #expect(Self.wiring(store, key: false, local: false).backend(for: "com.a") == nil)
    }

    @Test func explicitTierIsHonouredAndNeverFallsBack() {
        let store = InMemorySettingsStore()
        S.setMode(.off, store: store)
        #expect(Self.wiring(store, key: true, local: true).backend(for: nil) == nil, "an explicit Off beats a key")
        S.setMode(.cloud, store: store)
        #expect(Self.wiring(store, key: true).backend(for: nil) == .cloud)
        #expect(Self.wiring(store, key: false, local: true).backend(for: nil) == nil, "Cloud without a key writes nothing")
        S.setMode(.local, store: store)
        #expect(Self.wiring(store, key: true, local: true).backend(for: nil) == .local)
        #expect(Self.wiring(store, key: true, local: false).backend(for: nil) == nil, "On this Mac without a model writes nothing")
        S.setChoice(.automatic, store: store)
        #expect(store.string(S.modeKey) == nil)
    }

    @Test func perAppOverrideWinsAndSettingsApplyToTheNextRun() {
        let store = InMemorySettingsStore()
        let w = Self.wiring(store, key: true, local: true)
        S.setOverride(.local, for: "com.apple.Terminal", store: store)
        S.setOverride(.off, for: "com.apple.mail", store: store)
        #expect(w.backend(for: "com.apple.Notes") == .cloud)        // Automatic with a key
        #expect(w.backend(for: "com.apple.Terminal") == .local)
        #expect(w.backend(for: "com.apple.mail") == nil)
        S.setMode(.off, store: store)                                 // read per run
        #expect(w.backend(for: "com.apple.Notes") == nil)
        #expect(w.backend(for: "com.apple.Terminal") == .local)
    }

    @Test @MainActor func settingsPageShowsAutomaticWithWhatItResolvesTo() {
        let store = InMemorySettingsStore()
        let secrets = InMemorySecretStore([SecretKey.apiKey(APIEndpoint.openRouter.providerID): "sk-or-test"])
        let m = ContextCorrectionSettingsModel(store: store, database: nil, secrets: secrets, localModelOnDisk: { true })
        #expect(m.choice == .automatic)
        #expect(m.title(for: .automatic) == "Automatic: Cloud")
        #expect(m.selectedMode == .cloud && m.modeDetail == ContextCorrectionCopy.automaticDetail)
        let noKey = ContextCorrectionSettingsModel(store: store, database: nil, secrets: InMemorySecretStore(), localModelOnDisk: { true })
        #expect(noKey.title(for: .automatic) == "Automatic: On this Mac")
        let nothing = ContextCorrectionSettingsModel(store: store, database: nil, secrets: InMemorySecretStore(), localModelOnDisk: { false })
        #expect(nothing.title(for: .automatic) == "Automatic: Off")
        nothing.choice = .local
        #expect(store.string(S.modeKey) == "local" && nothing.modeDetail == ContextCorrectionCopy.localMissing)
        #expect(ContextCorrectionSettings.Choice.allCases.map { nothing.title(for: $0) } == ["Automatic: Off", "Off", "On this Mac", "Cloud"])
    }

    // MARK: Chain

    @Test func writerSitsAtCleanupsPositionBeforeStyle() {
        let w = Self.wiring()
        let withCleanup = CleanupWiring.insertingWriter(w.stage(), into: CleanupWiring.inserting(CleanupStage(generator: nil),
                                                                                                 into: StageRegistry.allStages()))
        let ids = withCleanup.map(\.id)
        let writer = ids.firstIndex(of: ContextWriterStage.stageID)
        let cleanup = ids.firstIndex(of: .cleanup), style = ids.firstIndex(of: .style)
        #expect(writer.map { $0 + 1 } == cleanup && cleanup.map { $0 + 1 } == style)
        let noCleanup = CleanupWiring.insertingWriter(w.stage(), into: StageRegistry.allStages()).map(\.id)
        #expect(noCleanup.firstIndex(of: ContextWriterStage.stageID).map { $0 + 1 } == noCleanup.firstIndex(of: .style))
        // The trace notes the writer's outcome; the sheet titles its row.
        let traced = TurnTraceWiring.tracingWriter([w.stage()], recorder: TurnTraceRecorder())
        #expect((traced.first as? WriterGateStage)?.inner.trace != nil)
        #expect(StageDiff.title(for: ContextWriterStage.stageID) == "Context Writer")
    }

    struct EchoCleanup: CleanupGenerating {
        let promptStyle: CleanupPromptStyle = .delimited
        func cleanup(_ prompt: CleanupPrompt, context: StageContext) async throws -> String { "" }
    }

    final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var codes: [String] = []
        func add(_ c: String) { lock.withLock { codes.append(c) } }
        var all: [String] { lock.withLock { codes } }
    }

    @Test func cleanupStepsAsideOnlyWhileTheWriterHandlesTheRun() async throws {
        let outcomes = Outcomes()
        let cleanup = CleanupStage(generator: EchoCleanup(), mode: { .always }, observer: { outcomes.add($0.code) })
        let spans = Self.words("we are starting face two next week")
        var active = StageContext()
        active.extra[WriterWiring.activeKey] = "true"
        _ = try await cleanup.process(spans, context: active)
        _ = try await cleanup.process(spans, context: StageContext())
        #expect(outcomes.all.first == "skipped:writer")
        #expect(outcomes.all.last != "skipped:writer", "Correction off: cleanup runs as before")
    }

    @Test func correctionOffLeavesTheRunExactlyAsBefore() async throws {
        let store = InMemorySettingsStore()
        S.setMode(.off, store: store)
        let events = EventLog()
        let channel = WriterLandingEvents()
        channel.subscribe { events.add($0) }
        let cloud = ScriptedBackend { _ in "Something else" }
        let w = Self.wiring(store, cloud: cloud, events: channel)
        let probe = ContextProbe()
        let spans = Self.words("send it to cotari", uncertain: ["cotari": ["Kothari"]])
        let result = await Self.lander(w, stages: [w.stage(), probe]).land(spans, startedAt: Date(), focus: Self.mock().frontmost)
        #expect(result.text == "send it to cotari")
        let ctx = try #require(probe.context)
        #expect(ContextPacket.read(from: ctx) == nil && ctx.extra[WriterWiring.activeKey] == nil)
        #expect(cloud.callCount == 0 && events.all.isEmpty)
        // The gate passes spans through untouched: no writer provenance.
        let through = try await w.stage().process(spans, context: StageContext())
        #expect(through == spans)
    }

    // MARK: Events

    @Test func startedAndFinishedWithChangedWordsInTheFinalText() async throws {
        let events = EventLog()
        let channel = WriterLandingEvents()
        channel.subscribe { events.add($0) }
        let cloud = ScriptedBackend { _ in "send it to Kothari" }
        let w = Self.wiring(key: true, cloud: cloud, events: channel)
        let spans = Self.words("send it to cotari", uncertain: ["cotari": ["Kothari"]])
        let result = await Self.lander(w, stages: [w.stage()]).land(spans, startedAt: Date(), focus: Self.mock().frontmost)
        #expect(result.text == "send it to Kothari")
        #expect(cloud.callCount == 1)
        let all = events.all
        #expect(all.count == 2)
        #expect(all.first == .started(landingID: result.utteranceID, backend: "cloud"))
        guard case .finished(let id, let outcome, let changed, let ms)? = all.last else { Issue.record("no finished event"); return }
        #expect(id == result.utteranceID && outcome == "accepted" && ms >= 0)
        #expect(changed == [WriterChangedWord(heard: "cotari", written: "Kothari", range: 11..<18)])
        // The landed spans keep what was heard as the undo alternate.
        let last = try #require(result.pending?.spans.last)
        #expect(last.provenance.contains(ContextWriterStage.stageID) && last.alternates.first?.text == "cotari")
    }

    @Test func unchangedReplyPostsFinishedWithNoChanges() async {
        let events = EventLog()
        let channel = WriterLandingEvents()
        channel.subscribe { events.add($0) }
        let w = Self.wiring(key: true, cloud: ScriptedBackend { _ in WriterPrompt.unchangedToken }, events: channel)
        let result = await Self.lander(w, stages: [w.stage()]).land(Self.words("hello there"), startedAt: Date(), focus: Self.mock().frontmost)
        #expect(result.text == "hello there")
        guard case .finished(_, let outcome, let changed, _)? = events.all.last else { Issue.record("no finished event"); return }
        #expect(outcome == "unchanged" && changed.isEmpty)
    }

    @Test func localBackendRunsWhenOnlyAModelIsOnDisk() async {
        let local = ScriptedBackend { _ in "send it to Kothari" }
        let cloud = ScriptedBackend { _ in "never" }
        let events = EventLog()
        let channel = WriterLandingEvents()
        channel.subscribe { events.add($0) }
        let w = Self.wiring(key: false, local: true, cloud: cloud, localBackend: local, events: channel)
        let spans = Self.words("send it to cotari", uncertain: ["cotari": ["Kothari"]])
        let result = await Self.lander(w, stages: [w.stage()]).land(spans, startedAt: Date(), focus: Self.mock().frontmost)
        #expect(result.text == "send it to Kothari" && local.callCount == 1 && cloud.callCount == 0)
        #expect(events.all.first == .started(landingID: result.utteranceID, backend: "local"))
    }

    @Test func changedWordRangesFollowLaterFormatting() {
        // The writer changed span 3; style then capitalised and closed the sentence.
        var spans = Self.words("send it to Kothari")
        spans[3].provenance.append(ContextWriterStage.stageID)
        spans[3].alternates = [Alternate(text: "cotari", score: 0, source: .repair)]
        spans[0].text = "Send"
        spans[3].text = "Kothari."
        let run = WriterRunLedger.Run(outcome: "accepted", ms: 12, changes: [.init(span: 3, heard: "cotari", written: "Kothari")], outputCount: 4)
        let changed = WriterWiring.changedWords(run, finalSpans: spans, text: "Send it to Kothari.")
        #expect(changed == [WriterChangedWord(heard: "cotari", written: "Kothari", range: 11..<18)])
        // A span count that changed later is found by its writer provenance and heard alternate.
        let merged = Array(spans[2...])
        let found = WriterWiring.changedWords(run, finalSpans: merged, text: "to Kothari.")
        #expect(found.map(\.heard) == ["cotari"] && found.first?.range == 3..<10)
    }

    // MARK: Packet

    @Test func landerWritesThePacketWithThePreBoostHeard() async throws {
        let w = Self.wiring(key: true, cloud: ScriptedBackend { _ in WriterPrompt.unchangedToken })
        // The final pass boosted "cotari" → "Kothari"; the engine kept the pre-boost text.
        w.sources.preBoostText = { spans in spans.map(\.text).joined(separator: " ") == "send it to Kothari" ? "send it to cotari" : nil }
        let probe = ContextProbe()
        var boosted = Self.words("send it to Kothari")
        boosted[3].provenance.append(.boosted)
        boosted[3].confidence = 0.4
        _ = await Self.lander(w, stages: [w.stage(), probe]).land(boosted, startedAt: Date(), focus: Self.mock().frontmost)
        let ctx = try #require(probe.context)
        let packet = try #require(ContextPacket.read(from: ctx))
        #expect(packet.mode == .transcribe && ContextPacket.mode(of: ctx) == .transcribe)
        #expect(packet.heard.raw == "send it to cotari")
        #expect(packet.heard.words.map(\.text) == ["send", "it", "to", "cotari"])
        #expect(packet.heard.words.last?.alternates == ["Kothari"] && packet.heard.words.last?.isUncertain == true)
        #expect(packet.heard.boosted == "send it to Kothari")
        #expect(ctx.extra[WriterWiring.activeKey] == "true" && ctx.extra[WriterWiring.backendKey] == "cloud")
        #expect(ctx.extra[WriterWiring.landingIDKey] != nil)
    }

    @Test func verbatimAndExactRunsAskTheWriterToSkip() {
        let w = Self.wiring(key: true)
        var ctx = StageContext(appBundleID: "com.apple.Notes")
        ctx.extra[CleanupStage.skipKey] = "true"
        let out = w.augment(Self.words("rm dash rf"), ctx)
        #expect(out.extra[ContextWriterStage.skipKey] == "true" && out.extra[WriterWiring.activeKey] == "true")
    }

    @Test func preBoostSpansPutTheRecognisersWordsBack() {
        var boosted = Self.words("fan out subagents now")
        boosted[2].provenance.append(.boosted)
        let raw = PreBoostSpans.reconstruct(boosted: boosted, preBoostText: "fan out sub variance now")
        #expect(raw.map(\.text) == ["fan", "out", "sub variance", "now"])
        #expect(raw[2].alternates.first == Alternate(text: "subagents", score: 1, source: .biasing))
        #expect(raw[2].audioRange == boosted[2].audioRange && raw[0] == boosted[0] && raw[3] == boosted[3])
        #expect(PreBoostSpans.reconstruct(boosted: boosted, preBoostText: nil) == boosted)
        #expect(PreBoostSpans.reconstruct(boosted: boosted, preBoostText: "fan out subagents now") == boosted)
        // Only the pass that produced these spans lends its text.
        let timing = FinalPassTiming(recogniseMs: 1, totalMs: 1, boostStatus: .boosted, rawPreBoostText: "fan out sub variance now",
                                     finalText: "fan out subagents now")
        #expect(PreBoostSpans.preBoostText(timing, for: boosted) == "fan out sub variance now")
        #expect(PreBoostSpans.preBoostText(timing, for: Self.words("something else entirely")) == nil)
    }

    // MARK: C1

    static func adaptation() throws -> AdaptationService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writer-wiring-\(UUID())")
        return try AdaptationService(root: root, werFile: root.appendingPathComponent("wer.json"),
                                     toastFile: root.appendingPathComponent("toasts.json"))
    }

    @Test func everyLandedDictationReachesTheRedictationLearner() async throws {
        let service = try Self.adaptation()
        let learner = RedictationLearner(adaptation: service)
        let store = InMemorySettingsStore()
        S.setMode(.off, store: store)                  // C1 learns whatever Correction is set to
        let w = Self.wiring(store, learner: learner)
        let lander = Self.lander(w, stages: [w.stage()])
        let mock = Self.mock()
        let first = await lander.land(Self.words("fan out sub variance"), startedAt: Date(), focus: mock.frontmost)
        #expect(first.landed)
        #expect(learner.lastLanding?.text == "fan out sub variance" && learner.lastLanding?.app == "com.apple.Notes")
        _ = await lander.land(Self.words("fan out subagents"), startedAt: Date(), focus: mock.frontmost)
        #expect(service.loop.lexicon.alias(forHeard: "sub variance") == "subagents")
    }

    @Test func undoCorrectionStoresANegativeAliasThroughTheInstalledWiring() throws {
        let service = try Self.adaptation()
        let w = Self.wiring(learner: RedictationLearner(adaptation: service))
        WriterWiring.install(w)
        #expect(WriterWiring.undoCorrection(heard: "face", written: "phase", app: "com.apple.Notes"))
        #expect(service.loop.lexicon.isBlocked(heard: "face", written: "phase"))
        #expect(!WriterWiring.undoCorrection(heard: "same", written: "Same", app: nil), "nothing to store")
        #expect(!Self.wiring().undoCorrection(heard: "a", written: "b", app: nil), "no learner")
    }

    // MARK: Key-down, booster

    @Test func keyDownPrewarmsTheResolvedBackendOnly() async throws {
        let cloud = ScriptedBackend { $0 }
        let local = ScriptedBackend { $0 }
        let w = Self.wiring(key: true, local: true, cloud: cloud, localBackend: local)
        w.beginTurn(app: FocusSnapshot(pid: 1, bundleID: "com.apple.Notes", appName: "Notes"))
        for _ in 0..<200 where cloud.prewarmCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(cloud.prewarmCount == 1 && local.prewarmCount == 0)
        let store = InMemorySettingsStore()
        S.setMode(.off, store: store)
        let offCloud = ScriptedBackend { $0 }
        let offWiring = Self.wiring(store, key: true, cloud: offCloud)
        offWiring.beginTurn(app: FocusSnapshot(pid: 1, bundleID: "com.apple.Notes", appName: "Notes"))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(offCloud.prewarmCount == 0 && !offWiring.speculates())
    }

    @Test func localPrefixPrewarmAndSpeculationUseTheKeyDownPacket() async throws {
        let local = ScriptedBackend { $0 }
        let w = Self.wiring(key: false, local: true, localBackend: local)
        #expect(w.stage().inner.speculation != nil, "the stage reads the speculator's cache")
        #expect(w.keyDownPacket() == nil, "no turn, no packet")
        w.beginTurn(app: FocusSnapshot(pid: 7, bundleID: "com.apple.Notes", appName: "Notes"))
        #expect(w.speculates())
        let packet = try #require(w.keyDownPacket())
        #expect(packet.heard.raw.isEmpty && packet.mode == .transcribe)
        w.noteSurfaceResolved(shell: nil)
        for _ in 0..<200 where local.packetPrewarmCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(local.packetPrewarmCount == 1)
        // A cloud turn opens the connection only; no prefix work.
        let cloud = ScriptedBackend { $0 }
        let c = Self.wiring(key: true, cloud: cloud)
        c.beginTurn(app: FocusSnapshot(pid: 7, bundleID: "com.apple.Notes", appName: "Notes"))
        c.noteSurfaceResolved(shell: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(cloud.packetPrewarmCount == 0)
    }

    // MARK: Replay

    static func token(_ id: Int, _ text: String, _ start: Double) -> DecodedToken {
        DecodedToken(tokenId: id, text: text, logProb: -0.05, startTime: start, endTime: start + 0.2)
    }

    @Test func replayRunsTheWriterOnTheRawHeardAndReportsIt() async throws {
        let script = [Self.token(1, "▁there", 0.1), Self.token(2, "▁is", 0.4), Self.token(3, "▁no", 0.7), Self.token(4, "▁budget", 1.0)]
        let cloud = ScriptedBackend { _ in "There is no budget." }
        let writer = ReplayWriter(backend: "cloud", generator: cloud)
        let stage = try #require(writer.stage)
        let runner = ReplayRunner(recognizer: DecoderFinalRecognizer(decoder: MockDecoder(script: script)), makeBooster: { nil },
                                  pipeline: PipelineRunner(stages: CleanupWiring.insertingWriter(stage, into: [])), writer: writer)
        let report = await runner.run(samples: [Float](repeating: 0, count: 32_000), source: "t.wav",
                                      surface: try #require(ReplaySurface.named("notes")))
        #expect(report.error == nil && report.finalText == "There is no budget.")
        let w = try #require(report.writer)
        #expect(w.backend == "cloud" && w.outcome == "accepted" && w.packet == "offline")
        #expect(w.changed.first == .init(from: "there", to: "There"))
        #expect(cloud.lastUser.contains("there is no budget"))
        #expect(report.rendered.contains("writer:  cloud · accepted"))
        // Off: no call, the report says so.
        let off = ReplayWriter(backend: "off", generator: nil)
        let offReport = await ReplayRunner(recognizer: DecoderFinalRecognizer(decoder: MockDecoder(script: script)), makeBooster: { nil },
                                           pipeline: PipelineRunner(stages: []), writer: off)
            .run(samples: [Float](repeating: 0, count: 32_000), source: "t.wav", surface: try #require(ReplaySurface.named("notes")))
        #expect(offReport.writer?.outcome == "off" && offReport.writer?.changed.isEmpty == true)
    }

    @Test func replayParsesWriterAndPacketAndChoosesTheBackend() throws {
        let o = try #require(ReplayCLI.parse(["app", "--replay", "a.wav", "--writer", "Cloud", "--packet", "/tmp/p.json"]))
        #expect(o.writer == "cloud" && o.packet == "/tmp/p.json")
        #expect(ReplayCLI.parse(["app", "--replay", "a.wav"])?.writer == nil)
        let surface = try #require(ReplaySurface.named("chat"))
        let keyed = InMemorySecretStore([SecretKey.apiKey(APIEndpoint.openRouter.providerID): "sk-or-test"])
        func choose(_ writer: String?, packet: String? = nil, secrets: SecretStore = keyed,
                    settings: SettingsStore = InMemorySettingsStore()) -> Result<ReplayWriter, ReplayCLI.WriterChoiceError> {
            var opts = ReplayCLI.Options(target: "a.wav")
            opts.writer = writer
            opts.packet = packet
            return ReplayCLI.liveWriter(opts, surface: surface, database: nil, settings: settings, secrets: secrets, vocabulary: false)
        }
        #expect((try? choose("off").get())?.stage == nil)
        #expect((try? choose("cloud").get())?.backend == "cloud")
        #expect(throws: ReplayCLI.WriterChoiceError.self) { try choose("cloud", secrets: InMemorySecretStore()).get() }
        #expect(throws: ReplayCLI.WriterChoiceError.self) { try choose("bogus").get() }
        #expect(throws: ReplayCLI.WriterChoiceError.self) { try choose("off", packet: "/nonexistent/packet.json").get() }
        // Default: the app's resolved tier (an explicit Off here).
        let offStore = InMemorySettingsStore()
        S.setMode(.off, store: offStore)
        #expect((try? choose(nil, settings: offStore).get())?.backend == "off")
        // A packet file is used, its heard replaced by the recording's.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("packet-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let given = ContextPacket(destination: .init(profileID: "chat.message", appBundleID: "com.tinyspeck.slackmacgap"),
                                  screenTerms: ["Kothari"], heard: .init(raw: "stale"))
        try given.encoded().write(to: url, atomically: true, encoding: .utf8)
        let w = try choose("cloud", packet: url.path).get()
        #expect(w.packetSource == url.lastPathComponent)
        let packet = w.packet(raw: Self.words("ping cotari"), boosted: Self.words("ping Kothari"), surface: surface)
        #expect(packet.screenTerms == ["Kothari"] && packet.heard.raw == "ping cotari" && packet.heard.boosted == "ping Kothari")
    }

    @Test func boosterGetsNoScreenOrNearCaretTerms() {
        #expect(BoostingWiring.rubricConfig.screenTermsInBoost == false && BoostingWiring.rubricConfig.nearCaretInBoost == false)
        let now = Date()
        let rubric = BoostingWiring.rubricRanking(
            database: nil, learned: nil,
            surface: { SurfaceResolution(kind: .chatComposer, confidence: 0.9, isWebArea: false, signals: []) },
            turnCandidates: { [ContextCandidate(text: "Kubernetes", source: .screenNear, caretDistance: 1, observedAt: now),
                               ContextCandidate(text: "Postgres", source: .correction, observedAt: now)] },
            weights: nil, contacts: false)
        let ranked = rubric(now)
        let boost = (ranked?.stableLayer ?? []) + (ranked?.perTurnLayer ?? [])
        #expect(!boost.map(\.text).contains("Kubernetes"))
        #expect(boost.map(\.text).contains("Postgres"))
    }
}
