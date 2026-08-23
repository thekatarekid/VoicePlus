import Foundation
import Shared

/// Global network kill switch (T3 / T5). Backed by `UserDefaults` key `network.killSwitch`.
///
/// Providers do not import Lab; they take a closure at init, e.g.
/// `provider.egressAllowed = { EgressGate.shared.isAllowed(host: $0) }` (wired by P1.12),
/// and must call it before every request. When the switch is on, nothing may leave the machine.
/// Providers should also call `EgressGate.shared.log(...)` (or insert a `NetworkLogRecord`
/// themselves) after every request so the Data Panel stays complete.
public final class EgressGate: @unchecked Sendable {
    public static let killSwitchKey = "network.killSwitch"
    public static let shared = EgressGate(defaults: .standard)

    public enum Denied: Error, Equatable { case killSwitch(host: String) }

    public let defaults: UserDefaults
    private let lock = NSLock()
    private var blocked: [(Date, String)] = []
    public var database: AppDatabase?

    public init(defaults: UserDefaults, database: AppDatabase? = nil) {
        self.defaults = defaults
        self.database = database
    }

    public var isKillSwitchOn: Bool {
        get { defaults.bool(forKey: Self.killSwitchKey) }
        set { defaults.set(newValue, forKey: Self.killSwitchKey) }
    }

    /// The closure Providers get injected. Records blocked attempts so the panel can show them.
    public func isAllowed(host: String) -> Bool {
        if isKillSwitchOn {
            lock.lock(); blocked.append((Date(), host)); if blocked.count > 200 { blocked.removeFirst() }; lock.unlock()
            Log.network.notice("egress to \(host) blocked by kill switch")
            return false
        }
        return true
    }

    public func check(host: String) throws {
        guard isAllowed(host: host) else { throw Denied.killSwitch(host: host) }
    }

    public var blockedAttempts: [(Date, String)] { lock.lock(); defer { lock.unlock() }; return blocked }

    /// Convenience for Providers that log through the gate.
    @discardableResult
    public func log(stage: String, provider: String, host: String, bytesOut: Int, bytesIn: Int, purpose: String) throws -> NetworkLogRecord? {
        guard let database else { return nil }
        return try database.insert(NetworkLogRecord(stage: stage, provider: provider, host: host, bytesOut: bytesOut, bytesIn: bytesIn, purpose: purpose))
    }
}
