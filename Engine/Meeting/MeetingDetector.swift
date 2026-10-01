import CoreMediaIO
import EventKit
import Foundation
import Shared

/// Calendar event in the detection window. Only what the prompt needs; no attendees stored.
public struct CalendarMeeting: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    /// Zoom/Meet/Teams link if the event carries one. "Join" opens it in the user's browser — never a bot.
    public var meetingURL: URL?
    /// V5 M-d — the EventKit calendar the event lives in (Settings › Meetings "Calendars to include").
    /// Optional so records saved before M-d still decode.
    public var calendarID: String?
    public init(id: String, title: String, start: Date, end: Date, meetingURL: URL? = nil, calendarID: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.meetingURL = meetingURL
        self.calendarID = calendarID
    }
    public func isLive(at t: Date, lead: TimeInterval) -> Bool { t >= start.addingTimeInterval(-lead) && t < end }
}

/// Model for the notch notification (UI wired at integration).
public struct MeetingPrompt: Equatable, Sendable, Identifiable {
    public enum Choice: String, Codable, Sendable, CaseIterable { case joinAndRecord, record, ignore }
    /// `camera` / `microphone` / `callApp` / `browser` = a detected (non-calendar) meeting;
    /// `both` = a detected meeting while a calendar event is live.
    public enum Reason: String, Codable, Sendable { case camera, calendar, both, microphone, callApp, browser }
    public var id: String
    public var title: String
    public var reason: Reason
    public var event: CalendarMeeting?
    /// V5 M-d — the app the detected meeting is attributed to (call app or browser), if known.
    public var source: MeetingActivity?
    /// Join & Record is only offered when there is a link to open.
    public var choices: [Choice] { event?.meetingURL != nil ? [.joinAndRecord, .record, .ignore] : [.record, .ignore] }
    public init(id: String, title: String, reason: Reason, event: CalendarMeeting?, source: MeetingActivity? = nil) {
        self.id = id; self.title = title; self.reason = reason; self.event = event; self.source = source
    }
}

/// Inputs from the camera / calendar monitors and the user; outputs are effects for the app.
public enum MeetingSignal: Equatable, Sendable {
    case cameraStarted, cameraStopped
    /// V5 M-d — the input device is being captured by *another* process (not VoicePlus).
    case micInUseElsewhere(Bool)
    /// V5 M-d — known call apps currently running (Zoom, Teams, FaceTime, Slack, WhatsApp, …).
    case callApps([CallApp])
    /// V5 M-d — the frontmost browser tab, when it is a meeting page (nil otherwise).
    case browserMeeting(BrowserMeetingTab?)
    /// V5 M-d — Settings › Meetings changed (notifications, muted apps, reminder, calendars, auto-record).
    case policy(MeetingDetectionPolicy)
    /// Current calendar window contents (the monitor re-sends periodically; idempotent).
    case calendar([CalendarMeeting])
    case userChose(MeetingPrompt.Choice)
    case recordingStopped
    case tick
}

public enum MeetingEffect: Equatable, Sendable {
    case showPrompt(MeetingPrompt)
    case dismissPrompt
    case startRecording(MeetingPrompt, join: URL?)
    case stopRecording
}

/// Pure state machine. Prompt at most once per calendar event and once per detected-meeting
/// session; "Ignore" is sticky for that event / session; recording ends when the detected activity
/// stops and no event is live, or when the live event ends (with a grace period).
///
/// V5 M-d — a *detected* meeting is any of: the camera running somewhere; the microphone captured
/// by another process while a meeting page is the frontmost browser tab; the microphone captured by
/// another process while a known call app runs. A call app running, or a meeting tab open, without
/// the mic in use is not a meeting (Slack runs all day). `MeetingDetectionPolicy` (Settings ›
/// Meetings) gates prompts, mutes per app, sets the calendar reminder lead, filters calendars and
/// can auto-record calendar meetings.
public struct MeetingDetector: Sendable, Equatable {
    public enum State: Equatable, Sendable { case idle, prompted(MeetingPrompt), recording(MeetingPrompt), ignored(MeetingPrompt) }
    public var state: State = .idle
    /// How early before an event's start we prompt. `.policy(_)` sets it from the reminder timing.
    public var leadTime: TimeInterval
    /// How long after an event's end (activity off) before we stop a recording on our own.
    public var endGrace: TimeInterval
    public private(set) var policy: MeetingDetectionPolicy
    public private(set) var cameraOn = false
    public private(set) var micInUseElsewhere = false
    public private(set) var runningCallApps: [CallApp] = []
    public private(set) var browserTab: BrowserMeetingTab?
    /// Calendar events after the policy's calendar filter.
    public private(set) var events: [CalendarMeeting] = []
    private var allEvents: [CalendarMeeting] = []
    private var promptedEventIDs: Set<String> = []
    private var activityPrompted = false
    private var eventEndedAt: Date?

    public init(leadTime: TimeInterval = 120, endGrace: TimeInterval = 300, policy: MeetingDetectionPolicy = MeetingDetectionPolicy()) {
        self.leadTime = leadTime; self.endGrace = endGrace; self.policy = policy
    }

    /// Built from settings: the lead time comes from the policy's reminder timing.
    public init(policy: MeetingDetectionPolicy, endGrace: TimeInterval = 300) {
        self.init(leadTime: policy.reminder.leadTime, endGrace: endGrace, policy: policy)
    }

    public func liveEvent(at now: Date) -> CalendarMeeting? {
        events.filter { $0.isLive(at: now, lead: leadTime) }.sorted { $0.start < $1.start }.first
    }

    /// The detected (non-calendar) meeting right now, ignoring mutes. Keeps recordings alive.
    public var activity: MeetingActivity? { activity(excluding: []) }

    /// The detected meeting the user may be prompted about: muted apps never attribute one.
    public var promptableActivity: MeetingActivity? { activity(excluding: policy.mutedApps) }

    /// A detected call is still going on. Weaker than `activity` on purpose: once a call has been
    /// detected (prompted, recording or ignored), the camera or another process holding the mic is
    /// enough to keep it — switching the browser to another tab, or the call app's window losing
    /// the meeting page, must not end a recording or re-arm a prompt mid-call.
    public var callOngoing: Bool { cameraOn || micInUseElsewhere }

    private func activity(excluding muted: Set<String>) -> MeetingActivity? {
        let tab = browserTab.flatMap { muted.contains($0.browserBundleID) ? nil : $0 }
        let app = runningCallApps.first { !muted.contains($0.bundleID) }
        if cameraOn {
            if let tab { return .init(kind: .camera, tab: tab) }
            if let app { return .init(kind: .camera, app: app) }
            // Camera attributed to a muted app → muted; unattributed camera → still a meeting.
            let attributedToMuted = browserTab != nil || !runningCallApps.isEmpty
            return attributedToMuted ? nil : .init(kind: .camera)
        }
        guard micInUseElsewhere else { return nil }
        if let tab { return .init(kind: .browser, tab: tab) }
        if let app { return .init(kind: .callApp, app: app) }
        return nil
    }

    public mutating func apply(_ signal: MeetingSignal, at now: Date) -> [MeetingEffect] {
        switch signal {
        case .cameraStarted: cameraOn = true; activityPrompted = false
        case .cameraStopped: cameraOn = false
        case .micInUseElsewhere(let on): micInUseElsewhere = on
        case .callApps(let apps): runningCallApps = apps
        case .browserMeeting(let tab): browserTab = tab
        case .calendar(let list): allEvents = list; events = policy.filter(list)
        case .policy(let p):
            policy = p; leadTime = p.reminder.leadTime; events = p.filter(allEvents)
        case .userChose(let choice):
            guard case .prompted(let p) = state else { return [] }
            switch choice {
            case .ignore: state = .ignored(p); return [.dismissPrompt]
            case .record: state = .recording(p); return [.dismissPrompt, .startRecording(p, join: nil)]
            case .joinAndRecord: state = .recording(p); return [.dismissPrompt, .startRecording(p, join: p.event?.meetingURL)]
            }
        case .recordingStopped:
            if case .recording = state { state = .idle }
            eventEndedAt = nil
            return []
        case .tick: break
        }
        // A detected-meeting session ends when every activity signal is gone; the next one prompts anew.
        if activity == nil && !callOngoing { activityPrompted = false }
        return evaluate(at: now)
    }

    private mutating func evaluate(at now: Date) -> [MeetingEffect] {
        let live = liveEvent(at: now)
        let active = activity
        switch state {
        case .idle:
            if let ev = live, !promptedEventIDs.contains(ev.id) {
                promptedEventIDs.insert(ev.id)
                if active != nil { activityPrompted = true }
                let p = MeetingPrompt(id: "event:\(ev.id)", title: ev.title, reason: active != nil ? .both : .calendar,
                                      event: ev, source: active)
                if policy.autoRecordCalendarMeetings { state = .recording(p); return [.startRecording(p, join: nil)] }
                guard policy.notifications else { return [] }
                state = .prompted(p); return [.showPrompt(p)]
            }
            if let act = promptableActivity, !activityPrompted, policy.notifications {
                activityPrompted = true
                let prefix = act.kind == .camera ? "camera" : act.kind.rawValue
                let p = MeetingPrompt(id: "\(prefix):\(Int(now.timeIntervalSince1970))", title: live?.title ?? act.title,
                                      reason: live == nil ? act.reason : .both, event: live, source: act)
                state = .prompted(p); return [.showPrompt(p)]
            }
            return []
        case .prompted(let p):
            // Auto-dismiss when the trigger disappeared before the user answered.
            let stillRelevant = (p.event.map { $0.isLive(at: now, lead: leadTime) } ?? false) || (p.reason != .calendar && (active != nil || callOngoing))
            if !stillRelevant { state = .idle; return [.dismissPrompt] }
            return []
        case .ignored(let p):
            let eventOver = p.event.map { now >= $0.end } ?? true
            if p.reason == .calendar ? eventOver : (active == nil && !callOngoing && eventOver) { state = .idle }
            return []
        case .recording(let p):
            let eventLive = p.event.map { $0.isLive(at: now, lead: 0) } ?? false
            // Keep going while a detected meeting is on, the prompt's event is live, or (detected-only
            // prompt) any calendar event is live right now.
            let detectedCallGoesOn = active != nil || (p.reason != .calendar && callOngoing)
            if detectedCallGoesOn || eventLive || (p.event == nil && live != nil) { eventEndedAt = nil; return [] }
            let since = eventEndedAt ?? now
            eventEndedAt = since
            // Detected-only meetings stop when the activity stops; calendar ones get a grace window.
            let grace = p.event == nil ? 0 : endGrace
            if now.timeIntervalSince(since) >= grace { state = .idle; eventEndedAt = nil; return [.stopRecording] }
            return []
        }
    }
}

// MARK: - Live signals

/// Camera-in-use via CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` on every video
/// device (fires for any app using the camera, not just ours). No video is ever read.
public final class CameraInUseMonitor: @unchecked Sendable {
    public var onChange: ((Bool) -> Void)?
    private(set) public var isInUse = false
    private var listeners: [(CMIOObjectID, CMIOObjectPropertyAddress)] = []
    private let queue = DispatchQueue(label: "voiceplus.meeting.camera")

    public init() {}

    public func start() {
        let devices = Self.videoDevices()
        for dev in devices {
            var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                 mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                 mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            let status = CMIOObjectAddPropertyListenerBlock(dev, &addr, queue) { [weak self] _, _ in self?.refresh() }
            if status == noErr { listeners.append((dev, addr)) }
        }
        refresh()
    }

    public func stop() {
        for (dev, addr) in listeners {
            var a = addr
            CMIOObjectRemovePropertyListenerBlock(dev, &a, queue) { _, _ in }
        }
        listeners.removeAll()
    }

    private func refresh() {
        let now = Self.videoDevices().contains { Self.isRunningSomewhere($0) }
        guard now != isInUse else { return }
        isInUse = now
        onChange?(now)
    }

    static func videoDevices() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    static func isRunningSomewhere(_ dev: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr && value != 0
    }
}

/// Calendar window via EventKit. Asks for access once (macOS 14 full-access API); without it the
/// signal is simply empty — meetings are then detected from the camera alone.
///
/// The `EKEventStore` is built **lazily and only on demand**. Merely constructing one makes TCC
/// evaluate access for `kTCCServiceCalendar` *and* `kTCCServiceReminders` (the no-argument
/// initialiser covers every entity type), so holding one as a stored property meant a plain launch
/// popped two authorization dialogs the user never asked for. Nothing here touches the store until
/// either `requestAccess()` (the deliberate opt-in) or a `meetings()` call that has already
/// confirmed authorization via the static status query.
public final class EventKitCalendarSignal: @unchecked Sendable {
    private let storeLock = NSLock()
    private var madeStore: EKEventStore?
    private var store: EKEventStore {
        storeLock.lock(); defer { storeLock.unlock() }
        if let madeStore { return madeStore }
        let fresh = EKEventStore()
        madeStore = fresh
        return fresh
    }
    public var window: TimeInterval = 60 * 60
    public init() {}

    /// Status query only — never prompts, safe to call at launch.
    public var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// The only call here that may show a TCC dialog. Callers must have a user opt-in behind it.
    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func meetings(around now: Date = Date()) -> [CalendarMeeting] {
        guard isAuthorized else { return [] }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-window), end: now.addingTimeInterval(window), calendars: nil)
        return store.events(matching: pred).filter { !$0.isAllDay }.map { e in
            CalendarMeeting(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Meeting", start: e.startDate, end: e.endDate,
                            meetingURL: Self.meetingLink(e), calendarID: e.calendar?.calendarIdentifier)
        }
    }

    /// V5 M-d — event calendars for Settings › Meetings "Calendars to include". Empty unless already
    /// authorized; never prompts.
    public func calendars() -> [MeetingCalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).map { MeetingCalendarInfo(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static let linkHosts = BrowserMeetingClassifier.meetingHosts

    static func meetingLink(_ e: EKEvent) -> URL? {
        if let u = e.url, linkHosts.contains(where: { u.host?.hasSuffix($0) == true }) { return u }
        for text in [e.location, e.notes].compactMap({ $0 }) {
            if let u = firstLink(in: text) { return u }
        }
        return nil
    }

    public static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let u = m.url, linkHosts.contains(where: { u.host?.hasSuffix($0) == true }) { return u }
        }
        return nil
    }
}
