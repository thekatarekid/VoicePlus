import Foundation
import Testing
import Shared
@testable import Injection

/// N9-integrate / N24 verify — the live landing builds `InjectionRequest` without a surface, so
/// the injector resolves one from its own live evidence. These run with no `surfaceKind` passed.
@Suite struct InferredSurfaceVerifyTests {
    static let tsv = "Name\tQty\nApples\t3\nPears\t5"

    @Test func sheetsCellInWebAreaGetsRichTableWithoutACallerSurface() {
        let (injector, mock, _) = makeStack("com.unknown.Browser") {
            $0.inWebArea = true
            $0.documentURL = "https://docs.google.com/spreadsheets/d/abc/edit"
            $0.field = MockSystemAccess.Field(role: "AXCell")
        }
        _ = injector.inject(InjectionRequest(text: Self.tsv, expectedFocus: mock.frontmost))
        #expect(mock.pasteboardWrites.last?.types[RichPaste.htmlType] != nil, "\(mock.journal)")
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
    }

    @Test func plainNativeFieldStaysProseAndAXFirst() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        _ = injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
        #expect(mock.pasteboardWrites.allSatisfy { $0.types[RichPaste.htmlType] == nil })
        #expect(mock.field.value == "hello")
    }

    @Test func passwordLabelledTextFieldIsRefusedNotHeld() {
        let (injector, mock, _) = makeStack("com.unknown.Login") {
            $0.field = MockSystemAccess.Field(role: "AXTextField", hints: ["Password"])
        }
        let outcome = injector.inject(InjectionRequest(text: "hunter2", expectedFocus: mock.frontmost))
        #expect(outcome == .refused(.secureField), "\(outcome)")
        #expect(mock.postCount == 0)
        #expect(injector.focusGuard.held.isEmpty)
    }

    @Test func callerSurfaceStillWins() {
        let (injector, mock, _) = makeStack("com.unknown.Grid")
        _ = injector.inject(InjectionRequest(text: Self.tsv, expectedFocus: mock.frontmost, surfaceKind: .prose))
        #expect(mock.pasteboardWrites.allSatisfy { $0.types[RichPaste.htmlType] == nil })
    }
}
