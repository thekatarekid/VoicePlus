import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// R7.3 — one menu, from every entry point (V3 §9.2–9.3, `DESIGN.md` §10).
///
/// The menu is asserted through its **view model** (`StatusMenuSpec`), not through rendered AppKit:
/// this toolchain has no XCTest, no UI tests and no simulator, and an `NSStatusItem` cannot be built
/// in a test process (CLAUDE.md).
@Suite("One menu (R7.3, S6)")
struct OneMenuTests {
    // MARK: One menu, four ways in

    @Test func everyEntryPointProducesTheSameMenu() {
        let held = [StatusMenuState.Held(id: UUID(), title: "“hello there” — Notes")]
        let state = StatusMenuState(status: .latched, micName: "MacBook Pro Microphone", micStatus: .good,
                                    isCapturing: true, held: held, meetingRunning: true)
        let menus = MenuEntryPoint.allCases.map { StatusMenuSpec.entries(state, from: $0) }
        #expect(MenuEntryPoint.allCases.count == 4)
        #expect(Set(menus.map { $0.map(\.id).joined(separator: ",") }).count == 1)
        for menu in menus { #expect(menu == menus[0]) }
    }

    @Test func everyClickOnEitherSurfaceOpensTheMenu() {
        for state in [PresenceState.ready, .listening(level: 0), .processing, .muted, .paused,
                      .blocked(.microphoneDenied)] {
            for secondary in [false, true] {
                #expect(PresenceClickRouter.action(for: state, secondary: secondary) == .menu)
            }
        }
        #expect(PresenceClickRouter.entryPoint(secondary: false) == .notch)
        #expect(PresenceClickRouter.entryPoint(secondary: true) == .notchSecondary)
        #expect(MenuEntryPoint.glyph(secondary: true) == .glyphSecondary)
        #expect(MenuEntryPoint.notchSecondary.isNotch && MenuEntryPoint.notchSecondary.isSecondary)
        #expect(!MenuEntryPoint.glyph.isNotch && !MenuEntryPoint.glyph.isSecondary)
    }

    // MARK: Stop and Mute during capture

    @Test func stopAndMuteDuringCapture() {
        let capturing = StatusMenuSpec.entries(StatusMenuState(status: .listening, isCapturing: true))
        let stop = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: capturing)
        #expect(stop?.title == "Stop")
        #expect(stop?.isEnabled == true && stop?.action == .stopDictation)
        let mute = StatusMenuSpec.entry(StatusMenuSpec.ID.mute, in: capturing)
        #expect(mute?.title == "Mute microphone")
        #expect(mute?.isEnabled == true && mute?.action == .toggleMute)
        #expect(mute?.keyEquivalent == "m" && mute?.isOn == false)
    }

    @Test func idleOffersStartAndNoStop() {
        let idle = StatusMenuSpec.entries(StatusMenuState(status: .ready))
        let dictate = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: idle)
        #expect(dictate?.title == "Start dictation" && dictate?.action == .startDictation)
        #expect(dictate?.keyEquivalent == "d")
        #expect(!idle.contains { $0.action == .stopDictation })
        // Nothing is hidden to hide a problem: Mute is always there, and always enabled.
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.mute, in: idle)?.isEnabled == true)
    }

    @Test func mutedDisablesStartAndSaysWhy() {
        let muted = StatusMenuSpec.entries(StatusMenuState(status: .muted, isMuted: true))
        let dictate = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: muted)
        #expect(dictate?.isEnabled == false && dictate?.action == nil)
        #expect(dictate?.title.contains("muted") == true)
        let mute = StatusMenuSpec.entry(StatusMenuSpec.ID.mute, in: muted)
        #expect(mute?.title == "Mute microphone" && mute?.isOn == true && mute?.isEnabled == true)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: muted)?.title == "VoicePlus · Muted")
        // A hand-built state that forgot to say muted still reads muted on the first line.
        let forgot = StatusMenuSpec.entries(StatusMenuState(status: .ready, isMuted: true))
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: forgot)?.title == "VoicePlus · Muted")
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: forgot)?.showsReadyDot == false)
    }

    @Test func blockedStatesStayVisibleWithTheReason() {
        let blocked = StatusMenuSpec.entries(StatusMenuState(status: .blocked(.microphoneDenied), micAvailable: false))
        let dictate = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: blocked)
        #expect(dictate?.isEnabled == false && dictate?.title.contains("microphone access is off") == true)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: blocked)?.title == "VoicePlus · Blocked")
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: blocked)?.detail
                == "Microphone access is off — Open Microphone settings")
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.microphone, in: blocked)?.title.hasSuffix("— off") == true)
    }

    // MARK: The DESIGN §10 order

    @Test func orderMatchesTheSpec() {
        let held = [StatusMenuState.Held(id: UUID(), title: "“a” — Notes")]
        let entries = StatusMenuSpec.entries(StatusMenuState(status: .ready, held: held))
        let ids = entries.filter { !$0.isSeparator }.map(\.id)
        #expect(ids == [StatusMenuSpec.ID.status, StatusMenuSpec.ID.microphone, StatusMenuSpec.ID.dictate,
                        StatusMenuSpec.ID.mute, StatusMenuSpec.ID.held, StatusMenuSpec.ID.openWindow,
                        StatusMenuSpec.ID.settings, StatusMenuSpec.ID.quit])
        #expect(entries.filter(\.isSeparator).count == 3)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.settings, in: entries)?.keyEquivalent == ",")
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.quit, in: entries)?.keyEquivalent == "q")
    }

    // MARK: Held dictations — counted from R2.4's queue, not a second one

    @Test func heldRowIsHiddenUntilSomethingIsHeld() {
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.held, in: StatusMenuSpec.entries(StatusMenuState())) == nil)
    }

    @Test func heldRowMirrorsFocusGuardHeldOldestFirst() {
        let system = MockSystemAccess()
        let guardian = FocusGuard(system: system)
        let first = guardian.hold(InjectionRequest(text: "the first thing I said"), reason: "destination changed",
                                 destination: FocusSnapshot(pid: 1, bundleID: "com.apple.Notes", appName: "Notes"))
        let second = guardian.hold(InjectionRequest(text: "and then the second"), reason: "never-inject list",
                                  destination: FocusSnapshot(pid: 2, bundleID: "com.apple.Terminal", appName: "Terminal"))
        let held = HeldMenuRouter.held(in: guardian)
        #expect(held.map(\.id) == [first.id, second.id])
        #expect(held.first?.title.contains("Notes") == true)
        #expect(held.first?.text == "the first thing I said")
        let row = StatusMenuSpec.entry(StatusMenuSpec.ID.held, in: StatusMenuSpec.entries(StatusMenuState(held: held)))
        #expect(row?.title == "Couldn’t save 2 to Notes" && row?.action == .reviewHeld)
        #expect(guardian.discard(first.id))
        let after = StatusMenuSpec.entry(StatusMenuSpec.ID.held,
                                         in: StatusMenuSpec.entries(StatusMenuState(held: HeldMenuRouter.held(in: guardian))))
        #expect(after?.title == "Couldn’t save to Notes")
    }

    @Test func heldEntriesAlsoBuildFromTheAppSideMirror() {
        let store = HeldTextStore()
        let item = store.hold(text: "held for Notes", destination: "Notes", reason: "destination changed")
        let held = StatusMenuState.Held(item)
        #expect(held.title == HeldMenu.header(for: item))
        #expect(held.text == "held for Notes" && held.heldAt == item.heldAt && !held.isSaved)
    }

    // MARK: Focus is sacred

    @Test func openingTheMenuPreservesTheDestinationFocus() {
        let system = MockSystemAccess()
        system.frontmost = FocusSnapshot(pid: 42, bundleID: "com.apple.Notes", appName: "Notes")
        let guardian = FocusGuard(system: system)
        let snapshot = guardian.snapshot()
        let item = guardian.hold(InjectionRequest(text: "waiting for Notes"), reason: "destination changed",
                                destination: snapshot)
        let before = system.postCount

        // Everything opening the menu does: build the state, build the rows, from every entry point.
        for entryPoint in MenuEntryPoint.allCases {
            let entries = StatusMenuSpec.entries(StatusMenuState(held: HeldMenuRouter.held(in: guardian)),
                                                 from: entryPoint)
            #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.held, in: entries) != nil)
        }

        // The snapshot still matches, the held text is still held, and nothing was posted anywhere:
        // the destination dictation would land in is exactly where it was (DESIGN §5.3).
        #expect(guardian.matches(snapshot))
        #expect(system.frontmost == snapshot)
        #expect(guardian.held.map(\.id) == [item.id])
        #expect(system.postCount == before)
        #expect(system.pasteboardString == nil)
    }

    // MARK: G2 — the `handsFree` → `latched` rename

    @Test func menuModelSpeaksLatchedNotHandsFree() {
        var model = MenuModel(latched: true)
        #expect(model.latched)
        model.latched = false
        #expect(!model.latched)
        // G2: every file the rename swept, checked as text so it cannot regress. Not
        // `WakeVerbPreRoute.swift` — since V5 K20 it writes "latched" but keeps a one-release
        // `legacyLatchedValue = "handsFree"` read-compat alias (see WakeVerbTests).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let swept = [
            "App/Core/MenuModel.swift", "App/UI/StatusItemController.swift", "App/Core/PresenceClick.swift",
            "App/AppDelegate.swift", "App/UI/PillView.swift", "App/Core/HotkeyStateMachine.swift",
            "App/Services/LatchController.swift", "App/Services/LatchRuntime.swift",
            "App/Services/DictationCoordinator.swift", "App/Services/AppContainer.swift",
            "Engine/Audio/AudioPipeline.swift", "Engine/Speaker/SpeakerGate.swift",
        ]
        for path in swept {
            let source = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
            #expect(!source.isEmpty, "could not read \(path)")
            let code = source.split(separator: "\n").filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return !line.hasPrefix("///") && !line.hasPrefix("//")
            }.joined(separator: "\n")
            #expect(!code.contains("handsFree"), "\(path) still says handsFree outside comments")
        }
    }
}
