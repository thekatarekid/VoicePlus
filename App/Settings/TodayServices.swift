import AppKit
import Foundation
import GRDB
import Shared

// S7b — what Today, the turn detail and the recovery sheet talk to, as one injectable bundle. The
// app's bundle (`TodayServices.live`) reads the turn store S11 installed (`TurnStore.current`), the
// live held queue S3 wired (`TurnWiring.current`), the real pasteboard and the real frontmost app;
// tests hand in stubs for every one, so no rendering depends on hardware.

// MARK: - Pasteboard

/// Copy is acknowledged only when the copy is verified (design §8.1): write, then read back.
public protocol TodayPasteboard: AnyObject {
    /// Replaces the pasteboard's contents with `text`. False when the write was refused.
    @discardableResult func write(_ text: String) -> Bool
    /// The pasteboard's plain-text contents now.
    func read() -> String?
}

public final class SystemTodayPasteboard: TodayPasteboard {
    public init() {}

    public func write(_ text: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(text, forType: .string)
    }

    public func read() -> String? { NSPasteboard.general.string(forType: .string) }
}

public extension TodayPasteboard {
    /// Writes `text` and reads it back. True only when the pasteboard holds exactly `text`.
    func copyVerified(_ text: String) -> Bool {
        guard write(text) else { return false }
        return read() == text
    }
}

// MARK: - The turn store, for Today

/// Today's reader over the app's `TurnStore` (S11).
///
/// `TurnStore` answers every read, including a failed one, with rows — an unreadable database comes
/// back as `[]`, which Today would render as "Nothing dictated yet". Design §9 forbids exactly that
/// ("History can't be read"; never claim the store is empty), so this reader asks the database
/// directly whether the turn table can be read before believing an empty answer.
///
/// It also keeps the store's save failures (S03, `onPersistFailure`) and turns every change into one
/// coalesced `didChange` notification on the main queue, so an open Today follows new turns.
public final class TodayTurnStoreReader: TodayTurnReading, @unchecked Sendable {
    /// Posted on the main queue after the store changed (coalesced).
    public static let didChange = Notification.Name("VoicePlus.Today.turnsDidChange")

    private let store: TurnStore
    private let database: AppDatabase?
    private let lock = NSLock()
    private var failedSaves: Set<TurnID> = []
    private var changePending = false

    private static let registryLock = NSLock()
    private static var readers: [ObjectIdentifier: TodayTurnStoreReader] = [:]

    /// One reader per store: its callbacks are chained exactly once.
    public static func shared(for store: TurnStore, database: AppDatabase?) -> TodayTurnStoreReader {
        registryLock.withLock {
            if let reader = readers[ObjectIdentifier(store)] { return reader }
            let reader = TodayTurnStoreReader(store: store, database: database)
            readers[ObjectIdentifier(store)] = reader
            return reader
        }
    }

    public init(store: TurnStore, database: AppDatabase?) {
        self.store = store
        self.database = database
        // Chain, never replace: whoever set these before keeps getting them.
        let previousChange = store.onChange
        store.onChange = { [weak self] entry in
            previousChange?(entry)
            self?.changed(entry)
        }
        let previousRemove = store.onRemove
        store.onRemove = { [weak self] id in
            previousRemove?(id)
            self?.removed(id)
        }
        let previousFailure = store.onPersistFailure
        store.onPersistFailure = { [weak self] id, reason in
            previousFailure?(id, reason)
            self?.saveDidFail(id)
        }
    }

    // MARK: TodayTurnReading

    public func recentTurns(limit: Int) throws -> [TurnEntry] {
        try probe()
        return store.recent(limit: limit)
    }

    public func recoverableTurns(limit: Int) -> [TurnEntry] { store.recoverable(limit: limit) }

    public func turnEntry(_ id: TurnID) throws -> TurnEntry? {
        if let entry = store.entry(id) { return entry }
        // Not in memory and not found: gone — unless the store could not be asked at all.
        try probe()
        return nil
    }

    public var persistence: TurnStore.Persistence { store.persistence }

    public func saveFailed(_ id: TurnID) -> Bool { lock.withLock { failedSaves.contains(id) } }

    public func markResolved(_ id: TurnID) { store.update(id, stage: .resolved) }

    public func recordInsertion(_ id: TurnID, outcome: DeliveryOutcome) {
        let stage: TurnStage = outcome.isHeld ? .held : (outcome.writeReachedDestination ? .landed : .failed)
        store.update(id, stage: stage) { record in
            record.outcome = outcome
            if outcome.writeReachedDestination { record.writeAttempted = true }
        }
    }

    public func delete(_ id: TurnID) { store.remove(id) }

    // MARK: Store callbacks

    /// Reads one row of the turn table. Throws when there is a database and the table can't be read
    /// (missing, corrupt, locked out) — the one case the store itself hides.
    private func probe() throws {
        guard let database else { return }
        _ = try database.reader.read { db in
            try Row.fetchOne(db, sql: "SELECT id FROM \(TurnStore.table) LIMIT 1")
        }
    }

    private func changed(_ entry: TurnEntry) {
        if entry.persisted { lock.withLock { _ = failedSaves.remove(entry.id) } }
        announce()
    }

    private func removed(_ id: TurnID) {
        lock.withLock { _ = failedSaves.remove(id) }
        announce()
    }

    private func saveDidFail(_ id: TurnID) {
        lock.withLock { _ = failedSaves.insert(id) }
        announce()
    }

    private func announce() {
        let post = lock.withLock { () -> Bool in
            guard !changePending else { return false }
            changePending = true
            return true
        }
        guard post else { return }
        DispatchQueue.main.async { [weak self] in
            self?.lock.withLock { self?.changePending = false }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}

// MARK: - The bundle

/// Everything the Today section reaches outside itself. `live` is the app's; tests build their own.
@MainActor
public struct TodayServices {
    /// The turn store's reader. Resolved on every read: the store is installed by the composition
    /// root (`TurnWiring.attach`) and may appear after the window model was built.
    public var turns: @MainActor () -> (any TodayTurnReading)?
    /// "Save dictation history" (`TodayHistorySettings`).
    public var historyEnabled: @MainActor () -> Bool
    /// The injector's held queue (`FocusGuard`), for held text the pill's queue does not list.
    public var injection: @MainActor () -> (any TodayInjectionQueue)?
    public var pasteboard: any TodayPasteboard
    /// Where "Insert here" would go, and bringing it forward. Built on first use.
    public var destinations: @MainActor () -> any RecoveryDestinations
    /// Posted when the turn store changed; Today reloads on it.
    public var turnsDidChange: Notification.Name

    public init(turns: @escaping @MainActor () -> (any TodayTurnReading)?,
                historyEnabled: @escaping @MainActor () -> Bool,
                injection: @escaping @MainActor () -> (any TodayInjectionQueue)? = { nil },
                pasteboard: any TodayPasteboard = SystemTodayPasteboard(),
                destinations: @escaping @MainActor () -> any RecoveryDestinations = { LiveRecoveryDestinations.shared },
                turnsDidChange: Notification.Name = TodayTurnStoreReader.didChange) {
        self.turns = turns
        self.historyEnabled = historyEnabled
        self.injection = injection
        self.pasteboard = pasteboard
        self.destinations = destinations
        self.turnsDidChange = turnsDidChange
    }

    /// The app's: `TurnStore.current` through `TodayTurnStoreReader`, the history switch in
    /// `settings`, `FocusGuard` through `TurnWiring.current`, the general pasteboard and the real
    /// frontmost app.
    public static func live(settings: SettingsStore?, database: AppDatabase?) -> TodayServices {
        // Start following app activations now, while the app the user was in is still frontmost:
        // the recovery sheet's first destination preview then already knows it.
        _ = LiveRecoveryDestinations.shared
        return TodayServices(
            turns: { TurnStore.current.map { TodayTurnStoreReader.shared(for: $0, database: database) } },
            historyEnabled: { TodayHistorySettings.isEnabled(settings) },
            injection: { TurnWiring.current.map { LiveTodayInjectionQueue(focusGuard: $0.controller.focusGuard) } })
    }
}
