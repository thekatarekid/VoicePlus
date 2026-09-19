import AppKit
import SwiftUI

/// Public entry point wired by P1.1 / P1.12. One window at a time; re-showing brings it forward.
///
/// S8 (design §8.7): a normal closable window, never a full-screen input trap. Closing it — with the
/// close button or "Set up later" — keeps the step the user was on, and the next open resumes there.
@MainActor
public enum OnboardingWindowController {
    private static var window: NSWindow?
    private static var viewModel: OnboardingViewModel?
    private static var closeObserver: CloseObserver?

    /// The composition root's wiring for things only it can reach (the model loader, the enrollment
    /// recorder, the live hotkey service). Applied to every `show`, whichever entry point calls it —
    /// launch, Settings' "Run onboarding again", a resume — so no path opens a half-wired window.
    public static var configure: ((inout OnboardingDependencies) -> Void)?

    public static func show(dependencies: OnboardingDependencies, onFinished: ((Bool) -> Void)? = nil) {
        if let window {
            // Re-showing must re-place too: the display arrangement (or the active Space) may have
            // changed since the window was created.
            WindowPlacement.place(window, label: "onboarding (reshow)")
            return
        }
        var deps = dependencies
        configure?(&deps)
        let model = OnboardingViewModel(dependencies: deps)
        model.onFinished = onFinished
        model.onClose = { close() }
        model.onOpenVoicePlus = {
            close()
            if !MainWindowController.show(section: .today) {
                MainWindowController.show(dependencies: deps, section: .today)
            }
        }
        let host = NSHostingController(rootView: OnboardingView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to VoicePlus"
        w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        // An ordinary window: never floating, never full screen, never modal.
        w.level = .normal
        w.collectionBehavior = [.fullScreenNone]
        let observer = CloseObserver { windowWillClose() }
        w.delegate = observer
        closeObserver = observer
        // Never `center()`: that centres on NSScreen.main, which on this user's machine was an
        // AirPlay display running a full-screen Space — window off-screen, app apparently dead.
        WindowPlacement.place(w, label: "onboarding")
        window = w
        viewModel = model
    }

    public static func close() {
        // Closing mid-mic-check must not leave capture (and the poll timer) running.
        guard let w = window else { return }
        w.close()   // → windowWillClose
    }

    /// Every way the window goes away ends here: capture and timers stop, and the step stays
    /// persisted for the next open.
    private static func windowWillClose() {
        viewModel?.teardown()
        window?.delegate = nil
        window = nil
        viewModel = nil
        closeObserver = nil
    }

    /// True when onboarding has never been completed or skipped on this machine.
    public static func isNeeded(settings: SettingsStore = UserDefaultsSettingsStore()) -> Bool {
        !(settings.bool(SettingsKeys.onboardingCompleted) ?? false)
    }

    /// The window's delegate: routes the close button through the same teardown as "Set up later".
    private final class CloseObserver: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { onClose() }
        }
    }
}
