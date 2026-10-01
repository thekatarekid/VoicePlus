import Foundation
import Shared
#if canImport(AppKit)
import AppKit
#endif
#if canImport(EventKit)
import EventKit
#endif

// V5 P2 — local names: Contacts (exists: `ContactsSource`) + installed app names + calendar
// attendees + recent file / repo names from open documents → the `RankedContext.recent` tier.
//
// Every provider is local, cheap after its first read (cached with a TTL), and never prompts:
// Calendar is read only when full access was already granted; files and repos come from the paths
// of documents the user already has open (no folder is scanned, so no TCC prompt is triggered).

/// Installed application display names ("Visual Studio Code", "iTerm", "Linear").
public protocol InstalledAppNamesProvider: Sendable {
    func installedAppNames() -> [String]
}

/// Attendee names of nearby calendar events (M11 name hints share this).
public protocol CalendarAttendeesProvider: Sendable {
    func attendeeNames(around date: Date) -> [String]
}

/// Paths of documents open now (`LiveAXOpenDocuments` gives these).
public protocol RecentDocumentPathsProvider: Sendable {
    func openDocumentPaths() -> [String]
}

public struct StaticAppNames: InstalledAppNamesProvider {
    public var names: [String]
    public init(_ names: [String]) { self.names = names }
    public func installedAppNames() -> [String] { names }
}

public struct StaticAttendees: CalendarAttendeesProvider {
    public var names: [String]
    public init(_ names: [String]) { self.names = names }
    public func attendeeNames(around date: Date) -> [String] { names }
}

public struct StaticDocumentPaths: RecentDocumentPathsProvider {
    public var paths: [String]
    public init(_ paths: [String]) { self.paths = paths }
    public func openDocumentPaths() -> [String] { paths }
}

/// V5 P2 — one harvest source for app, attendee and file/repo names. Lands in the `.recent` tier:
/// apps and files as `.contacts`-kind entries (the lowest-weight name band — installing a hundred
/// apps must never displace the user's own words), attendees as `.participants`.
public final class LocalNamesSource: ContextSource, @unchecked Sendable {
    public let kind = ContextSourceKind.contacts
    private let apps: InstalledAppNamesProvider
    private let attendees: CalendarAttendeesProvider?
    private let documents: RecentDocumentPathsProvider?
    private let appsTTL: TimeInterval
    private let lock = NSLock()
    private var appsCache: (names: [String], at: Date)?
    /// File / repo name → last seen. Remembered for `recentWindow` after the document closes.
    private var recent: [String: Date] = [:]
    public let recentWindow: TimeInterval
    public static let maxRecent = 200

    public init(apps: InstalledAppNamesProvider, attendees: CalendarAttendeesProvider? = nil,
                documents: RecentDocumentPathsProvider? = nil, appsTTL: TimeInterval = 10 * 60,
                recentWindow: TimeInterval = 7 * 24 * 3600) {
        self.apps = apps
        self.attendees = attendees
        self.documents = documents
        self.appsTTL = appsTTL
        self.recentWindow = recentWindow
    }

    public func harvest(now: Date) -> [ContextEntry] {
        var out: [ContextEntry] = []
        for name in appNames(now: now) {
            out.append(ContextEntry(text: name, source: .contacts, observedAt: now, salience: 0.4))
        }
        for name in attendees?.attendeeNames(around: now) ?? [] where name.count >= 2 {
            out.append(ContextEntry(text: name, source: .participants, observedAt: now, salience: 0.8))
        }
        for (name, seen) in recentNames(now: now) {
            out.append(ContextEntry(text: name, source: .contacts, observedAt: seen, salience: 0.6))
        }
        return out
    }

    func appNames(now: Date) -> [String] {
        if let cached = lock.withLock({ appsCache }), now.timeIntervalSince(cached.at) < appsTTL { return cached.names }
        let names = Self.cleanAppNames(apps.installedAppNames())
        lock.withLock { appsCache = (names, now) }
        return names
    }

    func recentNames(now: Date) -> [(String, Date)] {
        let fresh = (documents?.openDocumentPaths() ?? []).flatMap(Self.names(fromPath:))
        return lock.withLock {
            for name in fresh { recent[name] = now }
            recent = recent.filter { now.timeIntervalSince($0.value) < recentWindow }
            if recent.count > Self.maxRecent {
                recent = Dictionary(uniqueKeysWithValues: recent.sorted { $0.value > $1.value }.prefix(Self.maxRecent).map { ($0.key, $0.value) })
            }
            return recent.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }

    /// Drops helpers, uninstallers and duplicates; strips ".app" and version suffixes.
    static func cleanAppNames(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for var name in raw {
            if name.hasSuffix(".app") { name.removeLast(4) }
            name = name.trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            guard name.count >= 2, name.count <= 40,
                  !["uninstall", "helper", "updater", "installer", "agent"].contains(where: { lower.contains($0) }),
                  seen.insert(lower).inserted else { continue }
            out.append(name)
        }
        return out.sorted()
    }

    /// Code roots whose immediate child is a repository name.
    static let codeRoots: Set<String> = ["developer", "projects", "src", "code", "repos", "github", "gitlab", "workspace", "dev", "git"]

    /// "~/Developer/VoiceInput/Pipeline/Stage.swift" → ["Stage", "VoiceInput"]. File stems keep
    /// their own spelling; generic names ("index", "main", "README") are dropped.
    static func names(fromPath path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        var out: [String] = []
        let stem = url.deletingPathExtension().lastPathComponent
        if stem.count >= 3, !genericStems.contains(stem.lowercased()) { out.append(stem) }
        let components = url.pathComponents
        if let root = components.lastIndex(where: { codeRoots.contains($0.lowercased()) }), root + 1 < components.count - 1 {
            out.append(components[root + 1])
        }
        return out
    }

    static let genericStems: Set<String> = ["index", "main", "readme", "untitled", "document", "license", "package", "makefile", "app", "test", "tests"]
}

#if canImport(AppKit)
/// `/Applications`, `/System/Applications`, `~/Applications` (top level + one folder deep) and the
/// running apps' localized names. Directory listings of these folders need no permission.
public struct LiveInstalledAppNames: InstalledAppNamesProvider {
    public init() {}
    public func installedAppNames() -> [String] {
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications")]
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var names: [String] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" { names.append(item.deletingPathExtension().lastPathComponent); continue }
                guard let inner = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                names += inner.filter { $0.pathExtension == "app" }.map { $0.deletingPathExtension().lastPathComponent }
            }
        }
        names += NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .regular ? $0.localizedName : nil }
        return names
    }
}
#endif

#if canImport(EventKit)
/// Attendees of events from 12 h before to 24 h after now. Reads only with full access already
/// granted (M11 asks); never requests access itself.
public struct LiveCalendarAttendees: CalendarAttendeesProvider {
    public init() {}
    public func attendeeNames(around date: Date) -> [String] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-12 * 3600),
                                                 end: date.addingTimeInterval(24 * 3600), calendars: nil)
        var names: [String] = []
        for event in store.events(matching: predicate).prefix(50) {
            for attendee in event.attendees ?? [] where !attendee.isCurrentUser {
                if let name = attendee.name, !name.contains("@") { names.append(name) }
            }
        }
        return Array(Set(names)).sorted()
    }
}
#endif

/// Adapts the existing open-documents reader (`LiveAXOpenDocuments`) to the P2 provider.
public struct OpenDocumentPaths: RecentDocumentPathsProvider {
    public let provider: OpenDocumentProvider
    public init(provider: OpenDocumentProvider) { self.provider = provider }
    public func openDocumentPaths() -> [String] { provider.openDocumentNames().filter { $0.contains("/") || $0.contains(".") } }
}
