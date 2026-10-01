import Engine
import Foundation
import GRDB
import Shared
import Testing
@testable import VoicePlusApp

/// V5 O2 + O3 — one decision per utterance, logged to Q13 and tagged onto every running recorder.
@Suite("V5 O3 — one decision per utterance")
struct UtteranceDecisionO3Tests {
    final class SpyRecorder: UtteranceTagRecording, @unchecked Sendable {
        var tags: [UtteranceTag] = []
        func record(_ tag: UtteranceTag) { tags.append(tag) }
    }

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func range(_ a: TimeInterval, _ b: TimeInterval) -> ClosedRange<Date> {
        t0.addingTimeInterval(a)...t0.addingTimeInterval(b)
    }

    static func landing(_ route: Utterance.Route, id: UUID = UUID()) -> LandingResult {
        LandingResult(utteranceID: id, route: route, register: .unknown, text: "x", injection: nil,
                      repair: nil, pipelineMs: 0, totalMs: 0)
    }

    @Test("the decision shape: owner, confidence (clamped), band, reason, question probabilities; Codable")
    func decisionShape() throws {
        let d = UtteranceDecision(owner: .note, confidence: 1.4, band: .note, reason: "layer1.kev",
                                  questionProbabilities: ["addressed": 0.2, "worthNoting": 0.7])
        #expect(d.confidence == 1)
        #expect(try JSONDecoder().decode(UtteranceDecision.self, from: JSONEncoder().encode(d)) == d)
        #expect(UtteranceDecision.explicit(.dictate, reason: "hotkey") ==
                UtteranceDecision(owner: .dictate, confidence: 1, reason: "hotkey"))
        #expect(UtteranceOwner.allCases.map(\.rawValue) == ["dictate", "edit", "act", "note", "ask", "ignore"])
        #expect(UtteranceBand.allCases.map(\.rawValue) == ["act", "ask", "note", "ignore"])
    }

    @Test("settled once: logged to Q13 with the record shape, tagged onto every recorder")
    func settleLogsAndTags() throws {
        let hub = UtteranceDecisionHub()
        let store = try TurnDiagnostics(writer: try DatabaseQueue())
        hub.diagnostics = { store.record($0, turn: $1) }
        let meeting = SpyRecorder(), ambient = SpyRecorder()
        hub.setRecorder(meeting, for: "meeting")
        hub.setRecorder(ambient, for: "ambient")
        let d = UtteranceDecision(owner: .ask, confidence: 0.72, band: .ask, reason: "layer1.kev",
                                  questionProbabilities: ["addressed": 0.9])
        #expect(hub.settle(d, utterance: "u1", range: Self.range(0, 2), turn: "turn-1"))
        #expect(!hub.settle(.explicit(.dictate, reason: "again"), utterance: "u1", range: Self.range(0, 2)))

        let rows = try store.entries(turn: "turn-1")
        #expect(rows.count == 1)
        #expect(rows.first?.event == .decision(.init(owner: "ask", confidence: 0.72, band: "ask",
                                                     reason: "arbiter:layer1.kev",
                                                     questionProbabilities: ["addressed": 0.9])))
        #expect(try store.entries().count == 1)
        let expected = UtteranceTag(utteranceID: "u1", owner: .ask, range: Self.range(0, 2))
        #expect(meeting.tags == [expected] && ambient.tags == [expected])
    }

    @Test("ignore is logged but tags no recorder; the arbiter's decision beats a provisional landing one")
    func ignoreAndArbiterPrecedence() {
        let hub = UtteranceDecisionHub()
        var logged: [TurnDiagnosticsEvent] = []
        hub.diagnostics = { e, _ in logged.append(e) }
        let rec = SpyRecorder()
        hub.setRecorder(rec, for: "meeting")
        #expect(hub.settle(.explicit(.ignore, reason: "layer1"), utterance: "a", range: Self.range(0, 1)))
        #expect(rec.tags.isEmpty && logged.count == 1)

        #expect(hub.settle(.explicit(.note, reason: "wakeVerb.note"), utterance: "arb", range: Self.range(10, 12)))
        // The landing of the same speech arrives under its own id: provisional, overlapping → dropped.
        #expect(!hub.settle(.explicit(.dictate, reason: "route.dictate"), utterance: "landing",
                            range: Self.range(10.5, 12.5), source: .landing))
        // A landing that does not overlap any arbiter decision settles.
        #expect(hub.settle(.explicit(.dictate, reason: "route.dictate"), utterance: "later",
                           range: Self.range(30, 31), source: .landing))
        #expect(rec.tags.map(\.owner) == [.note, .dictate])
        #expect(logged.count == 3)
    }

    @Test("recorders are weak and keyed: re-registering replaces, a released recorder drops out")
    func recorderRegistry() {
        let hub = UtteranceDecisionHub()
        var a: SpyRecorder? = SpyRecorder()
        let b = SpyRecorder()
        hub.setRecorder(a, for: "meeting")
        hub.setRecorder(b, for: "meeting")
        #expect(hub.recorderKeys == ["meeting"])
        hub.setRecorder(a, for: "ambient")
        a = nil
        #expect(hub.recorderKeys == ["meeting"])
        hub.settle(.explicit(.dictate, reason: "r"), utterance: "u", range: Self.range(0, 1))
        #expect(b.tags.count == 1)
    }

    @Test("provisional decisions from the landing route")
    func landingMapping() {
        #expect(UtteranceDecisionHub.decision(for: Self.landing(.dictate)).owner == .dictate)
        #expect(UtteranceDecisionHub.decision(for: Self.landing(.repairCommand)).owner == .edit)
        #expect(UtteranceDecisionHub.decision(for: Self.landing(.transform)).owner == .edit)
        #expect(UtteranceDecisionHub.decision(for: Self.landing(.question)).owner == .ask)
        #expect(UtteranceDecisionHub.decision(for: Self.landing(.none)) == .explicit(.ignore, reason: "route.none"))
        #expect(UtteranceDecisionHub.decision(for: Self.landing(.dictate)).confidence == 1)
    }

    @Test("the ambient timeline labels the user's own span in its day record, once")
    func ambientTimelineTagger() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-o2-ambient-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let meetings = MeetingStore(root: root)
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let offset = now.timeIntervalSince(day)
        let id = AmbientTranscriptStore.recordID(for: now)
        var record = MeetingRecord(id: id, title: "Ambient", startedAt: day, labeler: "ambient")
        record.transcript.utterances = [
            MeetingUtterance(speaker: .others(1), text: "other", range: offset...(offset + 2), confidence: 1),
            MeetingUtterance(speaker: .you, text: "mine", range: offset...(offset + 2), confidence: 1),
        ]
        try meetings.save(record)
        let tagger = AmbientTimelineTagger(meetings: meetings)
        let tag = UtteranceTag(utteranceID: "u", owner: .dictate, range: now...now.addingTimeInterval(2))
        #expect(tagger.apply(tag) == 1)
        #expect(tagger.apply(tag) == 0)
        #expect(try meetings.load(id: id).transcript.utterances.map(\.tag) == [nil, .dictate])
        // No day record → nothing written.
        let empty = AmbientTimelineTagger(meetings: MeetingStore(root: root.appendingPathComponent("none")))
        #expect(empty.apply(tag) == 0)
    }
}

/// O3 — the session coordinator settles each landing with the window the claim was open.
@Suite("V5 O3 — landings settle through the session coordinator")
@MainActor
struct SessionCoordinatorDecisionTests {
    @Test("a hotkey landing settles one dictate decision over the claim window, tagged onto recorders")
    func landingSettles() {
        let hub = UtteranceDecisionHub()
        let rec = UtteranceDecisionO3Tests.SpyRecorder()
        hub.setRecorder(rec, for: "meeting")
        var logged: [TurnDiagnosticsEvent] = []
        hub.diagnostics = { e, _ in logged.append(e) }
        let dictation = DictationCoordinator(engine: StatusMenuControllerTests.CountingEngine(), database: nil,
                                             pill: PillPanelController())
        var pillSaw = 0
        dictation.onLanded = { _ in pillSaw += 1 }        // the app's own handler, set first
        let session = SessionCoordinator(dictation: dictation,
                                         mute: MuteController(store: InMemoryMuteStore(muted: false)),
                                         decisions: hub)
        var now = UtteranceDecisionO3Tests.t0
        session.clock = { now }
        session.start(.hotkey)
        now = now.addingTimeInterval(3)
        session.stop(.hotkey)
        now = now.addingTimeInterval(1)          // formatting + dwell before landing
        let result = UtteranceDecisionO3Tests.landing(.dictate)
        dictation.onLanded?(result)
        dictation.onLanded?(result)              // a repeated callback is not a second decision
        #expect(pillSaw == 2)                    // the chain keeps the app's handler
        #expect(rec.tags == [UtteranceTag(utteranceID: result.utteranceID.uuidString, owner: .dictate,
                                          range: UtteranceDecisionO3Tests.range(0, 3))])
        #expect(logged.count == 1)
        if case .decision(let d) = logged.first {
            #expect(d.owner == "dictate" && d.confidence == 1 && d.reason == "landing:route.dictate")
        } else { Issue.record("expected a decision event") }
    }
}
