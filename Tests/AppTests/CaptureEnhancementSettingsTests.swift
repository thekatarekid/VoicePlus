import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 C1/C1b — Settings › Voice "Noise and echo reduction": the choice is stored, LocalVQE fetches
/// its weights first, and a failed download leaves capture exactly as it was.
@Suite("V5 C1/C1b — Settings › Voice noise and echo reduction")
@MainActor
struct CaptureEnhancementSettingsTests {
    final class FakeInstaller: LocalVQEInstalling, @unchecked Sendable {
        var installed: Bool
        var fails: Bool
        var installs = 0
        init(installed: Bool, fails: Bool = false) { self.installed = installed; self.fails = fails }
        func isInstalled() async -> Bool { installed }
        func install() async throws {
            installs += 1
            if fails { throw URLError(.notConnectedToInternet) }
            installed = true
        }
    }

    private func defaults() -> UserDefaults {
        let name = "c1.settings.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultIsOffAndAllThreeAreSelectable() {
        let model = CaptureEnhancementViewModel(defaults: defaults(), installer: FakeInstaller(installed: false))
        #expect(model.selection == .off)
        #expect(model.options == [.off, .appleVoiceProcessing, .localVQE])
        #expect(CaptureEnhancement.appleVoiceProcessing.title == "Noise and echo reduction (Apple)")
    }

    @Test func choosingAppleStoresItAndAnnouncesTheChange() async {
        let d = defaults()
        let model = CaptureEnhancementViewModel(defaults: d, installer: FakeInstaller(installed: false))
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: CaptureEnhancement.didChangeNotification,
                                                           object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        await model.select(.appleVoiceProcessing)
        #expect(model.selection == .appleVoiceProcessing)
        #expect(CaptureEnhancement.current(defaults: d, environment: [:]) == .appleVoiceProcessing)
        #expect(posted >= 1)
    }

    @Test func localVQEDownloadsFirstThenSwitches() async {
        let d = defaults()
        let installer = FakeInstaller(installed: false)
        let model = CaptureEnhancementViewModel(defaults: d, installer: installer)
        await model.select(.localVQE)
        #expect(installer.installs == 1)
        #expect(model.selection == .localVQE)
        #expect(CaptureEnhancement.current(defaults: d, environment: [:]) == .localVQE)
    }

    @Test func failedDownloadLeavesCaptureAsItWas() async {
        let d = defaults()
        let model = CaptureEnhancementViewModel(defaults: d, installer: FakeInstaller(installed: false, fails: true))
        await model.select(.localVQE)
        #expect(model.selection == .off)
        #expect(CaptureEnhancement.current(defaults: d, environment: [:]) == .off)
        #expect(model.note == CaptureEnhancementCopy.downloadFailed)
        #expect(!model.installing)
    }
}
