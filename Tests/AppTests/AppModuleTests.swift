import Shared
import Testing

@Test func sharedIsReachableFromApp() {
    #expect(!SharedModule.version.isEmpty)
}
