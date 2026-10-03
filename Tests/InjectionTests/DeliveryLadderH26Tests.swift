import Foundation
import Injection
import Shared
import Testing

/// H26 / rq (2026-10-04) — "no field → Notes" in every runtime: a focused button or an empty,
/// non-settable web group in Claude desktop turned a dictated sentence into "r?". A failed /
/// unfamiliar role read is never "no field". Pure: no AX.
@Suite("Delivery ladder: no field → Notes (H26, rq)")
struct DeliveryLadderH26Tests {
    @Test("field presence from the AX role")
    func presence() {
        typealias L = DeliveryLadder
        #expect(L.fieldPresence(role: "AXTextArea") == .textField)
        #expect(L.fieldPresence(role: "AXTextField") == .textField)
        #expect(L.fieldPresence(role: "AXButton") == .none)
        #expect(L.fieldPresence(role: "AXList") == .none)
        #expect(L.fieldPresence(role: "AXGroup") == .unknown, "a custom view may take text: N3 decides")
        #expect(L.fieldPresence(role: "AXWebArea") == .unknown)
        #expect(L.fieldPresence(role: nil) == .unknown, "a failed read is never 'no field'")
        #expect(L.fieldPresence(role: "") == .unknown)
        #expect(L.fieldPresence(role: "unknown") == .unknown)
        #expect(L.fieldPresence(role: "AXButton", isSecure: true) == .textField, "secure is refused elsewhere, never Notes")
    }

    @Test("the rule (rq): no field → Notes in every runtime; a text field or unknown focus never")
    func rule() {
        typealias L = DeliveryLadder
        #expect(L.noFieldGoesToNotes(ownProcess: true, runtime: nil, field: .none))
        #expect(L.noFieldGoesToNotes(ownProcess: false, runtime: .native, field: .none))
        for web in [SurfaceRuntime.electron, .chromium, .webkit, .unknown] {
            #expect(L.noFieldGoesToNotes(ownProcess: false, runtime: web, field: .none), "\(web): no field → Notes")
        }
        #expect(L.noFieldGoesToNotes(ownProcess: false, runtime: nil, field: .none))
        for field in [L.FieldPresence.textField, .unknown] {
            for runtime in [SurfaceRuntime?.none, .native, .electron, .chromium] {
                #expect(!L.noFieldGoesToNotes(ownProcess: false, runtime: runtime, field: field))
            }
            #expect(!L.noFieldGoesToNotes(ownProcess: true, runtime: nil, field: field))
        }
    }

    @Test("web content: an empty, non-settable AXGroup / AXWebArea is no field; anything doubtful is unknown")
    func webPresence() {
        typealias L = DeliveryLadder
        for role in ["AXGroup", "AXWebArea"] {
            #expect(L.fieldPresence(role: role, value: "", textSettable: false, runtime: .electron) == .none)
            #expect(L.fieldPresence(role: role, value: nil, textSettable: false, runtime: .chromium) == .none)
            #expect(L.fieldPresence(role: role, value: "", textSettable: false, runtime: .native, inWebArea: true) == .none)
            #expect(L.fieldPresence(role: role, value: "", textSettable: true, runtime: .electron) == .unknown, "settable: may take text")
            #expect(L.fieldPresence(role: role, value: "", textSettable: nil, runtime: .electron) == .unknown, "settability unread")
            #expect(L.fieldPresence(role: role, value: "Hello", textSettable: false, runtime: .electron) == .unknown)
            #expect(L.fieldPresence(role: role, value: "", textSettable: false, runtime: .native) == .unknown, "native custom view")
            #expect(L.fieldPresence(role: role, value: "", textSettable: false, runtime: nil) == .unknown)
        }
        #expect(L.fieldPresence(role: "AXTextArea", value: "", textSettable: false, runtime: .electron) == .textField)
        #expect(L.fieldPresence(role: "AXButton", value: "", textSettable: false, runtime: .electron) == .none)
        #expect(L.fieldPresence(role: "AXButton", value: "", textSettable: nil, runtime: .electron) == .unknown)
        #expect(L.fieldPresence(role: "AXButton", value: "", textSettable: nil, runtime: .native) == .none, "native: role rule (H26)")
        // ChatGPT-like: the caret's paragraph inside an editable ProseMirror root, never "no field".
        #expect(L.fieldPresence(role: "AXStaticText", value: "", textSettable: false, runtime: .chromium) == .unknown)
        #expect(L.fieldPresence(role: "AXStaticText", value: "hello", textSettable: false, runtime: .webkit) == .unknown)
        #expect(L.fieldPresence(role: "AXGroup", value: "", textSettable: true, runtime: .chromium) == .unknown,
                "a settable ProseMirror root is a composer")
        #expect(L.fieldPresence(role: "AXScrollArea", value: "", textSettable: false, runtime: .electron) == .unknown)
        #expect(L.fieldPresence(role: "AXGroup", value: "", textSettable: false, runtime: .unknown) == .none, "unsniffable runtime: web evidence")
        #expect(L.fieldPresence(role: "AXGroup", value: "", textSettable: false, runtime: .electron, isSecure: true) == .textField)
        #expect(L.fieldPresence(nil, runtime: .electron) == .unknown, "a failed read is never 'no field'")
    }

    @Test("TargetRevision answers the same question (hands-free stop, H26 before the write)")
    func revisionPresence() {
        let claude = FocusSnapshot(pid: 7, bundleID: "com.anthropic.claudefordesktop")
        let group = TargetRevision(focus: claude, role: "AXGroup", selection: 0..<0,
                                   textVersion: TargetRevision.version(of: ""), isTextSettable: false)
        #expect(group.fieldPresence(runtime: .electron) == .none)
        #expect(group.fieldPresence(runtime: .native) == .unknown)
        var unread = group; unread.isTextSettable = nil
        #expect(unread.fieldPresence(runtime: .electron) == .unknown)
        var full = group; full.textVersion = TargetRevision.version(of: "Hello")
        #expect(full.fieldPresence(runtime: .electron) == .unknown)
        #expect(TargetRevision(focus: claude, role: "AXButton", textVersion: TargetRevision.version(of: ""),
                               isTextSettable: false).fieldPresence(runtime: .electron) == .none)
        #expect(TargetRevision(focus: claude, role: "AXButton").fieldPresence(runtime: nil) == .none)
        #expect(TargetRevision(focus: claude, role: "AXTextArea").fieldPresence(runtime: .electron) == .textField)
    }

    @Test("decide: web content with a focused button or empty group is Notes, never a delivery")
    func decideWeb() {
        typealias L = DeliveryLadder
        func decide(_ field: L.FieldPresence, readable: Bool = true) -> L.Decision {
            L.decide(focusSame: true, window: .same, secureInput: false, fieldReadable: readable,
                     surface: nil, multiline: false, webContent: true, field: field)
        }
        let button = L.fieldPresence(role: "AXButton", value: "", textSettable: false, runtime: .electron)
        let group = L.fieldPresence(role: "AXGroup", value: "", textSettable: false, runtime: .electron)
        #expect(decide(button) == .notes(.noField))
        #expect(decide(group) == .notes(.noField))
        #expect(!decide(group, readable: false).isDelivery)
        // The composer (AXTextArea) in Claude: keystrokes, verified — unchanged.
        let composer = L.fieldPresence(role: "AXTextArea", value: "", textSettable: true, runtime: .electron)
        #expect(decide(composer) == .deliver(method: .keystrokes, verify: true))
        #expect(decide(.unknown) == .deliver(method: .keystrokes, verify: true), "unknown never refused")
        // A terminal surface keeps bracketed paste whatever the role says.
        #expect(L.decide(focusSame: true, window: .same, secureInput: false, fieldReadable: true,
                         surface: .terminal, multiline: false, field: .none) == .deliver(method: .paste, verify: true))
    }

    @Test("TargetRevision: an empty group reading \"\\n\" is blank (Claude's empty contenteditable)")
    func revisionNewlineIsBlank() {
        let focus = FocusSnapshot(pid: 9, bundleID: "com.anthropic.claudefordesktop")
        let group = TargetRevision(focus: focus, role: "AXGroup", textVersion: TargetRevision.version(of: "\n"),
                                   isTextSettable: false)
        #expect(group.fieldPresence(runtime: .electron) == .none)
        var typed = group; typed.textVersion = TargetRevision.version(of: "r?")
        #expect(typed.fieldPresence(runtime: .electron) == .unknown, "a group with text is not certain")
        #expect(group.fieldPresence(runtime: .native) == .unknown, "native AXGroup: H26 role rule, unchanged")
    }

    @Test("decide: a password field in web content is refused, never Notes")
    func passwordBeatsNoField() {
        let secure = DeliveryLadder.fieldPresence(role: "AXTextField", value: "", textSettable: false,
                                                  runtime: .chromium, isSecure: true)
        #expect(secure == .textField)
        #expect(DeliveryLadder.decide(focusSame: true, window: .same, secureInput: true, fieldReadable: false,
                                      surface: nil, multiline: false, webContent: true, passwordField: true,
                                      field: .none) == .hold(.passwordField))
    }
}
