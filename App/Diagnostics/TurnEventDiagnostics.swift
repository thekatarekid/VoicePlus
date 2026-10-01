import AppKit
import Foundation
import Injection
import Shared

// V5 Q13 follow-up — the turn controller's own events into the Q13 store: how text landed
// (K-lanes: verdict + app + method + settle ms) and every dwell pause / resume (reason + pointer).
// No dictated text: verdicts, methods and reasons are short codes; the app is a bundle id.

public enum TurnEventDiagnostics {
    /// Test seam: every event recorded here as well, with its turn id.
    nonisolated(unsafe) public static var observer: ((TurnDiagnosticsEvent, String) -> Void)?
    /// Where the pointer is (AppKit global coordinates). Swappable in tests.
    nonisolated(unsafe) public static var pointer: () -> DiagnosticsPoint? = { DiagnosticsPoint(NSEvent.mouseLocation) }

    /// Appends to the shared Q13 store (`PillDiagnostics.store`, set by the composition root).
    public static func record(_ event: TurnDiagnosticsEvent, turn: String) {
        observer?(event, turn)
        PillDiagnostics.store?.record(event, turn: turn)
    }

    /// The landing event for one write. `verdict` is Q4's readback verdict when the injector left
    /// one (`LandingVerdictLedger`); without it an unverified delivery reads "unverified".
    public static func landingEvent(delivery: DeliveryOutcome?, verdict: LandingVerdict?,
                                    appBundleID: String?, settleMs: Int?) -> TurnDiagnosticsEvent {
        let v: String
        let method: String
        switch delivery {
        case let .delivered(verified, m)?:
            v = verified ? LandingVerdict.confirmed.rawValue : (verdict?.rawValue ?? "unverified")
            method = m
        case let .partial(m)?:
            v = "partial"; method = m
        case let .held(reason)?:
            v = "held: \(reason)"; method = "none"
        case let .failed(reason)?:
            v = "failed: \(reason)"; method = "none"
        case nil:
            v = "none"; method = "none"
        }
        return .landing(verdict: v, appBundleID: appBundleID, method: method, settleMs: settleMs.map { max(0, $0) })
    }

    static func pauseEvent(_ reason: String, resumed: Bool) -> TurnDiagnosticsEvent {
        resumed ? .resume(reason: reason, pointer: pointer(), frame: nil)
                : .pause(reason: reason, pointer: pointer(), frame: nil)
    }
}
