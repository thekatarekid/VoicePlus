import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

// T-probe — the read-only accessibility probe: field signals from a mock tree, values only as length
// and hash (never for a secure field), the URL as a host, and the switch decision ladder.

private final class Node: AXProbeNode {
    var attrs: [String: String]
    var parent: Node?
    var settable = false
    var value: String?
    var caret: CGRect?
    var url: String?
    private(set) var valueReads = 0
    init(_ attrs: [String: String], parent: Node? = nil) { self.attrs = attrs; self.parent = parent }
    func string(_ a: String) -> String? { attrs[a] }
    var parentNode: AXProbeNode? { parent }
    var isValueSettable: Bool { settable }
    func valueLength() -> Int? { valueReads += 1; return value?.count }
    func valueForHash() -> String? { valueReads += 1; return value }
    func caretRect() -> CGRect? { caret }
    func urlString() -> String? { url }
}

struct AXProbeTests {
    @Test func chromiumComposerInsideWebArea() throws {
        let web = Node(["AXRole": "AXWebArea"]); web.url = "https://chatgpt.com/c/secret-path?q=1"
        let editor = Node(["AXRole": "AXGroup", "AXDOMIdentifier": "prompt-textarea", "AXDOMClassList": "ProseMirror"], parent: web)
        editor.settable = true
        let para = Node(["AXRole": "AXStaticText"], parent: editor)
        para.value = "hello there"
        para.caret = CGRect(x: 10, y: 20, width: 1, height: 18)
        let r = AXProbe.record(focused: para, bundleID: "com.openai.chat", appName: "ChatGPT", pid: 42,
                               rendererHelper: true, switchNeeded: .manual)
        #expect(r.editable && r.editableAncestorRole == "AXGroup" && r.editableAncestorDepth == 1)
        #expect(r.inWebArea && r.webAreaDepth == 2)
        #expect(r.urlHost == "chatgpt.com")
        #expect(r.caret == .init(x: 10, y: 20, w: 1, h: 18))
        #expect(r.valueLength == 11 && r.valueHash == AXProbe.hash("hello there") && r.valueHash?.count == 12)
        #expect(r.switchNeeded == .manual && r.rendererHelper)
        // Never a text value in the output.
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!json.contains("hello") && !json.contains("secret-path"))
    }

    @Test func secureFieldValueIsNeverRead() {
        let pw = Node(["AXRole": "AXTextField", "AXSubrole": "AXSecureTextField", "AXPlaceholderValue": "Password"])
        pw.value = "hunter2"
        let r = AXProbe.record(focused: pw, bundleID: "com.apple.Safari", appName: nil, pid: nil,
                               rendererHelper: false, switchNeeded: .none)
        #expect(r.secure && r.editable && r.placeholder == "Password")
        #expect(r.valueLength == nil && r.valueHash == nil && pw.valueReads == 0)
    }

    @Test func nativeFieldAndNoFocus() {
        let f = Node(["AXRole": "AXTextArea", "AXDescription": "Note body", "AXIdentifier": "note"])
        let r = AXProbe.record(focused: f, bundleID: "com.apple.Notes", appName: "Notes", pid: 1, rendererHelper: false, switchNeeded: .none)
        #expect(r.editable && r.editableAncestorDepth == 0 && !r.inWebArea && r.urlHost == nil && r.label == "Note body")
        let none = AXProbe.record(focused: nil, bundleID: "x", appName: nil, pid: nil, rendererHelper: false, switchNeeded: .unresolved)
        #expect(!none.focused && !none.editable && none.role == nil)
        #expect(!AXProbe.isEditable(Node(["AXRole": "AXButton"])))
    }

    @Test func switchLadder() {
        var manualTried = 0, enhancedTried = 0
        func decide(_ now: Bool, allow: Bool, renderer: Bool, manual: Bool, enhanced: Bool) -> AXProbeSwitch {
            AXProbe.decideSwitch(readableNow: now, allowSwitch: allow, hasRendererHelper: renderer,
                                 afterManual: { manualTried += 1; return manual },
                                 afterEnhanced: { enhancedTried += 1; return enhanced })
        }
        #expect(decide(true, allow: true, renderer: true, manual: true, enhanced: true) == .none)
        #expect(manualTried == 0)
        #expect(decide(false, allow: false, renderer: true, manual: true, enhanced: true) == .notTried)
        #expect(manualTried == 0 && enhancedTried == 0)   // nothing flips without the explicit flag
        #expect(decide(false, allow: true, renderer: true, manual: true, enhanced: true) == .manual)
        #expect(enhancedTried == 0)
        #expect(decide(false, allow: true, renderer: true, manual: false, enhanced: true) == .enhanced)
        // A native app (no renderer helper) never gets the enhanced attribute.
        let before = enhancedTried
        #expect(decide(false, allow: true, renderer: false, manual: false, enhanced: true) == .unresolved)
        #expect(enhancedTried == before)
    }

    @Test func rendererHelperStructuralCheck() throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)/Fake.app")
        defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
        let helpers = app.appendingPathComponent("Contents/Frameworks/Owl Framework.framework/Helpers")
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        #expect(!AXProbe.hasRendererHelper(bundleURL: app))
        try fm.createDirectory(at: helpers.appendingPathComponent("Fake Helper (Renderer).app"), withIntermediateDirectories: true)
        #expect(AXProbe.hasRendererHelper(bundleURL: app))
        #expect(!AXProbe.hasRendererHelper(bundleURL: nil))
    }

    @Test func hostAndCLIParse() {
        #expect(AXProbe.host(of: "https://Docs.Google.com/document/d/1/edit") == "docs.google.com")
        #expect(AXProbe.host(of: "not a url") == nil)
        #expect(AXProbeCLI.parse(["app"]) == nil)
        let o = AXProbeCLI.parse(["app", "--ax-probe", "--watch", "30", "--out", "p.jsonl"])
        #expect(o?.watch == 30 && o?.out == "p.jsonl" && o?.allowSwitch == false && o?.delay == 3)
        #expect(AXProbeCLI.parse(["app", "--ax-probe", "--allow-switch", "--delay", "0"])?.allowSwitch == true)
    }
}
