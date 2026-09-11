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
@Suite("One menu (R7.3)")
struct OneMenuTests {
    // MARK: One menu, four ways in

    @Test func everyEntryPointProducesTheSameMenu() {
        let held = [StatusMenuState.Held(id: UUID(), title: "“hello there” — Notes")]
        let state = StatusMenuState(presence: .listening(level: 0.4), micName: "MacBook Pro Microphone",
                                    micStatus: .good, isCapturing: true, isLatched: true,
                                    hasLastText: true, held: held, meeting: .running)
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
        let capturing = StatusMenuSpec.entries(StatusMenuState(presence: .listening(level: 0.2),
                                                              isCapturing: true))
        let stop = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: capturing)
        #expect(stop?.title == "Stop")
        #expect(stop?.isEnabled == true && stop?.action == .stopDictation)
        let mute = StatusMenuSpec.entry(StatusMenuSpec.ID.mute, in: capturing)
        #expect(mute?.title == "Mute microphone (hard)")
        #expect(mute?.isEnabled == true && mute?.action == .toggleMute)
        #expect(mute?.keyEquivalent == "m" && mute?.isDestructive == true)
    }

    @Test func idleOffersStartAndNoStop() {
        let idle = StatusMenuSpec.entries(StatusMenuState(presence: .ready))
        let dictate = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: idle)
        #expect(dictate?.title == "Start dictation" && dictate?.action == .startDictation)
        #expect(dictate?.keyEquivalent == "d")
        #expect(!idle.contains { $0.action == .stopDictation })
        // Nothing is hidden to hide a problem: Mute is always there, and always enabled.
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.mute, in: idle)?.isEnabled == true)
    }

    @Test func mutedDisablesStartAndLatchAndSaysWhy() {
        let muted = StatusMenuSpec.entries(StatusMenuState(presence: .muted, isMuted: true))
        let dictate = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: muted)
        #expect(dictate?.isEnabled == false && dictate?.action == nil)
        #expect(dictate?.title.contains("muted") == true)
        let latch = StatusMenuSpec.entry(StatusMenuSpec.ID.latch, in: muted)
        #expect(latch?.isEnabled == false && latch?.title == "Latch (muted)")
        let mute = StatusMenuSpec.entry(StatusMenuSpec.ID.mute, in: muted)
        #expect(mute?.title == "Unmute microphone" && mute?.isOn == true && mute?.isEnabled == true)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: muted)?.title == PresenceState.muted.detail)
    }

    @Test func latchReflectsTheSessionAndStaysStoppable() {
        let latched = StatusMenuSpec.entries(StatusMenuState(presence: .listening(level: 0),
                                                            isCapturing: true, isLatched: true))
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.latch, in: latched)?.isOn == true)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: latched)?.action == .stopDictation)
    }

    @Test func blockedStatesStayVisibleWithTheReason() {
        let blocked = StatusMenuSpec.entries(StatusMenuState(presence: .blocked(.microphoneDenied),
                                                            micAvailable: false))
        let dictate = StatusMenuSpec.entry(StatusMenuSpec.ID.dictate, in: blocked)
        #expect(dictate?.isEnabled == false && dictate?.title.contains("Mic off") == true)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.status, in: blocked)?.title
                == PresenceBlockReason.microphoneDenied.detail)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.microphone, in: blocked)?.title.hasSuffix("— off") == true)
    }

    // MARK: The DESIGN §10 order, and what is not in it

    @Test func orderMatchesTheSpec() {
        let entries = StatusMenuSpec.entries(StatusMenuState(presence: .ready, hasLastText: true))
        let ids = entries.filter { !$0.isSeparator }.map(\.id)
        #expect(ids == [StatusMenuSpec.ID.status, StatusMenuSpec.ID.microphone, StatusMenuSpec.ID.dictate,
                        StatusMenuSpec.ID.latch, StatusMenuSpec.ID.mute, StatusMenuSpec.ID.copyLast,
                        StatusMenuSpec.ID.meeting, StatusMenuSpec.ID.openWindow,
                        StatusMenuSpec.ID.settings, StatusMenuSpec.ID.quit])
        #expect(entries.filter(\.isSeparator).count == 3)
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.settings, in: entries)?.keyEquivalent == ",")
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.quit, in: entries)?.keyEquivalent == "q")
        // No diagnostics, no second source of truth for what the window owns (DESIGN §10).
        let titles = entries.map(\.title).joined(separator: " | ")
        for gone in ["Lab", "Data Panel", "Feature flags", "Enroll voice", "Launch at login",
                     "Check for updates", "Check permissions", "indicator under the notch",
                     "Dictation key", "Actions key"] {
            #expect(!titles.contains(gone), "menu still offers \(gone)")
        }
    }

    @Test func copyLastTextNeedsALastText() {
        let empty = StatusMenuSpec.entry(StatusMenuSpec.ID.copyLast,
                                         in: StatusMenuSpec.entries(StatusMenuState()))
        #expect(empty?.isEnabled == false && empty?.action == nil)
        let ready = StatusMenuSpec.entry(StatusMenuSpec.ID.copyLast,
                                         in: StatusMenuSpec.entries(StatusMenuState(hasLastText: true)))
        #expect(ready?.isEnabled == true && ready?.action == .copyLastText)
    }

    @Test func meetingRowStates() {
        func title(_ meeting: StatusMenuState.Meeting) -> String? {
            StatusMenuSpec.entry(StatusMenuSpec.ID.meeting,
                                 in: StatusMenuSpec.entries(StatusMenuState(meeting: meeting)))?.title
        }
        #expect(title(.needsCalendarAccess) == "Start meeting (asks for Calendar access)")
        #expect(title(.idle(canStart: true)) == "Start meeting")
        #expect(title(.running) == "Stop meeting")
        let waiting = StatusMenuSpec.entry(StatusMenuSpec.ID.meeting,
                                           in: StatusMenuSpec.entries(StatusMenuState(meeting: .idle(canStart: false))))
        #expect(waiting?.isEnabled == false && waiting?.title.contains("detected") == true)
    }

    // MARK: Recover text — R2.4's queue, not a second one

    @Test func recoverTextIsHiddenUntilSomethingIsHeld() {
        #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.recover, in: StatusMenuSpec.entries(StatusMenuState())) == nil)
    }

    @Test func recoverTextMirrorsFocusGuardHeldOldestFirst() {
        let system = MockSystemAccess()
        let guardian = FocusGuard(system: system)
        let first = guardian.hold(InjectionRequest(text: "the first thing I said"), reason: "destination changed",
                                 destination: FocusSnapshot(pid: 1, bundleID: "com.apple.Notes", appName: "Notes"))
        let second = guardian.hold(InjectionRequest(text: "and then the second"), reason: "never-inject list",
                                  destination: FocusSnapshot(pid: 2, bundleID: "com.apple.Terminal", appName: "Terminal"))
        let entries = StatusMenuSpec.entries(StatusMenuState(held: HeldMenuRouter.held(in: guardian)))
        let recover = StatusMenuSpec.entry(StatusMenuSpec.ID.recover, in: entries)
        #expect(recover?.title == "Recover text (2)")
        #expect(recover?.children.map(\.id) == [StatusMenuSpec.ID.held(first.id), StatusMenuSpec.ID.held(second.id)])
        #expect(recover?.children.first?.title.contains("Notes") == true)
        // Each item carries R2.4's three actions, in their shipped order.
        #expect(recover?.children.first?.children.map(\.title) == ["Insert here", "Copy", "Discard"])
        #expect(recover?.children.first?.children.map(\.action)
                == [.held(first.id, .insertHere), .held(first.id, .copy), .held(first.id, .discard)])
        // One item left → the title drops the count (DESIGN §10).
        #expect(HeldMenuRouter.perform(.discard, on: first.id, in: guardian))
        let after = StatusMenuSpec.entry(StatusMenuSpec.ID.recover,
                                         in: StatusMenuSpec.entries(StatusMenuState(held: HeldMenuRouter.held(in: guardian))))
        #expect(after?.title == "Recover text")
        #expect(after?.children.count == 1)
    }

    @Test func eachHeldActionCallsThroughToTheHeldQueue() {
        let system = MockSystemAccess()
        let guardian = FocusGuard(system: system)
        var inserted = 0
        guardian.inserter = { _ in
            inserted += 1
            return .injected(method: .keystroke, verified: true)
        }
        let a = guardian.hold(InjectionRequest(text: "insert me"), reason: "destination changed", destination: nil)
        let b = guardian.hold(InjectionRequest(text: "copy me"), reason: "destination changed", destination: nil)
        let c = guardian.hold(InjectionRequest(text: "discard me"), reason: "destination changed", destination: nil)

        func run(_ id: UUID, _ action: HeldAction) {
            let entries = StatusMenuSpec.entries(StatusMenuState(held: HeldMenuRouter.held(in: guardian)))
            guard let entry = StatusMenuSpec.entry(StatusMenuSpec.ID.held(id, action), in: entries),
                  case .held(let heldID, let heldAction)? = entry.action else {
                Issue.record("no menu entry for \(action) on \(id)")
                return
            }
            #expect(HeldMenuRouter.perform(heldAction, on: heldID, in: guardian))
        }
        run(a.id, .insertHere)
        #expect(inserted == 1)
        run(b.id, .copy)
        #expect(system.pasteboardString == "copy me")
        run(c.id, .discard)
        #expect(guardian.held.isEmpty)
    }

    @Test func heldEntriesAlsoBuildFromTheAppSideMirror() {
        let store = HeldTextStore()
        let item = store.hold(text: "held for Notes", destination: "Notes", reason: "destination changed")
        let entries = StatusMenuSpec.entries(StatusMenuState(held: [StatusMenuState.Held(item)]))
        let recover = StatusMenuSpec.entry(StatusMenuSpec.ID.recover, in: entries)
        #expect(recover?.children.first?.title == HeldMenu.header(for: item))
        #expect(recover?.children.first?.children.count == HeldMenu.actions.count)
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
            #expect(StatusMenuSpec.entry(StatusMenuSpec.ID.held(item.id, .insertHere), in: entries) != nil)
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
        #expect(model.statusSymbol == "mic.badge.plus")
        model.latched = false
        #expect(model.statusSymbol == "mic")
        model.paused = true
        #expect(model.statusSymbol == "mic.slash")
        // The words in the two files this task owns, checked as text so the rename cannot regress.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for path in ["App/Core/MenuModel.swift", "App/UI/StatusItemController.swift", "App/Core/PresenceClick.swift"] {
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
