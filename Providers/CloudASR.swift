import Foundation
import Shared

/// T7. Cloud ASR slot. Hidden behind `FeatureFlag.cloudASR` (default off, post-v1).
/// No transport is wired in Phase 1; the slot exists so the routing table, Data Panel and
/// settings can reason about it.
public struct CloudASRProvider: Provider {
    public let secrets: SecretStore
    public let session: URLSession
    public init(secrets: SecretStore, session: URLSession = .shared) { self.secrets = secrets; self.session = session }

    public let id: ProviderID = "cloud.asr"
    public let displayName = "Cloud speech recognition"
    public let capabilities: ProviderCapabilities = [.asr]
    public let costClass: CostClass = .metered
    public let privacyClass: PrivacyClass = .cloud

    public func isAvailable() async -> Bool { false }   // no transport in Phase 1

    public func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext) async throws -> ProviderCompletion {
        guard context.isEnabled(.cloudASR) else { throw ProviderError.flagDisabled(FeatureFlag.cloudASR.id) }
        throw ProviderError.capabilityMissing("pipeline")
    }
}
