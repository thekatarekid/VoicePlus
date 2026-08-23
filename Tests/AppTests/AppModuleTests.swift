import Shared
import Testing
@testable import VoicePlusApp

@Test func sharedIsReachableFromApp() {
    #expect(!SharedModule.version.isEmpty)
    #expect(VoicePlusAppModule.name == "VoicePlusApp")
}
