import AppKit
import SwiftUI

/// Public entry point wired by P1.1 / P1.12. One window at a time; re-showing brings it forward.
@MainActor
public enum OnboardingWindowController {
    private static var window: NSWindow?
    private static var viewModel: OnboardingViewModel?

    public static func show(dependencies: OnboardingDependencies, onFinished: ((Bool) -> Void)? = nil) {
        if let window {
            // Re-showing must re-place too: the display arrangement (or the active Space) may have
            // changed since the window was created.
            WindowPlacement.place(window, label: "onboarding (reshow)")
            return
        }
        let model = OnboardingViewModel(dependencies: dependencies)
        model.onFinished = onFinished
        let host = NSHostingController(rootView: OnboardingView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to VoicePlus"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        // Never `center()`: that centres on NSScreen.main, which on this user's machine was an
        // AirPlay display running a full-screen Space — window off-screen, app apparently dead.
        WindowPlacement.place(w, label: "onboarding")
        window = w
        viewModel = model
    }

    public static func close() {
        // Closing mid-mic-check must not leave capture (and the poll timer) running.
        viewModel?.teardown()
        window?.close()
        window = nil
        viewModel = nil
    }

    /// True when onboarding has never been completed or skipped on this machine.
    public static func isNeeded(settings: SettingsStore = UserDefaultsSettingsStore()) -> Bool {
        !(settings.bool(SettingsKeys.onboardingCompleted) ?? false)
    }
}
