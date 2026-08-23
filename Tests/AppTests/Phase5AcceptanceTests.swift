import Engine
import Foundation
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Phase 5 acceptance — hands-free gate (directed speech × speaker × mute), wake-verb pre-route,
/// "not you" correction, and the meeting detector → session → notes flow, all against mocks.
@Suite("Phase 5 acceptance — hands-free + meetings")
struct Phase5AcceptanceTests {
    // MARK: Directed speech

    /// P5.1 metric harness over the shipped corpus — the reading DECISIONS.md records.
    @Test func directedSpeechHarnessMeetsShipBarOnFixtureCorpus() throws {
        let fixtures = try #require(AppPaths.fixturesDirectory())
        let harness = DirectedSpeechHarness(fixturesDirectory: fixtures)
        let metrics = try harness.evaluate(classifier: DirectedSpeechClassifier())
        print("P5 acceptance harness: \(metrics)")
        #expect(metrics.meetsShipBar, "false-trigger rate \(metrics.falseTriggersPerDay)/day ≥ ship bar")
        #expect(metrics.missedAddressRate < 0.5)
    }

    static func controller(flagOn: Bool = true, threshold: Double = 0.0) -> (HandsFreeController, InMemoryMuteStore) {
        let store = InMemoryMuteStore()
        let flags = FeatureFlagService.inMemory(["directedSpeech": flagOn])
        let controller = HandsFreeController(flags: flags, mute: MuteController(store: store),
                                             embedder: MFCCEmbedder(),
                                             profiles: SpeakerProfileStore(url: FileManager.default.temporaryDirectory
                                                .appendingPathComponent("p5-profile-\(UUID()).json")))
        controller.detector.classifier.threshold = threshold
        controller.isHandsFree = { true }
        return (controller, store)
    }

    static func tone(_ hz: Float, seconds: Float = 1.0, rate: Float = 16_000) -> [Float] {
        (0..<Int(rate * seconds)).map { 0.4 * sin(2 * .pi * hz * Float($0) / rate) }
    }

    static func speak(_ controller: HandsFreeController, samples: [Float]? = nil) -> Bool {
        let audio = samples ?? tone(220)
        controller.appendAudio(audio)
        controller.handle(.speechStart(at: 0))
        return controller.handle(.speechEnd(at: Double(audio.count) / 16_000), utteranceSamples: samples)
    }

    @Test func handsFreeGateOpensOnDirectedSpeechOnly() {
        let (controller, _) = Self.controller()
        var captures = 0
        controller.onShouldCapture = { _ in captures += 1 }
        #expect(Self.speak(controller))
        #expect(captures == 1)

        // Classifier says "not directed" → no capture.
        controller.detector.classifier.threshold = 1.1
        #expect(!Self.speak(controller))
        #expect(captures == 1)
        #expect(controller.lastRejection == "not directed")
    }

    @Test func experimentalFlagAndHardMuteGateEverything() {
        let (off, _) = Self.controller(flagOn: false)
        var captures = 0
        off.onShouldCapture = { _ in captures += 1 }
        #expect(!Self.speak(off), "flag off → hands-free never triggers")
        #expect(captures == 0)

        let (muted, store) = Self.controller()
        muted.onShouldCapture = { _ in captures += 1 }
        muted.mute.mute()
        #expect(!Self.speak(muted))
        #expect(captures == 0)
        #expect(muted.lastRejection == "muted")
        #expect(store.muted, "hard mute persists")
        // Unmute is never automatic — still muted after more speech.
        _ = Self.speak(muted)
        #expect(muted.mute.isMuted)
    }

    // MARK: Speaker gate (P5.3)

    @Test func speakerGateRejectsOtherVoices() throws {
        let (controller, _) = Self.controller()
        let embedder = MFCCEmbedder()
        // Enroll: three takes of the "user" (low harmonic voice).
        var enrollment = SpeakerEnrollment()
        for detune in [Float(0), 2, -2] {
            let take = zip(Self.tone(120 + detune), Self.tone(240 + detune)).map { $0 + 0.5 * $1 }
            _ = enrollment.record(try embedder.embed(take))
        }
        let profile = try #require(enrollment.profile)
        controller.install(profile: profile)

        var captures = 0
        controller.onShouldCapture = { _ in captures += 1 }

        // The TV (white noise) speaks: rejected.
        var seed: UInt64 = 42
        let noise = (0..<16_000).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed) % 1000) / 1500
        }
        #expect(!Self.speak(controller, samples: noise))
        #expect(controller.lastRejection == "speaker")
        #expect(captures == 0)

        // The user speaks again: accepted.
        let user = zip(Self.tone(121), Self.tone(241)).map { $0 + 0.5 * $1 }
        #expect(Self.speak(controller, samples: user))
        #expect(captures == 1)
    }

    // MARK: "not you" (P5.4)

    @Test func notYouTeachesTheClassifierAndIsNeverTyped() {
        let (controller, _) = Self.controller()
        _ = Self.speak(controller)
        let before = controller.detector.classifier.correctionCount

        var ctx = StageContext()
        ctx.extra[WakeVerbPreRoute.modeKey] = WakeVerbPreRoute.handsFreeValue
        let decision = controller.preRoute("not you", context: ctx)
        #expect(decision?.route == Utterance.Route.none)
        #expect(controller.detector.classifier.correctionCount == before + 1)
        #expect(controller.consumeClaim(), "claimed → the lander must not type it")
        #expect(!controller.consumeClaim(), "claim is consumed once")

        // Outside hands-free the phrase is ordinary text.
        #expect(controller.preRoute("not you", context: StageContext()) == nil)
    }

    // MARK: Wake verb (P5.2)

    @Test func wakeVerbRoutesAndStripsInHandsFreeOnly() async throws {
        let wake = WakeVerbPreRoute()
        var ctx = StageContext()
        ctx.extra[WakeVerbPreRoute.modeKey] = WakeVerbPreRoute.handsFreeValue

        let decision = try #require(wake.preRoute("type hello world", context: ctx))
        #expect(decision.route == .dictate)
        #expect(decision.routeSource == .rules)

        let stage = WakeVerbStage(preRoute: wake)
        let spans = ["type", "hello", "world"].enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: 0.9, audioRange: Double(i) * 0.2...Double(i + 1) * 0.2)
        }
        let out = try await stage.process(spans, context: ctx)
        #expect(out.joinedText.trimmingCharacters(in: .whitespaces) == "hello world", "wake verb is stripped from the landed text")

        // Not in hands-free → the grammar stays out of the way.
        #expect(wake.preRoute("type hello world", context: StageContext()) == nil)
    }

    // MARK: Meeting capture (P5.5)

    final class ScriptedMeetingTranscriber: MeetingTranscriber, @unchecked Sendable {
        func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] {
            let text = chunk.samples.first == 1 ? "we decided to ship on friday" : "sounds good I will send the notes"
            return [TranscriptSpan(text: text, confidence: 0.9, audioRange: chunk.range)]
        }
    }

    @Test func meetingDetectorFlowProducesDiarizedNotesFullyLocally() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("p5-meetings-\(UUID())")
        let coordinator = MeetingCoordinator(store: MeetingStore(root: root))
        let store = coordinator.store
        coordinator.makeSession = { prompt in
            MeetingSession(title: prompt.title, transcriber: ScriptedMeetingTranscriber(),
                           labeler: ChannelLabeler(), store: store)
        }
        var prompts: [MeetingPrompt?] = []
        coordinator.onPrompt = { prompts.append($0) }
        var recording: [Bool] = []
        coordinator.onRecordingChanged = { recording.append($0) }
        var notified: MeetingRecord?
        coordinator.onNotes = { notified = $0 }
        var opened: [URL] = []
        coordinator.openURL = { opened.append($0) }

        // Camera comes on + a live calendar event → one prompt, reason both, Join&Record offered.
        let event = CalendarMeeting(id: "e1", title: "Design sync", start: Date(), end: Date().addingTimeInterval(1800),
                                    meetingURL: URL(string: "https://meet.example.com/abc"))
        coordinator.apply(.calendar([event]))
        coordinator.apply(.cameraStarted)
        let prompt = try #require(prompts.compactMap { $0 }.last)
        #expect(prompt.choices.contains(.joinAndRecord))
        #expect(prompt.choices.contains(.record))
        #expect(prompt.choices.contains(.ignore))

        // User picks Record → session starts, no browser join.
        coordinator.choose(.record)
        #expect(recording.last == true)
        #expect(opened.isEmpty)
        #expect(coordinator.session != nil)

        // Mic ("You") and system ("Others") chunks arrive.
        let mic = MeetingChunk(channel: .mic, chunk: AudioChunk(samples: [1, 0, 0], range: 0...3, reason: .speechEnd))
        let sys = MeetingChunk(channel: .system, chunk: AudioChunk(samples: [0.5, 0, 0], range: 3.5...6, reason: .speechEnd))
        await coordinator.ingest([mic, sys])

        let record = try #require(await coordinator.finishSession())
        #expect(notified?.id == record.id, "notes arrive as a notification after the call")
        let speakers = Set(record.transcript.utterances.map(\.speaker.label))
        #expect(speakers.contains("You"))
        #expect(speakers.contains { $0.hasPrefix("Others") })
        let notes = try #require(record.notes)
        #expect(!notes.summary.isEmpty)
        #expect(notes.provider == "extractive-local", "notes are produced locally")
        // Persisted to the store, loadable.
        #expect(try store.load(id: record.id).transcript.utterances.count == 2)
    }

    @Test func joinAndRecordOpensTheMeetingURL() throws {
        let coordinator = MeetingCoordinator(store: MeetingStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("p5-meetings-\(UUID())")))
        coordinator.makeSession = { _ in nil }
        var opened: [URL] = []
        coordinator.openURL = { opened.append($0) }
        let event = CalendarMeeting(id: "e2", title: "Standup", start: Date(), end: Date().addingTimeInterval(900),
                                    meetingURL: URL(string: "https://meet.example.com/standup"))
        coordinator.apply(.calendar([event]))
        coordinator.apply(.cameraStarted)
        coordinator.choose(.joinAndRecord)
        #expect(opened == [URL(string: "https://meet.example.com/standup")!])
    }
}
