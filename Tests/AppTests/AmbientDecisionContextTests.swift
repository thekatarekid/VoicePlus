import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// V5 O5 / O4 verify fixes — the production O5 state reaches Layer 1 (app, field role, meeting,
/// another voice in the last 10 s), and "Not for you" nudges the bands in the app, not only in tests.
@Suite("V5 O5 AmbientDecisionContext")
struct AmbientDecisionContextTests {
    final class StateSpy: DecisionModel, @unchecked Sendable {
        let id = "spy"
        private let lock = NSLock()
        private var _states: [String] = []
        var states: [String] { lock.withLock { _states } }
        func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
            lock.withLock { _states.append(state) }
            return DecisionAnswers([.addressed: ["no": 0.9, "yes": 0.1], .complete: ["no": 0.1, "yes": 0.9],
                                    .capability: ["ignore": 0.9, "act": 0.1], .continuation: ["no": 0.9, "yes": 0.1],
                                    .needsAgent: ["no": 0.9, "yes": 0.1], .worthNoting: ["no": 0.9, "yes": 0.1]])
        }
    }

    @Test("context: frontmost app, focused field role and meeting state")
    func context() {
        let make = AmbientDecisionContext.make(
            frontmostApp: { "com.apple.mail" },
            field: { app in FieldContext(appBundleID: app, axRole: "AXTextArea") },
            meetingActive: { true })
        let s = make("send it")
        #expect(s.utterance == "send it")
        #expect(s.frontmostApp == "com.apple.mail")
        #expect(s.textFieldFocused)
        #expect(s.fieldRole == FieldRole.multilineText.rawValue)
        #expect(s.meetingActive)

        let none = AmbientDecisionContext.make(frontmostApp: { nil }, field: { _ in nil }, meetingActive: { false })("hi")
        #expect(!none.textFieldFocused && none.fieldRole == nil && !none.meetingActive)
    }

    @Test("pipeline: the model sees the context, and another voice heard in the last 10 s")
    func otherVoice() async {
        let settings = InMemorySettingsStore()
        let mode = AmbientModeController(settings: settings)
        mode.set(.listenAndNote)
        let spy = StateSpy()
        let arbiter = IntentArbiter(model: { spy })
        let pipeline = AmbientDecisionPipeline(
            mode: mode, arbiter: { arbiter }, verdict: { .unknown },
            context: AmbientDecisionContext.make(frontmostApp: { "us.zoom.xos" }, field: { _ in nil },
                                                 meetingActive: { true }))
        let t0 = Date()
        let you = SpeakerGate.Verdict.user(similarity: 0.9)
        await pipeline.handle("first", utteranceID: "a", range: t0...t0, verdict: you)
        // Another voice, discarded by the gate but still heard.
        pipeline.heard(.other(similarity: 0.1), at: t0.addingTimeInterval(1))
        let t1 = t0.addingTimeInterval(5)
        await pipeline.handle("second", utteranceID: "b", range: t1...t1, verdict: you)
        let t2 = t0.addingTimeInterval(30)
        await pipeline.handle("third", utteranceID: "c", range: t2...t2, verdict: you)

        let states = spy.states
        #expect(states.count == 3)
        #expect(states[0].contains("app: us.zoom.xos"))
        #expect(states[0].contains("meeting recording: yes"))
        #expect(states[0].contains("another voice in the last 10 s: no"))
        #expect(states[1].contains("another voice in the last 10 s: yes"))
        #expect(states[1].contains("[ignore] first"))
        #expect(states[2].contains("another voice in the last 10 s: no"))
    }

    @Test("process: a discarded other-voice segment still reaches the O5 signal")
    func processFeedsOtherVoice() {
        let settings = InMemorySettingsStore()
        let mode = AmbientModeController(settings: settings)
        let pipeline = AmbientDecisionPipeline(mode: mode, arbiter: { nil }, verdict: { .unknown })
        let now = Date()
        let heard = AmbientHeard(id: "x", text: "someone else", verdict: .other(similarity: 0.1),
                                 capturedAt: now, duration: 1)
        let off = AmbientCaptureGate(isEnabled: false, capturesEverySpeaker: false,
                                     filter: SpeakerFilter(isOn: true, gate: SpeakerGate(profile: nil), canIdentify: false))
        final class Sink: AmbientTranscriptSink, @unchecked Sendable { func store(_ e: AmbientEntry) throws -> String { "" } }
        AmbientWiring.process(heard, sink: Sink(), gate: off, decisions: pipeline)
        #expect(pipeline.otherVoiceRecently(before: now.addingTimeInterval(3)))
        #expect(!pipeline.otherVoiceRecently(before: now.addingTimeInterval(20)))
    }

    @Test("Not for you: the correction's observer nudges the frontmost app's bands")
    func notForYouNudges() {
        let settings = InMemorySettingsStore()
        let bands = DecisionBandsSettings(settings: settings)
        let correction = NotYouCorrection(teacher: RecordingTeacher())
        correction.observer = BandNudgingTeacher(inner: nil, bands: bands, frontmostApp: { "com.zoom" })
        correction.didTrigger(PendingTrigger(text: "open the door"))
        correction.notYou(reason: .notTalkingToYou)
        #expect(bands.bands.perAppOffset["com.zoom"] == DecisionBands.nudgeStep)
    }
}
