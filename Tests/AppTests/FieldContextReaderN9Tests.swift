import Foundation
import Testing
import Injection
import Pipeline
import Shared
@testable import VoicePlusApp

/// N9-integrate — `FieldContextReader` feeds the live tree's evidence (editable, runtime) into the
/// resolver and knows browsers only from the seed table (no private list).
@Suite struct FieldContextReaderN9Tests {
    static func reader(_ bundle: String, field: MockSystemAccess.Field, settable: Bool = true,
                       runtime: SurfaceRuntime? = nil, web: Bool = false) -> (FieldContextReader, MockSystemAccess) {
        let mock = MockSystemAccess(frontmost: FocusSnapshot(pid: 77, bundleID: bundle, appName: bundle, elementToken: "e"))
        mock.field = field
        mock.axWriteWorks = settable
        mock.inWebArea = web
        if let runtime { mock.runtimeByPID[77] = runtime }
        return (FieldContextReader(system: mock), mock)
    }

    @Test func browsersComeFromTheSeedTable() {
        #expect(FieldContextReader.isBrowser("com.google.Chrome"))
        #expect(FieldContextReader.isBrowser("com.google.Chrome.canary"))
        #expect(FieldContextReader.isBrowser("com.apple.Safari"))
        #expect(!FieldContextReader.isBrowser("com.openai.chat"))
        #expect(!FieldContextReader.isBrowser(nil))
        for id in SeedHints.bundleIDs(.browser) { #expect(FieldContextReader.isBrowser(id)) }
    }

    @Test func canvasRoleWithNothingEditableResolvesCanvas() throws {
        let (r, _) = Self.reader("com.example.whiteboard", field: .init(role: "AXCanvas"), settable: false)
        let field = try #require(r.fieldContext(bundleID: "com.example.whiteboard"))
        #expect(field.surface.kind == .canvas)
        #expect(field.surface.refusesTyping)
    }

    @Test func editableTextIsNeverACanvas() throws {
        let (r, _) = Self.reader("com.example.whiteboard", field: .init(role: "AXCanvas"), settable: true)
        let field = try #require(r.fieldContext(bundleID: "com.example.whiteboard"))
        #expect(field.surface.kind != .canvas)
    }

    @Test func evidenceCarriesEditableAndRuntime() {
        let info = FocusedElementInfo(role: "AXTextArea", value: nil, selectedRange: nil,
                                      isValueSettable: false, isSelectedTextSettable: false)
        let field = FieldContext(appBundleID: "com.example.owl", axRole: "AXTextArea", caret: .unknown)
        let e = FieldContextReader.surfaceEvidence(field: field, info: info, runtime: .chromium)
        #expect(e.isEditable == true)
        #expect(e.runtime == .chromium)
        #expect(!e.secureInputActive)   // secure input is a write-time check (N4), never fed here
        let unknown = FieldContextReader.surfaceEvidence(field: field, info: FocusedElementInfo(
            role: "AXGroup", value: nil, selectedRange: nil, isValueSettable: false, isSelectedTextSettable: false), runtime: .unknown)
        #expect(unknown.isEditable == nil)
        #expect(unknown.runtime == nil)
    }

    @Test func unknownChromiumComposerGetsSafeWebPlan() throws {
        // An unlisted Chromium wrapper (ChatGPT/Owl-like): resolved from structure, never Return.
        let (r, _) = Self.reader("com.example.owl", field: .init(role: "AXTextArea", hints: ["Message"]),
                                 runtime: .chromium, web: true)
        let field = try #require(r.fieldContext(bundleID: "com.example.owl"))
        let plan = AdapterRegistry.standard().adapter(for: "com.example.owl", surface: field.surface)
        #expect(plan is NewlineSafeAdapter)
        #expect(!plan.methodOrder.contains(.ax))
    }

    @Test func unknownNativeAppGetsSafeProse() throws {
        let (r, _) = Self.reader("com.example.native", field: .init(role: "AXTextArea"))
        let field = try #require(r.fieldContext(bundleID: "com.example.native"))
        #expect(field.surface.kind == .prose)
    }
}
