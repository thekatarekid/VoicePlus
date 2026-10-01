import Foundation

// V5 M-d — the detection vocabulary beyond camera + calendar: call apps, meeting pages in a browser,
// the mic captured by another process, and the user's detection policy (Settings › Meetings).
// Everything here is pure value types; the live readers are in `MeetingDetectorMonitors.swift`.

/// A known call app (matched by bundle id against the running applications).
public struct CallApp: Codable, Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    /// What a meeting in it is called ("Zoom call", "Slack huddle").
    public var meetingNoun: String
    public init(bundleID: String, name: String, meetingNoun: String = "call") {
        self.bundleID = bundleID; self.name = name; self.meetingNoun = meetingNoun
    }
}

public enum CallAppCatalog {
    public static let all: [CallApp] = [
        CallApp(bundleID: "us.zoom.xos", name: "Zoom"),
        CallApp(bundleID: "com.microsoft.teams2", name: "Microsoft Teams"),
        CallApp(bundleID: "com.microsoft.teams", name: "Microsoft Teams"),
        CallApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        CallApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", meetingNoun: "huddle"),
        CallApp(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp"),
        CallApp(bundleID: "desktop.WhatsApp", name: "WhatsApp"),
        CallApp(bundleID: "com.cisco.webexmeetingsapp", name: "Webex"),
        CallApp(bundleID: "Cisco-Systems.Spark", name: "Webex"),
        CallApp(bundleID: "com.hnc.Discord", name: "Discord"),
        CallApp(bundleID: "com.skype.skype", name: "Skype"),
    ]

    /// Known call apps among `bundleIDs`, in catalog order (deterministic attribution).
    public static func running(in bundleIDs: some Sequence<String>) -> [CallApp] {
        let ids = Set(bundleIDs)
        return all.filter { ids.contains($0.bundleID) }
    }

    public static func app(for bundleID: String) -> CallApp? { all.first { $0.bundleID == bundleID } }
}

/// The frontmost browser tab when it is a meeting page.
public struct BrowserMeetingTab: Codable, Equatable, Hashable, Sendable {
    public var browserBundleID: String
    /// "Google Meet", "Microsoft Teams", "Zoom", …
    public var service: String
    public var url: URL?
    public var title: String?
    public init(browserBundleID: String, service: String, url: URL? = nil, title: String? = nil) {
        self.browserBundleID = browserBundleID; self.service = service; self.url = url; self.title = title
    }
}

/// Pure URL/title → meeting-service classifier for browser tabs. A host alone is not enough where
/// the site also has a non-meeting landing page (meet.google.com/ vs meet.google.com/abc-defg-hij).
public enum BrowserMeetingClassifier {
    /// Hosts that carry meetings — also used to spot meeting links in calendar events.
    public static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
                                      "webex.com", "whereby.com", "around.co"]

    /// Every browser the tab signal recognises, with its display name (Settings › Meetings'
    /// "Don't notify" list offers exactly these).
    public static let browserNames: [String: String] = [
        "com.apple.Safari": "Safari", "com.apple.SafariTechnologyPreview": "Safari Technology Preview",
        "com.google.Chrome": "Google Chrome", "com.google.Chrome.canary": "Google Chrome Canary",
        "company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Microsoft Edge",
        "org.mozilla.firefox": "Firefox", "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "Opera", "org.chromium.Chromium": "Chromium",
    ]

    public static let browserBundleIDs: Set<String> = Set(browserNames.keys)

    public static func isBrowser(_ bundleID: String?) -> Bool { bundleID.map(browserBundleIDs.contains) ?? false }

    /// The meeting service a tab shows, or nil when it is not a meeting page.
    public static func service(url: URL?, title: String?) -> String? {
        if let url, let s = service(url: url) { return s }
        if let title, let s = service(title: title) { return s }
        return nil
    }

    static func service(url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        let fragment = (url.fragment ?? "").lowercased()
        func on(_ h: String) -> Bool { host == h || host.hasSuffix("." + h) }
        if on("meet.google.com") {
            return path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil ? "Google Meet" : nil
        }
        if on("zoom.us") {
            return path.hasPrefix("/wc/") || path.contains("/wc/") || path.hasPrefix("/j/") ? "Zoom" : nil
        }
        if on("teams.microsoft.com") || on("teams.live.com") {
            let hay = path + "#" + fragment
            return ["meetup-join", "calling", "/meet/", "call"].contains(where: hay.contains) ? "Microsoft Teams" : nil
        }
        if on("whereby.com") { return path.count > 1 && !path.hasPrefix("/user") && !path.hasPrefix("/information") ? "Whereby" : nil }
        if on("around.co") { return path.count > 1 ? "Around" : nil }
        if on("webex.com") { return path.contains("/meet/") || path.contains("/wbxmjs/") || path.contains("/join") ? "Webex" : nil }
        if on("app.slack.com") { return path.contains("/huddle") ? "Slack huddle" : nil }
        return nil
    }

    static func service(title: String) -> String? {
        let t = title.lowercased()
        if t.range(of: #"(^|\s)meet\s*[-–]\s*[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil { return "Google Meet" }
        if t.contains("zoom meeting") || t.contains("zoom webinar") { return "Zoom" }
        if t.contains("| microsoft teams") && (t.contains("meeting") || t.contains("call")) { return "Microsoft Teams" }
        if t.contains("huddle") && t.contains("slack") { return "Slack huddle" }
        return nil
    }

    public static func classify(browserBundleID: String, url: URL?, title: String?) -> BrowserMeetingTab? {
        guard let svc = service(url: url, title: title) else { return nil }
        return BrowserMeetingTab(browserBundleID: browserBundleID, service: svc, url: url, title: title)
    }
}

/// What the detector believes is a meeting right now, and which app it is attributed to.
public struct MeetingActivity: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case camera, callApp, browser }
    public var kind: Kind
    public var bundleID: String?
    public var appName: String?
    public var title: String

    public init(kind: Kind, bundleID: String? = nil, appName: String? = nil, title: String = "Meeting in progress") {
        self.kind = kind; self.bundleID = bundleID; self.appName = appName; self.title = title
    }
    init(kind: Kind, app: CallApp) {
        self.init(kind: kind, bundleID: app.bundleID, appName: app.name, title: "\(app.name) \(app.meetingNoun)")
    }
    init(kind: Kind, tab: BrowserMeetingTab) {
        let title = tab.service.hasSuffix("huddle") ? tab.service : "\(tab.service) call"
        self.init(kind: kind, bundleID: tab.browserBundleID, appName: tab.service, title: title)
    }

    var reason: MeetingPrompt.Reason {
        switch kind { case .camera: return .camera; case .callApp: return .callApp; case .browser: return .browser }
    }
}

/// Settings › Meetings, as the detector sees it.
public struct MeetingDetectionPolicy: Codable, Equatable, Sendable {
    public enum Reminder: String, Codable, Sendable, CaseIterable {
        case atStart, fiveMinutesBefore
        public var leadTime: TimeInterval { self == .atStart ? 0 : 300 }
    }
    /// "Detected-meeting notifications": off = never prompt (auto-record still runs).
    public var notifications: Bool
    /// "Don't notify" apps (bundle ids): a meeting attributed to one never prompts.
    public var mutedApps: Set<String>
    public var reminder: Reminder
    /// nil = every calendar. Events without a calendar id are always kept.
    public var includedCalendarIDs: Set<String>?
    /// "Auto-record calendar meetings" (default off): a live event starts recording with no prompt.
    public var autoRecordCalendarMeetings: Bool

    public init(notifications: Bool = true, mutedApps: Set<String> = [], reminder: Reminder = .atStart,
                includedCalendarIDs: Set<String>? = nil, autoRecordCalendarMeetings: Bool = false) {
        self.notifications = notifications; self.mutedApps = mutedApps; self.reminder = reminder
        self.includedCalendarIDs = includedCalendarIDs; self.autoRecordCalendarMeetings = autoRecordCalendarMeetings
    }

    public func filter(_ events: [CalendarMeeting]) -> [CalendarMeeting] {
        guard let ids = includedCalendarIDs else { return events }
        return events.filter { $0.calendarID.map(ids.contains) ?? true }
    }
}

/// One event calendar, for the "Calendars to include" list.
public struct MeetingCalendarInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
