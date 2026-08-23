import Foundation
import Lab
import Pipeline
import Providers
import Shared

/// `PipelineProviderRouting` over the Providers `RoutingTable`, honouring the per-stage choice
/// the user made in Settings (`routing.<stage>` = `provider:<id>` / `local:<tier>` / auto).
/// Only an explicit provider pin enables routing; Auto and Local keep every stage on device.
public final class RoutingTableProviderRouting: PipelineProviderRouting, @unchecked Sendable {
    public let table: RoutingTable
    private let settings: SettingsStore
    private let lock = NSLock()

    public init(table: RoutingTable, settings: SettingsStore) {
        self.table = table
        self.settings = settings
    }

    func choice(for stage: StageID) -> ProviderChoice? {
        lock.withLock {
            settings.string(SettingsKeys.routingPrefix + stage.rawValue).flatMap(ProviderChoice.init(rawValue:))
        }
    }

    public func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool {
        guard !RoutingTable.alwaysLocalStages.contains(stage) else { return false }
        if case .provider? = choice(for: stage) { return true }
        return false
    }

    public func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String {
        guard case .provider(let id)? = choice(for: stage) else { throw ProviderRoutingError.disabled(stage: stage) }
        table.setChoice(.provider(ProviderID(rawValue: id)), for: stage)
        let span = TranscriptSpan(text: input, confidence: 1, audioRange: 0...0, provenance: [.asr])
        do {
            return try await table.complete(stage: stage, spans: [span], context: context, purpose: "pipeline:\(stage.rawValue)").completion.spans.joinedText
        } catch {
            throw ProviderRoutingError.unavailable
        }
    }
}

/// Builds the provider table: discovered providers, Keychain secrets, network log → AppDatabase,
/// egress closure → Lab's kill switch. Discovery probes local servers / CLIs only (no network
/// egress by itself: key presence is read from the Keychain, servers from localhost).
public enum ProviderWiring {
    public static func makeTable(database: AppDatabase?, flags: FeatureFlagService, gate: EgressGate) async -> RoutingTable {
        let logger: NetworkLogger = database.map { DatabaseNetworkLogger(db: $0) } ?? InMemoryNetworkLogger()
        let providers = await ProviderDiscovery.discover(secrets: KeychainSecretStore(), flags: flags)
        let table = RoutingTable(providers: providers, logger: logger)
        table.egressAllowed = { host in gate.isAllowed(host: host) }
        Log.providers.info("providers: \(providers.map(\.id.rawValue).joined(separator: ", "))")
        return table
    }
}
