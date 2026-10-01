import Foundation

// V5 N3 — the pill's "📝 notes · N" chip, as data. Shown in the pill's chip row while the turn is on
// screen and notes have accumulated since Notes was last opened; clicking it opens the section.
// Drawn by `PillChipRow` (App/UI/PillView.swift); fed by `NotesChipFeed` from the one store.
public enum NotesChip {
    public static func isVisible(count: Int) -> Bool { count > 0 }
    public static func title(count: Int) -> String { NotesCopy.chip(count) }
    public static func accessibilityLabel(count: Int) -> String {
        count == 1 ? "1 note kept" : "\(count) notes kept"
    }
}

/// Keeps a count in step with the Notes store: recounts on every add / delete and when Notes is
/// opened (which marks everything seen). The composition root points `onCount` at the pill model
/// and the status menu.
public final class NotesChipFeed: @unchecked Sendable {
    public let store: NotesStore
    private let settings: (any SettingsStore)?
    private var observer: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    /// Called on the main queue with the current unread count.
    public var onCount: ((Int) -> Void)? {
        didSet { publish() }
    }

    public init(store: NotesStore, settings: (any SettingsStore)?) {
        self.store = store
        self.settings = settings
        observer = NotificationCenter.default.addObserver(forName: NotesStore.didChange, object: store, queue: .main) { [weak self] _ in
            self?.publish()
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: NotesStore.didMarkSeen, object: nil, queue: .main) { [weak self] _ in
            self?.publish()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    public var count: Int { store.unreadCount(since: NotesStore.lastSeen(settings)) }

    public func publish() { onCount?(count) }
}
