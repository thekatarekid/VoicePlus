import Engine
import Shared
import Foundation

// V5 M-d — Settings › Meetings: keys, defaults and parsing in one place, plus the wiring that feeds
// the detector its policy and the new live signals, and runs auto-export + the post-meeting hook.
// `SettingsStore` carries strings and booleans only: sets are stored as JSON arrays of strings.

public extension SettingsKeys {
    /// Bool, default ON — show the notch prompt for detected and calendar meetings.
    static let meetingNotifications = "meeting.detect.notifications"
    /// JSON array of bundle ids that never prompt.
    static let meetingMutedApps = "meeting.detect.mutedApps"
    /// `atStart` (default) | `fiveMinutesBefore`.
    static let meetingReminder = "meeting.detect.reminder"
    /// JSON array of EventKit calendar ids; absent = every calendar.
    static let meetingCalendars = "meeting.detect.calendars"
    /// Bool, default OFF — a live calendar event starts recording with no prompt.
    static let meetingAutoRecordCalendar = "meeting.detect.autoRecordCalendar"
    /// `always` (default) | `sevenDays` | `never` — read by the meeting files store (M5).
    static let meetingSaveRecording = "meeting.recording.save"
    /// Absolute folder path; absent = no auto-export.
    static let meetingExportFolder = "meeting.export.folder"
    /// `markdown` (default) | `json`.
    static let meetingExportFormat = "meeting.export.format"
    /// Absolute path of an executable; absent = no hook.
    static let meetingHookPath = "meeting.hook.path"
    /// Decimal seconds, default 30, 1…600.
    static let meetingHookTimeout = "meeting.hook.timeout"
}

/// "Save meeting recording" (M5): Always by default.
public enum MeetingRecordingSaveMode: String, CaseIterable, Sendable {
    case always, sevenDays, never
    public var label: String {
        switch self { case .always: return "Always"; case .sevenDays: return "Keep 7 days"; case .never: return "Never" }
    }
    /// Days a recording is kept; nil = forever, 0 = not saved.
    public var retentionDays: Int? {
        switch self { case .always: return nil; case .sevenDays: return 7; case .never: return 0 }
    }
}

public enum MeetingSettings {
    /// Posted after any setter here wrote; the wiring re-sends the policy to the detector.
    public static let didChangeNotification = Notification.Name("VoicePlus.MeetingSettings.didChange")

    // MARK: Reads (defaults included)

    public static func policy(_ store: SettingsStore?) -> MeetingDetectionPolicy {
        MeetingDetectionPolicy(
            notifications: store?.bool(SettingsKeys.meetingNotifications) ?? true,
            mutedApps: Set(stringArray(store?.string(SettingsKeys.meetingMutedApps)) ?? []),
            reminder: store?.string(SettingsKeys.meetingReminder).flatMap(MeetingDetectionPolicy.Reminder.init(rawValue:)) ?? .atStart,
            includedCalendarIDs: stringArray(store?.string(SettingsKeys.meetingCalendars)).map(Set.init),
            autoRecordCalendarMeetings: store?.bool(SettingsKeys.meetingAutoRecordCalendar) ?? false)
    }

    public static func saveRecording(_ store: SettingsStore?) -> MeetingRecordingSaveMode {
        store?.string(SettingsKeys.meetingSaveRecording).flatMap(MeetingRecordingSaveMode.init(rawValue:)) ?? .always
    }

    public static func autoExport(_ store: SettingsStore?) -> MeetingAutoExport? {
        guard let path = nonBlank(store?.string(SettingsKeys.meetingExportFolder)) else { return nil }
        let format = store?.string(SettingsKeys.meetingExportFormat).flatMap(MeetingExportFormat.init(rawValue:)) ?? .markdown
        return MeetingAutoExport(folder: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true), format: format)
    }

    public static func hook(_ store: SettingsStore?) -> PostMeetingHookConfig? {
        guard let path = nonBlank(store?.string(SettingsKeys.meetingHookPath)) else { return nil }
        let timeout = store?.string(SettingsKeys.meetingHookTimeout).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return PostMeetingHookConfig(path: path, timeout: timeout.flatMap { $0.isFinite ? $0 : nil } ?? PostMeetingHookConfig.defaultTimeout)
    }

    // MARK: Writes

    public static func setPolicy(_ policy: MeetingDetectionPolicy, store: SettingsStore?, center: NotificationCenter = .default) {
        guard let store else { return }
        store.set(policy.notifications, for: SettingsKeys.meetingNotifications)
        store.set(json(policy.mutedApps.sorted()), for: SettingsKeys.meetingMutedApps)
        store.set(policy.reminder.rawValue, for: SettingsKeys.meetingReminder)
        store.set(policy.includedCalendarIDs.map { json($0.sorted()) }, for: SettingsKeys.meetingCalendars)
        store.set(policy.autoRecordCalendarMeetings, for: SettingsKeys.meetingAutoRecordCalendar)
        center.post(name: didChangeNotification, object: nil)
    }

    public static func setSaveRecording(_ mode: MeetingRecordingSaveMode, store: SettingsStore?, center: NotificationCenter = .default) {
        store?.set(mode.rawValue, for: SettingsKeys.meetingSaveRecording)
        center.post(name: didChangeNotification, object: nil)
    }

    public static func setAutoExport(_ export: MeetingAutoExport?, store: SettingsStore?, center: NotificationCenter = .default) {
        store?.set(export?.folder.path, for: SettingsKeys.meetingExportFolder)
        if let export { store?.set(export.format.rawValue, for: SettingsKeys.meetingExportFormat) }
        center.post(name: didChangeNotification, object: nil)
    }

    public static func setHook(_ hook: PostMeetingHookConfig?, store: SettingsStore?, center: NotificationCenter = .default) {
        store?.set(hook.flatMap { nonBlank($0.path) }, for: SettingsKeys.meetingHookPath)
        if let hook { store?.set(String(hook.timeout), for: SettingsKeys.meetingHookTimeout) }
        center.post(name: didChangeNotification, object: nil)
    }

    // MARK: Helpers

    static func stringArray(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    static func json(_ values: [String]) -> String {
        (try? String(data: JSONEncoder().encode(values), encoding: .utf8)) ?? "[]"
    }

    static func nonBlank(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// After a meeting: auto-export (if a folder is set), then the hook (if a path is set) with the
/// exported file's path in its payload. Failures are logged, never surfaced as errors to the call.
public enum MeetingPostProcessing {
    public struct Outcome: Equatable, Sendable {
        public var exported: URL?
        public var hook: PostMeetingHookResult?
    }

    public static func run(_ record: MeetingRecord, settings: SettingsStore?) async -> Outcome {
        var outcome = Outcome()
        if let export = MeetingSettings.autoExport(settings) {
            do { outcome.exported = try MeetingAutoExporter.export(record, to: export) } catch {
                Log.app.error("meeting auto-export failed: \(error)")
            }
        }
        if let hook = MeetingSettings.hook(settings) {
            let result = await PostMeetingHook.run(hook, payload: PostMeetingHookPayload(record: record, exportedFile: outcome.exported))
            Log.app.info("meeting post hook: \(String(describing: result))")
            outcome.hook = result
        }
        return outcome
    }
}

/// Connects Settings › Meetings to the coordinator: the policy now and on every change, the M-d
/// live sources started/stopped with monitoring, and post-meeting processing chained after notes.
public enum MeetingDetectionWiring {
    private static var observer: NSObjectProtocol?

    public static func install(coordinator: MeetingCoordinator, settings: SettingsStore?,
                               sources: MeetingSignalSources = MeetingSignalSources(),
                               ownCaptureActive: (() -> Bool)? = nil,
                               center: NotificationCenter = .default) {
        // Before macOS 14.2 the mic signal cannot tell our own capture from a call's; masking it
        // while our pipeline runs keeps dictation-with-Slack-open from looking like a huddle.
        if let ownCaptureActive {
            for case let mic as MicInUseMonitor in sources.sources { mic.ownCaptureActive = ownCaptureActive }
        }
        coordinator.apply(.policy(MeetingSettings.policy(settings)))
        if let observer { center.removeObserver(observer) }
        observer = center.addObserver(forName: MeetingSettings.didChangeNotification, object: nil, queue: nil) { [weak coordinator] _ in
            coordinator?.apply(.policy(MeetingSettings.policy(settings)))
        }
        coordinator.detectionSources = sources
        let previous = coordinator.onNotes
        coordinator.onNotes = { record in
            previous?(record)
            Task.detached { _ = await MeetingPostProcessing.run(record, settings: settings) }
        }
    }
}
