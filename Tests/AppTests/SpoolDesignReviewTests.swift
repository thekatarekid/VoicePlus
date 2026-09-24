import AppKit
import Combine
import Testing
@testable import VoicePlusApp

@Suite("Native V3 diagnostic targeting")
@MainActor
struct SpoolDesignReviewTests {
    @Test func everyFixtureHasTheExpectedProductionStateAndOwnedSurface() {
        let expected = ["idle": "hidden", "ready": "ready", "starting": "starting",
            "listening": "preview", "quiet": "listeningQuiet", "latched": "latched",
            "finishing": "finishing", "preview": "finalPreview", "uncertain": "finalPreview",
            "inserting": "inserting", "inserted": "landed", "held": "held",
            "unconfirmed": "landedUnverified", "partial": "landedPartial", "micWarning": "warning",
            "cancelled": "cancelled", "muted": "muted", "unavailable": "unavailable",
            "editing": "editing", "undo": "undoAvailable", "meeting": "meeting",
            "paused": "meeting", "notes": "meeting", "error": "error",
            "correcting": "correcting", "blocked": "error"]
        #expect(Set(SpoolDesignReview.keys) == Set(expected.keys))
        let model = PillViewModel()
        for key in SpoolDesignReview.keys {
            SpoolDesignReview.present(selection: key, text: "Can we meet with Mira on Friday?", on: model)
            #expect(model.state.caseName == expected[key], "\(key)")
            #expect(SpoolDesignReview.surface(for: key) == (key == "idle" ? .presence : .pill))
            if key != "idle" { #expect(model.state.isVisible) }
        }
        model.hide()
    }

    @Test func idleResetsSyntheticCaptureAndUsesTheRestingGreenPresenceChin() {
        let model = PillViewModel()
        for previous in SpoolDesignReview.keys where previous != "idle" {
            SpoolDesignReview.present(selection: previous, text: "Example", on: model)
            SpoolDesignReview.present(selection: "idle", text: "Example", on: model)
            #expect(model.state == .hidden, "idle after \(previous)")
            #expect(!model.turn.captureOpen)
            #expect(model.turn.liveText.isEmpty)
            #expect(model.turn.startedAt == nil)
        }
        var inputs = PresenceInputs()
        inputs.pillVisible = model.state.isVisible
        let state = PresenceStateReducer.reduce(inputs, microphone: .closed)
        #expect(state == .ready)
        #expect(PresenceHover.presentation(state: state, pointerOn: false, readyHint: "Hint") == .chin)
        #expect(PresenceGeometry.size(for: state) == CGSize(width: 64, height: 14))
    }

    @Test func clickThroughContentRemainsTheTargetAndNeverTheShadow() {
        // Deferred windows are never ordered in, focused, or made interactive by this test.
        let makePanel = { NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true) }
        let pill = makePanel(), presence = makePanel(), shadow = makePanel()
        pill.ignoresMouseEvents = true
        presence.ignoresMouseEvents = true
        shadow.ignoresMouseEvents = true
        for key in SpoolDesignReview.keys {
            let target = SpoolDesignReview.surface(for: key).panel(pill: pill, presence: presence)
            #expect(target === (key == "idle" ? presence : pill))
            #expect(target !== shadow)
            #expect(target.ignoresMouseEvents)
            #expect(!target.isVisible)
        }
    }

    @Test func inspectionRunsAfterTheQueuedProductionStateSubscriber() async {
        let model = PillViewModel()
        var rendered: [String] = []
        let subscription = model.$state.receive(on: DispatchQueue.main).sink { rendered.append($0.caseName) }
        SpoolDesignReview.present(selection: "cancelled", text: "Example", on: model)
        #expect(rendered.isEmpty)
        await withCheckedContinuation { continuation in
            SpoolDesignReview.afterPendingPresentation {
                #expect(rendered.last == "cancelled")
                continuation.resume()
            }
        }
        subscription.cancel()
        model.hide()
    }
}
