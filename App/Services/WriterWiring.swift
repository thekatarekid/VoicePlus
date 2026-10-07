import Engine
import Foundation
import GRDB
import Injection
import Lab
import Pipeline
import Providers
import Shared

// MARK: - Context Writer · app wiring (VoicePlus_ContextWriter_Plan.md §1, §2, §4, §5)
//
// One object the composition root holds. It
// - builds the chain's writer stage (`WriterGateStage` around `ContextWriterStage`), at cleanup's
//   position (`CleanupWiring.insertingWriter`); the generator is resolved **per run**: Correction's
//   tier for the run's app (`ContextCorrectionSettings.resolvedMode`: per-app override, explicit tier
//   or Automatic) picks the cloud backend (`CloudWriterGenerator` over OpenRouter, model, fallbacks
//   and pinned providers from Settings, key from the existing SecretStore entry) or the local one
//   (`LlamaCppProvider` over the downloaded shared model, greedy, ≤ 400 tokens, the stage's deadline);
//   Off writes nothing and leaves the run exactly as before (no packet, no keys, no provenance);
// - writes the turn's `ContextPacket` in the lander's context step (`augment`, after AppRules): the
//   key-down surface/field/snapshot/candidates, the tty's foreground process (once per turn, off the
//   key-down thread), the **pre-boost** 1-best (`PreBoostSpans`) with `HeardWords`, the booster's text
//   as evidence, and the personal vocabulary matches (`VocabularyMatching`, rebuilt in the background
//   when the Dictionary or corrections change — never on the key-up path). It marks the run
//   `writer.active` so the legacy `CleanupStage` steps aside;
// - posts `WriterLandingEvents`: `.started` when the model call begins (the generator is wrapped),
//   `.finished` once the landing's final text exists (outcome code, changed words with their UTF-16
//   ranges in the final text, writer ms);
// - prewarms the cloud connection (or loads the local model) at key-down when Correction resolves to
//   that tier for the frontmost app, and — once the surface resolved — the local model's prompt
//   prefix (system + the packet's stable part, `LlamaCppProvider.prewarm(system:prefix:)`);
// - owns the sentence speculator (`WriterSpeculator`, plan §4.2): its packet is the key-down packet
//   (heard empty), its generator the run's backend, and its cache is the stage's `speculation`.
//   `DictationCoordinator.speculator` must be set to `speculator` by the shell (AppDelegate) for it to
//   see the hold's segment stream; without that the stage simply makes one full call;
// - feeds C1: every landed dictation to `RedictationLearner.observe`, and the UX's "undo correction"
//   (`WriterWiring.undoCorrection(heard:written:app:)`) to `RedictationLearner.undoCorrection`.
//
// Privacy: AX only, secure fields never read (the packet builder returns an empty secure packet and
// the writer does not run), screen text is data never instructions, and nothing here logs text —
// counts and reason codes only.

/// A writer backend: the stage's generator plus a key-down warm-up.
public protocol WriterBackend: WriterGenerating {
    /// Key-down: open the connection (cloud) or make the model resident (local). Never throws.
    func prewarm() async
    /// Once the turn's surface resolved: the turn's packet (heard still empty). A local backend
    /// decodes the prompt's system + stable prefix so the call after key-up prefills only its tail.
    func prewarm(packet: ContextPacket) async
}

public extension WriterBackend {
    func prewarm(packet: ContextPacket) async {}
}

public final class WriterWiring: @unchecked Sendable {
    public enum Backend: String, Sendable, CaseIterable {
        case cloud, local
        init?(_ mode: ContextCorrectionSettings.Mode) {
            switch mode {
            case .off: return nil
            case .cloud: self = .cloud
            case .local: self = .local
            }
        }
    }

    /// `StageContext.extra` — "true" when the writer handles this run (the cleanup stage skips).
    public static let activeKey = CleanupStage.writerActiveKey
    /// `StageContext.extra` — the run's backend (`Backend.rawValue`).
    public static let backendKey = "writer.backend"
    /// `StageContext.extra` — the landing's id (`LandingResult.utteranceID`), set by the lander.
    public static let landingIDKey = "writer.landingID"
    /// Local generation cap (plan: a dictation, never an essay).
    public static let localMaxTokens = 400
    /// The availability probe (keychain + disk) is refreshed at every key-down, off its thread;
    /// a landing with no fresh value reads it again after this long.
    public static let availabilityTTL: TimeInterval = 30

    public let settings: SettingsStore
    public let events: WriterLandingEvents
    public let learner: RedictationLearner?
    public let vocabulary: WriterVocabulary
    /// Plan §4.2 — sentences written while the user speaks; its cache is the stage's `speculation`.
    public let speculator: WriterSpeculator
    let ledger = WriterRunLedger()
    let packetBuilder: ContextPacketBuilder
    /// The landing's turn sources (the composition root's `TurnSurfaceContext` / snapshot / engine).
    public var sources = TurnSources()

    private let hasCloudKey: @Sendable () -> Bool
    private let localModel: @Sendable () -> LocalLLMModel?
    private let makeCloud: @Sendable (CloudWriterConfig) -> any WriterBackend
    private let makeLocal: @Sendable (LocalLLMModel) -> any WriterBackend
    private let now: @Sendable () -> Date
    /// Where key-down work (availability, prewarm) and C1 learning run; nil = inline (tests).
    private let queue: DispatchQueue?
    private let lock = NSLock()
    private var cachedAvailability: (value: ContextCorrectionSettings.Availability, at: Date)?
    private var cloud: (config: CloudWriterConfig, backend: any WriterBackend)?
    private var local: (id: String, backend: any WriterBackend)?
    private var turn = TurnState()

    /// What the lander's context step reads from the turn (closures over the live objects).
    public struct TurnSources {
        public var resolved: () -> TurnSurfaceContext.Resolved? = { nil }
        public var contents: () -> TurnContextContents? = { nil }
        public var candidates: () -> [ContextCandidate] = { [] }
        /// The engine's pre-boost text for these (boosted) spans, when boosting changed them.
        public var preBoostText: ([TranscriptSpan]) -> String? = { _ in nil }
        public init() {}
    }

    struct TurnState {
        var app: FocusSnapshot?
        var field: FieldContext?
        var fieldPID: Int32?
        var foregroundProcess: String?
    }

    /// - Parameters:
    ///   - hasCloudKey: an OpenRouter key is stored and egress to it is allowed.
    ///   - localModel: the local instruct model on disk (nil: none).
    ///   - makeCloud / makeLocal: the backends (live: OpenRouter / llama.cpp; tests: scripted).
    public init(settings: SettingsStore, events: WriterLandingEvents = .shared, learner: RedictationLearner? = nil,
                packetBuilder: ContextPacketBuilder = ContextPacketBuilder(),
                vocabulary: WriterVocabulary = WriterVocabulary(build: { nil }),
                hasCloudKey: @escaping @Sendable () -> Bool,
                localModel: @escaping @Sendable () -> LocalLLMModel?,
                makeCloud: @escaping @Sendable (CloudWriterConfig) -> any WriterBackend,
                makeLocal: @escaping @Sendable (LocalLLMModel) -> any WriterBackend,
                now: @escaping @Sendable () -> Date = Date.init,
                queue: DispatchQueue? = DispatchQueue(label: "voiceplus.writer", qos: .userInitiated)) {
        self.settings = settings
        self.events = events
        self.learner = learner
        self.packetBuilder = packetBuilder
        self.vocabulary = vocabulary
        self.hasCloudKey = hasCloudKey
        self.localModel = localModel
        self.makeCloud = makeCloud
        self.makeLocal = makeLocal
        self.now = now
        self.queue = queue
        self.speculator = WriterSpeculator()
        packetBuilder.vocabulary = vocabulary
        Self.installGuardPhonetics
        speculator.vocabulary = vocabulary
        speculator.packetProvider = { [weak self] in self?.keyDownPacket() }
        speculator.generator = SpeculationRouter(wiring: self)
        speculator.isEnabled = { [weak self] in self?.speculates() ?? false }
    }

    /// The app's writer: Keychain key, the downloaded shared model, OpenRouter + llama.cpp backends,
    /// the network log, the egress kill switch, the packet's history / persona / language sources
    /// and the personal vocabulary over the Dictionary, corrections and the learned lexicon.
    public static func live(settings: SettingsStore, database: AppDatabase?, adaptation: AdaptationService?,
                            personas: PersonaManager?, secrets: SecretStore = KeychainSecretStore(),
                            fieldReadback: (@Sendable () -> String?)? = nil) -> WriterWiring {
        let learner = adaptation.map { RedictationLearner(adaptation: $0, fieldReadback: fieldReadback) }
        let vocabulary = WriterVocabulary(build: Self.vocabularyBuilder(database: database, adaptation: adaptation))
        vocabulary.observe(database)
        let wiring = WriterWiring(
            settings: settings, learner: learner,
            packetBuilder: ContextPacketBuilder(database: database, personas: personas, settings: settings),
            vocabulary: vocabulary,
            hasCloudKey: { Self.cloudKeyStored(secrets) && EgressGate.shared.isAllowed(host: Self.cloudHost) },
            localModel: { Self.installedLocalModel() },
            makeCloud: { CloudWriterBackend(generator: Self.cloudGenerator(config: $0, secrets: secrets, database: database)) },
            makeLocal: { LocalWriterBackend(model: $0) })
        vocabulary.rebuild()
        wiring.run { wiring.refreshAvailability() }   // the first key-down finds a cached answer
        return wiring
    }

    // MARK: Process-wide hooks (the UX's undo, the guard's ear)

    private static let currentBox = WeakBox()

    /// Makes `wiring` the one `undoCorrection(heard:written:app:)` reaches (the composition root's).
    public static func install(_ wiring: WriterWiring) { currentBox.set(wiring) }
    public static var current: WriterWiring? { currentBox.get() }

    /// The UX's "undo correction" (plan §4.6): the user put back what was heard where the writer had
    /// written `written`. Stored as a negative alias through C1 (`RedictationLearner.undoCorrection`)
    /// so that spelling is never proposed for that heard form again, off the caller's thread.
    /// Returns false when there is no learner or nothing to store (empty or equal texts).
    @discardableResult
    public static func undoCorrection(heard: String, written: String, app: String?) -> Bool {
        current?.undoCorrection(heard: heard, written: written, app: app) ?? false
    }

    @discardableResult
    public func undoCorrection(heard: String, written: String, app: String?) -> Bool {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let learner, !h.isEmpty, !w.isEmpty, h.lowercased() != w.lowercased() else { return false }
        let at = now(), vocabulary = self.vocabulary
        run {
            if learner.undoCorrection(heard: h, written: w, app: app, at: at) { vocabulary.invalidate() }
        }
        return true
    }

    /// H19's ear for the per-change guard: Double Metaphone, installed once, process-wide.
    static let installGuardPhonetics: Void = {
        WriterGuard.install(phonetic: TurnSurfaceContext.phoneticCodes)
    }()

    // MARK: Mode, per run

    /// What this Mac can run: the cached probe (refreshed at key-down), read again when stale.
    public func availability() -> ContextCorrectionSettings.Availability {
        if let cached = lock.withLock({ cachedAvailability }), now().timeIntervalSince(cached.at) < Self.availabilityTTL {
            return cached.value
        }
        return refreshAvailability()
    }

    @discardableResult
    func refreshAvailability() -> ContextCorrectionSettings.Availability {
        let value = ContextCorrectionSettings.Availability(hasCloudKey: hasCloudKey(), hasLocalModel: localModel() != nil)
        lock.withLock { cachedAvailability = (value, now()) }
        return value
    }

    /// The tier that runs for one dictation in `bundleID` (nil: Correction off for it, or the
    /// selected tier cannot run on this Mac). Read per run: a Settings change applies next time.
    public func backend(for bundleID: String?) -> Backend? {
        Backend(ContextCorrectionSettings.resolvedMode(for: bundleID, store: settings, availability: availability()))
    }

    /// The same from the cached probe only (nil when nothing is cached yet): safe on the key-down thread.
    func cachedBackend(for bundleID: String?) -> Backend? {
        guard let cached = lock.withLock({ cachedAvailability?.value }) else { return nil }
        return Backend(ContextCorrectionSettings.resolvedMode(for: bundleID, store: settings, availability: cached))
    }

    /// The speculator's gate at key-down: a hold in an app Correction writes for.
    func speculates() -> Bool {
        let app = lock.withLock { turn.app }
        guard let app, !OwnProcess.owns(app) else { return false }
        return cachedBackend(for: app.bundleID) != nil
    }

    /// The turn's packet as known at key-down (heard empty): the speculator's, and the local prefix
    /// prewarm's. nil without a turn app, or for a secure destination.
    public func keyDownPacket() -> ContextPacket? {
        guard let app = lock.withLock({ turn.app }) else { return nil }
        let packet = buildPacket([], context: StageContext(appBundleID: app.bundleID))
        return packet.isSecure ? nil : packet
    }

    /// The generator for `backend`, built once per cloud config / local model.
    public func generator(for backend: Backend) -> (any WriterBackend)? {
        switch backend {
        case .cloud:
            let config = ContextCorrectionSettings.cloudConfig(settings)
            return lock.withLock {
                if let cloud, cloud.config == config { return cloud.backend }
                let made = makeCloud(config)
                cloud = (config, made)
                return made
            }
        case .local:
            guard let model = localModel() else { return nil }
            return lock.withLock {
                if let local, local.id == model.id { return local.backend }
                let made = makeLocal(model)
                local = (model.id, made)
                return made
            }
        }
    }

    // MARK: The chain's stage

    /// The writer at cleanup's position: a pass-through unless the run is `writer.active`.
    /// The writer reuses sentences the speculator wrote during the hold (`speculator.cache`).
    public func stage(deadline: TimeInterval = ContextWriterStage.defaultDeadline) -> WriterGateStage {
        let router = RoutedWriterGenerator(events: events, resolve: { [weak self] in self?.generator(for: $0) })
        var inner = ContextWriterStage(generator: router, deadline: deadline)
        inner.speculation = speculator.cache
        return WriterGateStage(inner: inner, ledger: ledger)
    }

    // MARK: Key-down

    /// Key-down: forget the last turn, then — off this thread — refresh what this Mac can run,
    /// warm the backend Correction resolves to for the frontmost app, and rebuild a stale vocabulary.
    public func beginTurn(app: FocusSnapshot?) {
        lock.withLock { turn = TurnState(app: app) }
        let bundleID = app?.bundleID
        run { [weak self] in
            guard let self else { return }
            self.refreshAvailability()
            self.vocabulary.rebuildIfStale()
            guard let backend = self.backend(for: bundleID), let generator = self.generator(for: backend) else { return }
            Task.detached(priority: .userInitiated) { await generator.prewarm() }
        }
    }

    /// The key-down field read (`TurnSurfaceContext`'s reader, on its queue): kept for the packet.
    public func noteKeyDownField(_ field: FieldContext?, app: FocusSnapshot) {
        lock.withLock {
            guard turn.app == nil || turn.app?.pid == app.pid else { return }
            turn.field = field
            turn.fieldPID = app.pid
        }
    }

    /// The surface resolved (on `TurnSurfaceContext`'s queue): the tty's foreground process, once;
    /// then, off that queue, the local model's prompt prefix for this turn's packet.
    public func noteSurfaceResolved(shell: ShellContext?, table: (() -> [ShellProcessRecord])? = nil) {
        let process = shell.flatMap { TTYForegroundProcess.live($0, table: table) }
        let app = lock.withLock { () -> FocusSnapshot? in
            turn.foregroundProcess = process
            return turn.app
        }
        run { [weak self] in
            guard let self, self.backend(for: app?.bundleID) == .local, let generator = self.generator(for: .local),
                  let packet = self.keyDownPacket() else { return }
            Task.detached(priority: .userInitiated) { await generator.prewarm(packet: packet) }
        }
    }

    // MARK: The lander's context step

    /// After AppRules (and the surface, preset and mid-sentence steps): when Correction resolves to a
    /// tier for this run, the packet goes into the context with `writer.active` and the backend, and
    /// Verbatim / "Exact" / mid-sentence-off turns ask the writer to skip. Off → `context` unchanged.
    public func augment(_ spans: [TranscriptSpan], _ context: StageContext) -> StageContext {
        guard let backend = backend(for: context.appBundleID) else { return context }
        let packet = buildPacket(spans, context: context)
        guard !packet.isSecure else { return context }
        var ctx = context
        packet.write(into: &ctx)
        ctx.extra[Self.activeKey] = "true"
        ctx.extra[Self.backendKey] = backend.rawValue
        if ctx.extra[CleanupStage.skipKey] == "true" || SurfacePresets.active(in: ctx)?.allowsCleanup == false {
            ctx.extra[ContextWriterStage.skipKey] = "true"
        }
        return ctx
    }

    func buildPacket(_ spans: [TranscriptSpan], context: StageContext) -> ContextPacket {
        let state = lock.withLock { turn }
        var input = ContextPacketBuilder.Input(mode: .transcribe)
        let resolved = sources.resolved()
        // Bound to the app the turn started in: a landing elsewhere gets no screen from this turn.
        let sameApp = resolved.map { r in context.appBundleID.map { $0 == r.bundleID } ?? true } ?? false
        if sameApp, let resolved {
            input.app = state.app
            input.resolved = resolved
            if state.fieldPID == resolved.pid { input.field = state.field }
            input.contents = sources.contents()
            input.candidates = sources.candidates()
            input.foregroundProcess = state.foregroundProcess
        } else if let app = state.app, app.bundleID == context.appBundleID {
            input.app = app
        }
        let preBoost = sources.preBoostText(spans)
        input.spans = PreBoostSpans.reconstruct(boosted: spans, preBoostText: preBoost)
        input.boostedText = preBoost == nil ? nil : spans.renderedText
        return packetBuilder.build(input)
    }

    // MARK: Landing

    /// The landing's final text exists (`UtteranceLander`): `.finished` with the outcome code, the
    /// changed words and their ranges in `text`, and the writer's ms. Nothing for a run the writer did
    /// not handle. `text` nil = the landing ended before a final text (a command, a refusal).
    public func finishLanding(id: UUID, context: StageContext, finalSpans: [TranscriptSpan], text: String?) {
        guard context.extra[Self.activeKey] == "true" else { return }
        let run = ledger.take(id)
        let changed = run.map { Self.changedWords($0, finalSpans: finalSpans, text: text) } ?? []
        events.post(.finished(landingID: id, outcome: run?.outcome ?? "skipped:notRun", changed: changed, ms: run?.ms ?? 0))
    }

    /// C1 — a dictation landed (the injector confirmed the write): the re-dictation learner compares
    /// it with the previous landing, off the landing path. Own-process and secure fields never count.
    public func observeLanded(_ result: LandingResult) {
        guard let learner, result.landed, let pending = result.pending else { return }
        if let focus = pending.focus, OwnProcess.owns(focus) { return }
        if pending.axRole == FocusedElementInfo.secureRole { return }
        let text = result.text, app = pending.bundleID ?? pending.focus?.bundleID, at = now(), vocabulary = self.vocabulary
        run {
            if !learner.observe(landing: text, app: app, at: at).isEmpty { vocabulary.invalidate() }
        }
    }

    fileprivate func run(_ work: @escaping @Sendable () -> Void) {
        if let queue { queue.async(execute: work) } else { work() }
    }

    // MARK: Changed words

    /// Changed words of one writer run, in the landed text: the final spans whose provenance has the
    /// writer and whose `.repair` alternate holds what was heard (matched by index when the span count
    /// survived the later stages, else searched), adjacent ones grouped, their UTF-16 ranges found by
    /// aligning the final spans with `text` (`UncertaintyMarkMapper`). A change no later span carries
    /// (a word a later stage removed) is reported without a range.
    static func changedWords(_ run: WriterRunLedger.Run, finalSpans: [TranscriptSpan], text: String?) -> [WriterChangedWord] {
        guard !run.changes.isEmpty else { return [] }
        var heardBySpan: [Int: String] = [:]
        var unplaced: [WriterRunLedger.Change] = []
        for c in run.changes {
            if run.outputCount == finalSpans.count, c.span < finalSpans.count, carries(finalSpans[c.span], heard: c.heard) {
                heardBySpan[c.span] = c.heard
            } else {
                unplaced.append(c)
            }
        }
        var lost: [WriterRunLedger.Change] = []
        for c in unplaced {
            if let i = finalSpans.indices.first(where: { heardBySpan[$0] == nil && carries(finalSpans[$0], heard: c.heard) }) {
                heardBySpan[i] = c.heard
            } else {
                lost.append(c)
            }
        }
        // Adjacent changed spans are one change ("sub variance" → "subagents" + a merged-away span).
        var groups: [[Int]] = []
        for i in heardBySpan.keys.sorted() {
            if let last = groups.last?.last, last == i - 1 { groups[groups.count - 1].append(i) } else { groups.append([i]) }
        }
        var marks: [UncertainMark] = []
        if let text, !text.isEmpty {
            let probe = finalSpans.enumerated().map { i, s in
                TranscriptSpan(text: s.text, confidence: heardBySpan[i] == nil ? 1 : 0, audioRange: 1...2, provenance: s.provenance)
            }
            marks = UncertaintyMarkMapper.map(source: probe, finalText: text).marks
        }
        var out: [WriterChangedWord] = []
        for group in groups {
            let heard = group.compactMap { heardBySpan[$0] }.joined(separator: " ")
            let ranges = marks.filter { !Set($0.sourceSpans).isDisjoint(with: group) }.map(\.range)
            if let text, let lower = ranges.map(\.lowerBound).min(), let upper = ranges.map(\.upperBound).max(),
               let written = MarkWords.slice(text, lower..<upper) {
                out.append(WriterChangedWord(heard: heard, written: written, range: lower..<upper))
            } else {
                let written = group.map { finalSpans[$0].text }.filter { !$0.isEmpty }.joined(separator: " ")
                out.append(WriterChangedWord(heard: heard, written: written, range: nil))
            }
        }
        out += lost.map { WriterChangedWord(heard: $0.heard, written: $0.written, range: nil) }
        return out
    }

    static func carries(_ span: TranscriptSpan, heard: String) -> Bool {
        span.provenance.contains(ContextWriterStage.stageID)
            && span.alternates.contains { $0.source == .repair && $0.text == heard }
    }

    // MARK: Live parts

    public static let cloudHost = "openrouter.ai"

    static func cloudKeyStored(_ secrets: SecretStore) -> Bool {
        ((try? secrets.get(SecretKey.apiKey(APIEndpoint.openRouter.providerID))) ?? nil)?.isEmpty == false
    }

    /// What this Mac can run, read live (Settings lines; the writer itself caches it per turn).
    public static func liveAvailability(secrets: SecretStore = KeychainSecretStore()) -> ContextCorrectionSettings.Availability {
        .init(hasCloudKey: cloudKeyStored(secrets) && EgressGate.shared.isAllowed(host: cloudHost),
              hasLocalModel: installedLocalModel() != nil)
    }

    /// The shared instruct model the user downloaded: `llm.edit.preferredModel` when on disk, else
    /// any shared model on disk (`LocalModelManager.activeModel`); nil without the llama.cpp runtime.
    /// The cleanup fine-tunes (SpeakoFlow, S1) are not candidates: they cannot follow the writer's prompt.
    public static func installedLocalModel(manager: LocalModelManager = EditModels.manager) -> LocalLLMModel? {
        guard LlamaCppEngine.runtimeAvailable else { return nil }
        return manager.activeModel
    }

    static func cloudGenerator(config: CloudWriterConfig, secrets: SecretStore, database: AppDatabase?) -> CloudWriterGenerator {
        var generator = CloudWriterGenerator(config: config, secrets: secrets, logger: database.map { DatabaseNetworkLogger(db: $0) })
        generator.egressAllowed = { EgressGate.shared.isAllowed(host: $0) }
        return generator
    }

    /// §2.4 — the personal vocabulary through Engine's integrator factory (`VocabularyMatcher.build`):
    /// Dictionary rows with their spoken forms (Contacts only as full names), confirmed corrections,
    /// and the learned lexicon (C1 aliases as spoken forms, undone corrections as blocked pairs).
    static func vocabularyBuilder(database: AppDatabase?, adaptation: AdaptationService?) -> @Sendable () -> (any VocabularyMatching)? {
        { [weak adaptation] in
            let entries = database.flatMap { try? DictionaryOrigins.entries($0) } ?? []
            let corrections = database.flatMap { try? DatabaseCorrectionStore(database: $0, limit: 500).correctedTerms() } ?? []
            let lexicon = adaptation?.loop.lexicon
            guard !entries.isEmpty || !corrections.isEmpty || lexicon != nil else { return nil }
            return VocabularyMatcher.build(entries: entries, corrections: corrections, learned: lexicon)
        }
    }
}

// MARK: - The stage in the chain

/// `ContextWriterStage` behind the run's `writer.active` switch: with it off the spans pass through
/// untouched (no provenance, no observer, no trace note), so Correction off is exactly the old chain.
/// With it on, one run of the writer is recorded in the ledger under the landing id (outcome code,
/// ms, which spans changed) for `.finished`.
public struct WriterGateStage: PipelineStage {
    public var id: StageID { ContextWriterStage.stageID }
    public var inner: ContextWriterStage
    let ledger: WriterRunLedger

    init(inner: ContextWriterStage, ledger: WriterRunLedger) {
        self.inner = inner
        self.ledger = ledger
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard context.extra[WriterWiring.activeKey] == "true" else { return spans }
        let landing = context.extra[WriterWiring.landingIDKey].flatMap(UUID.init(uuidString:))
        let box = OutcomeBox()
        var stage = inner
        let previous = stage.observer
        stage.observer = { outcome in
            box.set(outcome)
            previous?(outcome)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let elapsed = { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
        let out: [TranscriptSpan]
        do {
            out = try await stage.process(spans, context: context)
        } catch {
            let code = String(String(describing: error).prefix(while: { $0 != "(" }).prefix(40))
            if let landing { ledger.record(landing, .init(outcome: "failed:\(code)", ms: elapsed(), changes: [], outputCount: spans.count)) }
            throw error
        }
        if let landing {
            var changes: [WriterRunLedger.Change] = []
            if out.count == spans.count {
                for (i, pair) in zip(spans, out).enumerated() where pair.0.text != pair.1.text {
                    changes.append(.init(span: i, heard: pair.0.text, written: pair.1.text))
                }
            }
            ledger.record(landing, .init(outcome: box.get()?.code ?? "unknown", ms: elapsed(), changes: changes, outputCount: out.count))
        }
        return out
    }
}

/// The stage's generator: the run's backend (`writer.backend`), with `.started` posted as the model
/// call begins. No backend for the run → `ProviderError.unavailable` (the stage reports `failed`).
struct RoutedWriterGenerator: WriterGenerating {
    let events: WriterLandingEvents
    let resolve: @Sendable (WriterWiring.Backend) -> (any WriterBackend)?

    func write(system: String, user: String, context: StageContext) async throws -> String {
        guard let backend = context.extra[WriterWiring.backendKey].flatMap(WriterWiring.Backend.init(rawValue:)),
              let generator = resolve(backend) else { throw ProviderError.unavailable("no writer backend for this run") }
        if let id = context.extra[WriterWiring.landingIDKey].flatMap(UUID.init(uuidString:)) {
            events.post(.started(landingID: id, backend: backend.rawValue))
        }
        return try await generator.write(system: system, user: user, context: context)
    }
}

/// The speculator's generator: the backend Correction resolves to for the turn's app, per call
/// (off the key-down thread). No backend → the chunk fails and the turn stops speculating.
struct SpeculationRouter: WriterGenerating {
    weak var wiring: WriterWiring?

    func write(system: String, user: String, context: StageContext) async throws -> String {
        guard let wiring, let backend = wiring.backend(for: wiring.turnApp?.bundleID),
              let generator = wiring.generator(for: backend) else { throw ProviderError.unavailable("no writer backend") }
        return try await generator.write(system: system, user: user, context: context)
    }
}

extension WriterWiring {
    var turnApp: FocusSnapshot? { lock.withLock { turn.app } }
}

/// One writer run per landing, until the lander posts `.finished` (bounded: the last 32).
final class WriterRunLedger: @unchecked Sendable {
    struct Change: Equatable, Sendable {
        /// Index of the span in the writer's output.
        var span: Int
        var heard: String
        var written: String
    }

    struct Run: Equatable, Sendable {
        var outcome: String
        var ms: Double
        var changes: [Change]
        /// Spans out of the writer (index matching against the final spans needs the same count).
        var outputCount: Int
    }

    static let capacity = 32
    private let lock = NSLock()
    private var runs: [UUID: Run] = [:]
    private var order: [UUID] = []

    func record(_ id: UUID, _ run: Run) {
        lock.withLock {
            if runs[id] == nil { order.append(id) }
            runs[id] = run
            while order.count > Self.capacity { runs[order.removeFirst()] = nil }
        }
    }

    func take(_ id: UUID) -> Run? {
        lock.withLock {
            order.removeAll { $0 == id }
            return runs.removeValue(forKey: id)
        }
    }
}

final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WriterOutcome?
    func set(_ v: WriterOutcome) { lock.withLock { value = v } }
    func get() -> WriterOutcome? { lock.withLock { value } }
}

final class WeakBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: WriterWiring?
    func set(_ v: WriterWiring?) { lock.withLock { value = v } }
    func get() -> WriterWiring? { lock.withLock { value } }
}

// MARK: - Backends

/// Cloud: `CloudWriterGenerator` (OpenRouter, Settings' model / fallbacks / pinned providers, the
/// stored key, reasoning off, 2.5 s, keep-alive). Bytes and purpose are logged, never text.
public struct CloudWriterBackend: WriterBackend {
    public let generator: CloudWriterGenerator
    public init(generator: CloudWriterGenerator) { self.generator = generator }
    public func write(system: String, user: String, context: StageContext) async throws -> String {
        try await generator.write(system: system, user: user)
    }
    public func prewarm() async { await generator.prewarm() }
}

/// On this Mac: `LlamaCppProvider` over the shared model's GGUF, under the shared model's residency
/// key (the same weights the edit / planner provider loads), greedy, ≤ 400 tokens, the stage's
/// deadline; refuses to *load* under critical memory pressure. The residency's own idle sweep
/// unloads it (no per-provider idle timer: dictation is the hot path).
public final class LocalWriterBackend: WriterBackend, @unchecked Sendable {
    public let model: LocalLLMModel
    public let provider: LlamaCppProvider
    private let residency: ModelResidency

    public init(model: LocalLLMModel, residency: ModelResidency = .shared, plan: ResidencyPlan = ResidencyPlanStore.shared.plan,
                deadline: TimeInterval = ContextWriterStage.defaultDeadline, engine: (any LocalLLMEngine)? = nil) {
        self.model = model
        self.residency = residency
        let key = ComputerUseSettings.residencyKey(for: model)
        provider = LlamaCppProvider(
            config: LlamaCppConfig(modelPath: model.localURL(), residencyKey: key,
                                   tier: ComputerUseSettings.plannerTier(for: model, plan: plan),
                                   estimatedBytes: model.residentBytes, maxTokens: WriterWiring.localMaxTokens,
                                   deadline: deadline, lighterAlternative: plan.lighterAlternative(for: key),
                                   sampling: .greedy, idleUnloadAfter: nil, refuseUnderCriticalPressure: true),
            displayName: "\(model.displayName) on this Mac", residency: residency, engine: engine)
    }

    public func write(system: String, user: String, context: StageContext) async throws -> String {
        try await provider.generate(prompt: user, system: system, stage: ContextWriterStage.stageID).text
    }

    /// Key-down: register and load the weights while the user speaks (not under memory pressure).
    public func prewarm() async {
        guard await provider.isAvailable() else { return }
        await provider.registerWithResidency()
        guard await !residency.isRunningLighter else { return }
        try? await residency.acquire(provider.config.residencyKey)
    }

    /// The surface resolved: decode the prompt's system + stable prefix for this destination (the KV
    /// prefix cache), so the call after key-up prefills only VOCAB / HEARD / ALT. Not for a secure or
    /// verbatim destination (the stage does not call the model there).
    public func prewarm(packet: ContextPacket) async {
        let profile = Pipeline.DestinationProfiles.resolve(profileID: packet.destination.profileID)
        guard !packet.isSecure, !profile.isSecure, packet.mode == .transcribe else { return }
        let parts = WriterPrompt.renderParts(packet: packet, profile: profile)
        await provider.prewarm(system: parts.system, prefix: parts.stablePrefix)
    }
}

// MARK: - Personal vocabulary

/// §2.4 — the packet's `VocabularyMatching`, rebuilt in the background: at launch, when the
/// Dictionary or the corrections change (a database observation), after C1 learns or undoes an
/// alias, and at key-down when the index is older than `staleAfter` (the learned lexicon retrains on
/// its own clock). A landing only ever reads the index it finds; it never builds one.
public final class WriterVocabulary: VocabularyMatching, @unchecked Sendable {
    public static let staleAfter: TimeInterval = 600
    private let build: @Sendable () -> (any VocabularyMatching)?
    private let queue: DispatchQueue?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var matcher: (any VocabularyMatching)?
    private var builtAt: Date?
    private var pending = false
    private var observation: AnyDatabaseCancellable?

    /// - Parameter queue: where rebuilds run; nil = inline (tests).
    public init(build: @escaping @Sendable () -> (any VocabularyMatching)?,
                queue: DispatchQueue? = DispatchQueue(label: "voiceplus.writer.vocabulary", qos: .utility),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.build = build
        self.queue = queue
        self.now = now
    }

    public func matches(heard: ContextPacket.Heard, limit: Int) -> [ContextPacket.VocabularyMatch] {
        lock.withLock { matcher }?.matches(heard: heard, limit: limit) ?? []
    }

    public var isBuilt: Bool { lock.withLock { builtAt != nil } }

    /// Rebuild now (inline without a queue), coalescing requests that arrive while one is queued.
    public func rebuild() {
        let start = lock.withLock { () -> Bool in
            if pending { return false }
            pending = true
            return true
        }
        guard start else { return }
        let work: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.pending = false }
            let t0 = DispatchTime.now().uptimeNanoseconds
            let made = self.build()
            self.lock.withLock { self.matcher = made; self.builtAt = self.now() }
            Log.app.debug("writer vocabulary: rebuilt in \(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) ms")
        }
        if let queue { queue.asyncAfter(deadline: .now() + 0.5, execute: work) } else { work() }
    }

    /// The sources changed: rebuild in the background.
    public func invalidate() { rebuild() }

    /// Key-down: rebuild when the index is older than `staleAfter` (never built counts as stale).
    public func rebuildIfStale() {
        let stale = lock.withLock { builtAt.map { now().timeIntervalSince($0) > Self.staleAfter } ?? true }
        if stale { rebuild() }
    }

    /// Rebuild whenever the Dictionary or the corrections table changes.
    func observe(_ database: AppDatabase?) {
        guard let database else { return }
        let observation = DatabaseRegionObservation(tracking: Table(DictionaryRecord.databaseTableName),
                                                    Table(CorrectionRecord.databaseTableName))
        let cancellable = observation.start(in: database.writer, onError: { error in
            Log.app.error("writer vocabulary: observation failed: \(error)")
        }, onChange: { [weak self] _ in self?.invalidate() })
        lock.withLock { self.observation = cancellable }
    }
}

// MARK: - One run outside the app chain (Lab, replay)

/// What one writer run did: the spans out, the outcome code, the changed words (ranges in `text`)
/// and the writer's own ms (packet render + model call + guard).
public struct WriterRunResult: Sendable, Equatable {
    public var spans: [TranscriptSpan]
    public var outcome: String
    public var changed: [WriterChangedWord]
    public var ms: Double
    public var text: String { spans.renderedText }
}

extension WriterWiring {
    /// Runs the writer once on `spans` with `packet` through `generator` — the same gate, stage,
    /// guard and changed-word mapping as the app — in a fresh context (the packet's app; the
    /// register a shell / code destination would get from the gatekeeper, so verbatim surfaces skip
    /// exactly as in the app).
    public static func runOnce(spans: [TranscriptSpan], packet: ContextPacket, generator: any WriterGenerating,
                               context base: StageContext = StageContext(),
                               deadline: TimeInterval = ContextWriterStage.defaultDeadline) async -> WriterRunResult {
        let ledger = WriterRunLedger()
        let gate = WriterGateStage(inner: ContextWriterStage(generator: generator, deadline: deadline), ledger: ledger)
        var ctx = base
        if ctx.appBundleID == nil { ctx.appBundleID = packet.destination.appBundleID }
        if ctx.register == .unknown { ctx.register = register(forProfile: packet.destination.profileID) }
        packet.write(into: &ctx)
        let id = UUID()
        ctx.extra[activeKey] = "true"
        ctx.extra[landingIDKey] = id.uuidString
        let out = (try? await gate.process(spans, context: ctx)) ?? spans
        let run = ledger.take(id)
        let changed = run.map { changedWords($0, finalSpans: out, text: out.renderedText) } ?? []
        return WriterRunResult(spans: out, outcome: run?.outcome ?? "unknown", changed: changed, ms: run?.ms ?? 0)
    }

    /// The gatekeeper's register for a destination profile, where it matters to the writer.
    static func register(forProfile id: String) -> Utterance.Register {
        switch id {
        case "shell": return .terminal
        case "code.body", "code.comment", "commit": return .code
        default: return .unknown
        }
    }

    /// Spans for a packet's heard words (a text-only Lab case): one span per word, its confidence,
    /// its alternates best first. Without words, the raw text as confident words.
    public static func spans(from heard: ContextPacket.Heard) -> [TranscriptSpan] {
        let words = heard.words.isEmpty
            ? heard.raw.split(whereSeparator: \.isWhitespace).map { ContextPacket.HeardWord(text: String($0), confidence: 1) }
            : heard.words
        return words.enumerated().map { i, w in
            let n = Float(w.alternates.count)
            return TranscriptSpan(text: w.text, confidence: w.confidence,
                                  audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3),
                                  alternates: w.alternates.enumerated().map { Alternate(text: $1, score: (n - Float($0)) / max(n, 1), source: .beam) },
                                  provenance: [.asr])
        }
    }
}
