import Engine
import Foundation
import Lab
import Providers
import Shared
import SwiftUI

// S7g — Settings › Providers (design §8.6): the selected route, connectivity, and credentials in a
// secure control. Secrets never appear in errors: every failure on this page is a recovery-catalogue
// entry (N01–N04, S02), and the raw error goes to the log only (`RecoveryCatalog.report`).

// MARK: - Connected services (P4.6 connectors)

/// One row per connector with OAuth start / sign-out. Every API call the connectors make is logged
/// to the Data Panel (see `ConnectorHub.log`).
@MainActor
public final class ConnectorsSettingsViewModel: ObservableObject {
    public struct Row: Identifiable {
        public let id: String
        public let name: String
        public let scopes: [String]
        public var signedIn: Bool
        public var configured: Bool
        public var usesPAT: Bool
    }

    private let hub: ConnectorHub?
    @Published public private(set) var rows: [Row] = []
    @Published public var busy: String?
    /// The last failure as its catalogue entry — never the error's own text, which can carry a
    /// token or a response body.
    @Published public private(set) var failure: SectionBanner?
    @Published public var githubPAT: String = ""

    public init(hub: ConnectorHub?) {
        self.hub = hub
        reload()
    }

    public var isAvailable: Bool { hub != nil }
    public var anySignedIn: Bool { rows.contains(where: \.signedIn) }

    public func reload() {
        guard let hub else { rows = []; return }
        rows = ConnectorHub.descriptors.map { d in
            Row(id: d.id, name: d.displayName, scopes: d.scopes,
                signedIn: hub.isSignedIn(d), configured: hub.clientID(for: d) != nil || d.authKind == .githubPAT,
                usesPAT: d.authKind == .githubPAT)
        }
    }

    public func connect(_ id: String) {
        guard let hub, let descriptor = ConnectorHub.descriptors.first(where: { $0.id == id }) else { return }
        busy = id
        failure = nil
        Task { @MainActor in
            do { try await hub.signIn(descriptor) } catch { self.note(error) }
            self.busy = nil
            self.reload()
        }
    }

    /// The typed token is kept in the field when the save fails (design §9: a failed save keeps the
    /// entered value), and cleared only once the Keychain has it.
    public func saveGitHubPAT() {
        guard let hub, !githubPAT.isEmpty else { return }
        do {
            try hub.storeGitHubPAT(githubPAT)
            githubPAT = ""
            failure = nil
        } catch {
            _ = RecoveryCatalog.report(error)
            failure = .recovery(RecoveryCatalog.entry(.S02))
        }
        reload()
    }

    public func disconnect(_ id: String) {
        guard let hub, let descriptor = ConnectorHub.descriptors.first(where: { $0.id == id }) else { return }
        do { try hub.signOut(descriptor) } catch { note(error) }
        reload()
    }

    public func dismissFailure() { failure = nil }

    func note(_ error: Error) { failure = .recovery(RecoveryCatalog.report(error)) }

    public func status(_ row: Row) -> String {
        if busy == row.id { return ProvidersCopy.connecting }
        if row.signedIn { return ProvidersCopy.connected }
        return row.configured ? ProvidersCopy.notConnected : ProvidersCopy.noClientID
    }
}

/// The connectors group, drawn with the design's group and rows.
struct ConnectorsSettingsTab: View {
    @ObservedObject var model: ConnectorsSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            GroupBox(ProvidersCopy.connectorsTitle, layout: .rows) {
                if !model.isAvailable {
                    RowView(ProvidersCopy.connectorsUnavailable)
                }
                ForEach(model.rows) { row in
                    RowView(row.name, detail: model.status(row)) {
                        trailing(row)
                    }
                    .accessibilityIdentifier("settings.connector.\(row.id)")
                }
            }
            if let failure = model.failure {
                ScopedBanner(failure, onAction: { model.dismissFailure(); model.reload() })
            }
            Text(ProvidersCopy.connectorsFootnote)
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
        }
    }

    @ViewBuilder private func trailing(_ row: ConnectorsSettingsViewModel.Row) -> some View {
        if model.busy == row.id {
            ProgressView().controlSize(.small)
        } else if row.signedIn {
            HStack(spacing: Tokens.Spacing.s) {
                StatusTag(ProvidersCopy.connected, kind: .good)
                Button(ProvidersCopy.signOut) { model.disconnect(row.id) }
            }
        } else if row.usesPAT {
            HStack(spacing: Tokens.Spacing.s) {
                SecureField(ProvidersCopy.githubToken, text: $model.githubPAT)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .accessibilityIdentifier("settings.connector.githubToken")
                Button(ProvidersCopy.save) { model.saveGitHubPAT() }.disabled(model.githubPAT.isEmpty)
            }
        } else {
            Button(ProvidersCopy.connect) { model.connect(row.id) }.disabled(!row.configured)
        }
    }
}

// MARK: - Provider credentials (API keys)

/// One paid service VoicePlus can send a stage to, keyed in the Keychain the provider table reads
/// (`SecretKey.apiKey`, the same store `ProviderDiscovery` checks at launch).
public struct ProviderService: Identifiable, Equatable, Sendable {
    public let endpoint: APIEndpoint
    public let name: String
    public var id: String { endpoint.name }

    public static let all: [ProviderService] = [
        ProviderService(endpoint: .openRouter, name: "OpenRouter"),
        ProviderService(endpoint: .openAI, name: "OpenAI"),
        ProviderService(endpoint: .anthropic, name: "Anthropic"),
        ProviderService(endpoint: .groq, name: "Groq"),
        ProviderService(endpoint: .cerebras, name: "Cerebras"),
    ]

    public var secretKey: String { SecretKey.apiKey(endpoint.providerID) }
}

/// What a service row says about itself.
public enum ProviderServiceStatus: Equatable, Sendable {
    case noKey
    case storageUnavailable
    case saved
    /// "Testing connection…" (design §9, Providers loading).
    case testing
    case reachable
    case failed(RecoveryID)

    public var line: String {
        switch self {
        case .noKey: return ProvidersCopy.noKey
        case .storageUnavailable: return ProvidersCopy.storageUnavailable
        case .saved: return ProvidersCopy.keySaved
        case .testing: return ProvidersCopy.testing
        case .reachable: return ProvidersCopy.reachable
        case .failed(let id): return RecoveryCatalog.entry(id).headline
        }
    }

    public var hasKey: Bool { self != .noKey && self != .storageUnavailable }
}

/// Connectivity: a real, keyed request that costs no tokens (`GET <base>/models`), refused when the
/// network kill switch blocks the host, and logged to the Data Panel like every other request.
public protocol ProviderConnectivityProbing: Sendable {
    func test(_ endpoint: APIEndpoint, key: String) async -> ProviderServiceStatus
}

public struct LiveProviderConnectivityProbe: ProviderConnectivityProbing {
    public var gate: EgressGate
    public var session: URLSession

    public init(gate: EgressGate = .shared, session: URLSession = .shared) {
        self.gate = gate
        self.session = session
    }

    public func test(_ endpoint: APIEndpoint, key: String) async -> ProviderServiceStatus {
        let url = endpoint.baseURL.appendingPathComponent("models")
        let host = url.host ?? endpoint.name
        do { try gate.check(host: host) } catch { return .failed(RecoveryCatalog.recoveryID(for: error)) }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        if endpoint.isAnthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            _ = try? gate.log(stage: "settings", provider: endpoint.providerID.rawValue, host: host,
                              bytesOut: 0, bytesIn: data.count, purpose: "connection test")
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.status(forHTTP: status)
        } catch {
            return .failed(RecoveryCatalog.recoveryID(for: ProviderError.unavailable("connection test")))
        }
    }

    /// The same N01–N04 split the catalogue applies to a provider's HTTP answer.
    static func status(forHTTP code: Int) -> ProviderServiceStatus {
        (200..<300).contains(code) ? .reachable : .failed(RecoveryCatalog.recoveryID(for: ProviderError.http(code, "")))
    }
}

@MainActor
public final class ProviderCredentialsModel: ObservableObject {
    @Published public private(set) var statuses: [String: ProviderServiceStatus] = [:]
    /// What each secure field holds. Never filled from the Keychain: a saved key is never shown.
    @Published public var entered: [String: String] = [:]
    /// Per-row save failures (S02). The entered value stays in the field.
    @Published public private(set) var saveFailures: [String: SectionBanner] = [:]

    private let secrets: SecretStore
    private let probe: ProviderConnectivityProbing

    public init(secrets: SecretStore = KeychainSecretStore(), probe: ProviderConnectivityProbing = LiveProviderConnectivityProbe()) {
        self.secrets = secrets
        self.probe = probe
        reload()
    }

    public var services: [ProviderService] { ProviderService.all }

    public func status(_ service: ProviderService) -> ProviderServiceStatus { statuses[service.id] ?? .noKey }

    public var hasAnyKey: Bool { statuses.values.contains(where: \.hasKey) }
    public var hasStorageFailure: Bool { statuses.values.contains(.storageUnavailable) }

    public func reload() {
        for service in services {
            let keyed: Bool
            do { keyed = !(try secrets.get(service.secretKey) ?? "").isEmpty }
            catch { statuses[service.id] = .storageUnavailable; continue }
            switch statuses[service.id] {
            case .reachable?, .failed?, .testing?: if !keyed { statuses[service.id] = .noKey }
            default: statuses[service.id] = keyed ? .saved : .noKey
            }
        }
    }

    public func save(_ service: ProviderService) {
        let key = (entered[service.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try secrets.set(key, for: service.secretKey)
            entered[service.id] = ""
            saveFailures[service.id] = nil
            statuses[service.id] = .saved
        } catch {
            _ = RecoveryCatalog.report(error)
            saveFailures[service.id] = .recovery(RecoveryCatalog.entry(.S02))
        }
    }

    public func remove(_ service: ProviderService) {
        do {
            try secrets.delete(service.secretKey)
            statuses[service.id] = .noKey
            saveFailures[service.id] = nil
        } catch {
            _ = RecoveryCatalog.report(error)
            saveFailures[service.id] = .recovery(RecoveryCatalog.entry(.S02))
        }
    }

    /// Scoped to the row and disabled while it runs (design §9: retry is disabled during the retry).
    public func test(_ service: ProviderService) async {
        guard statuses[service.id] != .testing else { return }
        let saved: String?
        do { saved = try secrets.get(service.secretKey) }
        catch { statuses[service.id] = .storageUnavailable; return }
        guard let key = saved, !key.isEmpty else {
            statuses[service.id] = .noKey
            return
        }
        statuses[service.id] = .testing
        statuses[service.id] = await probe.test(service.endpoint, key: key)
    }
}

// MARK: - The route

/// Design §8.6 "selected route": where each stage runs, read from the same routing keys the
/// pipeline reads (`routing.<stage>`). Transcription is always on this Mac.
public enum ProviderRoute {
    public struct Row: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        public var isLocal: Bool
    }

    /// `routing` is `ModelsSettingsViewModel.routing`: a missing stage is Auto.
    public static func rows(routing: [StageID: ProviderChoice]) -> [Row] {
        var out = [
            Row(id: "speech", title: ProvidersCopy.speechTitle, detail: ProvidersCopy.speechDetail, isLocal: true),
            // Meeting notes are extractive and made on this Mac (`MeetingNotes`, provider
            // `extractive-local`); Ask stays disabled until a service route exists (S7c).
            Row(id: "meetings", title: ProvidersCopy.meetingsTitle, detail: ProvidersCopy.meetingsDetail, isLocal: true),
        ]
        for stage in RoutableStage.all where stage.acceptsProviders {
            switch routing[stage.id] ?? .auto {
            case .provider(let id):
                out.append(Row(id: stage.id.rawValue, title: stage.title, detail: ProvidersCopy.sentTo(id), isLocal: false))
            case .auto, .local:
                out.append(Row(id: stage.id.rawValue, title: stage.title,
                               detail: stage.acceptsLocal ? ProvidersCopy.staysLocal : ProvidersCopy.noProvider,
                               isLocal: stage.acceptsLocal))
            }
        }
        return out
    }
}

/// The Providers page's base rendering: "Nothing connected" only when nothing is — no key, no
/// discovered provider, no signed-in connector — and the user has not asked to look.
public enum ProvidersPage {
    public static func state(hasKey: Bool, discovered: [String], connectorsSignedIn: Bool,
                             exploring: Bool, hotkey: String) -> SectionState {
        if hasKey || !discovered.isEmpty || connectorsSignedIn || exploring { return .content }
        return .empty(.services, hotkey: hotkey)
    }
}

public enum ProvidersCopy {
    public static let routeTitle = "Processing route"
    public static let speechTitle = "Speech recognition"
    public static let speechDetail = "Current route is on device."
    public static let meetingsTitle = "Meeting notes / Ask"
    public static let meetingsDetail = "Notes are made on this Mac. Ask needs a configured service and stays off until one exists."
    public static let local = "Local"
    public static let service = "Service"
    public static let staysLocal = "On this Mac. Auto never sends this stage anywhere."
    public static let noProvider = "No provider pinned, so this stays off."
    public static func sentTo(_ provider: String) -> String { "Sent to \(provider) when used." }
    public static let cloudFallbackTitle = "Cloud fallback"
    public static let cloudFallbackDetail = "Never enabled silently. A service is used only for a stage you pin to it in Models."
    public static let off = "Off"
    public static let discoveredTitle = "Available services"
    public static func discovered(_ names: [String]) -> String { names.joined(separator: ", ") }
    public static let noneDiscovered = "None yet. Add a key below, or run a local server."
    public static let connectWhatYouPayFor = "Connect what you pay for…"
    public static let servicesTitle = "Services"
    public static let keyField = "API key"
    public static let save = "Save"
    public static let remove = "Remove key"
    public static let test = "Test connection"
    public static let noKey = "No key saved."
    public static let storageUnavailable = "Secure storage unavailable. Local dictation still works."
    public static let checkStorage = "Check again"
    public static let keySaved = "Key saved in your Keychain."
    public static let testing = "Testing connection…"
    public static let reachable = "Connected · the key was accepted."
    public static let keysFootnote = "Cloud services are optional. Saved keys stay in Keychain; VoicePlus never asks to unlock it automatically. Local dictation needs no Keychain access. A new key is picked up the next time VoicePlus starts."
    public static let connectorsTitle = "Connected services"
    public static let connectorsUnavailable = "Connectors are unavailable in this session."
    public static let connectorsFootnote = "Minimal scopes; every call is logged to the Data Panel."
    public static let connecting = "Connecting…"
    public static let connected = "Connected"
    public static let notConnected = "Not connected"
    public static let noClientID = "No client ID configured"
    public static let signOut = "Sign out"
    public static let connect = "Connect…"
    public static let githubToken = "GitHub token"
}
