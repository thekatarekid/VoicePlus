import Foundation

/// P5.2 — "printed inside pill first 10 uses, then fades". Counts successful wake-verb uses; the
/// pill asks `hint(for:)` each time it enters hands-free listening.
public final class WakeVerbHintModel: @unchecked Sendable {
    public static let fullHintUses = 10
    public static let fadeUses = 5
    public static let hintText = "Say “type …”, “send”, or “<app> …”"

    public enum Presentation: Equatable, Sendable {
        case full                  // first 10 uses
        case faded(opacity: Double) // uses 11…15, linearly to 0
        case hidden
    }

    private let lock = NSLock()
    private var uses: Int
    private let persist: ((Int) -> Void)?

    /// `initialUses` restores a persisted counter; `persist` is called on every increment (App wires UserDefaults).
    public init(initialUses: Int = 0, persist: ((Int) -> Void)? = nil) { uses = initialUses; self.persist = persist }

    public var useCount: Int { lock.lock(); defer { lock.unlock() }; return uses }

    public func recordUse() {
        lock.lock(); uses += 1; let u = uses; lock.unlock()
        persist?(u)
    }

    public var presentation: Presentation {
        let u = useCount
        if u < Self.fullHintUses { return .full }
        let over = u - Self.fullHintUses
        if over < Self.fadeUses { return .faded(opacity: 1 - Double(over + 1) / Double(Self.fadeUses + 1)) }
        return .hidden
    }

    /// Text the pill should print, or nil once faded out.
    public var hintText: String? { presentation == .hidden ? nil : Self.hintText }

    public func reset() { lock.lock(); uses = 0; lock.unlock(); persist?(0) }
}
