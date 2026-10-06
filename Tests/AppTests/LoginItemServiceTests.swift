import Foundation
import Testing
@testable import VoicePlusApp

/// Open at login (`LoginItemService`) against a mock `SMAppService`.
@MainActor
@Suite("LoginItemService")
struct LoginItemServiceTests {

    final class MockRegistrar: LoginItemRegistering {
        var status: LoginItemStatus
        var registerCalls = 0
        var unregisterCalls = 0
        var openedSettings = 0
        var failNext = false
        /// What `register()` leaves behind (`.requiresApproval` when the user must approve).
        var statusAfterRegister: LoginItemStatus = .enabled

        init(_ status: LoginItemStatus) { self.status = status }

        struct Refused: Error {}
        func register() throws {
            registerCalls += 1
            if failNext { failNext = false; throw Refused() }
            status = statusAfterRegister
        }
        func unregister() throws {
            unregisterCalls += 1
            if failNext { failNext = false; throw Refused() }
            status = .notRegistered
        }
        func openSystemSettingsLoginItems() { openedSettings += 1 }
    }

    static func defaults() -> UserDefaults {
        let name = "LoginItemServiceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("first launch registers by default, once")
    func defaultOnRegistersOnce() {
        let mock = MockRegistrar(.notRegistered)
        let d = Self.defaults()
        let service = LoginItemService(registrar: mock, defaults: d, location: .installed)
        #expect(service.state == .off)
        service.applyOnLaunch()
        #expect(mock.registerCalls == 1)
        #expect(service.state == .on && service.isOn)
        #expect(service.userChoice == nil)

        // Switched off in System Settings (now notRegistered) with no explicit choice: do not fight it.
        mock.status = .notRegistered
        LoginItemService(registrar: mock, defaults: d, location: .installed).applyOnLaunch()
        #expect(mock.registerCalls == 1)
    }

    @Test("a refused default registration is retried on the next launch, then spent")
    func refusedDefaultRetries() {
        let mock = MockRegistrar(.notRegistered)
        mock.failNext = true
        let d = Self.defaults()
        LoginItemService(registrar: mock, defaults: d, location: .installed).applyOnLaunch()
        #expect(mock.registerCalls == 1 && mock.status == .notRegistered)
        let service = LoginItemService(registrar: mock, defaults: d, location: .installed)
        service.applyOnLaunch()
        #expect(mock.registerCalls == 2 && service.state == .on)
        #expect(service.userChoice == nil)
        mock.status = .notRegistered   // later switched off in System Settings: left alone
        LoginItemService(registrar: mock, defaults: d, location: .installed).applyOnLaunch()
        #expect(mock.registerCalls == 2)
    }

    @Test("an opt-out made before the default ran (onboarding checkbox) is respected")
    func earlyOptOutRespected() throws {
        let mock = MockRegistrar(.notRegistered)
        let d = Self.defaults()
        let service = LoginItemService(registrar: mock, defaults: d, location: .installed)
        try service.setEnabled(false)
        service.applyOnLaunch()
        #expect(mock.registerCalls == 0 && service.state == .off && service.userChoice == false)
    }

    @Test("an unusable copy does not spend the default for the installed copy")
    func unusableCopyKeepsDefault() {
        let mock = MockRegistrar(.notRegistered)
        let d = Self.defaults()
        LoginItemService(registrar: mock, defaults: d, location: .diskImage).applyOnLaunch()
        #expect(mock.registerCalls == 0)
        LoginItemService(registrar: mock, defaults: d, location: .installed).applyOnLaunch()
        #expect(mock.registerCalls == 1 && mock.status == .enabled)
    }

    @Test("the user's OFF choice persists and wins at launch")
    func userOffWins() throws {
        let mock = MockRegistrar(.notRegistered)
        let d = Self.defaults()
        let service = LoginItemService(registrar: mock, defaults: d, location: .installed)
        service.applyOnLaunch()
        try service.setEnabled(false)
        #expect(mock.unregisterCalls == 1 && service.state == .off)
        #expect(service.userChoice == false)

        // Somehow registered again (old build's toggle): the next launch honours OFF.
        mock.status = .enabled
        let next = LoginItemService(registrar: mock, defaults: d, location: .installed)
        next.applyOnLaunch()
        #expect(mock.unregisterCalls == 2 && next.state == .off)
    }

    @Test("an explicit ON re-registers when the item went missing")
    func userOnReRegisters() throws {
        let mock = MockRegistrar(.notRegistered)
        let d = Self.defaults()
        let service = LoginItemService(registrar: mock, defaults: d, location: .installed)
        try service.setEnabled(true)
        #expect(mock.registerCalls == 1 && service.userChoice == true)
        mock.status = .notFound
        LoginItemService(registrar: mock, defaults: d, location: .installed).applyOnLaunch()
        #expect(mock.registerCalls == 2)
    }

    @Test("requiresApproval is shown with the Login Items button and left to the user")
    func requiresApproval() {
        let mock = MockRegistrar(.requiresApproval)
        let service = LoginItemService(registrar: mock, defaults: Self.defaults(), location: .installed)
        service.applyOnLaunch()
        #expect(mock.registerCalls == 0 && mock.unregisterCalls == 0)
        #expect(service.state == .requiresApproval && service.isOn)
        #expect(LoginItemCopy.detail(service.state).contains("System Settings › General › Login Items"))
        service.openLoginItemsSettings()
        #expect(mock.openedSettings == 1)
    }

    @Test("register that needs approval reports requiresApproval")
    func registerNeedsApproval() throws {
        let mock = MockRegistrar(.notRegistered)
        mock.statusAfterRegister = .requiresApproval
        let service = LoginItemService(registrar: mock, defaults: Self.defaults(), location: .installed)
        try service.setEnabled(true)
        #expect(service.state == .requiresApproval)
    }

    @Test("a refused change throws but keeps the user's choice for the next launch")
    func refusedChange() {
        let mock = MockRegistrar(.notRegistered)
        mock.failNext = true
        let d = Self.defaults()
        let service = LoginItemService(registrar: mock, defaults: d, location: .installed)
        #expect(throws: LoginItemNotSaved.self) { try service.setEnabled(true) }
        #expect(service.state == .off && service.userChoice == true)
        LoginItemService(registrar: mock, defaults: d, location: .installed).applyOnLaunch()
        #expect(mock.status == .enabled)
    }

    @Test("a DMG, translocated or stray copy never registers and says why")
    func unusableLocations() {
        for location in [LoginItemLocation.diskImage, .translocated, .notInApplications, .notBundled] {
            let mock = MockRegistrar(.notRegistered)
            let service = LoginItemService(registrar: mock, defaults: Self.defaults(), location: location)
            service.applyOnLaunch()
            #expect(mock.registerCalls == 0)
            #expect(service.state == .unavailable(location) && !service.isAvailable && !service.isOn)
            #expect(throws: LoginItemNotSaved.self) { try service.setEnabled(true) }
            #expect(mock.registerCalls == 0)
            #expect(!LoginItemCopy.detail(service.state).isEmpty)
        }
    }

    @Test("location classification")
    func classify() {
        let home = URL(fileURLWithPath: "/Users/me")
        func c(_ path: String, id: String? = "in.adityakatare.voiceplus") -> LoginItemLocation {
            LoginItemLocation.classify(bundleURL: URL(fileURLWithPath: path), bundleIdentifier: id, home: home)
        }
        #expect(c("/Applications/VoicePlus.app") == .installed)
        #expect(c("/Users/me/Applications/VoicePlus.app") == .installed)
        #expect(c("/Volumes/VoicePlus/VoicePlus.app") == .diskImage)
        #expect(c("/private/var/folders/x/T/AppTranslocation/ABC/d/VoicePlus.app") == .translocated)
        #expect(c("/Users/me/Documents/VoiceInput/Packaging/build/VoicePlus.app") == .notInApplications)
        #expect(c("/Applications/VoicePlus.app", id: nil) == .notBundled)
        #expect(c("/usr/local/bin/voiceplus") == .notBundled)
        // swift test runs outside an .app bundle.
        #expect(!LoginItemLocation.current.isUsable)
    }
}
