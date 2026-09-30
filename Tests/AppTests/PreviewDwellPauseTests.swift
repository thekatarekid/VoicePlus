import Foundation
import Testing
@testable import VoicePlusApp

/// V4.41 — why an auto-insert can stop happening at all, on a destination that is genuinely focused.
///
/// The final preview's dwell is frozen while the pointer is on the pill, while the pill holds
/// keyboard focus, and while the app is hidden (design §5 step 4). Each of those was a *one-way*
/// pause applied whenever a preview was published, with no matching release, and the hover half was
/// read from a cached flag that SwiftUI never retracts when the pill stops accepting the mouse. One
/// missed `onHover(false)` therefore parked every later payload at "Ready for <app> · Insert now",
/// where it waited for a click that the user had no reason to know was required.
///
/// Real hover, real panels and real Accessibility cannot be exercised here: these cover the decision
/// (`TurnWiring.previewPauses`) and the hover seam (`PillViewModel.isPointerReallyInside`).
@Suite("V4.41 — final preview dwell pauses")
struct PreviewDwellPauseTests {

    @Test("a preview with nothing pausing it releases both pauses instead of only not adding them")
    func nothingPausing() {
        let r = TurnWiring.previewPauses(pointerInside: false, appHidden: false)
        #expect(r.pause.isEmpty)
        #expect(r.resume == [.hover, .hiddenApp])
    }

    @Test("each condition pauses exactly its own reason and releases the other")
    func eachConditionIsIndependent() {
        let hovered = TurnWiring.previewPauses(pointerInside: true, appHidden: false)
        #expect(hovered.pause == [.hover])
        #expect(hovered.resume == [.hiddenApp])
        let hidden = TurnWiring.previewPauses(pointerInside: false, appHidden: true)
        #expect(hidden.pause == [.hiddenApp])
        #expect(hidden.resume == [.hover])
        let both = TurnWiring.previewPauses(pointerInside: true, appHidden: true)
        #expect(both.pause == [.hover, .hiddenApp])
        #expect(both.resume.isEmpty)
    }

    /// A pause and a release are never asked for together: `pauseDwell` / `resumeDwell` in any order
    /// would otherwise race on the same reason.
    @Test func aReasonIsNeverBothPausedAndResumed() {
        for pointer in [true, false] {
            for hidden in [true, false] {
                let r = TurnWiring.previewPauses(pointerInside: pointer, appHidden: hidden)
                #expect(r.pause.intersection(r.resume).isEmpty)
                #expect(r.pause.union(r.resume) == [.hover, .hiddenApp])
            }
        }
    }

    // MARK: The hover seam

    @MainActor
    @Test("a hover flag SwiftUI never retracted does not report the pointer as inside")
    func staleHoverIsNotTrusted() {
        let pill = PillViewModel()
        pill.setPointerInside(true)
        #expect(pill.pointerInside)
        #expect(pill.isPointerReallyInside, "with no hit test installed the flag is still the answer")
        pill.pointerHitTest = { false }        // the panel now ignores the mouse, or has moved away
        #expect(!pill.isPointerReallyInside)
        pill.pointerHitTest = { true }
        #expect(pill.isPointerReallyInside)
    }

    @MainActor
    @Test("no hover flag at all is never turned into a hover by the hit test")
    func theHitTestCannotInventHover() {
        let pill = PillViewModel()
        pill.pointerHitTest = { true }
        #expect(!pill.isPointerReallyInside)
    }
}
