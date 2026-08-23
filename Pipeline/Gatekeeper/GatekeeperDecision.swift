import Foundation
import Shared

/// What the gatekeeper decided for one utterance (P1.7 T1).
public struct GatekeeperDecision: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case rules, bayes, context, provider, fallback
    }

    public var route: Utterance.Route
    public var register: Utterance.Register
    public var routeConfidence: Float
    public var registerConfidence: Float
    public var routeSource: Source
    public var registerSource: Source
    public var latencyMs: Double

    public init(
        route: Utterance.Route, register: Utterance.Register,
        routeConfidence: Float, registerConfidence: Float,
        routeSource: Source, registerSource: Source, latencyMs: Double = 0
    ) {
        self.route = route
        self.register = register
        self.routeConfidence = routeConfidence
        self.registerConfidence = registerConfidence
        self.routeSource = routeSource
        self.registerSource = registerSource
        self.latencyMs = latencyMs
    }

    public static func fallback(register: Utterance.Register = .unknown) -> GatekeeperDecision {
        GatekeeperDecision(route: .dictate, register: register, routeConfidence: 0, registerConfidence: 0,
                           routeSource: .fallback, registerSource: .fallback)
    }
}

/// Synchronous local classifier. Must stay well under the 15 ms budget.
public protocol GatekeeperClassifying: Sendable {
    func classify(_ text: String, context: StageContext) -> GatekeeperDecision
}

/// Optional provider-backed classifier (T10 hook). Return `nil` to defer to the local
/// classifier. Implementations live in the Providers module.
public protocol ProviderGatekeeperClassifying: Sendable {
    func classify(_ text: String, context: StageContext) async throws -> GatekeeperDecision?
}
