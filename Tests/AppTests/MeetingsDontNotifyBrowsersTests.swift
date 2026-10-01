import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// V5 M-d follow-up — Settings › Meetings' "Don't notify" list offers every browser the tab signal
/// recognises (not a hand-picked six).
@Suite("Meetings settings: don't-notify browsers (M-d)")
struct MeetingsDontNotifyBrowsersTests {
    @Test @MainActor func listOffersEveryRecognisedBrowserOnce() {
        let ids = MeetingsSettingsModel.notifiableApps.map(\.id)
        #expect(BrowserMeetingClassifier.browserBundleIDs.isSubset(of: Set(ids)))
        #expect(Set(ids).count == ids.count, "no duplicates")
    }
}
