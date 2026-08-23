import Foundation
import Shared

/// Bet 5: the *act* domain is entered only by the second hotkey — never inferred from phrasing.
/// The App wires its second-key binding (HotkeyStateMachine) to an implementation of this protocol;
/// `ActIntentParser` consults it and stays inert while the domain is off.
public protocol ActDomainActivation: AnyObject, Sendable {
    var isActDomainActive: Bool { get }
    /// Called on second-key down / up by the App layer.
    func activate()
    func deactivate()
}

/// Thread-safe default; the App may subclass or replace it.
public final class ActDomainState: ActDomainActivation, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Bool
    public init(active: Bool = false) { self.active = active }
    public var isActDomainActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    public func activate() { lock.lock(); active = true; lock.unlock() }
    public func deactivate() { lock.lock(); active = false; lock.unlock() }
}

/// Pipeline-agnostic mirror of `Pipeline.GatekeeperPreRouting` (`Actions` does not link `Pipeline`).
/// The composition root adapts it in three lines: `preRoute(text, context:)` → `preRoute(text, appBundleID:)`,
/// returning `GatekeeperDecision(route: .none, …, routeSource: .rules)` when the act domain claimed the utterance.
public protocol ActPreRouting: Sendable {
    func preRoute(_ text: String, appBundleID: String?) -> ActRoute?
}
