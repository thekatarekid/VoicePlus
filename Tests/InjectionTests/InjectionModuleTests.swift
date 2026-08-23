import Foundation
import Testing
import Shared
@testable import Injection

@Test func injectionModuleName() {
    #expect(InjectionModule.name == "Injection")
}

// MARK: - Helpers

func focus(_ bundleID: String, pid: Int32 = 100, token: String? = "el-1") -> FocusSnapshot {
    FocusSnapshot(pid: pid, bundleID: bundleID, appName: bundleID, elementToken: token)
}

func makeStack(_ bundleID: String = "com.apple.TextEdit", value: String = "", configure: (MockSystemAccess) -> Void = { _ in })
    -> (TextInjector, MockSystemAccess, InMemoryOutcomeStore) {
    let mock = MockSystemAccess(frontmost: focus(bundleID))
    mock.field = MockSystemAccess.Field(value: value)
    configure(mock)
    let store = InMemoryOutcomeStore()
    let injector = TextInjector(system: mock, store: store)
    return (injector, mock, store)
}
