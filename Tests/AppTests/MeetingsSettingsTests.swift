import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

// V5 M-d — Settings › Meetings: defaults, round-trips, the page model, the wiring that feeds the
// detector, and post-meeting processing (auto-export + hook with a fake script).

@MainActor
@Suite("M-d Meetings settings", .serialized)
struct MeetingsSettingsTests {
    @Test func defaults() {
        let store = InMemorySettingsStore()
        let p = MeetingSettings.policy(store)
        #expect(p == MeetingDetectionPolicy())
        #expect(p.notifications && !p.autoRecordCalendarMeetings && p.reminder == .atStart && p.includedCalendarIDs == nil)
        #expect(MeetingSettings.saveRecording(store) == .always)
        #expect(MeetingSettings.autoExport(store) == nil && MeetingSettings.hook(store) == nil)
        #expect(MeetingSettings.policy(nil) == MeetingDetectionPolicy())
    }

    @Test func roundTrips() {
        let store = InMemorySettingsStore()
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: MeetingSettings.didChangeNotification, object: nil, queue: nil) { _ in posts += 1 }
        defer { center.removeObserver(token) }
        let policy = MeetingDetectionPolicy(notifications: false, mutedApps: ["us.zoom.xos"], reminder: .fiveMinutesBefore,
                                            includedCalendarIDs: ["a", "b"], autoRecordCalendarMeetings: true)
        MeetingSettings.setPolicy(policy, store: store, center: center)
        #expect(MeetingSettings.policy(store) == policy)
        MeetingSettings.setSaveRecording(.sevenDays, store: store, center: center)
        #expect(MeetingSettings.saveRecording(store) == .sevenDays && MeetingRecordingSaveMode.sevenDays.retentionDays == 7)
        MeetingSettings.setAutoExport(MeetingAutoExport(folder: URL(fileURLWithPath: "/tmp/exports"), format: .json), store: store, center: center)
        #expect(MeetingSettings.autoExport(store) == MeetingAutoExport(folder: URL(fileURLWithPath: "/tmp/exports", isDirectory: true), format: .json))
        MeetingSettings.setHook(PostMeetingHookConfig(path: "/usr/local/bin/hook", timeout: 5000), store: store, center: center)
        #expect(MeetingSettings.hook(store) == PostMeetingHookConfig(path: "/usr/local/bin/hook", timeout: 600))   // clamped
        MeetingSettings.setHook(nil, store: store, center: center)
        MeetingSettings.setAutoExport(nil, store: store, center: center)
        #expect(MeetingSettings.hook(store) == nil && MeetingSettings.autoExport(store) == nil)
        #expect(posts == 6)
    }

    @Test func pageModelEditsPersist() {
        let store = InMemorySettingsStore()
        let cals = [MeetingCalendarInfo(id: "work", title: "Work"), MeetingCalendarInfo(id: "home", title: "Home")]
        let model = MeetingsSettingsModel(settings: store, calendars: cals, center: NotificationCenter())
        model.setMuted("com.microsoft.teams2", true)                              // both Teams bundle ids
        #expect(MeetingSettings.policy(store).mutedApps == ["com.microsoft.teams2", "com.microsoft.teams"])
        model.setMuted("com.microsoft.teams", false)
        #expect(MeetingSettings.policy(store).mutedApps.isEmpty)
        model.setIncluded("home", false)
        #expect(MeetingSettings.policy(store).includedCalendarIDs == ["work"] && !model.isIncluded("home"))
        model.setIncluded("home", true)
        #expect(MeetingSettings.policy(store).includedCalendarIDs == nil)          // all ticked = all
        model.setReminder(.fiveMinutesBefore); model.setAutoRecord(true); model.setNotifications(false)
        let p = MeetingSettings.policy(store)
        #expect(p.reminder == .fiveMinutesBefore && p.autoRecordCalendarMeetings && !p.notifications)
        model.setSaveRecording(.never)
        #expect(MeetingSettings.saveRecording(store) == .never)
        model.setExport(folder: "/tmp/m", format: .json)
        #expect(MeetingSettings.autoExport(store)?.format == .json)
        model.setHook(path: "  ", timeout: 10)
        #expect(MeetingSettings.hook(store) == nil)
    }

    @Test func wiringSendsPolicyAndFollowsChanges() {
        let store = InMemorySettingsStore()
        let center = NotificationCenter()
        MeetingSettings.setPolicy(MeetingDetectionPolicy(reminder: .fiveMinutesBefore), store: store, center: center)
        let coordinator = MeetingCoordinator(settings: store)
        let source = FakeSource()
        MeetingDetectionWiring.install(coordinator: coordinator, settings: store,
                                       sources: MeetingSignalSources(sources: [source]), center: center)
        #expect(coordinator.detector.policy.reminder == .fiveMinutesBefore && coordinator.detector.leadTime == 300)
        MeetingSettings.setPolicy(MeetingDetectionPolicy(mutedApps: ["us.zoom.xos"]), store: store, center: center)
        #expect(coordinator.detector.policy.mutedApps == ["us.zoom.xos"])
        // Capture off → sources never start (no monitoring without the opt-in).
        coordinator.startMonitoring()
        #expect(source.started == 0)
        store.set(true, for: SettingsKeys.meetingCaptureEnabled)
        coordinator.startMonitoring()
        #expect(source.started == 1)
        source.emit?(.callApps([CallAppCatalog.app(for: "com.apple.FaceTime")!]))
        source.emit?(.micInUseElsewhere(true))
        if case .prompted(let p) = coordinator.detector.state { #expect(p.reason == .callApp) } else { Issue.record("no prompt") }
        coordinator.stopMonitoring()
        #expect(source.stopped == 1)
    }

    @Test func postProcessingExportsThenRunsHookWithExportPath() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("md-post-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let got = dir.appendingPathComponent("stdin.json")
        let hook = dir.appendingPathComponent("hook.sh")
        try "#!/bin/sh\ncat > \"\(got.path)\"\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let store = InMemorySettingsStore()
        let center = NotificationCenter()
        MeetingSettings.setAutoExport(MeetingAutoExport(folder: dir.appendingPathComponent("out")), store: store, center: center)
        MeetingSettings.setHook(PostMeetingHookConfig(path: hook.path, timeout: 10), store: store, center: center)
        let record = MeetingRecord(id: "r1", title: "Retro", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let outcome = await MeetingPostProcessing.run(record, settings: store)
        let exported = try #require(outcome.exported)
        #expect(FileManager.default.fileExists(atPath: exported.path) && outcome.hook == .finished(status: 0))
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let payload = try d.decode(PostMeetingHookPayload.self, from: Data(contentsOf: got))
        #expect(payload.exportedFile == exported.path && payload.record.id == "r1")
        // Nothing configured → nothing runs.
        let none = await MeetingPostProcessing.run(record, settings: InMemorySettingsStore())
        #expect(none == MeetingPostProcessing.Outcome())
    }
}

final class FakeSource: MeetingSignalSource {
    var started = 0, stopped = 0
    var emit: ((MeetingSignal) -> Void)?
    func start(emit: @escaping (MeetingSignal) -> Void) { started += 1; self.emit = emit }
    func stop() { stopped += 1 }
    func refresh() {}
}
