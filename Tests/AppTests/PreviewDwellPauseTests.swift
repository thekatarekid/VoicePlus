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

    @Test("a preview with nothing pausing it releases the hover pause instead of only not adding it")
    func nothingPausing() {
        let r = TurnWiring.previewPauses(pointerInside: false)
        #expect(r.pause.isEmpty)
        #expect(r.resume == [.hover])
    }

    /// V5 Q9 — `previewPauses` has no hidden-app input: the pill cannot be hidden, so no pause exists.
    @Test func previewPausesHaveNoHiddenAppInput() {
        #expect(TurnWiring.previewPauses(pointerInside: true) == (pause: [.hover], resume: []) as (pause: Set<DwellPause>, resume: Set<DwellPause>))
        #expect(!DwellPause.allCases.map(\.rawValue).contains("hiddenApp"))
        #expect(!DwellPause.allCases.map(\.rawValue).contains("emptyDraft"))
    }

    /// A pause and a release are never asked for together: `pauseDwell` / `resumeDwell` in any order
    /// would otherwise race on the same reason.
    @Test func aReasonIsNeverBothPausedAndResumed() {
        for pointer in [true, false] {
            let r = TurnWiring.previewPauses(pointerInside: pointer)
            #expect(r.pause.intersection(r.resume).isEmpty)
            #expect(r.pause.union(r.resume) == [.hover])
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
