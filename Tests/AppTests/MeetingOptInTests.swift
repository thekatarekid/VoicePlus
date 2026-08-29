import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// FIX A regression cover. `AppDelegate` calls `MeetingCoordinator.startMonitoring()` on every
/// launch, and `startMonitoring()` used to call `calendar.requestAccess()` unconditionally — so a
/// plain launch with zero interaction produced, in tccd:
///
///     Handling access request to kTCCServiceCalendar, from Sub:{in.adityakatare.voiceplus} … promptType: 1
///     Handling access request to kTCCServiceReminders,  from Sub:{in.adityakatare.voiceplus} … promptType: 1
///
/// (Reminders came along for free: `EKEventStore()`'s no-argument initialiser covers every entity
/// type, so merely holding one as a stored property made TCC evaluate both services.) A user who
/// never wanted meeting capture got two dialogs out of nowhere on first run.
///
/// These tests pin the rule with authorizers that record every call: with the feature off nothing
/// asks, and even with it on a *launch* only ever reads status. The request happens exactly once,
/// at the moment the user opts in.
@Suite("FIX A — meeting capture is opt-in, launch never requests authorization")
struct MeetingOptInTests {
    /// Records every call so a test can assert on the *absence* of a request, which is the whole
    /// point — a mock that only reported grants could not see this bug.
    final class RecordingCalendar: MeetingCalendarAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var authorized: Bool
        private(set) var requestCount = 0
        private(set) var statusReads = 0
        private(set) var meetingQueries = 0

        init(authorized: Bool = false) { self.authorized = authorized }

        var isAuthorized: Bool {
            lock.lock(); defer { lock.unlock() }
            statusReads += 1
            return authorized
        }

        func requestAccess() async -> Bool {
            lock.lock(); defer { lock.unlock() }
            requestCount += 1
            authorized = true
            return true
        }

        func meetings(around now: Date) -> [CalendarMeeting] {
            lock.lock(); defer { lock.unlock() }
            meetingQueries += 1
            return []
        }
    }

    final class RecordingNotifications: MeetingNotificationAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requestCount = 0
        func requestAuthorization() async -> Bool {
            lock.lock(); defer { lock.unlock() }
            requestCount += 1
            return true
        }
    }

    private static func make(enabled: Bool? = nil, authorized: Bool = false)
        -> (MeetingCoordinator, RecordingCalendar, RecordingNotifications, InMemorySettingsStore) {
        let settings = InMemorySettingsStore()
        if let enabled { settings.set(enabled, for: SettingsKeys.meetingCaptureEnabled) }
        let calendar = RecordingCalendar(authorized: authorized)
        let notifications = RecordingNotifications()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-optin-\(UUID())")
        let coordinator = MeetingCoordinator(store: MeetingStore(root: root), calendar: calendar,
                                             notifications: notifications, settings: settings)
        return (coordinator, calendar, notifications, settings)
    }

    // MARK: The launch path

    @Test func startMonitoringWithCaptureOffRequestsNoAuthorizationAtAll() {
        let (coordinator, calendar, notifications, _) = Self.make()
        #expect(coordinator.isMeetingCaptureEnabled == false, "meeting capture must default to OFF")

        coordinator.startMonitoring()   // exactly what AppDelegate does on every launch
        defer { coordinator.stopMonitoring() }

        #expect(calendar.requestCount == 0, "a plain launch must never request Calendar access")
        #expect(notifications.requestCount == 0, "a plain launch must never request notification authorization")
        #expect(calendar.meetingQueries == 0, "an EventKit query is itself a prompt risk when unauthorized")
    }

    @Test func aFreshInstallDefaultsToOffEvenWithNoStoredValue() {
        // No key written at all — the absent-value branch, which is what a first run actually hits.
        let (coordinator, calendar, notifications, settings) = Self.make(enabled: nil)
        #expect(settings.bool(SettingsKeys.meetingCaptureEnabled) == nil)
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        #expect(coordinator.isMeetingCaptureEnabled == false)
        #expect(calendar.requestCount == 0 && notifications.requestCount == 0)
    }

    @Test func noSettingsStoreMeansOffRatherThanOn() {
        // Headless runs and tests construct the coordinator without a store; failing open here
        // would put the prompt right back.
        let calendar = RecordingCalendar()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-optin-\(UUID())")
        let coordinator = MeetingCoordinator(store: MeetingStore(root: root), calendar: calendar)
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        #expect(coordinator.isMeetingCaptureEnabled == false)
        #expect(calendar.requestCount == 0)
    }

    @Test func startMonitoringWithCaptureOnStillOnlyReadsStatusNeverRequests() {
        let (coordinator, calendar, notifications, _) = Self.make(enabled: true, authorized: true)
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }

        #expect(coordinator.isMeetingCaptureEnabled == true)
        #expect(calendar.requestCount == 0, "launch is status-only even when the feature is on")
        #expect(notifications.requestCount == 0)
    }

    @Test func anUnauthorizedCalendarStaysDormantInsteadOfPrompting() {
        let (coordinator, calendar, _, _) = Self.make(enabled: true, authorized: false)
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        #expect(calendar.requestCount == 0, "not authorized is a reason to stay dormant, not to ask")
    }

    // MARK: The opt-in path — the one place a dialog may come from

    @Test func enablingMeetingCaptureIsTheOnlyThingThatRequestsCalendar() async {
        let (coordinator, calendar, _, settings) = Self.make()
        #expect(calendar.requestCount == 0)

        let granted = await coordinator.setMeetingCaptureEnabled(true)
        defer { coordinator.stopMonitoring() }

        #expect(granted)
        #expect(calendar.requestCount == 1, "the user's opt-in asks exactly once")
        #expect(settings.bool(SettingsKeys.meetingCaptureEnabled) == true, "the opt-in must persist")
        #expect(coordinator.isMeetingCaptureEnabled)
    }

    @Test func enablingWhenAlreadyAuthorizedDoesNotAskAgain() async {
        let (coordinator, calendar, _, _) = Self.make(authorized: true)
        _ = await coordinator.setMeetingCaptureEnabled(true)
        defer { coordinator.stopMonitoring() }
        #expect(calendar.requestCount == 0, "an existing grant is read, not re-requested")
        #expect(calendar.statusReads > 0)
    }

    @Test func disablingPersistsOffAndAsksForNothing() async {
        let (coordinator, calendar, notifications, settings) = Self.make(enabled: true, authorized: true)
        let granted = await coordinator.setMeetingCaptureEnabled(false)
        #expect(granted == false)
        #expect(settings.bool(SettingsKeys.meetingCaptureEnabled) == false)
        #expect(coordinator.isMeetingCaptureEnabled == false)
        #expect(calendar.requestCount == 0 && notifications.requestCount == 0)

        // And a subsequent launch is inert again.
        coordinator.startMonitoring()
        defer { coordinator.stopMonitoring() }
        #expect(calendar.requestCount == 0)
    }

    // MARK: Notifications

    @Test func finishedNotesAskForNotificationPermissionOnlyAfterOptIn() async throws {
        let (coordinator, _, notifications, _) = Self.make(enabled: true, authorized: true)
        coordinator.makeSession = { prompt in
            MeetingSession(title: prompt.title, transcriber: SilentMeetingTranscriber(),
                           labeler: ChannelLabeler(), store: coordinator.store)
        }
        let event = CalendarMeeting(id: "e1", title: "Design sync", start: Date(),
                                    end: Date().addingTimeInterval(1800), meetingURL: nil)
        coordinator.apply(.calendar([event]))
        coordinator.apply(.cameraStarted)
        coordinator.choose(.record)          // the user accepting the prompt — real intent
        #expect(notifications.requestCount == 0, "accepting the prompt does not yet need notifications")

        _ = await coordinator.finishSession()
        #expect(notifications.requestCount == 1, "notes exist to deliver, so now we may ask")
    }

    @Test func finishedNotesWithCaptureOffNeverAskForNotificationPermission() async throws {
        let (coordinator, _, notifications, _) = Self.make(enabled: false)
        coordinator.makeSession = { prompt in
            MeetingSession(title: prompt.title, transcriber: SilentMeetingTranscriber(),
                           labeler: ChannelLabeler(), store: coordinator.store)
        }
        coordinator.apply(.calendar([CalendarMeeting(id: "e2", title: "Standup", start: Date(),
                                                     end: Date().addingTimeInterval(900), meetingURL: nil)]))
        coordinator.apply(.cameraStarted)
        coordinator.choose(.record)
        _ = await coordinator.finishSession()
        #expect(notifications.requestCount == 0)
    }
}
