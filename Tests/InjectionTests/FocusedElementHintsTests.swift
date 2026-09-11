import Foundation
import Testing
import Shared
@testable import Injection

/// R4.2 wiring — `FocusedElementInfo.hints`, the four descriptive AX attributes that let
/// `Pipeline`'s `FieldRole.classify` tell a terminal *inside* an editor from the editor.
///
/// The mapping from the live accessibility tree to these strings cannot be exercised here (there is
/// no accessibility permission and no window server in this environment), so these tests pin the
/// normalization and the `SystemAccess` contract; `LiveSystemAccess.hints(of:)` is the unverified
/// part and is called out as such.
@Suite struct FocusedElementHintsTests {

    // MARK: All four attributes

    @Test func hintsCarryAllFourAttributesInOrder() {
        let hints = FocusedElementInfo.hints(from: ["terminal-input-1",     // AXIdentifier
                                                   "Terminal input",        // AXDescription
                                                   "zsh",                   // AXTitle
                                                   "text area"])            // AXRoleDescription
        #expect(hints == ["terminal-input-1", "Terminal input", "zsh", "text area"])
        #expect(FocusedElementInfo.hintAttributes ==
                ["AXIdentifier", "AXDescription", "AXTitle", "AXRoleDescription"])
    }

    @Test func theMockReportsEveryHintItIsGiven() throws {
        let mock = MockSystemAccess(frontmost: focus("com.microsoft.VSCode"))
        mock.field = MockSystemAccess.Field(role: "AXTextArea", hints: FocusedElementHintsTests.fourAttributes)
        let info = try mock.focusedElement()
        #expect(info.hints == FocusedElementHintsTests.fourAttributes)
        #expect(info.hints.count == 4)
    }

    static let fourAttributes = ["vscode-terminal", "Terminal input", "bash", "text area"]

    // MARK: Degrading

    @Test func absentAttributesDegradeToAnEmptyListWithoutError() throws {
        #expect(FocusedElementInfo.hints(from: [nil, nil, nil, nil]).isEmpty)
        #expect(FocusedElementInfo.hints(from: []).isEmpty)
        // The default: nothing was read, nothing is claimed.
        let bare = FocusedElementInfo(role: "AXTextField", value: "", selectedRange: 0..<0,
                                      isValueSettable: true, isSelectedTextSettable: true)
        #expect(bare.hints.isEmpty)
        // A mock field that was never given hints behaves the same, and still reads back fine.
        let mock = MockSystemAccess(frontmost: focus("com.apple.TextEdit"))
        mock.field = MockSystemAccess.Field(value: "hello")
        let info = try mock.focusedElement()
        #expect(info.hints.isEmpty)
        #expect(info.value == "hello")
    }

    @Test func partialAttributesKeepOnlyWhatWasThere() {
        #expect(FocusedElementInfo.hints(from: [nil, "Monaco editor", nil, "text area"])
                == ["Monaco editor", "text area"])
    }

    @Test func blankAndDuplicateAttributesAreDropped() {
        // An element whose title and role description are both "Terminal" contributes one hint,
        // and "   " is not a hint at all.
        #expect(FocusedElementInfo.hints(from: ["", "   ", "Terminal", "Terminal"]) == ["Terminal"])
        #expect(FocusedElementInfo.hints(from: [" Terminal input\n", "Terminal input"]) == ["Terminal input"])
    }

    // MARK: Secure fields still refuse (R2.3 + R4.2 agree)

    @Test("a password field is still refused, hints or no hints", arguments: [false, true])
    func secureFieldStillRefuses(webStyle: Bool) throws {
        let (injector, mock, _) = makeStack("com.apple.Safari") {
            $0.field = .secure(webStyle: webStyle)
            // A real password field is chatty: it has a label, and none of it changes the verdict.
            $0.field.hints = ["password", "Password", "secure text field"]
        }
        let info = try mock.focusedElement()
        #expect(info.isSecure)
        #expect(info.hints == ["password", "Password", "secure text field"])
        #expect(injector.inject(InjectionRequest(text: "hunter2", expectedFocus: mock.frontmost))
                == .refused(.secureField))
        #expect(mock.postCount == 0)
        #expect(mock.journal.isEmpty)
        #expect(mock.field.value == "")
        #expect(injector.focusGuard.held.isEmpty)
    }

    @Test func aTerminalHintNeverTurnsASecureFieldIntoSomethingInjectable() {
        // Belt and braces: the hint that *does* change formatting must not change the refusal.
        let (injector, mock, _) = makeStack("com.microsoft.VSCode") {
            $0.field = .secure()
            $0.field.hints = ["Terminal input"]
        }
        #expect(injector.inject(InjectionRequest(text: "sudo rm -rf /", expectedFocus: mock.frontmost))
                == .refused(.secureField))
        #expect(mock.postCount == 0)
    }
}
