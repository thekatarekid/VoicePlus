import AppKit
import Combine
import Engine
import Shared
import SwiftUI

// V5 M-d — the Settings › Meetings page: detected-meeting notifications, per-app "don't notify",
// reminder timing, calendars to include, auto-record calendar meetings, save recording, auto-export
// folder + format, and the post-meeting hook. Opened from the Meetings page's detection footer.

@MainActor
public final class MeetingsSettingsModel: ObservableObject {
    @Published public private(set) var policy: MeetingDetectionPolicy
    @Published public private(set) var saveRecording: MeetingRecordingSaveMode
    @Published public private(set) var exportFolder: String
    @Published public private(set) var exportFormat: MeetingExportFormat
    @Published public private(set) var hookPath: String
    @Published public private(set) var hookTimeout: Double
    @Published public private(set) var lastHookResult: String?
    public let calendars: [MeetingCalendarInfo]

    private let settings: SettingsStore?
    private let center: NotificationCenter

    public init(settings: SettingsStore?, calendars: [MeetingCalendarInfo] = EventKitCalendarSignal().calendars(),
                center: NotificationCenter = .default) {
        self.settings = settings
        self.center = center
        self.calendars = calendars
        policy = MeetingSettings.policy(settings)
        saveRecording = MeetingSettings.saveRecording(settings)
        let export = MeetingSettings.autoExport(settings)
        exportFolder = export?.folder.path ?? ""
        exportFormat = export?.format
            ?? settings?.string(SettingsKeys.meetingExportFormat).flatMap(MeetingExportFormat.init(rawValue:)) ?? .markdown
        let hook = MeetingSettings.hook(settings)
        hookPath = hook?.path ?? ""
        hookTimeout = hook?.timeout ?? PostMeetingHookConfig.defaultTimeout
    }

    /// The apps the "Don't notify" list offers: call apps (deduplicated by name) and browsers.
    public static let notifiableApps: [(id: String, name: String)] = {
        var seen = Set<String>()
        let calls = CallAppCatalog.all.filter { seen.insert($0.name).inserted }.map { (id: $0.bundleID, name: $0.name) }
        let browsers: [(id: String, name: String)] = [("com.apple.Safari", "Safari"), ("com.google.Chrome", "Google Chrome"),
                                                      ("company.thebrowser.Browser", "Arc"), ("com.microsoft.edgemac", "Microsoft Edge"),
                                                      ("org.mozilla.firefox", "Firefox"), ("com.brave.Browser", "Brave")]
        return calls + browsers
    }()

    /// Every bundle id sharing the app's name (Teams classic + new, both WhatsApps, both Webex).
    static func bundleIDs(forAppNamed id: String) -> Set<String> {
        guard let name = CallAppCatalog.app(for: id)?.name else { return [id] }
        return Set(CallAppCatalog.all.filter { $0.name == name }.map(\.bundleID))
    }

    // MARK: Edits

    public func setNotifications(_ on: Bool) { update { $0.notifications = on } }

    public func isMuted(_ bundleID: String) -> Bool { policy.mutedApps.contains(bundleID) }

    public func setMuted(_ bundleID: String, _ muted: Bool) {
        let ids = Self.bundleIDs(forAppNamed: bundleID)
        update { muted ? $0.mutedApps.formUnion(ids) : $0.mutedApps.subtract(ids) }
    }

    public func setReminder(_ r: MeetingDetectionPolicy.Reminder) { update { $0.reminder = r } }

    public func isIncluded(_ calendarID: String) -> Bool { policy.includedCalendarIDs?.contains(calendarID) ?? true }

    public func setIncluded(_ calendarID: String, _ on: Bool) {
        update { p in
            var ids = p.includedCalendarIDs ?? Set(calendars.map(\.id))
            if on { ids.insert(calendarID) } else { ids.remove(calendarID) }
            // Every calendar ticked = "all", so calendars added later are included too.
            p.includedCalendarIDs = ids.isSuperset(of: calendars.map(\.id)) ? nil : ids
        }
    }

    public func setAutoRecord(_ on: Bool) { update { $0.autoRecordCalendarMeetings = on } }

    public func setSaveRecording(_ mode: MeetingRecordingSaveMode) {
        saveRecording = mode
        MeetingSettings.setSaveRecording(mode, store: settings, center: center)
    }

    public func setExport(folder: String?, format: MeetingExportFormat) {
        exportFolder = folder ?? ""
        exportFormat = format
        settings?.set(format.rawValue, for: SettingsKeys.meetingExportFormat)
        let export = MeetingSettings.nonBlank(folder).map { MeetingAutoExport(folder: URL(fileURLWithPath: $0, isDirectory: true), format: format) }
        MeetingSettings.setAutoExport(export, store: settings, center: center)
    }

    public func setHook(path: String?, timeout: Double) {
        let config = MeetingSettings.nonBlank(path).map { PostMeetingHookConfig(path: $0, timeout: timeout) }
        hookPath = config?.path ?? ""
        hookTimeout = config?.timeout ?? timeout
        MeetingSettings.setHook(config, store: settings, center: center)
    }

    /// "Test hook": runs the hook once with a sample record.
    public func testHook() async {
        guard let config = MeetingSettings.hook(settings) else { lastHookResult = "No hook set."; return }
        let sample = MeetingRecord(id: "sample", title: "Sample meeting", startedAt: Date(), endedAt: Date())
        let result = await PostMeetingHook.run(config, payload: PostMeetingHookPayload(record: sample))
        lastHookResult = Self.describe(result)
    }

    static func describe(_ r: PostMeetingHookResult) -> String {
        switch r {
        case .notExecutable(let p): return "Not an executable file: \(p)"
        case .finished(let status): return status == 0 ? "Hook ran (exit 0)." : "Hook exited with status \(status)."
        case .timedOut: return "Hook timed out and was stopped."
        case .failed(let why): return "Hook failed: \(why)"
        }
    }

    private func update(_ change: (inout MeetingDetectionPolicy) -> Void) {
        var p = policy
        change(&p)
        policy = p
        MeetingSettings.setPolicy(p, store: settings, center: center)
    }
}

struct MeetingsSettingsPage: View {
    @ObservedObject var model: MeetingsSettingsModel
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Detection") {
                    Toggle("Notify me when a meeting is detected", isOn: Binding(get: { model.policy.notifications }, set: model.setNotifications))
                        .accessibilityIdentifier("meetings.settings.notifications")
                    Picker("Calendar reminder", selection: Binding(get: { model.policy.reminder }, set: model.setReminder)) {
                        Text("At start time").tag(MeetingDetectionPolicy.Reminder.atStart)
                        Text("5 minutes before").tag(MeetingDetectionPolicy.Reminder.fiveMinutesBefore)
                    }
                    .accessibilityIdentifier("meetings.settings.reminder")
                    Toggle("Record calendar meetings automatically", isOn: Binding(get: { model.policy.autoRecordCalendarMeetings }, set: model.setAutoRecord))
                        .accessibilityIdentifier("meetings.settings.autoRecord")
                    Text("Detects a meeting from your camera, your microphone in use by a call app or a meeting tab (Google Meet, Teams, Zoom, Whereby…), and Calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Don’t notify for") {
                    ForEach(MeetingsSettingsModel.notifiableApps, id: \.id) { app in
                        Toggle(app.name, isOn: Binding(get: { model.isMuted(app.id) }, set: { model.setMuted(app.id, $0) }))
                    }
                }
                Section("Calendars to include") {
                    if model.calendars.isEmpty {
                        Text("Calendar is not connected.").foregroundStyle(.secondary)
                    }
                    ForEach(model.calendars) { cal in
                        Toggle(cal.title, isOn: Binding(get: { model.isIncluded(cal.id) }, set: { model.setIncluded(cal.id, $0) }))
                    }
                }
                MeetingSpeakerLabelSettingsSection()   // V5 M13
                MeetingDuringSettingsSection()   // V5 M14
                Section("After the meeting") {
                    Picker("Save meeting recording", selection: Binding(get: { model.saveRecording }, set: model.setSaveRecording)) {
                        ForEach(MeetingRecordingSaveMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("meetings.settings.saveRecording")
                    HStack {
                        Text("Auto-export to")
                        Spacer()
                        Text(model.exportFolder.isEmpty ? "Off" : (model.exportFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                        if !model.exportFolder.isEmpty { Button("Off") { model.setExport(folder: nil, format: model.exportFormat) } }
                    }
                    Picker("Export format", selection: Binding(get: { model.exportFormat },
                                                               set: { model.setExport(folder: model.exportFolder, format: $0) })) {
                        Text("Markdown").tag(MeetingExportFormat.markdown)
                        Text("JSON").tag(MeetingExportFormat.json)
                    }
                    HStack {
                        Text("Post-meeting hook")
                        Spacer()
                        Text(model.hookPath.isEmpty ? "None" : (model.hookPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseHook() }
                        if !model.hookPath.isEmpty { Button("Remove") { model.setHook(path: nil, timeout: model.hookTimeout) } }
                    }
                    if !model.hookPath.isEmpty {
                        Stepper("Timeout: \(Int(model.hookTimeout)) s", value: Binding(get: { model.hookTimeout },
                                                                                   set: { model.setHook(path: model.hookPath, timeout: $0) }),
                                in: PostMeetingHookConfig.timeoutRange, step: 5)
                        HStack {
                            Button("Test hook") { Task { await model.testHook() } }
                            if let r = model.lastHookResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text("The hook runs once per meeting with the meeting as JSON on standard input.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
                .padding(12)
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.setExport(folder: url.path, format: model.exportFormat) }
    }

    private func chooseHook() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { model.setHook(path: url.path, timeout: model.hookTimeout) }
    }
}
