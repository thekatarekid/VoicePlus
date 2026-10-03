import Foundation
import Injection
import Shared
import Testing

/// H26 — "no field → Notes" applies to native apps and VoicePlus's own windows only; Electron,
/// Chromium and WebKit content keep N3's "deliver unverified". A failed / unfamiliar role read is
/// never "no field". Pure: no AX.
@Suite("Delivery ladder: no field → Notes, native only (H26)")
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

    @Test("the rule: own window or native app with no field → Notes; web/Electron keep N3")
    func rule() {
        typealias L = DeliveryLadder
        #expect(L.noFieldGoesToNotes(ownProcess: true, runtime: nil, field: .none))
        #expect(L.noFieldGoesToNotes(ownProcess: false, runtime: .native, field: .none))
        for web in [SurfaceRuntime.electron, .chromium, .webkit] {
            #expect(!L.noFieldGoesToNotes(ownProcess: false, runtime: web, field: .none), "\(web) still delivered")
        }
        #expect(!L.noFieldGoesToNotes(ownProcess: false, runtime: .unknown, field: .none))
        #expect(!L.noFieldGoesToNotes(ownProcess: false, runtime: nil, field: .none))
        for field in [L.FieldPresence.textField, .unknown] {
            #expect(!L.noFieldGoesToNotes(ownProcess: true, runtime: nil, field: field))
            #expect(!L.noFieldGoesToNotes(ownProcess: false, runtime: .native, field: field))
        }
    }
}
