import AppKit
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H31 — the destination badge: which rows carry it, its animations (Reduce Motion: none), what it draws
/// for native, Electron and browser destinations, and how the pill model feeds it.
@Suite("H31 destination badge")
struct DestinationBadgeTests {
    static let t0 = Date(timeIntervalSince1970: 120_000)
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    let fav = NSImage(size: NSSize(width: 32, height: 32))

    private func app(_ name: String, _ bundle: String) -> DestinationIdentity {
        DestinationIdentity(appIcon: icon, appName: name, bundleID: bundle)
    }

    @Test func sizeIs22To24() {
        #expect((22...24).contains(DestinationBadgeRule.size))
    }

    @Test func listeningInsertingAndOutcomeRowsOnly() {
        let shown: [PillState] = [.listening(level: 0.2), .listeningQuiet, .latched(elapsed: 1), .inserting(text: "x"),
                                  .landedPartial(text: "x"), .undoAvailable, .landing]
        for s in shown { #expect(DestinationBadgeRule.showsBadge(for: s), "\(s.caseName)") }
        let hidden: [PillState] = [.hidden, .idle, .ready(hint: "h"), .muted, .error(message: "e"), .cancelled,
                                   .starting, .unavailable(reason: "r")]
        for s in hidden { #expect(!DestinationBadgeRule.showsBadge(for: s), "\(s.caseName)") }
    }

    @Test func motionPerEventAndReduceMotionIsStatic() {
        #expect(DestinationBadgeRule.motion(for: .inserting, reduced: false) == .insertSweep)
        #expect(DestinationBadgeRule.motion(for: .destinationChanged, reduced: false) == .attention)
        #expect(DestinationBadgeRule.motion(for: .other, reduced: false) == .none)
        #expect(DestinationBadgeRule.motion(for: .inserting, reduced: true) == .none)
        #expect(DestinationBadgeRule.motion(for: .destinationChanged, reduced: true) == .none)
    }

    @Test func nativeAndElectronDrawTheAppIcon() {
        for id in [app("Mail", "com.apple.mail"), app("Slack", "com.tinyspeck.slackmacgap")] {
            let images = DestinationBadgeRule.images(for: id)
            #expect(images.primary === icon)
            #expect(images.corner == nil)
            #expect(DestinationBadgeRule.accessibilityLabel(for: id) == id.appName)
        }
    }

    @Test func browserDrawsFaviconWithBrowserInCorner() {
        let page = DestinationIdentity(appIcon: icon, appName: "Safari", isBrowser: true, siteFavicon: fav,
                                       tabTitle: "Claude", siteHost: "claude.ai", bundleID: "com.apple.Safari")
        let images = DestinationBadgeRule.images(for: page)
        #expect(images.primary === fav)
        #expect(images.corner === icon)
        #expect(DestinationBadgeRule.accessibilityLabel(for: page) == "Claude in Safari")
        // No favicon yet: the browser icon alone.
        var bare = page
        bare.siteFavicon = nil
        #expect(DestinationBadgeRule.images(for: bare).primary === icon)
    }

    @Test func modelAsksForIdentityPerTurnAndPulsesOnInserting() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        let mail = app("Mail", "com.apple.mail")
        model.destinationIdentityProvider = { mail }
        model.present(.listening(level: 0.3))
        #expect(model.destinationIdentity?.appName == "Mail")
        let before = model.badgeInsertPulse
        model.present(.inserting(text: "Hello"))
        #expect(model.badgeInsertPulse == before + 1)
        model.present(.inserting(text: "Hello there"))
        #expect(model.badgeInsertPulse == before + 1, "one pulse per insert, not per text update")
        model.present(.hidden)
        #expect(model.destinationIdentity == nil)
    }

    @Test func handsFreeDestinationChangeBounces() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        model.latched = true
        model.destinationIdentityProvider = { self.app("Notes", "com.apple.Notes") }
        model.present(.latched(elapsed: 1))
        let a = model.badgeAttention
        model.destinationChanged(to: app("Notes", "com.apple.Notes"))
        #expect(model.badgeAttention == a, "same destination: no bounce")
        model.destinationChanged(to: app("Slack", "com.tinyspeck.slackmacgap"))
        #expect(model.badgeAttention == a + 1)
        #expect(model.destinationIdentity?.appName == "Slack")
    }

    @Test func lateDetailsRefineWithoutBounce() {
        let model = PillViewModel()
        model.now = { Self.t0 }
        let quick = DestinationIdentity(appIcon: icon, appName: "Safari", isBrowser: true, bundleID: "com.apple.Safari")
        model.destinationIdentityProvider = { quick }
        model.present(.listening(level: 0.2))
        let a = model.badgeAttention
        var full = quick
        full.tabTitle = "Claude"; full.siteHost = "claude.ai"; full.siteFavicon = fav
        model.destinationDetailsResolved(full)
        #expect(model.destinationIdentity?.siteFavicon != nil)
        #expect(model.destinationIdentity?.tabTitle == "Claude")
        #expect(model.badgeAttention == a)
        // Details for another app (the user moved on) are ignored.
        model.destinationDetailsResolved(app("Mail", "com.apple.mail"))
        #expect(model.destinationIdentity?.appName == "Safari")
    }
}
