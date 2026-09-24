import Shared
import Testing
@testable import VoicePlusApp

@Suite("Menu capture has an explicit pill Finish")
@MainActor
struct MenuCapturePillTests {
    @Test func menuCaptureKeepsItsArtworkAndFinishAcrossLiveAndQuietStates() async {
        let rig = StatusMenuControllerTests.Rig()
        let pill = PillViewModel()
        MenuCapturePillWiring.attach(rig.session, pill: pill)
        rig.controller.run(.startDictation)
        await rig.settle()
        for state: PillState in [.starting, .listening(level: 0.3), .listeningQuiet,
                                  .preview(text: "Menu words"), .warning(.unknownGood)] {
            pill.present(state)
            // The presenter may keep the quiet row while a partial arrives.
            let standard = PillContent.make(pill.state, context: pill.context())
            let actual = pill.content()
            #expect(actual.designKey == standard.designKey)
            #expect(actual.spoolKey == standard.spoolKey)
            #expect(actual.status == standard.status)
            #expect(actual.words == standard.words)
            #expect(actual.buttons.filter { $0.action == .finish }.count == 1)
            #expect(actual.helper == "Click Finish to stop dictation")
        }
        pill.present(.listeningQuiet)
        var stopped: SessionCoordinator.Requester?
        rig.session.onStopped = { requester, _ in stopped = requester }
        pill.perform(.finish)
        await rig.settle()
        #expect(stopped == .menu)
        #expect(rig.engine.stops == 1)
        #expect(rig.session.activeRequester == nil)
        #expect(!rig.dictation.isSessionHeld)
    }

    @Test func finishingEachMenuCaptureRowStopsItsOwnerExactlyOnce() async {
        for state: PillState in [.starting, .listening(level: 0.3), .listeningQuiet,
                                  .preview(text: "Menu words"), .latched(elapsed: 2)] {
            let rig = StatusMenuControllerTests.Rig()
            let pill = PillViewModel()
            var fallbackCalls = 0
            pill.onAction = { _, _ in fallbackCalls += 1 }
            MenuCapturePillWiring.attach(rig.session, pill: pill)
            rig.controller.run(.startDictation)
            await rig.settle()
            pill.present(.listening(level: 0.3))
            pill.present(state)
            pill.perform(.finish)
            await rig.settle()
            #expect(rig.engine.stops == 1)
            #expect(rig.session.activeRequester == nil)
            #expect(fallbackCalls == 0)
        }
    }

    @Test func hotkeyHoldAndLatchRetainTheirOriginalCopyAndRoutes() async {
        let rig = StatusMenuControllerTests.Rig()
        let pill = PillViewModel()
        var forwarded: [PillActionKind] = []
        pill.onAction = { action, _ in forwarded.append(action) }
        MenuCapturePillWiring.attach(rig.session, pill: pill)
        rig.session.start(.hotkey, mode: .hold)
        await rig.settle()
        pill.present(.listening(level: 0.2))
        #expect(pill.content().helper == PillDeck.listeningHelper(key: pill.keyLabel()))
        #expect(!pill.content().buttons.contains { $0.action == .finish })
        pill.present(.listeningQuiet)
        #expect(pill.content().helper == PillDeck.quietHelper)
        #expect(pill.content().buttons.isEmpty)
        pill.present(.latched(elapsed: 2))
        #expect(pill.content().helper == PillDeck.latchedHelper(key: pill.keyLabel()))
        #expect(pill.content().buttons == PillDeck.latchedButtons)
        pill.perform(.finish)
        #expect(forwarded == [.finish])
        #expect(rig.engine.stops == 0)
        rig.session.cancel(.hotkey)
        await rig.settle()
    }

    @Test func finalPreviewAndRecoveryNeverOfferCaptureFinish() {
        for state: PillState in [.finishing(elapsedWarning: false),
                                  .finalPreview(FinalPreviewInfo(text: "Words", dwellRemaining: 0.6)),
                                  .error(message: "Microphone unavailable"), .hidden, .ready(hint: "Ready")] {
            #expect(!MenuCapturePillWiring.canFinish(state, captureOpen: true))
        }
        #expect(!MenuCapturePillWiring.canFinish(.preview(text: "Notice"), captureOpen: false))
    }
}
