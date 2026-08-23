import Foundation
import Shared

/// P1.7 T10 — the hook any pipeline stage may use to route work to a Provider (P1.10).
///
/// Only the protocol lives here; the `Providers` module implements it later and the app
/// wires an instance into `PipelineRunner`. The local default (`LocalOnlyProviderRouting`)
/// never enables routing, so every stage ships with a purely on-device path.
public protocol PipelineProviderRouting: Sendable {
    /// True when the user has explicitly enabled a provider for this stage.
    func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool

    /// Run `prompt` over `input` on the user's chosen provider and return the completion.
    /// Implementations must log every network call to the Data Panel (ground rule: privacy).
    /// Throw `ProviderRoutingError.unavailable` when no provider is configured; stages then
    /// fall back to their local path.
    func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String
}

public enum ProviderRoutingError: Error, Equatable, Sendable {
    case unavailable
    case disabled(stage: StageID)
}

/// Default: everything stays on device.
public struct LocalOnlyProviderRouting: PipelineProviderRouting {
    public init() {}
    public func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { false }
    public func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String {
        throw ProviderRoutingError.disabled(stage: stage)
    }
}

/// Convenience used by stages: try the provider when enabled, otherwise run `local`.
public extension PipelineProviderRouting {
    func completeOrLocal(
        stage: StageID, prompt: String, input: String, context: StageContext,
        local: () async throws -> String
    ) async throws -> String {
        guard isProviderEnabled(for: stage, context: context) else { return try await local() }
        do { return try await complete(stage: stage, prompt: prompt, input: input, context: context) }
        catch { return try await local() }
    }
}
