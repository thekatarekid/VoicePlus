import AppKit
import ApplicationServices
import Foundation
import Injection
import Shared

// S7b — what the recovery sheet's **Insert here** stands on (design §8.1, §5; `DESIGN.md` §9.1).
//
// Insert here is an explicit re-target: the user picks a text field in another app (the field that
// has focus in the app they last worked in — that is the "current destination preview"), comes back,
// and chooses Insert here. The sheet then brings that app forward, reads the field that has focus
// once it is frontmost, and only inserts when it is still the field the user picked — a moved focus,
// a password field or a non-text element holds the text instead (revalidate after the pick). A new
// destination never receives held text on its own.
//
// Nothing here can be exercised without a window server, Accessibility trust and a second app, so
// the sheet talks to `RecoveryDestinations` and `TodayInjectionQueue`; the live implementations below
// are `implemented` only, and the tests drive stubs.

// MARK: - The field Insert here would use

/// A text field in another app, as one read saw it.
public struct RecoveryTarget: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    /// Opaque identity of the focused element (the AX element's hash), when readable.
    public var elementToken: String?
    /// AX role of the focused element (`AXTextField`, `AXTextArea`, …); nil when unreadable.
    public var role: String?
    /// A password field. Never written (D03).
    public var isSecure: Bool
    /// Takes typed text: a text role, or a settable value / selection.
    public var isEditable: Bool

    public init(pid: Int32, bundleID: String, appName: String, elementToken: String? = nil, role: String? = nil,
                isSecure: Bool = false, isEditable: Bool = true) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.elementToken = elementToken
        self.role = role
        self.isSecure = isSecure
        self.isEditable = isEditable
    }

    /// The field in words — never an AX role token in copy.
    public var fieldKind: String {
        if isSecure { return "Password field" }
        switch role {
        case "AXTextField": return "Text field"
        case "AXTextArea": return "Text area"
        case "AXSearchField": return "Search field"
        case "AXComboBox": return "Combo box"
        case "AXWebArea": return "Web page"
        default: return isEditable ? "Text field" : "Not a text field"
        }
    }

    /// "Notes · Text area" — the destination preview.
    public var summary: String {
        let app = appName.isEmpty ? TodayCopy.unknownApp : appName
        return "\(app) · \(fieldKind)"
    }

    /// Same app and process, and — when both reads could see it — the same element. An element that
    /// could not be read on one side is not held against the other (many apps re-create their focused
    /// element between reads; `FocusGuard.strictElementIdentity` makes the same call).
    public func isSameField(as other: RecoveryTarget) -> Bool {
        guard pid == other.pid, bundleID == other.bundleID else { return false }
        if let a = elementToken, let b = other.elementToken, a != b { return false }
        return true
    }

    /// The injector's focus expectation for this field.
    public var snapshot: FocusSnapshot {
        FocusSnapshot(pid: pid, bundleID: bundleID, appName: appName, elementToken: elementToken)
    }
}

/// Where Insert here would go, and bringing it forward.
@MainActor
public protocol RecoveryDestinations: AnyObject {
    /// VoicePlus can read other apps' fields (Accessibility). Without it nothing can be inserted
    /// (P02 "Allow VoicePlus to type").
    var canReadFields: Bool { get }
    /// The focused field of the app the user last worked in (never VoicePlus itself). Nil when there
    /// is no such app yet or nothing in it has focus.
    func pickedTarget() -> RecoveryTarget?
    /// Brings `target`'s app to the front and returns the field that has focus once it is frontmost
    /// — nil when the app never came forward.
    func bringForward(_ target: RecoveryTarget) async -> RecoveryTarget?
    /// Opens System Settings › Privacy & Security › Accessibility.
    func openAccessibilitySettings()
}

// MARK: - Live: NSWorkspace + Accessibility

/// The live destinations: remembers the last app other than VoicePlus that was frontmost, and reads
/// its focused element through Accessibility. `implemented` — needs a window server, Accessibility
/// trust and another app to verify (build doc §5).
@MainActor
public final class LiveRecoveryDestinations: RecoveryDestinations {
    public static let shared = LiveRecoveryDestinations()

    private var lastOther: NSRunningApplication?
    private var observer: NSObjectProtocol?
    /// How long an activation may take before Insert here gives up (and holds the text).
    public var activationTimeout: TimeInterval = 1.5
    /// Settle time after the app is frontmost, for it to restore its own focused field.
    public var focusSettle: TimeInterval = 0.15

    public init() {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own { lastOther = front }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != own else { return }
            MainActor.assumeIsolated { self?.lastOther = app }
        }
    }

    public var canReadFields: Bool { AXIsProcessTrusted() }

    public func pickedTarget() -> RecoveryTarget? {
        guard let app = lastOther, !app.isTerminated else { return nil }
        return Self.target(of: app)
    }

    public func bringForward(_ target: RecoveryTarget) async -> RecoveryTarget? {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return nil }
        app.activate(options: [])
        let deadline = Date().addingTimeInterval(activationTimeout)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != target.pid {
            guard Date() < deadline else { return nil }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: UInt64(focusSettle * 1_000_000_000))
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self.target(of: front)
    }

    public func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The app's focused element through `AXUIElementCreateApplication` — readable while the app is
    /// in the background, so the preview works with VoicePlus in front.
    static func target(of app: NSRunningApplication) -> RecoveryTarget? {
        let pid = app.processIdentifier
        var target = RecoveryTarget(pid: pid, bundleID: app.bundleIdentifier ?? "",
                                    appName: app.localizedName ?? "", isEditable: false)
        guard AXIsProcessTrusted() else { return target }
        let root = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement // swiftlint:disable:this force_cast
        func string(_ attribute: String) -> String? {
            var out: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
            return out as? String
        }
        func settable(_ attribute: String) -> Bool {
            var flag = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success && flag.boolValue
        }
        let role = string(kAXRoleAttribute)
        let subrole = string(kAXSubroleAttribute)
        target.role = role
        target.elementToken = String(CFHash(element))
        target.isSecure = role == FocusedElementInfo.secureRole || subrole == FocusedElementInfo.secureRole
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
        target.isEditable = textRoles.contains(role ?? "") || settable(kAXValueAttribute) || settable(kAXSelectedTextAttribute)
        return target
    }
}

// MARK: - The injector's held queue

/// The injector's own held queue (`FocusGuard.held`), for held text the pill's queue does not list
/// (a turn held without a delivery row) and for text held before a relaunch, which no live queue
/// has. Held text the pill lists goes through the pill's `heldAction` instead, so the pill row and
/// the status menu drop it too.
@MainActor
public protocol TodayInjectionQueue: AnyObject {
    /// The turn a live held item carries.
    func turn(ofHeld id: UUID) -> TurnID?
    /// The live held item carrying `turn`'s payload.
    func heldID(forTurn turn: TurnID) -> UUID?
    /// Insert here for a live held item: the whole stack against the current focus, once.
    func insertHeld(_ id: UUID) -> DeliveryOutcome?
    /// Inserts text no live queue holds, at the current focus, refusing if focus is not `target`.
    func insert(text: String, turn: TurnID?, expecting target: RecoveryTarget) -> DeliveryOutcome?
    func copyHeld(_ id: UUID) -> Bool
    func discardHeld(_ id: UUID) -> Bool
}

/// The live queue: `FocusGuard` as S3 wired it (`TurnWiring.current`). Resolutions report back to
/// the turn through `FocusGuard.onResolved` → `TurnController`, so the turn record follows.
@MainActor
public final class LiveTodayInjectionQueue: TodayInjectionQueue {
    private let focusGuard: FocusGuard

    public init(focusGuard: FocusGuard) { self.focusGuard = focusGuard }

    public func turn(ofHeld id: UUID) -> TurnID? { focusGuard.heldText(id: id)?.turnID }

    public func heldID(forTurn turn: TurnID) -> UUID? { focusGuard.heldText(turn: turn)?.id }

    public func insertHeld(_ id: UUID) -> DeliveryOutcome? { focusGuard.insertHere(id)?.delivery }

    public func insert(text: String, turn: TurnID?, expecting target: RecoveryTarget) -> DeliveryOutcome? {
        guard let inserter = focusGuard.inserter else { return nil }
        let snapshot = target.snapshot
        let item = HeldText(request: InjectionRequest(text: text, expectedFocus: snapshot), destination: snapshot,
                            reason: DeliveryReason.destinationChanged, turnID: turn)
        return inserter(item).delivery
    }

    public func copyHeld(_ id: UUID) -> Bool { focusGuard.copy(id) }

    public func discardHeld(_ id: UUID) -> Bool { focusGuard.discard(id) }
}
