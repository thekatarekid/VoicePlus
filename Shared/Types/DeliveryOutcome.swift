import Foundation

/// R2.1 — what actually happened to one piece of committed text (Build doc §2, V3 §6).
///
/// The readback rule: a method that posted without throwing has *possibly landed*.
/// If readback cannot confirm it, the outcome is `.delivered(verified: false, …)` — never
/// a retry with another method. Only a method that threw before posting anything may fall
/// through to the next one.
///
/// Encoded with an explicit `kind` discriminator so logs and persisted rows stay readable
/// and stable:
/// `{"kind":"delivered","verified":false,"method":"paste"}`,
/// `{"kind":"partial","method":"keystroke"}`,
/// `{"kind":"held","reason":"destination changed"}`,
/// `{"kind":"failed","reason":"secure field"}`.
public enum DeliveryOutcome: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Text was posted. `verified` is `true` only when readback confirmed it; `method`
    /// names the injection method that posted (e.g. `"keystroke"`, `"paste"`).
    case delivered(verified: Bool, method: String)
    /// G0.1 — a method began posting and stopped part-way (it threw, or readback shows only part
    /// of the payload). Some text may be in the destination; it is uncertain, never "nothing was
    /// typed", and never retried with another method (design §12). The user reviews both versions.
    case partial(method: String)
    /// Committed text with no safe destination. Waits for Insert here / Copy / Discard.
    case held(reason: String)
    /// Nothing was posted and nothing is pending.
    case failed(reason: String)

    // MARK: - Convenience surface

    /// True when nothing further will happen on its own. `.held` is *not* terminal: it is
    /// waiting for the user to choose Insert here / Copy / Discard.
    public var isTerminal: Bool {
        switch self {
        case .delivered, .partial, .failed: return true
        case .held: return false
        }
    }

    /// True for `.delivered`, whether or not readback confirmed it. A `.partial` write is not a
    /// delivery; see `isPartial`.
    public var isDelivered: Bool {
        if case .delivered = self { return true }
        return false
    }

    /// True only for a delivery readback actually confirmed. Drives the "Landed" copy;
    /// unverified deliveries must say so instead.
    public var isVerified: Bool {
        if case .delivered(let verified, _) = self { return verified }
        return false
    }

    /// G0.1 — part of the payload may have been written.
    public var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }

    /// True when a method posted at least part of the payload (`.delivered` or `.partial`) — the
    /// readback rule's "possibly landed": no other method may follow.
    public var writeReachedDestination: Bool {
        switch self {
        case .delivered, .partial: return true
        case .held, .failed: return false
        }
    }

    /// True when the text still exists and needs a user decision.
    public var isHeld: Bool {
        if case .held = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// The injection method that posted, when one did (fully or in part).
    public var method: String? {
        switch self {
        case .delivered(_, let method), .partial(let method): return method
        case .held, .failed: return nil
        }
    }

    /// The reason a delivery is held or failed.
    public var reason: String? {
        switch self {
        case .delivered, .partial: return nil
        case .held(let reason), .failed(let reason): return reason
        }
    }

    /// Log-friendly form: `delivered(verified, paste)` · `partial(keystroke)` · `held(destination changed)`.
    public var description: String {
        switch self {
        case .delivered(let verified, let method):
            return "delivered(\(verified ? "verified" : "unverified"), \(method))"
        case .partial(let method): return "partial(\(method))"
        case .held(let reason): return "held(\(reason))"
        case .failed(let reason): return "failed(\(reason))"
        }
    }

    // MARK: - Codable

    /// Stable discriminator values; also the strings written to logs and rows.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case delivered, partial, held, failed
    }

    public var kind: Kind {
        switch self {
        case .delivered: return .delivered
        case .partial: return .partial
        case .held: return .held
        case .failed: return .failed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, verified, method, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .delivered:
            self = .delivered(
                verified: try c.decodeIfPresent(Bool.self, forKey: .verified) ?? false,
                method: try c.decodeIfPresent(String.self, forKey: .method) ?? ""
            )
        case .partial:
            self = .partial(method: try c.decodeIfPresent(String.self, forKey: .method) ?? "")
        case .held:
            self = .held(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case .failed:
            self = .failed(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .delivered(let verified, let method):
            try c.encode(verified, forKey: .verified)
            try c.encode(method, forKey: .method)
        case .partial(let method):
            try c.encode(method, forKey: .method)
        case .held(let reason), .failed(let reason):
            try c.encode(reason, forKey: .reason)
        }
    }
}
