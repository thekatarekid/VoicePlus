import AppKit
import Foundation
import Shared

/// The one-click "macOS is holding this grant until VoicePlus restarts" offer (P6).
///
/// Two things kept this from existing before 1.6.7. The app believed a relaunch was never required
/// — a belief measured on a process that already had the grant, and false for Microphone and Input
/// Monitoring. And the only trigger it did ship, `CapabilityWatcher.onTapProvenDead`, presupposes an
/// armed tap, which is precisely what a frozen `CGPreflightListenEventAccess()` prevents.
///
/// The copy is a pure value so it can be asserted in a unit test; only `present` touches AppKit.
public enum RelaunchPrompt {
    public struct Copy: Equatable, Sendable {
        public var title: String
        public var message: String
        /// Title of the button that quits and reopens, or nil when relaunching cannot help — a
        /// translocated copy can only relaunch into another translocated copy.
        public var relaunchTitle: String?
        public var dismissTitle: String

        public init(title: String, message: String, relaunchTitle: String?, dismissTitle: String) {
            self.title = title
            self.message = message
            self.relaunchTitle = relaunchTitle
            self.dismissTitle = dismissTitle
        }
    }

    /// nil for a service macOS re-reads live — offering a relaunch for Accessibility would teach a
    /// false model of the system and is exactly the over-correction to avoid.
    public static func copy(for permission: Permission,
                            identity: AppCodeIdentity = PermissionDiagnostics.identity()) -> Copy? {
        guard !permission.grantReachesRunningApp else { return nil }
        let consequence: String
        switch permission {
        case .microphone:
            consequence = "Until it restarts, VoicePlus will keep reading the microphone as off and cannot hear you."
        case .inputMonitoring:
            consequence = "Until it restarts, the hold-to-talk key won't work in other apps. The menu-bar “Start dictation” item still does."
        case .accessibility:
            consequence = ""
        }
        // Say what macOS said. The user has just dismissed that exact alert; contradicting it is how
        // 1.6.6 lost their trust, and paraphrasing it loosely is only a slower way to do the same.
        let quoted = permission.systemQuitWarning.map { "macOS put it plainly: \($0)\n\n" } ?? ""
        if identity.isTranslocated {
            return Copy(
                title: "VoicePlus is running from a temporary copy",
                message: quoted
                    + "Relaunching would only make another temporary copy, so it cannot help here. Quit VoicePlus, "
                    + "drag it to your Applications folder, run “\(identity.dequarantineCommand)” in Terminal once, "
                    + "then open it from Applications and turn \(permission.title) on again.",
                relaunchTitle: nil,
                dismissTitle: "OK"
            )
        }
        // Conditional on purpose. The trigger is "you went to Settings and came back with this still
        // reading off", which cannot distinguish "granted it and macOS is withholding it" from
        // "looked and changed nothing" — the app cannot read TCC.db. A headline that asserted the
        // first would be a new false claim, and this whole item exists because of one of those. The
        // conditional sentence is true in both worlds, and costs one click to dismiss.
        return Copy(
            title: "If you just turned \(permission.title) on…",
            message: quoted
                + "macOS doesn't hand a permission to an app that is already running — VoicePlus has "
                + "to be quit and reopened before it can see it. \(consequence)",
            relaunchTitle: "Quit & Reopen",
            dismissTitle: "Later"
        )
    }

    /// Shows the offer once and performs the relaunch if the user takes it. Returns false when there
    /// is nothing honest to show (Accessibility).
    @MainActor
    @discardableResult
    public static func present(for permission: Permission,
                               identity: AppCodeIdentity = PermissionDiagnostics.identity(),
                               relauncher: AppRelaunching = NSWorkspaceRelauncher()) -> Bool {
        guard let copy = copy(for: permission, identity: identity) else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = copy.title
        alert.informativeText = copy.message
        if let relaunchTitle = copy.relaunchTitle {
            alert.addButton(withTitle: relaunchTitle)
        }
        alert.addButton(withTitle: copy.dismissTitle)
        NSApp?.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard copy.relaunchTitle != nil, response == .alertFirstButtonReturn else {
            Log.app.notice("relaunch offer for \(permission.rawValue): dismissed")
            return true
        }
        switch identity.relaunchOutcome {
        case .translocated:
            Log.app.warning("relaunch refused: running translocated from \(identity.bundlePath)")
        case .relaunch(let path):
            Log.app.notice("relaunching \(path) to pick up \(permission.rawValue)")
            relauncher.relaunch(bundlePath: path)
        }
        return true
    }
}
