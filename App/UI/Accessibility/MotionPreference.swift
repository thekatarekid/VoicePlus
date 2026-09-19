import AppKit
import Combine
import SwiftUI

// S10 — Reduce Motion (design §11, §11.1): macOS's Reduce Motion *or* Settings › Appearance › Reduce
// motion. Under it Spool draws its still, representative frame (no reel rotation, no twist, flat
// tape), the tape flight is suppressed, geometry transitions are instant, and a numeric level readout
// stands in for capture motion. State labels, dwell and order never change: only movement does.

/// What Reduce Motion changes, as data. Pure: every surface asks this, never the setting directly.
public struct MotionPolicy: Equatable, Sendable {
    /// macOS › Accessibility › Display › Reduce motion.
    public var system: Bool
    /// Settings › Appearance › Reduce motion (`AppearanceSettings.reducesMotion`).
    public var app: Bool

    public init(system: Bool, app: Bool) {
        self.system = system
        self.app = app
    }

    /// Never less than the system asks for (`AppearanceSettings.effectiveReduceMotion`).
    public var reduced: Bool { system || app }

    /// Spool draws the still frame of its state: parked reels, flat tape, no twist, no blink.
    public var drawsStillSpool: Bool { reduced }

    /// The mouth-to-caret tape flight (S4). Suppressed under Reduce Motion; the label and the
    /// outcome are unchanged.
    public var allowsTapeFlight: Bool { !reduced }

    /// The pill's geometry and row transitions: 180 ms ease-out (design §11: 160–220 ms, no elastic
    /// bounce), none under Reduce Motion.
    public var transitionDuration: TimeInterval { reduced ? 0 : 0.18 }

    /// The same transition as a SwiftUI animation; `nil` = change without animating.
    public var transition: Animation? { reduced ? nil : .easeOut(duration: transitionDuration) }

    /// A numeric level readout replaces the tape's capture motion — only while capture is live
    /// (the states whose tape follows the microphone).
    func showsLevelReadout(for key: SpoolStateKey) -> Bool {
        reduced && SpoolPoseTable.isLive(key)
    }
}

/// The live Reduce Motion preference: the system switch plus the app's own, re-read whenever either
/// changes (`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`, `UserDefaults` writes).
/// `shared` reads the app's real settings store; tests build their own over an in-memory store.
public final class MotionPreference: ObservableObject {
    public static let shared = MotionPreference(store: UserDefaultsSettingsStore())

    @Published public private(set) var policy: MotionPolicy

    public var reduced: Bool { policy.reduced }

    private let store: SettingsStore?
    private let system: () -> Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(store: SettingsStore?,
                system: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
                center: NotificationCenter = .default,
                workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.store = store
        self.system = system
        policy = MotionPolicy(system: system(), app: AppearanceSettings.reducesMotion(store))
        let refresh: (Notification) -> Void = { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread { self.refresh() } else { DispatchQueue.main.async { self.refresh() } }
        }
        observers = [
            (workspaceCenter, workspaceCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil,
                using: refresh)),
            (center, center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil,
                                        using: refresh)),
        ]
    }

    deinit {
        observers.forEach { $0.0.removeObserver($0.1) }
    }

    /// Re-reads both switches; publishes only when the policy changed.
    public func refresh() {
        let next = MotionPolicy(system: system(), app: AppearanceSettings.reducesMotion(store))
        if next != policy { policy = next }
    }
}

/// The numeric capture level shown instead of tape motion under Reduce Motion ("Level 40%"), in
/// 5 % steps so it does not flicker, and its place in the pill: the tape lane, just under the flat
/// tape, inside the text column — never in the character bay, never over the transcript or its marks.
public enum LevelReadout {
    public static let step = 5

    /// 0…100 in `step` increments; silence, NaN and out-of-range levels clamp.
    public static func percent(level: Double) -> Int {
        guard level.isFinite else { return 0 }
        let clamped = Swift.min(1, Swift.max(0, level))
        return Int((clamped * 100 / Double(step)).rounded()) * step
    }

    public static func text(level: Double) -> String { "Level \(percent(level: level))%" }

    static let height: CGFloat = 12
    static let maximumWidth: CGFloat = 96
    /// Below the flat tape's 8 pt ribbon (tape centre `tapeY`).
    static let gapBelowTape: CGFloat = 6

    /// Where the readout sits in a pill of `lanes`.
    static func rect(in lanes: PillLaneLayout) -> CGRect {
        CGRect(x: lanes.statusRow.minX, y: lanes.tapeY + gapBelowTape,
               width: Swift.min(maximumWidth, lanes.statusRow.width), height: height)
    }
}

extension SpoolView {
    /// S10 — whether a Spool draws its still frame: an explicit override wins; otherwise the system
    /// switch (SwiftUI's environment) or the policy (system + Settings › Appearance) reduces it.
    static func reducesMotion(explicit: Bool?, system: Bool, policy: MotionPolicy) -> Bool {
        explicit ?? (system || policy.reduced)
    }
}
