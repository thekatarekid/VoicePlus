import AppKit
import Foundation

// V5 L3 · keeps the ambient listener's attachment matching the world.
//
// The listener is attached exactly while the mode listens and the microphone is not hard-muted.
// Three things can change that, and each is followed:
// * the mode — written by the menu (`AmbientModeController`), Settings › Privacy and by voice, all of
//   which land in `UserDefaults` (`UserDefaults.didChangeNotification`);
// * hard mute — `MuteController.observe` (mute also stands every recorder down in `SessionCoordinator`);
// * lock and sleep — V3 §8 closes the microphone for every subscriber; `SessionCoordinator` forgets the
//   recorder, and this detaches it. Unlock / wake rejoins only because the mode is a standing setting
//   the user chose (the menu-bar glyph and the system mic indicator say it is listening again);
// * the capture graph being swapped after an engine change — the old stream ends, and the periodic
//   check rejoins the new graph (`interval`, cheap: a settings read and a flag).

public final class AmbientListenerWiring: @unchecked Sendable {
    public let listener: AmbientListener
    private let isMuted: () -> Bool
    private var defaultsObserver: NSObjectProtocol?
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private let lock = NSLock()
    private var suspended = false

    public init(listener: AmbientListener, isMuted: @escaping () -> Bool) {
        self.listener = listener
        self.isMuted = isMuted
    }

    deinit {
        timer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        systemObservers.forEach { $0.0.removeObserver($0.1) }
    }

    /// Lock / sleep: leave the capture until unlock / wake.
    public func setSuspended(_ on: Bool) {
        lock.withLock { suspended = on }
        update()
    }

    /// Starts following. Call once at launch, on the main thread.
    public func start(mute: MuteController?, interval: TimeInterval = 10) {
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: nil) { [weak self] _ in
            // Async: a defaults write can happen anywhere, including under a capture transition.
            DispatchQueue.main.async { self?.update() }
        }
        mute?.observe { [weak self] _ in DispatchQueue.main.async { self?.update() } }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for (center, name, on) in [(workspace, NSWorkspace.willSleepNotification, true),
                                   (workspace, NSWorkspace.didWakeNotification, false),
                                   (distributed, Notification.Name("com.apple.screenIsLocked"), true),
                                   (distributed, Notification.Name("com.apple.screenIsUnlocked"), false)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.setSuspended(on) }
            systemObservers.append((center, token))
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    /// Detaches while muted, locked or asleep; otherwise lets the listener follow the mode.
    public func update() {
        if isMuted() || lock.withLock({ suspended }) { listener.detach() } else { listener.refresh() }
    }
}
