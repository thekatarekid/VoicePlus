import Foundation
import Testing
@testable import Engine

// V5 M-d — the detector state machine with the new signals (mic in use elsewhere, call apps,
// browser meeting tab, policy), the browser classifier, auto-export and the post-meeting hook with a
// fake script. Live readers (CoreAudio process list, NSWorkspace, AX) are not exercised → T1.

@Suite("M-d detection signals")
struct MeetingDetectionSignalsTests {
    let t0 = Date(timeIntervalSince1970: 20_000)
    let zoom = CallAppCatalog.app(for: "us.zoom.xos")!
    let slack = CallAppCatalog.app(for: "com.tinyspeck.slackmacgap")!
    var meetTab: BrowserMeetingTab {
        BrowserMeetingClassifier.classify(browserBundleID: "com.google.Chrome",
                                          url: URL(string: "https://meet.google.com/abc-defg-hij"), title: "Meet - abc-defg-hij")!
    }

    @Test func callAppAloneIsNotAMeetingMicPlusCallAppIs() {
        var d = MeetingDetector()
        #expect(d.apply(.callApps([slack]), at: t0) == [])                       // Slack runs all day
        #expect(d.apply(.micInUseElsewhere(true), at: t0 + 1).count == 1)
        guard case .prompted(let p) = d.state else { Issue.record("no prompt"); return }
        #expect(p.reason == .callApp && p.title == "Slack huddle" && p.source?.bundleID == slack.bundleID)
        #expect(p.choices == [.record, .ignore])
        // Mic released before the user answered → prompt goes away.
        #expect(d.apply(.micInUseElsewhere(false), at: t0 + 5) == [.dismissPrompt])
    }

    @Test func micAloneIsNotAMeeting() {
        var d = MeetingDetector()
        #expect(d.apply(.micInUseElsewhere(true), at: t0) == [])
        #expect(d.state == .idle)
    }

    @Test func browserMeetingTabWithMicPromptsAndRecordingStopsWhenMicStops() {
        var d = MeetingDetector()
        #expect(d.apply(.browserMeeting(meetTab), at: t0) == [])                  // tab open, not talking yet
        let fx = d.apply(.micInUseElsewhere(true), at: t0 + 2)
        guard case .showPrompt(let p)? = fx.first else { Issue.record("no prompt"); return }
        #expect(p.reason == .browser && p.title == "Google Meet call" && p.id.hasPrefix("browser:"))
        #expect(d.apply(.userChose(.record), at: t0 + 3) == [.dismissPrompt, .startRecording(p, join: nil)])
        #expect(d.apply(.tick, at: t0 + 600) == [])
        #expect(d.apply(.micInUseElsewhere(false), at: t0 + 900) == [.stopRecording])
        #expect(d.apply(.recordingStopped, at: t0 + 901) == [])
    }

    @Test func browserTabIsPreferredOverARunningCallApp() {
        var d = MeetingDetector()
        _ = d.apply(.callApps([slack]), at: t0)
        _ = d.apply(.browserMeeting(meetTab), at: t0)
        _ = d.apply(.micInUseElsewhere(true), at: t0)
        guard case .prompted(let p) = d.state else { Issue.record("no prompt"); return }
        #expect(p.reason == .browser && p.source?.bundleID == "com.google.Chrome")
    }

    @Test func oneSessionOnePromptAcrossSignalChanges() {
        var d = MeetingDetector()
        _ = d.apply(.callApps([zoom]), at: t0)
        _ = d.apply(.micInUseElsewhere(true), at: t0)
        #expect(d.apply(.userChose(.ignore), at: t0 + 1) == [.dismissPrompt])
        // Camera joins the same call: still ignored, no second prompt.
        #expect(d.apply(.cameraStarted, at: t0 + 10) == [])
        #expect(d.apply(.cameraStopped, at: t0 + 20) == [])
        if case .ignored = d.state {} else { Issue.record("ignore should be sticky while the call goes on") }
        // Call ends → next call prompts again.
        _ = d.apply(.micInUseElsewhere(false), at: t0 + 30)
        #expect(d.state == .idle)
        #expect(d.apply(.micInUseElsewhere(true), at: t0 + 100).count == 1)
    }

    @Test func mutedAppNeverPromptsButOthersDo() {
        var d = MeetingDetector()
        _ = d.apply(.policy(MeetingDetectionPolicy(mutedApps: [slack.bundleID])), at: t0)
        _ = d.apply(.callApps([slack]), at: t0)
        #expect(d.apply(.micInUseElsewhere(true), at: t0) == [])
        #expect(d.apply(.cameraStarted, at: t0 + 1) == [])                       // camera attributed to muted Slack
        // Zoom launches: not muted → prompt attributed to Zoom.
        let fx = d.apply(.callApps([zoom, slack]), at: t0 + 2)
        guard case .showPrompt(let p)? = fx.first else { Issue.record("no prompt"); return }
        #expect(p.source?.bundleID == zoom.bundleID && p.reason == .camera)
    }

    @Test func notificationsOffSuppressesPromptsCalendarAutoRecordStillRuns() {
        let ev = CalendarMeeting(id: "e1", title: "Planning", start: t0 + 300, end: t0 + 1_200, calendarID: "work")
        var d = MeetingDetector(policy: MeetingDetectionPolicy(notifications: false))
        _ = d.apply(.calendar([ev]), at: t0)
        _ = d.apply(.callApps([zoom]), at: t0)
        #expect(d.apply(.micInUseElsewhere(true), at: t0 + 10) == [])
        #expect(d.apply(.tick, at: t0 + 300) == [])                               // event live, no prompt
        var auto = MeetingDetector(policy: MeetingDetectionPolicy(notifications: false, autoRecordCalendarMeetings: true))
        _ = auto.apply(.calendar([ev]), at: t0)
        let fx = auto.apply(.tick, at: t0 + 300)
        guard case .startRecording(let p, nil)? = fx.first else { Issue.record("no auto-record"); return }
        #expect(p.event?.id == "e1" && fx.count == 1)
        if case .recording = auto.state {} else { Issue.record("expected recording") }
    }

    @Test func reminderTimingSetsLeadAndCalendarFilterApplies() {
        let work = CalendarMeeting(id: "w", title: "Work sync", start: t0 + 300, end: t0 + 900, calendarID: "work")
        let home = CalendarMeeting(id: "h", title: "Dentist", start: t0 + 300, end: t0 + 900, calendarID: "home")
        var d = MeetingDetector(policy: MeetingDetectionPolicy(reminder: .atStart, includedCalendarIDs: ["work"]))
        #expect(d.leadTime == 0)
        _ = d.apply(.calendar([home, work]), at: t0)
        #expect(d.events.map(\.id) == ["w"])
        #expect(d.apply(.tick, at: t0 + 299) == [])                               // at start, not before
        guard case .showPrompt(let p)? = d.apply(.tick, at: t0 + 300).first else { Issue.record("no prompt"); return }
        #expect(p.event?.id == "w")
        var early = MeetingDetector()
        _ = early.apply(.policy(MeetingDetectionPolicy(reminder: .fiveMinutesBefore)), at: t0)
        #expect(early.leadTime == 300)
        #expect(early.apply(.calendar([home]), at: t0 - 1) == [])                 // 5 min 1 s before
        #expect(early.apply(.tick, at: t0).count == 1)                            // 5 min before
        // Re-filtering on a policy change keeps the stored list.
        _ = early.apply(.policy(MeetingDetectionPolicy(includedCalendarIDs: ["work"])), at: t0 + 2)
        #expect(early.events.isEmpty)
    }

    @Test func classifierRecognisesMeetingPagesOnly() {
        func svc(_ u: String, _ t: String? = nil) -> String? { BrowserMeetingClassifier.service(url: URL(string: u), title: t) }
        #expect(svc("https://meet.google.com/abc-defg-hij?authuser=0") == "Google Meet")
        #expect(svc("https://meet.google.com/") == nil)
        #expect(svc("https://app.zoom.us/wc/123456/join") == "Zoom")
        #expect(svc("https://us02web.zoom.us/j/8812345") == "Zoom")
        #expect(svc("https://zoom.us/pricing") == nil)
        #expect(svc("https://teams.microsoft.com/l/meetup-join/19%3ameeting") == "Microsoft Teams")
        #expect(svc("https://whereby.com/team-room") == "Whereby")
        #expect(svc("https://example.com/meet") == nil)
        #expect(BrowserMeetingClassifier.service(url: nil, title: "Meet – abc-defg-hij") == "Google Meet")
        #expect(BrowserMeetingClassifier.service(url: nil, title: "Zoom Meeting") == "Zoom")
        #expect(BrowserMeetingClassifier.service(url: nil, title: "Inbox (3) - Gmail") == nil)
        #expect(CallAppCatalog.running(in: ["com.apple.Safari", "us.zoom.xos", "com.apple.FaceTime"]).map(\.name) == ["Zoom", "FaceTime"])
    }

    @Test func calendarMeetingDecodesWithoutCalendarID() throws {
        let old = #"{"id":"e","title":"T","start":0,"end":60}"#
        let m = try JSONDecoder().decode(CalendarMeeting.self, from: Data(old.utf8))
        #expect(m.calendarID == nil)
    }
}

@Suite("M-d post-meeting hook + auto-export", .serialized)
struct PostMeetingHookTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("md-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func script(_ body: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("hook.sh")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    var record: MeetingRecord {
        MeetingRecord(id: "m1", title: "Design review: Q4/plan", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      endedAt: Date(timeIntervalSince1970: 1_700_001_800))
    }

    @Test func hookReceivesJSONRecordOnStdin() async throws {
        let dir = try tempDir()
        let out = dir.appendingPathComponent("got.json")
        let hook = try script("cat > \"\(out.path)\"\nexit 0\n", in: dir)
        let result = await PostMeetingHook.run(PostMeetingHookConfig(path: hook.path, timeout: 10),
                                               payload: PostMeetingHookPayload(record: record, exportedFile: URL(fileURLWithPath: "/tmp/x.md")))
        #expect(result == .finished(status: 0))
        let data = try Data(contentsOf: out)
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let payload = try d.decode(PostMeetingHookPayload.self, from: data)
        #expect(payload.schema == "voiceplus.meeting/1" && payload.record.id == "m1" && payload.exportedFile == "/tmp/x.md")
        #expect(payload.markdown.hasPrefix("# Design review"))
    }

    @Test func hookExitStatusTimeoutAndNonExecutable() async throws {
        let dir = try tempDir()
        let failing = try script("exit 3\n", in: dir)
        #expect(await PostMeetingHook.run(PostMeetingHookConfig(path: failing.path), payload: .init(record: record)) == .finished(status: 3))
        let slow = try script("sleep 30\n", in: dir)
        let started = Date()
        #expect(await PostMeetingHook.run(PostMeetingHookConfig(path: slow.path, timeout: 1), payload: .init(record: record)) == .timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        let plain = dir.appendingPathComponent("plain.txt")
        try "x".write(to: plain, atomically: true, encoding: .utf8)
        #expect(await PostMeetingHook.run(PostMeetingHookConfig(path: plain.path), payload: .init(record: record)) == .notExecutable(plain.path))
    }

    @Test func hookThatIgnoresStdinDoesNotCrashUs() async throws {
        let dir = try tempDir()
        let quick = try script("exit 0\n", in: dir)
        var big = record
        big.title = String(repeating: "long ", count: 40_000)                   // > pipe buffer
        #expect(await PostMeetingHook.run(PostMeetingHookConfig(path: quick.path), payload: .init(record: big)) == .finished(status: 0))
    }

    @Test func autoExportWritesMarkdownOrJSONWithoutOverwriting() throws {
        let dir = try tempDir()
        let md = try MeetingAutoExporter.export(record, to: MeetingAutoExport(folder: dir, format: .markdown))
        #expect(md.pathExtension == "md" && !md.lastPathComponent.contains("/"))
        #expect(md.lastPathComponent.contains("Design review  Q4 plan") || md.lastPathComponent.contains("Design review"))
        #expect(try String(contentsOf: md, encoding: .utf8).hasPrefix("# Design review"))
        let again = try MeetingAutoExporter.export(record, to: MeetingAutoExport(folder: dir, format: .markdown))
        #expect(again != md && again.lastPathComponent.hasSuffix(" 2.md"))
        let json = try MeetingAutoExporter.export(record, to: MeetingAutoExport(folder: dir, format: .json))
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        #expect(try d.decode(MeetingRecord.self, from: Data(contentsOf: json)).id == "m1")
    }
}
