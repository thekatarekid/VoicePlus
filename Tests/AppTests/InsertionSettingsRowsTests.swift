import Foundation
import Testing
@testable import VoicePlusApp

/// V5 W1 Lane 1b settings rows: Q2 "Expose text in Chromium browsers" (default on) and Q14
/// "Confirm in apps that hide their text (uses Screen Recording)" (default off), indexed in
/// `SettingsReachability` (whose reachability test proves the markers are on screen).
@Suite("Insertion settings rows (V5 Q2/Q14)")
struct InsertionSettingsRowsTests {
    private func defaults() -> UserDefaults {
        let name = "InsertionSettingsRowsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsAreChromiumOnScreenRecordingOff() {
        let d = defaults()
        #expect(InsertionSettings.exposeChromiumText(d) == true)
        #expect(InsertionSettings.confirmHiddenText(d) == false)
        d.set(false, forKey: InsertionSettings.exposeChromiumTextKey)
        d.set(true, forKey: InsertionSettings.confirmHiddenTextKey)
        #expect(InsertionSettings.exposeChromiumText(d) == false)
        #expect(InsertionSettings.confirmHiddenText(d) == true)
    }

    /// The Q2 reader in `Injection` uses this exact key (`InjectionSettingsKeys.exposeChromiumText`).
    @Test func chromiumKeyMatchesTheInjectionReader() {
        #expect(InsertionSettings.exposeChromiumTextKey == "injection.exposeChromiumText")
    }

    @Test func bothRowsAreIndexedOnSettingsGeneral() throws {
        for marker in ["settings.insertion.exposeChromiumText", "settings.insertion.confirmHiddenText"] {
            let item = try #require(SettingsReachability.newlySurfaced.first { $0.marker == marker })
            #expect(item.home == .settings)
            #expect(item.subpage == .general)
        }
        #expect(InsertionSettings.confirmHiddenTitle == "Confirm in apps that hide their text (uses Screen Recording)")
        #expect(InsertionSettings.exposeChromiumTitle == "Expose text in Chromium browsers")
    }
}
