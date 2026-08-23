import Foundation
import Testing
@testable import Engine
@testable import Shared

// MARK: - Watchdog

final class MockHeartbeatSource: HeartbeatSource, @unchecked Sendable {
    var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    let device: AudioDeviceInfo?
    var lastDelivery: Date?
    var starts = 0, stops = 0
    var failStart = false
    init(name: String) { device = AudioDeviceInfo(id: 0, uid: name, name: name, transport: .virtual, sampleRate: 16_000, inputChannels: 1) }
    func prewarm() throws {}
    func start() throws { if failStart { throw AudioCaptureError.noInputDevice }; starts += 1 }
    func stop() { stops += 1 }
    func switchDevice(to device: AudioDeviceInfo?) throws {}
    func beat(at t: Date) {
        lastDelivery = t
        let s: [Float] = [0, 0]
        s.withUnsafeBufferPointer { sink?($0) }
    }
}

@Suite struct CaptureWatchdogTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func policyRestartsThenFallsBack() {
        var wd = CaptureWatchdog(staleAfter: 5, maxRestarts: 2, startupGrace: 3)
        wd.started(at: t0)
        #expect(wd.evaluate(lastDelivery: nil, now: t0 + 4) == .none)           // grace
        #expect(wd.evaluate(lastDelivery: t0 + 1, now: t0 + 5) == .none)        // heartbeat fresh
        #expect(wd.evaluate(lastDelivery: t0 + 1, now: t0 + 7) == .restart)     // stale > 5 s
        #expect(wd.restarts == 1)
        #expect(wd.evaluate(lastDelivery: t0 + 1, now: t0 + 8) == .none)        // new grace after restart
        #expect(wd.evaluate(lastDelivery: t0 + 1, now: t0 + 13) == .restart)
        #expect(wd.evaluate(lastDelivery: t0 + 1, now: t0 + 19) == .fallback)
        #expect(wd.fellBack)
        #expect(wd.evaluate(lastDelivery: t0 + 1, now: t0 + 30) == .none)       // terminal
    }

    @Test func heartbeatResetsRestartCount() {
        var wd = CaptureWatchdog(staleAfter: 5, maxRestarts: 1, startupGrace: 1)
        wd.started(at: t0)
        #expect(wd.evaluate(lastDelivery: nil, now: t0 + 6) == .restart)
        #expect(wd.evaluate(lastDelivery: t0 + 7, now: t0 + 8) == .none)        // recovered
        #expect(wd.restarts == 0)
        #expect(wd.evaluate(lastDelivery: t0 + 7, now: t0 + 14) == .restart)    // counts from zero again
    }

    @Test func recorderRestartsPrimaryThenFallsBackToSCK() throws {
        let primary = MockHeartbeatSource(name: "tap"), fallback = MockHeartbeatSource(name: "sck")
        final class Clock: @unchecked Sendable { var now: Date; init(_ d: Date) { now = d } }
        let clock = Clock(t0)
        let rec = SystemAudioRecorder(primary: primary, fallback: fallback, watchdog: CaptureWatchdog(staleAfter: 5, maxRestarts: 1, startupGrace: 1), tickInterval: 0, clock: { clock.now })
        var stages: [SystemAudioRecorder.Stage] = []
        rec.onStageChanged = { stages.append($0) }
        var delivered = 0
        rec.sink = { delivered += $0.count }
        try rec.start()
        #expect(rec.stage == .primary && primary.starts == 1)
        primary.beat(at: t0 + 1)
        #expect(delivered == 2)                                   // sink is wired through to the active source
        clock.now = t0 + 3; rec.tick()
        #expect(primary.starts == 1)                              // fresh heartbeat: nothing
        clock.now = t0 + 8; rec.tick()                            // stale → restart
        #expect(primary.starts == 2 && primary.stops == 1 && rec.stage == .primary)
        clock.now = t0 + 15; rec.tick()                           // still silent → fallback
        #expect(rec.stage == .fallback && fallback.starts == 1 && primary.stops == 2)
        #expect(rec.device?.uid == "sck")
        fallback.beat(at: t0 + 16)
        #expect(delivered == 4)
        clock.now = t0 + 30; rec.tick()                           // fallback silent → restart fallback, never back to tap
        #expect(fallback.starts == 2 && primary.starts == 2)
        rec.stop()
        #expect(stages == [.primary, .fallback, .idle])
    }

    @Test func recorderUsesFallbackWhenPrimaryCannotStart() throws {
        let primary = MockHeartbeatSource(name: "tap"); primary.failStart = true
        let fallback = MockHeartbeatSource(name: "sck")
        let rec = SystemAudioRecorder(primary: primary, fallback: fallback, tickInterval: 0)
        try rec.start()
        #expect(rec.stage == .fallback && fallback.starts == 1)
        let none = SystemAudioRecorder(primary: nil, fallback: nil, tickInterval: 0)
        #expect(throws: AudioCaptureError.self) { try none.start() }
        #expect(none.stage == .failed)
    }
}

// MARK: - Notes

@Suite struct MeetingNotesTests {
    static let transcript = MeetingTranscript(utterances: [
        MeetingUtterance(speaker: .you, text: "Thanks for joining. Today we need to finalise the launch plan for the dictation beta.", range: 0...6, confidence: 0.9),
        MeetingUtterance(speaker: .others(1), text: "The launch plan depends on the signing identity. I will get the Developer ID sorted by Friday.", range: 6...12, confidence: 0.85),
        MeetingUtterance(speaker: .you, text: "Great. We agreed the beta ships with ad-hoc signing if that slips. Um, yeah.", range: 12...18, confidence: 0.9),
        MeetingUtterance(speaker: .others(1), text: "Okay. You should send the release notes to the testers tomorrow.", range: 18...22, confidence: 0.8),
    ])

    @Test func extractiveNotesAreDeterministic() async throws {
        let p = ExtractiveNotesProvider(maxSummary: 3)
        let a = try await p.notes(for: Self.transcript)
        let b = try await p.notes(for: Self.transcript)
        #expect(a == b)
        #expect(a.markdown == b.markdown)
        #expect(a.provider == "extractive-local")
        #expect(a.summary.count == 3)
        // Summary keeps transcript order and favours the "launch plan" sentences.
        #expect(a.summary.contains { $0.contains("launch plan") })
        let order = a.summary.compactMap { s in Self.transcript.plainText.range(of: s)?.lowerBound }
        #expect(order == order.sorted())
    }

    @Test func actionItemsAndDecisionsByCue() async throws {
        let n = try await ExtractiveNotesProvider().notes(for: Self.transcript)
        #expect(n.decisions == ["We agreed the beta ships with ad-hoc signing if that slips."])
        #expect(n.actionItems.contains("Others: I will get the Developer ID sorted by Friday."))
        #expect(n.actionItems.contains("Others: You should send the release notes to the testers tomorrow."))
        #expect(n.actionItems.contains { $0.contains("need to finalise") })
        #expect(n.markdown.contains("- [ ] Others: I will get the Developer ID sorted by Friday."))
        let empty = try await ExtractiveNotesProvider().notes(for: MeetingTranscript())
        #expect(empty.summary.isEmpty && empty.markdown.contains("nothing captured"))
    }
}

// MARK: - Detector state machine

@Suite struct MeetingDetectorTests {
    let t0 = Date(timeIntervalSince1970: 10_000)
    var standup: CalendarMeeting { CalendarMeeting(id: "e1", title: "Standup", start: t0 + 600, end: t0 + 1_500, meetingURL: URL(string: "https://zoom.us/j/123")) }
    var noLink: CalendarMeeting { CalendarMeeting(id: "e2", title: "1:1", start: t0 + 600, end: t0 + 1_500) }

    @Test func calendarPromptsOncePerEventWithJoinWhenLinked() {
        var d = MeetingDetector(leadTime: 120, endGrace: 60)
        #expect(d.apply(.calendar([standup]), at: t0) == [])                    // too early
        let fx = d.apply(.tick, at: t0 + 500)                                     // inside lead window
        guard case .showPrompt(let p)? = fx.first else { Issue.record("no prompt"); return }
        #expect(p.reason == .calendar && p.choices == [.joinAndRecord, .record, .ignore] && p.event?.id == "e1")
        #expect(d.apply(.tick, at: t0 + 501) == [])                               // no re-prompt
        let start = d.apply(.userChose(.joinAndRecord), at: t0 + 502)
        #expect(start == [.dismissPrompt, .startRecording(p, join: URL(string: "https://zoom.us/j/123"))])
        #expect(d.apply(.tick, at: t0 + 1_400) == [])                             // event live
        #expect(d.apply(.tick, at: t0 + 1_520) == [])                             // ended, in grace
        #expect(d.apply(.tick, at: t0 + 1_600) == [.stopRecording])               // grace elapsed
        #expect(d.state == .idle)
        #expect(d.apply(.tick, at: t0 + 1_601) == [])                             // never prompts the same event again
    }

    @Test func cameraPromptsWithoutLinkAndStopsWhenCameraStops() {
        var d = MeetingDetector()
        let fx = d.apply(.cameraStarted, at: t0)
        guard case .showPrompt(let p)? = fx.first else { Issue.record("no prompt"); return }
        #expect(p.reason == .camera && p.choices == [.record, .ignore] && p.event == nil)
        #expect(d.apply(.userChose(.record), at: t0 + 1) == [.dismissPrompt, .startRecording(p, join: nil)])
        #expect(d.apply(.cameraStopped, at: t0 + 900) == [.stopRecording])        // camera-only: immediate
        #expect(d.apply(.recordingStopped, at: t0 + 901) == [])
        #expect(d.apply(.cameraStarted, at: t0 + 2_000).count == 1)               // new camera session → new prompt
    }

    @Test func ignoreIsStickyAndPromptAutoDismisses() {
        var d = MeetingDetector()
        _ = d.apply(.cameraStarted, at: t0)
        #expect(d.apply(.userChose(.ignore), at: t0 + 1) == [.dismissPrompt])
        #expect(d.apply(.tick, at: t0 + 60) == [])
        if case .ignored = d.state {} else { Issue.record("expected ignored") }
        _ = d.apply(.cameraStopped, at: t0 + 100)
        #expect(d.state == .idle)
        // Unanswered prompt disappears when the camera goes away.
        _ = d.apply(.cameraStarted, at: t0 + 200)
        #expect(d.apply(.cameraStopped, at: t0 + 210) == [.dismissPrompt])
        #expect(d.state == .idle)
        // Calendar ignore lasts until the event ends.
        _ = d.apply(.calendar([noLink]), at: t0 + 550)
        _ = d.apply(.userChose(.ignore), at: t0 + 551)
        _ = d.apply(.tick, at: t0 + 1_000)
        if case .ignored = d.state {} else { Issue.record("still ignored during event") }
        _ = d.apply(.tick, at: t0 + 1_600)
        #expect(d.state == .idle)
    }

    @Test func cameraDuringEventMergesIntoOnePrompt() {
        var d = MeetingDetector()
        _ = d.apply(.calendar([standup]), at: t0)
        _ = d.apply(.cameraStarted, at: t0 + 300)                                 // before lead window → camera prompt w/o event
        guard case .prompted(let p1) = d.state else { Issue.record("no prompt"); return }
        #expect(p1.reason == .camera)
        _ = d.apply(.userChose(.record), at: t0 + 301)
        // Camera stops while the event is live: keep recording (event still on).
        #expect(d.apply(.cameraStopped, at: t0 + 700) == [])
        _ = d.apply(.recordingStopped, at: t0 + 701)
        // Later the event prompt fires with "both" when the camera is back.
        _ = d.apply(.cameraStarted, at: t0 + 800)
        guard case .prompted(let p2) = d.state else { Issue.record("no event prompt"); return }
        #expect(p2.reason == .both && p2.event?.id == "e1")
    }

    @Test func meetingLinkDetection() {
        #expect(EventKitCalendarSignal.firstLink(in: "Join: https://meet.google.com/abc-defg-hij see you")?.host == "meet.google.com")
        #expect(EventKitCalendarSignal.firstLink(in: "Agenda at https://example.com/doc") == nil)
    }
}

// MARK: - Session + store

@Suite struct MeetingSessionTests {
    struct FakeASR: MeetingTranscriber {
        func transcribe(_ chunk: AudioChunk) async throws -> [TranscriptSpan] {
            let level = chunk.samples.first ?? 0
            return [TranscriptSpan(text: level > 0 ? "hello from mic" : "hello from system", confidence: 0.9, audioRange: 0...chunk.duration)]
        }
    }

    @Test func sessionBuildsDiarizedTranscriptAndPersists() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-meeting-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root)
        let session = MeetingSession(title: "Test call", transcriber: FakeASR(), labeler: ChannelLabeler(), store: store)
        func chunk(_ ch: MeetingChannel, _ level: Float, _ t: TimeInterval) -> MeetingChunk {
            MeetingChunk(channel: ch, chunk: AudioChunk(samples: [Float](repeating: level, count: 16_000 * 3), range: t...(t + 3), reason: .speechEnd))
        }
        try await session.ingest([chunk(.mic, 0.1, 0), chunk(.mic, 0.1, 3), chunk(.system, -0.1, 7), chunk(.mic, 0.1, 12)])
        let rec = try await session.finish(at: Date())
        #expect(rec.transcript.utterances.map(\.speaker) == [.you, .others(1), .you])      // contiguous same-speaker merged
        #expect(rec.transcript.utterances[0].text == "hello from mic hello from mic")
        #expect(rec.transcript.utterances[0].range == 0...6)
        #expect(rec.notes != nil && rec.endedAt != nil && rec.labeler == "channel")
        let loaded = try store.load(id: rec.id)
        #expect(loaded.id == rec.id && loaded.transcript == rec.transcript && loaded.notes == rec.notes && loaded.title == rec.title)
        #expect(abs(loaded.startedAt.timeIntervalSince(rec.startedAt)) < 1)   // ISO8601 is whole seconds
        #expect(store.list().map(\.id) == [rec.id])
        let md = try String(contentsOf: store.directory(for: rec.id).appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(md.contains("# Test call") && md.contains("**Others** [00:07] hello from system") && md.contains("## Transcript"))
        #expect(rec.markdown == md)
        try store.delete(id: rec.id)
        #expect(store.list().isEmpty)
    }

    @Test func defaultStoreLivesUnderAppPaths() {
        #expect(MeetingStore().root.path.hasPrefix(AppPaths.supportDirectory().path))
        #expect(MeetingStore().root.lastPathComponent == "Meetings")
    }
}
