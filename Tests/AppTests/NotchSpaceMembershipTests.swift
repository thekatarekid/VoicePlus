import AppKit
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Fix notch (owner report 2026-10-03): after a Space-layout change the Dock detached every
/// ordered-out all-Spaces window from every Space. The pill, ribbon and ink overlays were then ordered
/// in on no Space (WindowServer "none→hidden"). The chin never stood down, so its listening bar (the
/// "white dot") showed instead of the notch. The ribbon was logged as flown but was never visible.
@Suite("Fix notch · Space membership, chin, ribbon honesty, presence log")
struct NotchSpaceMembershipTests {

    /// A window as the WindowServer sees it. `joined` is membership in every Space. Ordering in does
    /// not rejoin; sending the all-Spaces tag again does (when `tagRejoins`), either always or only
    /// while the window is ordered in (`tagRejoinsOnlyWhileIn`).
    final class FakeWindow: SpaceMemberWindow {
        var joined: Bool
        var tagRejoins: Bool
        var tagRejoinsOnlyWhileIn: Bool
        private(set) var isVisible = false
        private(set) var tagChanges: [NSWindow.CollectionBehavior] = []
        private(set) var orderIns = 0
        var collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle] {
            didSet {
                tagChanges.append(collectionBehavior)
                if collectionBehavior.contains(.canJoinAllSpaces), !oldValue.contains(.canJoinAllSpaces), tagRejoins,
                   !tagRejoinsOnlyWhileIn || isVisible {
                    joined = true
                }
            }
        }
        var isOnActiveSpace: Bool { isVisible && joined }
        init(joined: Bool, tagRejoins: Bool = true, tagRejoinsOnlyWhileIn: Bool = false) {
            self.joined = joined
            self.tagRejoins = tagRejoins
            self.tagRejoinsOnlyWhileIn = tagRejoinsOnlyWhileIn
        }
        func orderFrontRegardless() { isVisible = true; orderIns += 1 }
        func orderOut() { isVisible = false }
        /// The Dock's `BatchReassociateWindowsToSpace` for an ordered-out sticky window.
        func spaceLayoutChanged() { if !isVisible { joined = false } }
    }

    // MARK: SpaceMembership

    /// The owner's sequence: shown, ordered out, Space created and destroyed, ordered in again.
    @Test func detachedPillRejoinsEverySpaceWhenOrderedIn() {
        let pill = FakeWindow(joined: true)
        #expect(SpaceMembership.orderIn([pill]) == .onActiveSpace)
        pill.orderOut()
        pill.spaceLayoutChanged()
        #expect(!pill.joined)
        // Before the fix: a bare `orderFrontRegardless` → in, on no Space.
        let bare = FakeWindow(joined: false)
        bare.orderFrontRegardless()
        #expect(bare.isVisible && !bare.isOnActiveSpace, "the bug: ordered in on no Space")
        // After: reassert before ordering in.
        #expect(SpaceMembership.orderIn([pill]) == .onActiveSpace)
        #expect(pill.isOnActiveSpace)
        #expect(pill.collectionBehavior == [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle],
                "the original behaviour is restored")
    }

    @Test func windowThatRejoinsOnlyWhileInIsReassertedAgain() {
        let pill = FakeWindow(joined: false, tagRejoinsOnlyWhileIn: true)
        #expect(SpaceMembership.orderIn([pill]) == .rejoined)
        #expect(pill.isOnActiveSpace)
    }

    @Test func windowThatNeverRejoinsAsksTheCallerToRebuild() {
        let pill = FakeWindow(joined: false, tagRejoins: false)
        #expect(SpaceMembership.orderIn([pill]) == .offActiveSpace)
        // A rebuilt window is new to the WindowServer and joins every Space at first order-in.
        #expect(SpaceMembership.orderIn([FakeWindow(joined: true)]) == .onActiveSpace)
    }

    @Test func pillAndShadowAreBothRejoinedAndOrderedInShadowFirst() {
        let shadow = FakeWindow(joined: false), pill = FakeWindow(joined: false)
        #expect(SpaceMembership.orderIn([shadow, pill]) == .onActiveSpace)
        #expect(shadow.isOnActiveSpace && pill.isOnActiveSpace)
        #expect(shadow.orderIns == 1 && pill.orderIns == 1)
    }

    /// The chin calls this on every 5 Hz refresh: a window already on screen is never retagged,
    /// so nothing flickers.
    @Test func visibleWindowIsNotRetagged() {
        let chin = FakeWindow(joined: true)
        chin.orderFrontRegardless()
        #expect(SpaceMembership.orderIn([chin]) == .onActiveSpace)
        #expect(chin.tagChanges.isEmpty)
    }

    @Test func windowThatDoesNotJoinAllSpacesIsLeftAlone() {
        let w = FakeWindow(joined: true)
        w.collectionBehavior = [.moveToActiveSpace]
        let before = w.tagChanges.count
        SpaceMembership.reassert(w)
        #expect(w.tagChanges.count == before)
    }

    @MainActor @Test func realPanelKeepsItsBehaviourAcrossReassert() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.collectionBehavior = behavior
        SpaceMembership.reassert(panel)
        #expect(panel.collectionBehavior == behavior)
    }

    // MARK: Notch, not dot

    static let laptop = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), topInset: 38,
                                      notchWidth: 200, menuBarHeight: 38, displayID: 1)

    /// A pill ordered in on no Space is off screen, so the chin keeps the surface (and says why in the
    /// log). A pill on the active Space is on screen, and the chin stands down for the notch.
    @Test func pillOnNoSpaceIsOffScreenAndTheChinKeepsTheSurface() {
        let shown = CGRect(x: 620, y: 970, width: 560, height: 160)
        let hidden = PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: true, frame: shown,
                                                chosenScreen: Self.laptop, onActiveSpace: false)
        #expect(!hidden.onScreen)
        #expect(!PresenceIndicatorController.pillSuppressesChin(stateVisible: true, panelOnScreen: hidden.onScreen,
                                                                pillDisplay: hidden.display, chinDisplay: Self.laptop))
        let onSpace = PillSurfaceReport.evaluate(orderedIn: true, occlusionVisible: true, frame: shown,
                                                 chosenScreen: Self.laptop, onActiveSpace: true)
        #expect(onSpace.onScreen && onSpace.display == Self.laptop)
        #expect(PresenceIndicatorController.pillSuppressesChin(stateVisible: true, panelOnScreen: onSpace.onScreen,
                                                               pillDisplay: onSpace.display, chinDisplay: Self.laptop),
                "the notch pill shows; the chin's listening bar does not")
    }

    // MARK: Ribbon honesty

    typealias T = TapeFlightTests
    typealias L = TapeFlightLadderQ5Tests

    final class SpaceAwareSurface: TapeFlightSurface {
        var visible: Bool?
        private(set) var shown = 0
        var lastShowVisible: Bool? { visible }
        func show(_ run: TapeFlightRun) { shown += 1 }
        func clear() {}
    }

    final class Sink: @unchecked Sendable { var reports: [RibbonReport] = [] }

    private func fly(surfaceVisible: Bool?) -> (SpaceAwareSurface, [RibbonReport]) {
        let surface = SpaceAwareSurface()
        surface.visible = surfaceVisible
        let sink = Sink()
        let controller = TapeFlightController(
            reader: TapeFlightReader(probe: T.FakeProbe(T.caret), caret: L.LadderCaret(element: L.elementRect)),
            mouth: { T.mouth }, displays: { [T.builtIn, T.external] }, reduceMotion: { false },
            surface: surface, clock: T.Clock(), queues: TapeFlightQueues(read: { $0() }, deliver: { $0() }),
            diagnostics: { sink.reports.append($0) })
        controller.stateChanged(.finalPreview(FinalPreviewInfo(text: T.text, dwellRemaining: 0.9)))
        controller.stateChanged(.inserting(text: T.text))
        return (surface, sink.reports)
    }

    /// Every landed turn with a caret arms the ribbon, and its report says whether anyone could see it.
    @Test func ribbonArmsOnEveryLandedTurnAndReportsItsVisibility() {
        for visible in [true, false, nil] as [Bool?] {
            let (surface, reports) = fly(surfaceVisible: visible)
            #expect(surface.shown == 1, "the ribbon is drawn on every landed turn with a caret")
            #expect(reports.map(\.outcome) == [.flew])
            #expect(reports.first?.surfaceVisible == visible)
        }
    }

    @Test func hiddenFlightIsLoggedAsFlewHidden() {
        let hidden = RibbonDiagnostics.event(RibbonReport(outcome: .flew, rung: .textMarker, onDisplay: true,
                                                          locateMs: 30, surfaceVisible: false))
        guard case let .decision(h) = hidden else { Issue.record("not a decision"); return }
        #expect(h.reason == "flewHidden" && h.confidence == 0)
        #expect(h.questionProbabilities["surfaceVisible"] == 0)
        let seen = RibbonDiagnostics.event(RibbonReport(outcome: .flew, rung: .textMarker, onDisplay: true,
                                                        locateMs: 30, surfaceVisible: true))
        guard case let .decision(v) = seen else { return }
        #expect(v.reason == "flew" && v.confidence == 1 && v.questionProbabilities["surfaceVisible"] == 1)
    }

    // MARK: Presence log noise

    @Test func listeningLevelChangesAreNotStateChanges() {
        #expect(!PresenceStateLog.changed(previous: .listening(level: 0.1), next: .listening(level: 0.8),
                                          wasExpanded: false, expanded: false))
        #expect(PresenceStateLog.changed(previous: .ready, next: .listening(level: 0.2), wasExpanded: false, expanded: false))
        #expect(PresenceStateLog.changed(previous: .listening(level: 0.2), next: .listening(level: 0.2),
                                         wasExpanded: false, expanded: true))
        #expect(PresenceStateLog.changed(previous: .listening(level: 0.2), next: .off, wasExpanded: false, expanded: false))
    }
}
