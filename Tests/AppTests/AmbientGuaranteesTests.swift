import Actions
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 L2 — the ambient guarantees (amends V3 §8; replaces R8.1's `AmbientNeverInjectsTests` /
/// `AmbientInjectionAudit`):
///   1. no inject / act unless the mode is Listen & act;
///   2. only the user's voice (K4/M6 verdict `.you` → `SpeakerGate.Verdict.user`);
///   3. only the act band (ask pill: at least the ask band);
///   4. irreversible steps are never self-confirmed;
///   and Listen & note never reaches `delivery`.
@Suite("V5 L2 AmbientGuarantees")
struct AmbientGuaranteesTests {
    // MARK: Rig

    final class Model: DecisionModel, @unchecked Sendable {
        let id = "mock"
        var addressed: Double
        var capability: UtteranceOwner
        private(set) var calls = 0
        init(addressed: Double = 0.97, capability: UtteranceOwner = .act) { self.addressed = addressed; self.capability = capability }
        func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
            calls += 1
            var cap: [String: Double] = [:]
            for o in UtteranceOwner.allCases { cap[o.rawValue] = o == capability ? 0.9 : 0.02 }
            return DecisionAnswers([.addressed: ["no": 1 - addressed, "yes": addressed], .complete: ["no": 0.05, "yes": 0.95],
                                    .capability: cap, .continuation: ["no": 0.5, "yes": 0.5],
                                    .needsAgent: ["no": 0.9, "yes": 0.1], .worthNoting: ["no": 0.9, "yes": 0.1]])
        }
    }

    final class DeliverySpy: AmbientDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var _got: [(String, UtteranceOwner)] = []
        var got: [(String, UtteranceOwner)] { lock.withLock { _got } }
        func deliver(_ text: String, owner: UtteranceOwner, decision: UtteranceDecision) async {
            lock.withLock { _got.append((text, owner)) }
        }
    }

    /// The latch delivery: ambient must never enter it in any mode.
    final class LatchSpy: LatchDelivering, @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var entered: Int { lock.withLock { n } }
        func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool { lock.withLock { n += 1 }; return true }
        func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String { lock.withLock { n += 1 }; return "" }
        func insertHeld(into target: String) -> Int { lock.withLock { n += 1 }; return 0 }
    }

    final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var _texts: [String] = []
        var texts: [String] { lock.withLock { _texts } }
        func add(_ t: String) { lock.withLock { _texts.append(t) } }
    }

    struct Rig {
        let settings = InMemorySettingsStore()
        let mode: AmbientModeController
        let model: Model
        let arbiter: IntentArbiter
        let delivery = DeliverySpy()
        let notes = Notes()
        let pipeline: AmbientDecisionPipeline
        let hub = UtteranceDecisionHub()

        init(mode m: AmbientMode, verdict: SpeakerGate.Verdict, model: Model = Model()) {
            mode = AmbientModeController(settings: settings)
            mode.set(m)
            self.model = model
            arbiter = IntentArbiter(layer0: ArbiterWiring.layer0(actParser: nil), model: { model })
            arbiter.onDecision = ArbiterWiring.settle(on: hub)
            let arbiter = self.arbiter
            pipeline = AmbientDecisionPipeline(mode: mode, arbiter: { arbiter }, verdict: { verdict })
            pipeline.delivery = delivery
            let notes = self.notes
            pipeline.note = { t, _ in notes.add(t); return true }
        }

        func say(_ text: String, id: String = UUID().uuidString) async -> AmbientDisposition {
            await pipeline.handle(text, utteranceID: id, range: Date()...Date())
        }
    }

    static let you = SpeakerGate.Verdict.user(similarity: 0.9)
    static let other = SpeakerGate.Verdict.other(similarity: 0.2)

    // MARK: 1 + 2 + 3 — the disposition matrix, exhaustively

    @Test("delivery only when mode == Listen & act, voice == user, band == act (ask pill: ≥ ask)")
    func matrix() {
        let verdicts: [SpeakerGate.Verdict] = [Self.you, Self.other, .unknown]
        let bands: [UtteranceBand?] = UtteranceBand.allCases + [nil]
        for mode in AmbientMode.allCases {
            for verdict in verdicts {
                for owner in UtteranceOwner.allCases {
                    for band in bands {
                        for confidence in [0.5, 1.0] {
                            let d = UtteranceDecision(owner: owner, confidence: confidence, band: band, reason: "t")
                            let out = AmbientGuarantees.disposition(mode: mode, verdict: verdict, decision: d, text: "do the thing")
                            let eff = AmbientGuarantees.effectiveBand(d)
                            if out.delivers {
                                #expect(mode == .listenAndAct, "delivered in \(mode)")
                                #expect(verdict.isUser, "delivered for \(verdict)")
                                if owner == .ask { #expect(eff == .act || eff == .ask) }
                                else { #expect(eff == .act, "delivered \(owner) in band \(eff)") }
                                #expect(owner != .note && owner != .ignore)
                            }
                            if !mode.listens { #expect(out == .recordOnly(.modeOff)) }
                            if mode == .listenAndNote { #expect(!out.delivers, "Listen & note reached delivery") }
                            if !verdict.isUser { #expect(!out.delivers && out != .note) }
                        }
                    }
                }
            }
        }
        // The positive control: the matrix is not vacuous.
        let act = UtteranceDecision(owner: .act, confidence: 0.95, band: .act, reason: "t")
        #expect(AmbientGuarantees.disposition(mode: .listenAndAct, verdict: Self.you, decision: act, text: "open mail") == .deliver(.act))
        #expect(AmbientGuarantees.disposition(mode: .listenAndNote, verdict: Self.you, decision: act, text: "open mail") == .note)
    }

    // MARK: 4 — never self-confirm

    @Test("an ambient utterance never confirms an irreversible step")
    func noSelfConfirm() {
        #expect(!AmbientGuarantees.mayConfirm("confirm", source: .ambient, reversibility: .irreversible))
        #expect(AmbientGuarantees.mayConfirm("confirm", source: .explicitTurn, reversibility: .irreversible))
        #expect(AmbientGuarantees.mayConfirm("anything", source: .click, reversibility: .irreversible))
        #expect(!AmbientGuarantees.mayConfirm("confirm the meeting", source: .explicitTurn, reversibility: .semi))
        let d = UtteranceDecision(owner: .act, confidence: 1, reason: "explicit")
        #expect(AmbientGuarantees.disposition(mode: .listenAndAct, verdict: Self.you, decision: d, text: "Confirm.")
                == .recordOnly(.cannotSelfConfirm))
    }

    // MARK: Behaviour through the pipeline

    @Test("Listen & note: a confident act from the user's own voice becomes a note, never a delivery")
    func listenAndNoteNeverDelivers() async {
        let rig = Rig(mode: .listenAndNote, verdict: Self.you)
        #expect(await rig.say("open my calendar") == .note)
        #expect(rig.delivery.got.isEmpty)
        #expect(rig.notes.texts == ["open my calendar"])
        #expect(rig.model.calls == 1)
    }

    @Test("Listen & act: the same utterance is delivered (control — the rig can deliver)")
    func listenAndActDelivers() async {
        let rig = Rig(mode: .listenAndAct, verdict: Self.you)
        #expect(await rig.say("open my calendar") == .deliver(.act))
        #expect(rig.delivery.got.map(\.1) == [.act])
    }

    @Test("another voice and an unknown voice never act")
    func onlyUserVoice() async {
        for v in [Self.other, SpeakerGate.Verdict.unknown] {
            let rig = Rig(mode: .listenAndAct, verdict: v)
            #expect(await rig.say("open my calendar") == .recordOnly(.notUserVoice))
            #expect(rig.delivery.got.isEmpty)
            #expect(rig.notes.texts.isEmpty)
        }
    }

    @Test("below the act band nothing acts; the note band notes")
    func bandGate() async {
        let rig = Rig(mode: .listenAndAct, verdict: Self.you, model: Model(addressed: 0.7, capability: .act))
        #expect(await rig.say("maybe open the calendar") == .deliver(.ask))   // ask band → the ask pill only
        rig.model.addressed = 0.5
        #expect(await rig.say("calendar") == .note)
        rig.model.addressed = 0.1
        rig.model.capability = .ignore
        #expect(await rig.say("lunch at noon?") == .recordOnly(.ignored))
        #expect(rig.delivery.got.map(\.1) == [.ask])
    }

    @Test("Off: the arbiter is not even consulted")
    func off() async {
        let rig = Rig(mode: .off, verdict: Self.you)
        #expect(await rig.say("open my calendar") == .recordOnly(.modeOff))
        #expect(rig.model.calls == 0)
    }

    @Test("spoken mode switches: anyone may turn it down, only the user may turn acting back on")
    func voiceSwitch() async {
        let other = Rig(mode: .listenAndNote, verdict: Self.other)
        _ = await other.say("you can act again")
        #expect(other.mode.mode == .listenAndNote)
        _ = await other.say("stop listening")
        #expect(other.mode.mode == .off)
        let you = Rig(mode: .listenAndNote, verdict: Self.you)
        #expect(await you.say("you can act again") == .recordOnly(.modeCommand))
        #expect(you.mode.mode == .listenAndAct)
        #expect(you.model.calls == 0)
    }

    @Test("the arbiter's own Layer 2 handoff is never used for ambient speech; the decision is settled once")
    func noBypass() async {
        final class Handoff: Layer2Handoff, @unchecked Sendable {
            var n = 0
            func handle(_ decision: UtteranceDecision, text: String, answers: DecisionAnswers?) async { n += 1 }
        }
        let rig = Rig(mode: .listenAndNote, verdict: Self.you)
        let h = Handoff()
        rig.arbiter.handoff = h
        var settled: [UtteranceDecision] = []
        rig.hub.onSettled = { d, _ in settled.append(d) }
        _ = await rig.say("open my calendar", id: "u1")
        #expect(h.n == 0)
        #expect(settled.map(\.owner) == [.act])
    }

    @Test("end to end: ambient latch segments never enter LatchDelivering, in any mode")
    func latchNeverEntered() async throws {
        for m in AmbientMode.allCases {
            let latchSpy = LatchSpy()
            let runtime = LatchRuntime(delivery: latchSpy)
            runtime.isLatched = { true }
            runtime.source = .ambient
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("l2-\(UUID().uuidString)")
            let store = AmbientTranscriptStore(meetings: MeetingStore(root: root), database: try AppDatabase.inMemory(),
                                              retention: { AmbientRetentionPolicy(days: 7) })
            let rig = Rig(mode: m, verdict: Self.you)
            let gate = AmbientCaptureGate(isEnabled: true, capturesEverySpeaker: true,
                                          filter: SpeakerFilter(isOn: false, gate: SpeakerGate(profile: nil), canIdentify: false))
            AmbientWiring.attach(to: runtime, sink: store, gate: { gate }, decisions: rig.pipeline)
            runtime.handle(.closed(segment: SegmentID(sessionID: UUID(), index: 0),
                                   spans: [TranscriptSpan(text: "open my calendar", confidence: 0.9, audioRange: 0...1, provenance: [.asr])],
                                   stability: .committed, reason: .endpoint))
            await runtime.settle()
            await rig.pipeline.settle()
            #expect(latchSpy.entered == 0, "ambient reached LatchDelivering in \(m)")
            #expect(store.entries().count == 1)
            #expect(rig.delivery.got.count == (m == .listenAndAct ? 1 : 0), "\(m)")
            #expect(rig.notes.texts.count == (m == .listenAndNote ? 1 : 0), "\(m)")
        }
    }
}
