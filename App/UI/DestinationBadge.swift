import AppKit
import SwiftUI

/// H31 — the destination badge on the turn pill's listening, inserting and outcome rows (Follow-up §6
/// "Destination logo", owner decision round 3 "Destination identity"): the app icon, or for a web page the
/// real site favicon with the browser's icon tucked in its corner. 22 pt. Inserting: the badge pulses once
/// as the words sweep in. Destination change during hands-free: a short bounce plus a ring. Reduce Motion:
/// static badge, no pulse, no bounce, no ring.
public enum DestinationBadgeRule {
    /// 22–24 pt per the fix list; 22 sits on the 16 pt status line without growing the row.
    public static let size: CGFloat = 22
    /// The browser icon in the favicon's corner.
    public static let cornerSize: CGFloat = 11

    /// Listening, inserting and outcome rows only — never the hint, warnings, errors or transform rows.
    public static func showsBadge(for state: PillState) -> Bool {
        switch state {
        case .listening, .listeningQuiet, .latched, .landing, .inserting, .landed, .landedPartial, .held, .undoAvailable:
            return true
        default:
            return false
        }
    }

    public enum Motion: Equatable { case none, insertSweep, attention }

    public enum Event: Equatable { case inserting, destinationChanged, other }

    /// Which animation an event plays; Reduce Motion plays none.
    public static func motion(for event: Event, reduced: Bool) -> Motion {
        guard !reduced else { return .none }
        switch event {
        case .inserting: return .insertSweep
        case .destinationChanged: return .attention
        case .other: return .none
        }
    }

    /// What the badge draws: the primary image and, for a page with a favicon, the browser in the corner.
    public struct Images {
        public var primary: NSImage?
        public var corner: NSImage?
    }

    public static func images(for identity: DestinationIdentity) -> Images {
        if identity.isBrowser, let fav = identity.siteFavicon { return Images(primary: fav, corner: identity.appIcon) }
        return Images(primary: identity.appIcon, corner: nil)
    }

    /// VoiceOver: "Claude in Google Chrome", or the app name.
    public static func accessibilityLabel(for identity: DestinationIdentity) -> String {
        if identity.isBrowser, let title = identity.tabTitle { return "\(title) in \(identity.appName)" }
        return identity.appName
    }
}

struct DestinationBadge: View {
    let identity: DestinationIdentity
    /// Bumped by the model when the row turns `.inserting` (sweep + pulse).
    let insertPulse: Int
    /// Bumped by the model when the destination changes during a hands-free session (bounce + ring).
    let attention: Int
    @ObservedObject private var motion = MotionPreference.shared
    @State private var pulse = false
    @State private var bounce = false
    @State private var ring = false

    init(identity: DestinationIdentity, insertPulse: Int = 0, attention: Int = 0) {
        self.identity = identity
        self.insertPulse = insertPulse
        self.attention = attention
    }

    var body: some View {
        let images = DestinationBadgeRule.images(for: identity)
        let s = DestinationBadgeRule.size
        ZStack(alignment: .bottomTrailing) {
            icon(images.primary)
                .frame(width: s, height: s)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            if let corner = images.corner {
                Image(nsImage: corner).resizable().interpolation(.high)
                    .frame(width: DestinationBadgeRule.cornerSize, height: DestinationBadgeRule.cornerSize)
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: s, height: s)
        .scaleEffect(pulse ? 1.15 : 1)
        .offset(y: bounce ? -4 : 0)
        .overlay(
            Circle().stroke(Tokens.Pill.Token.ink.color.opacity(ring ? 0 : 0.7), lineWidth: 1.5)
                .scaleEffect(ring ? 1.7 : 1)
                .opacity(ring ? 1 : 0)
        )
        .accessibilityElement()
        .accessibilityLabel(DestinationBadgeRule.accessibilityLabel(for: identity))
        .accessibilityIdentifier("pill.destinationBadge")
        .onChange(of: insertPulse) { _, _ in play(.inserting) }
        .onChange(of: attention) { _, _ in play(.destinationChanged) }
    }

    @ViewBuilder private func icon(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Tokens.Pill.Token.secondaryInk.color.opacity(0.3))
        }
    }

    private func play(_ event: DestinationBadgeRule.Event) {
        switch DestinationBadgeRule.motion(for: event, reduced: motion.reduced) {
        case .none: return
        case .insertSweep:
            withAnimation(.easeOut(duration: 0.14)) { pulse = true }
            withAnimation(.easeIn(duration: 0.18).delay(0.14)) { pulse = false }
        case .attention:
            withAnimation(.interpolatingSpring(stiffness: 400, damping: 10)) { bounce = true }
            withAnimation(.interpolatingSpring(stiffness: 400, damping: 12).delay(0.12)) { bounce = false }
            ring = false
            withAnimation(.easeOut(duration: 0.5)) { ring = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { ring = false }
        }
    }
}

/// H31 — the inserting sweep: the words travel into the badge as they land. Drawn over the status row's
/// leading edge while the row is `.inserting` (the ribbon still flies to the caret, Q8). Static under Reduce Motion.
struct DestinationSweep: View {
    let trigger: Int
    @ObservedObject private var motion = MotionPreference.shared
    @State private var progress: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [Tokens.Pill.Token.ink.color.opacity(0), Tokens.Pill.Token.ink.color.opacity(0.35)],
                                     startPoint: .trailing, endPoint: .leading))
                .frame(width: max(0, geo.size.width * (1 - progress)), height: 3)
                .frame(maxHeight: .infinity, alignment: .center)
                .offset(x: DestinationBadgeRule.size / 2)
                .opacity(progress < 1 ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in
            guard !motion.reduced else { return }
            progress = 0
            withAnimation(.easeIn(duration: 0.28)) { progress = 1 }
        }
    }
}
