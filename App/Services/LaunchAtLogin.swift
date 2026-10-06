import AppKit
import Foundation
import ServiceManagement
import Shared

// MARK: - Open VoicePlus at login (SMAppService.mainApp, macOS 13+)
//
// Default ON: the first launch of a build that has this service registers the main app as a login
// item unless the user has already turned it off. The user's choice is persisted
// (`loginItem.userChoice`) and wins from then on. The status shown is always the real
// `SMAppService.status`, including `.requiresApproval` (turned off in System Settings › General ›
// Login Items), which gets an "Open Login Items" button.
//
// Caveats (ad-hoc signed build): a login item records *this* bundle's path, so registration only
// makes sense for the copy in /Applications (or ~/Applications). A copy run from the DMG, a
// translocated copy, or a build product is reported `unavailable` with the reason instead.
//
// Launch at login is quiet by construction: VoicePlus is an LSUIElement (menu bar only) and opens
// no window at launch unless onboarding is unfinished.

/// The four `SMAppService.Status` values, as a plain enum the tests can produce.
public enum LoginItemStatus: String, Equatable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound
}

/// The slice of `SMAppService` VoicePlus uses (protocol so tests can mock it).
public protocol LoginItemRegistering: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// The live `SMAppService.mainApp`.
public final class SystemLoginItemRegistrar: LoginItemRegistering {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }
    public func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// Where this copy of VoicePlus runs from, and whether it may register itself as a login item.
public enum LoginItemLocation: Equatable, Sendable {
    case installed
    case notBundled
    case translocated
    case diskImage
    case notInApplications

    public var isUsable: Bool { self == .installed }

    public static func classify(bundleURL: URL, bundleIdentifier: String?,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LoginItemLocation {
        guard bundleIdentifier != nil, bundleURL.pathExtension == "app" else { return .notBundled }
        let path = bundleURL.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent().path
        let userApps = home.appendingPathComponent("Applications").standardizedFileURL.path
        if parent == "/Applications" || parent == userApps { return .installed }
        return .notInApplications
    }

    public static var current: LoginItemLocation {
        classify(bundleURL: Bundle.main.bundleURL, bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}

/// What the Settings row shows.
public enum LoginItemState: Equatable, Sendable {
    case on
    case off
    /// Registered, but switched off in System Settings › General › Login Items.
    case requiresApproval
    case unavailable(LoginItemLocation)
}

public struct LoginItemNotSaved: Error, Equatable {
    public let reason: String
}

@MainActor
public final class LoginItemService: ObservableObject {
    public static let shared = LoginItemService()

    /// The user's explicit choice; absent = never chosen (default ON).
    static let choiceKey = "loginItem.userChoice"
    /// Set once the default-ON registration has been attempted, so it happens once per install.
    static let defaultAppliedKey = "loginItem.defaultApplied"

    private let registrar: LoginItemRegistering
    private let defaults: UserDefaults
    public let location: LoginItemLocation

    @Published public private(set) var state: LoginItemState = .off

    public init(registrar: LoginItemRegistering = SystemLoginItemRegistrar(),
                defaults: UserDefaults = .standard,
                location: LoginItemLocation = .current) {
        self.registrar = registrar
        self.defaults = defaults
        self.location = location
        refresh()
    }

    /// The persisted choice; `nil` when the user never touched the toggle.
    public var userChoice: Bool? {
        defaults.object(forKey: Self.choiceKey) == nil ? nil : defaults.bool(forKey: Self.choiceKey)
    }

    /// What the user wants: their choice, or ON by default.
    public var wantsOpenAtLogin: Bool { userChoice ?? true }

    public var isAvailable: Bool { location.isUsable }

    /// The toggle's value: on while registered (approved or awaiting approval).
    public var isOn: Bool {
        switch state {
        case .on, .requiresApproval: return true
        case .off, .unavailable: return false
        }
    }

    public func refresh() {
        guard location.isUsable else { state = .unavailable(location); return }
        switch registrar.status {
        case .enabled: state = .on
        case .requiresApproval: state = .requiresApproval
        case .notRegistered, .notFound: state = .off
        }
    }

    /// Launch hook: register by default once (unless the user turned it off), re-register when the
    /// user chose ON but the item went missing (app replaced/moved back), unregister when the user
    /// chose OFF. A `.requiresApproval` item is left to the user (they switched it off in System
    /// Settings; re-registering would not override that).
    public func applyOnLaunch() {
        guard location.isUsable else {
            Log.app.info("login item: skipped, location=\(String(describing: self.location))")
            refresh()
            return
        }
        let status = registrar.status
        let choice = userChoice
        let defaultApplied = defaults.bool(forKey: Self.defaultAppliedKey)
        do {
            switch (choice, status) {
            case (false, .enabled), (false, .requiresApproval):
                try registrar.unregister()
                Log.app.notice("login item: unregistered (user chose off)")
            case (true, .notRegistered), (true, .notFound):
                try registrar.register()
                Log.app.notice("login item: re-registered (user chose on)")
            case (nil, .notRegistered), (nil, .notFound):
                if !defaultApplied {
                    try registrar.register()
                    Log.app.notice("login item: registered by default")
                }
            default:
                break
            }
        } catch {
            Log.app.error("login item: launch apply failed: \(error)")
        }
        if choice == nil { defaults.set(true, forKey: Self.defaultAppliedKey) }
        refresh()
        Log.app.info("login item: status=\(self.registrar.status.rawValue) choice=\(choice.map(String.init) ?? "default")")
    }

    /// The Settings / onboarding toggle. Persists the choice even when SMAppService refuses, so the
    /// next launch retries it; throws so the row can show the failure.
    public func setEnabled(_ on: Bool) throws {
        defaults.set(on, forKey: Self.choiceKey)
        defer { refresh() }
        guard location.isUsable else {
            throw LoginItemNotSaved(reason: LoginItemCopy.unavailableDetail(location))
        }
        do {
            if on {
                if registrar.status != .enabled { try registrar.register() }
            } else if registrar.status == .enabled || registrar.status == .requiresApproval {
                try registrar.unregister()
            }
        } catch {
            Log.app.error("login item: set(\(on)) failed: \(error)")
            throw LoginItemNotSaved(reason: error.localizedDescription)
        }
    }

    public func openLoginItemsSettings() { registrar.openSystemSettingsLoginItems() }
}

/// Copy for the Settings row and onboarding checkbox.
public enum LoginItemCopy {
    public static let title = "Open at login"
    public static let onboardingCheckbox = "Open VoicePlus at login"
    public static let onDetail = "VoicePlus starts quietly in the menu bar when you log in."
    public static let offDetail = "Start VoicePlus yourself after you log in."
    public static let requiresApprovalDetail = "Allow in System Settings › General › Login Items."
    public static let openLoginItems = "Open Login Items"

    public static func detail(_ state: LoginItemState) -> String {
        switch state {
        case .on: return onDetail
        case .off: return offDetail
        case .requiresApproval: return requiresApprovalDetail
        case .unavailable(let location): return unavailableDetail(location)
        }
    }

    public static func unavailableDetail(_ location: LoginItemLocation) -> String {
        switch location {
        case .installed: return onDetail
        case .notBundled:
            return "Only a VoicePlus that is running from an .app bundle can open at login."
        case .translocated, .diskImage:
            return "Move VoicePlus to the Applications folder and open it from there to open it at login."
        case .notInApplications:
            return "Only the copy in the Applications folder can open at login."
        }
    }
}

/// Compatibility facade for the menu model and older callers.
public enum LaunchAtLogin {
    public static var isAvailable: Bool { LoginItemLocation.current.isUsable }
    public static var isEnabled: Bool { isAvailable && SystemLoginItemRegistrar().status == .enabled }
}
