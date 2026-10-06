import Foundation
import Testing
@testable import VoicePlusApp

@Suite struct AppIconChoiceTests {
    @Test func uncertainIsTheBundleIcon() {
        #expect(AppIconChoice.bundleDefault == .uncertain)
        #expect(AppIconChoice.uncertain.resourceName == "AppIcon")
        #expect(AppIconChoice.ready.resourceName == "AppIcon-Ready")
    }

    @Test func finderActionOnSelect() {
        #expect(AppIconChoice.ready.finderAction(hasCustomIcon: false) == .setCustomIcon)
        #expect(AppIconChoice.ready.finderAction(hasCustomIcon: true) == .setCustomIcon)
        #expect(AppIconChoice.uncertain.finderAction(hasCustomIcon: true) == .removeCustomIcon)
        #expect(AppIconChoice.uncertain.finderAction(hasCustomIcon: false) == .none)
    }

    /// Launch never rewrites an icon that is already there; it restores one an update dropped.
    @Test func launchOnlyRepairs() {
        #expect(AppIconChoice.ready.launchFinderAction(hasCustomIcon: true) == .none)
        #expect(AppIconChoice.ready.launchFinderAction(hasCustomIcon: false) == .setCustomIcon)
        #expect(AppIconChoice.uncertain.launchFinderAction(hasCustomIcon: true) == .removeCustomIcon)
        #expect(AppIconChoice.uncertain.launchFinderAction(hasCustomIcon: false) == .none)
    }

    @MainActor @Test func choicePersistsAndUnbundledRunTouchesNothing() throws {
        let suite = "AppIconChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppIconService(defaults: defaults).choice == .uncertain)
        let service = AppIconService(defaults: defaults) // test runner: not an .app bundle
        service.select(.ready)
        #expect(service.failure == nil)
        #expect(AppIconService(defaults: defaults).choice == .ready)
        defaults.set("bogus", forKey: AppIconChoice.defaultsKey)
        #expect(AppIconService(defaults: defaults).choice == .uncertain)
    }
}
