import Foundation
import Shared

/// T6. Per-stage provider selection. In the app, `.auto` means **local only**: no stage leaves the
/// Mac unless the user pins `.provider(_)` for it (`RoutingTableProviderRouting` only enables
/// routing for an explicit pin, and Settings/Privacy report Auto as "on this Mac"). `chain(for:)`
/// still orders local providers before cloud ones for `.auto` callers that use the table directly,
/// with fallback down the chain when a provider throws mid-call. Every remote call is
/// logged to `network_log` via `NetworkLogger` (timestamp, stage, provider, bytes, purpose).
public enum RouteChoice: Codable, Equatable, Sendable {
    case auto
    case provider(ProviderID)
    case localOnly
}

public protocol NetworkLogger: Sendable {
    func log(_ record: NetworkLogRecord)
}

public struct DatabaseNetworkLogger: NetworkLogger {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }
    public func log(_ record: NetworkLogRecord) {
        do { try db.insert(record) } catch { Log.providers.error("network log insert failed: \(error)") }
    }
}

public final class InMemoryNetworkLogger: NetworkLogger, @unchecked Sendable {
    private let lock = NSLock(); private var items: [NetworkLogRecord] = []
    public init() {}
    public func log(_ record: NetworkLogRecord) { lock.lock(); items.append(record); lock.unlock() }
    public var records: [NetworkLogRecord] { lock.lock(); defer { lock.unlock() }; return items }
}

public struct RouteOutcome: Sendable {
    public var completion: ProviderCompletion
    public var provider: ProviderID
    public var attempts: [(ProviderID, ProviderError?)]
}

/// Thread-safe registry + routing. Gatekeeper is always local (Part 4.6 routing rule 1).
public final class RoutingTable: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [any Provider] = []
    private var choices: [StageID: RouteChoice] = [:]
    public let logger: NetworkLogger
    public let fallback: any Provider
    /// Egress gate (Lab's kill switch, wired by the app). Consulted before every remote provider
    /// call with a host label; `false` skips the provider as unavailable. Default: allow.
    public var egressAllowed: @Sendable (String) -> Bool = { _ in true }
    public static let alwaysLocalStages: Set<StageID> = [.gatekeeper, .asr, .biasing, .injection]

    public init(providers: [any Provider], logger: NetworkLogger, fallback: any Provider = LocalRulesProvider()) {
        self.providers = providers; self.logger = logger; self.fallback = fallback
    }

    public func register(_ p: any Provider) { lock.lock(); providers.removeAll { $0.id == p.id }; providers.append(p); lock.unlock() }
    public func unregister(_ id: ProviderID) { lock.lock(); providers.removeAll { $0.id == id }; lock.unlock() }
    public var allProviders: [any Provider] { lock.lock(); defer { lock.unlock() }; return providers }
    public func provider(_ id: ProviderID) -> (any Provider)? { allProviders.first { $0.id == id } }

    public func setChoice(_ c: RouteChoice, for stage: StageID) { lock.lock(); choices[stage] = c; lock.unlock() }
    public func choice(for stage: StageID) -> RouteChoice { lock.lock(); defer { lock.unlock() }; return choices[stage] ?? .auto }

    /// Ordered candidate chain for a stage. Local-first in Auto; a pinned provider is tried
    /// first then the local chain; the rules fallback is always last.
    public func chain(for stage: StageID) -> [any Provider] {
        let pipeline = allProviders.filter { $0.capabilities.contains(.pipeline) }
        let local = pipeline.filter { $0.privacyClass < .cloud }.sorted { $0.privacyClass < $1.privacyClass }
        let cloud = pipeline.filter { $0.privacyClass == .cloud }
        var out: [any Provider]
        if Self.alwaysLocalStages.contains(stage) { out = local }
        else {
            switch choice(for: stage) {
            case .auto: out = local + cloud
            case .localOnly: out = local
            case .provider(let id): out = (provider(id).map { [$0] } ?? []) + local
            }
        }
        out.removeAll { $0.id == fallback.id }
        out.append(fallback)
        return out
    }

    public func complete(stage: StageID, spans: [TranscriptSpan], context: StageContext, purpose: String = "pipeline") async throws -> RouteOutcome {
        var attempts: [(ProviderID, ProviderError?)] = []
        for p in chain(for: stage) {
            guard await p.isAvailable() else { attempts.append((p.id, .unavailable("not available"))); continue }
            if p.isRemote, !egressAllowed(p.id.rawValue) {
                Log.providers.notice("egress to \(p.id) blocked by kill switch")
                attempts.append((p.id, .unavailable("blocked by egress kill switch"))); continue
            }
            do {
                let c = try await p.complete(stage: stage, spans: spans, context: context)
                if p.isRemote {
                    logger.log(NetworkLogRecord(stage: stage.rawValue, provider: p.id.rawValue, host: c.host,
                                                bytesOut: c.bytesOut, bytesIn: c.bytesIn, purpose: purpose))
                }
                attempts.append((p.id, nil))
                return RouteOutcome(completion: c, provider: p.id, attempts: attempts)
            } catch {
                let pe = (error as? ProviderError) ?? .unavailable("\(error)")
                if p.isRemote {
                    logger.log(NetworkLogRecord(stage: stage.rawValue, provider: p.id.rawValue, host: "?", bytesOut: 0, bytesIn: 0,
                                                purpose: "\(purpose) (failed: \(pe))"))
                }
                Log.providers.warning("\(p.id) failed on \(stage): \(pe); falling back")
                attempts.append((p.id, pe))
            }
        }
        throw ProviderError.unavailable("no provider completed \(stage)")
    }
}

/// Wraps a routed stage as a `PipelineStage` so the pipeline can call providers uniformly.
public struct RoutedStage: PipelineStage {
    public let id: StageID
    public let table: RoutingTable
    public init(id: StageID, table: RoutingTable) { self.id = id; self.table = table }
    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        try await table.complete(stage: id, spans: spans, context: context).completion.spans
    }
}

/// Builds the default provider set from what is installed/configured on this machine.
public enum ProviderDiscovery {
    public static func discover(secrets: SecretStore, session: URLSession = .shared, flags: FeatureFlagService? = nil) async -> [any Provider] {
        var out: [any Provider] = [LocalRulesProvider()]
        for s in await LocalServerDetector(session: session).detect() { out.append(LocalServerProvider(info: s, session: session)) }
        for (ep, model) in [(APIEndpoint.openRouter, "openai/gpt-4o-mini"), (.openAI, "gpt-4o-mini"), (.anthropic, "claude-3-5-haiku-latest"),
                            (.groq, "llama-3.1-8b-instant"), (.cerebras, "llama3.1-8b")] {
            let c = OpenAICompatibleClient(endpoint: ep, model: model, secrets: secrets, session: session)
            if await c.isAvailable() { out.append(c) }
        }
        let oauth = OAuthSession(config: .chatGPT, secrets: secrets, session: session)
        if oauth.isSignedIn { out.append(ChatGPTSubscriptionProvider(oauth: oauth, session: session)) }
        out.append(contentsOf: CLIDetector().detectAll())
        if let flags, flags.isEnabled(.cloudASR) { out.append(CloudASRProvider(secrets: secrets, session: session)) }
        return out
    }
}
