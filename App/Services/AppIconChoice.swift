import AppKit
import Foundation
import SwiftUI

// MARK: - App icon (Settings › General › App icon)
//
// The app icon is Spool, the notch cassette. The bundle ships two renders (Packaging/icon/):
// `AppIcon.icns` — Spool *uncertain* (tilted, one eyelid down, a lopsided smirk), the default and
// `CFBundleIconFile` — and `AppIcon-Ready.icns` — Spool *ready* (upright, calm smile).
//
// Choosing Ready sets the running app's icon (About panel, alerts) and gives the bundle a Finder
// custom icon (`NSWorkspace.setIcon`), which Finder, Spotlight and Launchpad show. Choosing
// Uncertain removes the custom icon, so the bundle's own icon shows again. An update replaces the
// bundle and drops the custom icon; `applyAtLaunch()` puts it back.
//
// Caveat: a Finder custom icon is an `Icon\r` file in the bundle root, which `codesign --verify
// --strict` reports as unsealed content. It does not change the executable's cdhash, so the
// ad-hoc TCC grants (keyed on it) are unaffected. A read-only copy (DMG, translocated) just
// keeps the bundle icon.

public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case uncertain, ready

    public static let defaultsKey = "appIcon.choice"
    /// The bundle's own icon (`CFBundleIconFile` = AppIcon).
    public static let bundleDefault: AppIconChoice = .uncertain

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .uncertain: return "Spool, curious"
        case .ready: return "Spool, ready"
        }
    }

    /// The `.icns` in Contents/Resources.
    public var resourceName: String {
        switch self {
        case .uncertain: return "AppIcon"
        case .ready: return "AppIcon-Ready"
        }
    }

    /// What the bundle needs so Finder shows this choice, given whether it has a custom icon now.
    public enum FinderAction: Equatable, Sendable { case none, setCustomIcon, removeCustomIcon }

    public func finderAction(hasCustomIcon: Bool) -> FinderAction {
        if self == Self.bundleDefault { return hasCustomIcon ? .removeCustomIcon : .none }
        return .setCustomIcon
    }

    /// At launch only a missing custom icon is (re)written; an existing one is left alone.
    public func launchFinderAction(hasCustomIcon: Bool) -> FinderAction {
        let action = finderAction(hasCustomIcon: hasCustomIcon)
        return action == .setCustomIcon && hasCustomIcon ? .none : action
    }
}

public enum AppIconCopy {
    public static let title = "App icon"
    public static let detail = "The icon Finder, Spotlight and the About panel show for VoicePlus."
    public static func failed(_ path: String) -> String {
        "Couldn’t change the Finder icon: \(path) isn’t writable. The running app uses it anyway."
    }
}

@MainActor
public final class AppIconService: ObservableObject {
    public static let shared = AppIconService()

    @Published public private(set) var choice: AppIconChoice
    @Published public private(set) var failure: String?

    private let defaults: UserDefaults
    private let bundle: Bundle

    public init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        self.bundle = bundle
        choice = defaults.string(forKey: AppIconChoice.defaultsKey).flatMap(AppIconChoice.init(rawValue:))
            ?? AppIconChoice.bundleDefault
    }

    public func select(_ newChoice: AppIconChoice) {
        choice = newChoice
        defaults.set(newChoice.rawValue, forKey: AppIconChoice.defaultsKey)
        apply(newChoice.finderAction(hasCustomIcon: hasCustomIcon))
    }

    public func applyAtLaunch() {
        apply(choice.launchFinderAction(hasCustomIcon: hasCustomIcon))
    }

    private var isBundled: Bool { bundle.bundleURL.pathExtension == "app" }

    /// Finder's custom-icon file for a folder or bundle.
    private var hasCustomIcon: Bool {
        isBundled && FileManager.default.fileExists(atPath: bundle.bundleURL.appendingPathComponent("Icon\r").path)
    }

    private func image(for choice: AppIconChoice) -> NSImage? {
        bundle.url(forResource: choice.resourceName, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }

    private func apply(_ action: AppIconChoice.FinderAction) {
        guard isBundled, let image = image(for: choice) else { return }
        NSApp.applicationIconImage = image
        let path = bundle.bundlePath
        var ok = true
        switch action {
        case .none: break
        case .setCustomIcon: ok = NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        case .removeCustomIcon: ok = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        }
        failure = ok ? nil : AppIconCopy.failed(path)
        if action != .none { NSWorkspace.shared.noteFileSystemChanged(path) }
    }
}

/// Settings › General "App icon" row.
struct AppIconRow: View {
    @ObservedObject var service: AppIconService = .shared

    var body: some View {
        SettingsPickerRow(title: AppIconCopy.title, detail: service.failure ?? AppIconCopy.detail,
                          selection: Binding(get: { service.choice }, set: { service.select($0) }),
                          options: AppIconChoice.allCases, label: \.title, identifier: "settings.appIcon")
    }
}
