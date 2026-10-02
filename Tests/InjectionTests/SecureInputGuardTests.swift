import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - N4 — macOS secure input before a blind write

@Suite struct SecureInputGuardTests {
    private func stack(_ configure: (MockSystemAccess) -> Void) -> (TextInjector, MockSystemAccess, InMemoryOutcomeStore) {
        let mock = MockSystemAccess()
        configure(mock)
        let store = InMemoryOutcomeStore()
        return (TextInjector(system: mock, store: store), mock, store)
    }

    @Test func secureInputOnWithUnreadableFieldRefusesAndPostsNothing() {
        let (injector, mock, _) = stack { $0.axReadable = false; $0.secureEventInput = true }
        let outcome = injector.inject(InjectionRequest(text: "hunter2", expectedFocus: mock.frontmost))
        #expect(outcome == .refused(.secureField))
        #expect(mock.postCount == 0)
        #expect(mock.journal.isEmpty)
        #expect(mock.field.value.isEmpty)
        #expect(injector.focusGuard.held.isEmpty)   // never held: it may be a secret
    }

    @Test func secureInputOnWithNoFocusedElementRefuses() {
        let (injector, mock, _) = stack { $0.hasFocusedElement = false; $0.secureEventInput = true }
        #expect(injector.inject(InjectionRequest(text: "x", expectedFocus: mock.frontmost)) == .refused(.secureField))
        #expect(mock.postCount == 0)
    }

    @Test func secureInputOffWithUnreadableFieldStillWrites() {
        let (injector, mock, _) = stack { $0.axReadable = false }
        let outcome = injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
        #expect(outcome.succeeded)
        #expect(mock.postCount > 0)
    }

    @Test func secureInputOnWithReadableNormalFieldWrites() {
        let (injector, mock, _) = stack { $0.secureEventInput = true }
        let outcome = injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
        #expect(outcome == .injected(method: .ax, verified: true))
        #expect(mock.field.value == "hello")
    }

    @Test(arguments: [false, true])
    func passwordFieldAlwaysRefused(webStyle: Bool) {
        let (injector, mock, _) = stack { $0.field = .secure(webStyle: webStyle) }
        #expect(injector.inject(InjectionRequest(text: "x", expectedFocus: mock.frontmost)) == .refused(.secureField))
        #expect(mock.postCount == 0)
    }

    private func info(_ role: String, _ value: String?, subrole: String? = nil) -> FocusedElementInfo {
        FocusedElementInfo(role: role, value: value, selectedRange: nil, isValueSettable: true,
                           isSelectedTextSettable: true, subrole: subrole)
    }

    // The pure check L3's pull-back calls before re-typing into the original window.
    @Test func blocksWriteTable() {
        let readable = info("AXTextArea", "a")
        let unreadable = info("AXTextArea", nil)
        let password = info(FocusedElementInfo.secureRole, nil)
        let webPassword = info("AXTextField", nil, subrole: FocusedElementInfo.secureRole)
        #expect(SecureInputGuard.blocksWrite(focused: readable, secureInput: false) == nil)
        #expect(SecureInputGuard.blocksWrite(focused: readable, secureInput: true) == nil)
        #expect(SecureInputGuard.blocksWrite(focused: unreadable, secureInput: false) == nil)
        #expect(SecureInputGuard.blocksWrite(focused: unreadable, secureInput: true) == .secureInputBlindWrite)
        #expect(SecureInputGuard.blocksWrite(focused: nil, secureInput: true) == .secureInputBlindWrite)
        #expect(SecureInputGuard.blocksWrite(focused: password, secureInput: false) == .passwordField)
        #expect(SecureInputGuard.blocksWrite(focused: webPassword, secureInput: false) == .passwordField)
    }

    @Test func probeReadsFlagFromSystemOrDefaultsOff() {
        let mock = MockSystemAccess()
        #expect(SecureInputGuard.isActive(on: mock) == false)
        mock.secureEventInput = true
        #expect(SecureInputGuard.isActive(on: mock) == true)
        #expect(SecureInputGuard.isActive(on: NSObject()) == false)
    }
}
