import SwiftUI

/// P4.6 — "Connected services" tab: one row per connector with OAuth start / sign-out.
/// Every API call the connectors make is logged to the Data Panel (see `ConnectorHub.log`).
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
    @Published public var error: String?
    @Published public var githubPAT: String = ""

    public init(hub: ConnectorHub?) {
        self.hub = hub
        reload()
    }

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
        error = nil
        Task { @MainActor in
            do { try await hub.signIn(descriptor) } catch { self.error = "\(error)" }
            self.busy = nil
            self.reload()
        }
    }

    public func saveGitHubPAT() {
        guard let hub, !githubPAT.isEmpty else { return }
        do {
            try hub.storeGitHubPAT(githubPAT)
            githubPAT = ""
            error = nil
        } catch { self.error = "\(error)" }
        reload()
    }

    public func disconnect(_ id: String) {
        guard let hub, let descriptor = ConnectorHub.descriptors.first(where: { $0.id == id }) else { return }
        try? hub.signOut(descriptor)
        reload()
    }
}

struct ConnectorsSettingsTab: View {
    @ObservedObject var model: ConnectorsSettingsViewModel

    var body: some View {
        Form {
            Section("Connected services") {
                if model.rows.isEmpty {
                    Text("Connectors are unavailable in this session.").foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(row.signedIn ? "Connected" : (row.configured ? "Not connected" : "No client ID configured"))
                                .font(.caption).foregroundStyle(row.signedIn ? .green : .secondary)
                        }
                        Spacer()
                        if model.busy == row.id {
                            ProgressView().controlSize(.small)
                        } else if row.signedIn {
                            Button("Sign out") { model.disconnect(row.id) }
                        } else if row.usesPAT {
                            SecureField("GitHub token", text: $model.githubPAT).frame(width: 140)
                            Button("Save") { model.saveGitHubPAT() }.disabled(model.githubPAT.isEmpty)
                        } else {
                            Button("Connect…") { model.connect(row.id) }.disabled(!row.configured)
                        }
                    }
                }
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Minimal scopes; every call is logged to the Data Panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
