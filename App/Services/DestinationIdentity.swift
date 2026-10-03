import AppKit
import ApplicationServices
import Shared

/// X6 — who the words are going to, as the notch shows it (owner decision round 3, "Destination identity").
/// Apps: app icon + app name. Web pages: browser icon + browser name, plus the real site favicon and the tab
/// title (the AX window title — never the URL).
public struct DestinationIdentity: Equatable {
    public var appIcon: NSImage?
    public var appName: String
    public var isBrowser: Bool
    public var siteFavicon: NSImage?
    public var tabTitle: String?
    /// The page's host, used only as the favicon/cache key and to notice a site change. Never displayed.
    public var siteHost: String?
    public var bundleID: String?

    public init(appIcon: NSImage?, appName: String, isBrowser: Bool = false, siteFavicon: NSImage? = nil,
                tabTitle: String? = nil, siteHost: String? = nil, bundleID: String? = nil) {
        self.appIcon = appIcon
        self.appName = appName
        self.isBrowser = isBrowser
        self.siteFavicon = siteFavicon
        self.tabTitle = tabTitle
        self.siteHost = siteHost
        self.bundleID = bundleID
    }

    /// The words beside the badge: the tab title for a web page, the app name otherwise.
    public var label: String { (isBrowser ? tabTitle : nil) ?? appName }

    /// Same place for the attention animation: same app, and for a browser the same site.
    public func isSameDestination(as other: DestinationIdentity?) -> Bool {
        guard let other else { return false }
        return bundleID == other.bundleID && appName == other.appName && siteHost == other.siteHost
    }

    public static func == (a: DestinationIdentity, b: DestinationIdentity) -> Bool {
        a.appName == b.appName && a.isBrowser == b.isBrowser && a.tabTitle == b.tabTitle
            && a.siteHost == b.siteHost && a.bundleID == b.bundleID
            && (a.appIcon == nil) == (b.appIcon == nil) && (a.siteFavicon == nil) == (b.siteFavicon == nil)
    }
}

/// X6 — the browsers we recognise, by bundle identifier, with the Chromium profile folder that holds their
/// `Favicons` database (nil: no readable store; network fetch only).
public enum KnownBrowser {
    public static let chromiumProfiles: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.google.Chrome.beta": "Google/Chrome Beta",
        "com.google.Chrome.canary": "Google/Chrome Canary",
        "company.thebrowser.Browser": "Arc/User Data",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "com.operasoftware.Opera",
    ]
    public static let others: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
        "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    public static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromiumProfiles[bundleID] != nil || others.contains(bundleID)
    }
}

/// The running-app facts the resolver needs, behind a seam so tests never touch NSRunningApplication.
public struct DestinationAppInfo {
    public var name: String?
    public var bundleID: String?
    public var icon: NSImage?
    public init(name: String?, bundleID: String?, icon: NSImage?) {
        self.name = name
        self.bundleID = bundleID
        self.icon = icon
    }
}

/// The window facts read through Accessibility: its title and the page URL (used for the host only).
public struct DestinationWindowInfo {
    public var title: String?
    public var url: URL?
    public init(title: String?, url: URL?) {
        self.title = title
        self.url = url
    }
}

/// X6 — `resolve(pid:axWindow:)` is synchronous (cached favicon only: memory, disk, browser store) so the
/// key-down path never waits on the network; `resolveFavicon(for:)` completes the favicon later.
public final class DestinationIdentityResolver {
    public typealias AppLookup = (pid_t) -> DestinationAppInfo?
    public typealias WindowLookup = (AXUIElement?) -> DestinationWindowInfo

    private let appLookup: AppLookup
    private let windowLookup: WindowLookup
    private let favicons: FaviconSource
    private let ownBundleID: String?

    public init(appLookup: @escaping AppLookup = DestinationIdentityResolver.runningApp,
                windowLookup: @escaping WindowLookup = DestinationIdentityResolver.axWindowInfo,
                favicons: FaviconSource = FaviconPipeline.live(),
                ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.appLookup = appLookup
        self.windowLookup = windowLookup
        self.favicons = favicons
        self.ownBundleID = ownBundleID
    }

    public func resolve(pid: pid_t, axWindow: AXUIElement?) -> DestinationIdentity? {
        guard let app = appLookup(pid),
              let name = PillDestination.name(localizedName: app.name, bundleID: app.bundleID, ownBundleID: ownBundleID)
        else { return nil }
        guard KnownBrowser.isBrowser(app.bundleID) else {
            return DestinationIdentity(appIcon: app.icon, appName: name, bundleID: app.bundleID)
        }
        let window = windowLookup(axWindow)
        let host = Self.host(of: window.url)
        let title = Self.tabTitle(window.title, browserName: name, host: host)
        let icon = host.flatMap { favicons.cachedFavicon(host: $0, browserBundleID: app.bundleID) }
        return DestinationIdentity(appIcon: app.icon, appName: name, isBrowser: true, siteFavicon: icon,
                                   tabTitle: title, siteHost: host, bundleID: app.bundleID)
    }

    /// Completes a browser identity's favicon (network fetch of the host's /favicon.ico when nothing is cached).
    public func resolveFavicon(for identity: DestinationIdentity) async -> DestinationIdentity {
        guard identity.isBrowser, identity.siteFavicon == nil, let host = identity.siteHost else { return identity }
        var out = identity
        out.siteFavicon = await favicons.fetchFavicon(host: host, browserBundleID: identity.bundleID)
        return out
    }

    // MARK: Pure helpers

    /// Only http(s) hosts; lower-cased; nil for file:, about:, data: and the like.
    static func host(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// The AX window title with the browser's suffix stripped ("Inbox - Google Chrome" → "Inbox"). A title
    /// that is a URL or the bare host is dropped — the notch never shows the URL.
    static func tabTitle(_ raw: String?, browserName: String, host: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        for sep in [" - ", " — ", " – "] {
            for suffix in [browserName, "Google Chrome", "Brave", "Microsoft Edge", "Mozilla Firefox", "Arc", "Vivaldi", "Opera"] {
                if t.hasSuffix(sep + suffix) { t = String(t.dropLast(sep.count + suffix.count)) }
            }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t == browserName { return nil }
        let lower = t.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return nil }
        if let host, lower == host || lower.hasPrefix(host + "/") { return nil }
        if !lower.contains(" "), lower.contains("."), lower.contains("/") { return nil }
        return t
    }

    // MARK: Live lookups

    public static func runningApp(_ pid: pid_t) -> DestinationAppInfo? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return DestinationAppInfo(name: app.localizedName, bundleID: app.bundleIdentifier, icon: app.icon)
    }

    public static func axWindowInfo(_ window: AXUIElement?) -> DestinationWindowInfo {
        guard let window else { return DestinationWindowInfo(title: nil, url: nil) }
        let title = stringAttr(window, kAXTitleAttribute)
        var url = urlAttr(window, kAXDocumentAttribute)
        if url == nil { url = webAreaURL(in: window, depth: 0, budget: 60) }
        return DestinationWindowInfo(title: title, url: url)
    }

    /// The focused window of `pid` (for callers that have only the pid).
    /// K18 — through `AXGuard`: never an AX root for our own pid (off-main own-pid AX deadlocks, FX1).
    public static func focusedWindow(pid: pid_t) -> AXUIElement? {
        guard let app = AXGuard.application(pid: pid) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttr(_ el: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func urlAttr(_ el: AXUIElement, _ name: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if let u = value as? URL { return u }
        if let s = value as? String { return URL(string: s) }
        return nil
    }

    /// Bounded walk for the first AXWebArea and its AXURL (Chromium exposes the page URL there).
    private static func webAreaURL(in el: AXUIElement, depth: Int, budget: Int) -> URL? {
        var remaining = budget
        var queue: [(AXUIElement, Int)] = [(el, depth)]
        while !queue.isEmpty, remaining > 0 {
            let (node, d) = queue.removeFirst()
            remaining -= 1
            if stringAttr(node, kAXRoleAttribute) == "AXWebArea" { return urlAttr(node, "AXURL") }
            guard d < 8 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.prefix(12).map { ($0, d + 1) })
            }
        }
        return nil
    }
}
