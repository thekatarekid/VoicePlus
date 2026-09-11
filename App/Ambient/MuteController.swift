import Foundation

/// Persists the mute state so a muted VoicePlus relaunches muted (unmute is never automatic).
/// "Latch" is the double-tap capture mode (V3 §4.7) and never this — the mute is a *hard mute*.
public protocol MuteStore: AnyObject, Sendable {
    func loadMuted() -> Bool
    func saveMuted(_ muted: Bool)
}

public final class UserDefaultsMuteStore: MuteStore, @unchecked Sendable {
    public static let key = "ambient.muted"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func loadMuted() -> Bool { defaults.bool(forKey: Self.key) }
    public func saveMuted(_ muted: Bool) { defaults.set(muted, forKey: Self.key) }
}

public final class InMemoryMuteStore: MuteStore, @unchecked Sendable {
    public var muted: Bool
    public init(muted: Bool = false) { self.muted = muted }
    public func loadMuted() -> Bool { muted }
    public func saveMuted(_ muted: Bool) { self.muted = muted }
}

/// Owns the `AmbientStateModel`, persists the mute, and fans state changes out to the glyph views.
/// Thread-safe; observers are called synchronously on the mutating thread.
public final class MuteController: @unchecked Sendable {
    public private(set) var model: AmbientStateModel
    private let store: any MuteStore
    private let lock = NSLock()
    private var observers: [(AmbientStateModel) -> Void] = []

    public init(store: any MuteStore) {
        self.store = store
        model = AmbientStateModel(muted: store.loadMuted())
    }

    public var state: AmbientState { lock.withLock { model.state } }
    public var isMuted: Bool { lock.withLock { model.muted } }

    public func observe(_ f: @escaping (AmbientStateModel) -> Void) {
        lock.withLock { observers.append(f) }
        f(lock.withLock { model })
    }

    /// Menu-bar click / dedicated key: one gesture.
    public func toggleMute() { mutate { $0.toggleMute() } }
    public func mute() { mutate { $0.mute() } }
    public func unmute() { mutate { $0.unmute() } }
    public func setProcessing(_ on: Bool) { mutate { $0.setProcessing(on) } }
    public func acknowledgeDirected(at now: Date = Date()) { mutate { $0.acknowledgeDirected(at: now) } }

    private func mutate(_ f: (inout AmbientStateModel) -> Void) {
        let (snapshot, obs): (AmbientStateModel, [(AmbientStateModel) -> Void]) = lock.withLock {
            f(&model); return (model, observers)
        }
        store.saveMuted(snapshot.muted)
        obs.forEach { $0(snapshot) }
    }
}
