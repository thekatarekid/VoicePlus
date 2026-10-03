import Foundation
import Injection
import Pipeline
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// H8 / X5-notch-offer — an edit that cannot run is never silent: a password field is refused before
/// any selection read; an LLM command with no model says "Needs the on-device model · Saved to Notes",
/// keeps the words in Notes, leaves the selection untouched and offers the download in the notch once.
/// Mock providers only; nothing downloads.
@Suite("H8 — edit failures never silent")
struct TransformNeedsModelH8Tests {
    typealias Box<T> = TransformPreviewGateTests.Box<T>

    struct H {
        let lander: UtteranceLander
        let landing: TransformLanding
        let system: MockSystemAccess
        let events: Box<[TransformPillReducer.Event]>
        let notes: Box<[(text: String, app: String, reason: String)]>
        let policy: ModelOfferPolicy
    }

    /// No pinned provider, no on-device model: `LocalOnlyProviderRouting`.
    static func make(_ value: String, _ selection: Range<Int>, field: MockSystemAccess.Field? = nil,
                     providers: any PipelineProviderRouting = LocalOnlyProviderRouting(),
                     saves: Bool = true, policy: ModelOfferPolicy = ModelOfferPolicy(store: .inMemory())) -> H {
        let system = MockSystemAccess()
        var f = field ?? MockSystemAccess.Field()
        f.value = value; f.selection = selection
        system.field = f
        let injector = TextInjector(system: system)
        let session = TransformSession(executor: TransformExecutor(providers: providers), sink: InjectionTransformReplaceSink(system: system))
        let landing = TransformLanding(session: session, detector: SystemAccessSelectionDetector(system: system),
                                       qa: QuestionAnswerStage(answerer: HeuristicAnswerer()), system: system, injector: injector)
        let lander = UtteranceLander(pipeline: PipelineRunner.standard(), injector: injector, system: system, repair: nil,
                                     flags: .inMemory(), database: nil)
        lander.transform = landing
        let h = H(lander: lander, landing: landing, system: system, events: Box([]), notes: Box([]), policy: policy)
        landing.onEvent = { [events = h.events] in events.value.append($0) }
        landing.sleep = { _ in }
        landing.offerPolicy = policy
        landing.saveToNotes = { [notes = h.notes] text, app, reason in
            notes.value.append((text, app, reason))
            return saves ? .savedToNotes(intendedApp: app, reason: .editFailed) : nil
        }
        return h
    }

    static func land(_ h: H, _ text: String, low: Set<String> = []) async -> LandingResult {
        let spans = text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: low.contains(String(w)) ? 0.3 : 0.95, audioRange: Double(i)...Double(i + 1))
        }
        return await h.lander.land(spans, startedAt: Date(), focus: h.system.frontmost)
    }

    // MARK: No model

    @Test("LLM command without a model → message + Notes + Download offered; selection untouched")
    func needsModelSavesAndOffers() async {
        let h = Self.make("hey can you send it", 0..<19)
        let r = await Self.land(h, "make this sound friendlier")
        guard case .transformed(.failed(.unavailable(let why)))? = r.transform else {
            Issue.record("got \(String(describing: r.transform))"); return
        }
        #expect(why == TransformLanding.needsModelReason)
        #expect(h.system.field.value == "hey can you send it")
        #expect(h.system.field.selection == 0..<19)
        #expect(r.injection == nil)
        #expect(h.notes.value.count == 1)
        #expect(h.notes.value.first?.text == "make this sound friendlier")
        #expect(h.notes.value.first?.reason == NoteReason.editFailed.rawValue)
        #expect(h.events.value.last == .needsModel(line: TransformLanding.needsModelLine, offerDownload: true))
        #expect(h.policy.stage == .settingsOnly)
    }

    @Test("X5 — the notch offers the download only once; afterwards Settings only")
    func offerOnlyOnce() async {
        let h = Self.make("hey can you send it", 0..<19)
        _ = await Self.land(h, "make this sound friendlier")
        _ = await Self.land(h, "make this more formal")
        let offers = h.events.value.compactMap { e -> Bool? in
            if case .needsModel(_, let o) = e { return o }; return nil
        }
        #expect(offers == [true, false])
        #expect(h.notes.value.count == 2)
    }

    @Test("X5 — a model chosen in onboarding is never offered again in the notch")
    func noOfferAfterOnboardingChoice() async {
        let policy = ModelOfferPolicy(store: .inMemory())
        policy.recordOnboardingChoice()
        let h = Self.make("hello there", 0..<11, policy: policy)
        _ = await Self.land(h, "make this sound friendlier")
        #expect(h.events.value.last == .needsModel(line: TransformLanding.needsModelLine, offerDownload: false))
    }

    @Test("Notes could not keep the words → the line does not claim it saved them")
    func unsavedLine() async {
        let h = Self.make("hello there", 0..<11, saves: false)
        _ = await Self.land(h, "make this sound friendlier")
        guard case .needsModel(let line, _)? = h.events.value.last else { Issue.record("\(h.events.value)"); return }
        #expect(line == TransformLanding.needsModelUnsavedLine)
    }

    @Test("a deterministic command still runs with no model at all")
    func deterministicWithoutModel() async {
        let h = Self.make("ship it now", 0..<7)
        let r = await Self.land(h, "make this all caps")
        guard case .transformed(.applied)? = r.transform else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "SHIP IT now")
        #expect(h.notes.value.isEmpty)
    }

    // MARK: Password first

    @Test("secure field with a selection: nothing read, nothing to a model, Notes or history; nothing typed")
    func secureRefusedFirst() async {
        let provider = ScriptedRewriter(); provider.script = [(instruction: "formal", output: "LEAKED")]
        let h = Self.make("hunter2", 0..<7, field: .secure(), providers: provider)
        let r = await Self.land(h, "make this formal")
        #expect(r.transform == nil)
        #expect(provider.calls == 0)
        #expect(h.notes.value.isEmpty)
        #expect(h.events.value.isEmpty)
        #expect(h.system.field.value == "hunter2")
        if let inj = r.injection { #expect(inj.succeeded == false) }
    }

    @Test("web-style password (subrole) is refused the same way")
    func secureWebRefused() async {
        let h = Self.make("hunter2", 0..<7, field: .secure(webStyle: true))
        let out = await h.landing.handle(TransformLandingTests.spans("make this sound friendlier"), decision: .fallback(), context: StageContext())
        #expect(out == .notHandled)
        #expect(h.notes.value.isEmpty && h.events.value.isEmpty)
        #expect(SystemAccessSelectionDetector(system: h.system).currentSelection() == nil)
    }

    // MARK: T05 only when the uncertain word decides

    @Test("one uncertain filler word → the edit still runs")
    func uncertainFillerRuns() async {
        let h = Self.make("ship it now", 0..<7)
        let r = await Self.land(h, "um make this all caps", low: ["um", "this"])
        guard case .transformed(.applied)? = r.transform else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "SHIP IT now")
    }

    @Test("an uncertain word that decides the command → T05, nothing changed, no Notes")
    func uncertainDecidingWordRefuses() async {
        let h = Self.make("ship it now", 0..<7)
        let r = await Self.land(h, "make this formal", low: ["formal"])
        guard case .transformed(.failed)? = r.transform else { Issue.record("got \(String(describing: r.transform))"); return }
        #expect(h.system.field.value == "ship it now")
        #expect(h.events.value.last == .failed(RecoveryCatalog.entry(.T05).headline))
    }
}

/// H8 / X5 — the needs-model row and its one-time Download button.
@Suite("H8 — needs-model row")
@MainActor
struct TransformNeedsModelRowTests {
    @Test("reducer: the offer shows, outlives a plain notice, and retracts")
    func reducerOffer() {
        var r = TransformPillReducer()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let s = r.reduce(.needsModel(line: TransformLanding.needsModelLine, offerDownload: true), now: t0)
        #expect(s == .transform(.init(editingWords: 0, stage: .notice(TransformLanding.needsModelLine))))
        #expect(r.offersDownload)
        _ = r.reduce(.tick, now: t0 + 5)
        #expect(r.offersDownload)
        #expect(r.reduce(.tick, now: t0 + TransformPillReducer.downloadOfferNotice + 0.1) == .hidden)
        #expect(!r.offersDownload)

        _ = r.reduce(.needsModel(line: "x", offerDownload: false), now: t0)
        #expect(!r.offersDownload)
        #expect(r.reduce(.tick, now: t0 + TransformPillReducer.needsModelNotice + 0.1) == .hidden)
    }

    @Test("driver: Download calls onDownloadModel once and closes the row; no offer → nothing")
    func driverDownload() {
        let d = TransformPillDriver(pill: PillViewModel())
        var calls = 0
        d.onDownloadModel = { calls += 1 }
        d.perform(.downloadModel)
        #expect(calls == 0)
        d.handle(.needsModel(line: TransformLanding.needsModelLine, offerDownload: true))
        #expect(d.offersDownload)
        d.perform(.downloadModel)
        #expect(calls == 1)
        #expect(!d.offersDownload)
        d.perform(.downloadModel)
        #expect(calls == 1)
    }
}
