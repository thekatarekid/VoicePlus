import Engine
import Foundation
import Pipeline
import Providers
import Shared
import AppKit
import SwiftUI

// V5 D2 — Settings › Models "AI cleanup": Off / Automatic (default) / Always, and the model row
// (name, size, state: not downloaded / downloading / on disk / in memory). Downloading is the only
// network action here and only on the user's click; the model then loads through ModelResidency.

@MainActor
public final class AICleanupSettingsModel: ObservableObject {
    private let settings: SettingsStore
    private let downloader: LocalLLMDownloader
    private let residency: ModelResidency
    public let model: LocalLLMModel
    @Published public private(set) var mode: CleanupMode
    /// X4 — the four independent LLM modes.
    @Published public private(set) var modes: LLMModes
    @Published public private(set) var install: LocalLLMInstallState
    @Published public private(set) var resident = false

    public init(settings: SettingsStore = UserDefaultsSettingsStore(), model: LocalLLMModel = CleanupWiring.model,
                downloader: LocalLLMDownloader = LocalLLMDownloader(), residency: ModelResidency = .shared) {
        self.settings = settings
        self.model = model
        self.downloader = downloader
        self.residency = residency
        self.mode = CleanupWiring.mode(settings: settings)
        self.modes = CleanupWiring.llmModes(settings: settings)
        self.install = downloader.isInstalled(model) ? .downloaded : .notDownloaded
    }

    /// X4 — one of the four switches changed. Persisted; applies from the next dictation.
    public func update(_ change: (inout LLMModes) -> Void) {
        var m = modes
        change(&m)
        CleanupWiring.setLLMModes(m, settings: settings)
        modes = m
        let mode = CleanupWiring.mode(settings: settings)
        self.mode = mode
        syncResidency(mode)
    }

    public func setFastPathOnly(_ on: Bool) { update { $0.setFastPathOnly(on) } }
    public func setPerAppPolish(_ on: Bool) { update { $0.perAppPolish = on } }
    public func setAutoPolish(_ on: Bool) { update { $0.autoPolishWhenUnsure = on } }
    public func setEveryDictation(_ on: Bool) { update { $0.everyDictation = on } }
    public func setPolish(_ bundleID: String, _ on: Bool) {
        update { if on { $0.polishApps.insert(bundleID) } else { $0.polishApps.remove(bundleID) } }
    }

    /// Pre-X4 entry point (Off / Automatic / Always), kept for callers: maps onto the modes.
    public func select(_ mode: CleanupMode) {
        switch mode {
        case .off: setFastPathOnly(true)
        case .automatic: update { $0.everyDictation = false; $0.autoPolishWhenUnsure = true }
        case .always: setEveryDictation(true)
        }
    }

    private func syncResidency(_ mode: CleanupMode) {
        let residency = self.residency
        Task { await CleanupWiring.syncResidency(CleanupWiring.provider(model: model, residency: residency),
                                                 mode: mode, residency: residency) }
    }

    public var modeDetail: String { mode.detail }

    public static let fastPathTitle = "Fast path only"
    public static let fastPathDetail = "Built-in rules only. Nothing loads, nothing waits."
    public static let perAppTitle = "Polish in chosen apps"
    public static let perAppDetail = "A small model on this Mac tidies every dictation in the apps you pick."
    public static let unsureTitle = "Polish automatically when unsure"
    public static let unsureDetail = "The model steps in for self-corrections, lists, numbers and long dictations."
    public static let everyTitle = "Use the model on every dictation"
    public static let everyDetail = "Checks every dictation. Adds about 1 to 2.5 s."

    public var modelDetail: String {
        let state: String
        switch install {
        case .notDownloaded: state = "Not downloaded"
        case .downloading: state = "Downloading…"
        case .downloaded: state = resident ? "In memory" : "On this Mac, loads when needed"
        case .failed(let why): state = "Download failed (\(why))"
        }
        return "\(model.sizeLabel) · \(model.license) · \(state)"
    }

    public var canDownload: Bool {
        switch install { case .notDownloaded, .failed: return mode != .off; default: return false }
    }

    public func refresh() async {
        if case .downloading = install {} else { install = downloader.isInstalled(model) ? .downloaded : .notDownloaded }
        resident = await residency.isResident(ResidencyKey.cleanup)
    }

    public func download() {
        install = .downloading(0)
        let downloader = self.downloader, model = self.model, residency = self.residency
        Task {
            do {
                try await downloader.download(model)
                install = .downloaded
                await CleanupWiring.syncResidency(CleanupWiring.provider(model: model, residency: residency),
                                                  mode: mode, residency: residency)
            } catch {
                install = .failed(error is LocalLLMDownloadError ? "checksum" : "network")
            }
        }
    }
}

struct AICleanupGroup: View {
    @StateObject private var model = AICleanupSettingsModel()

    var body: some View {
        VStack(spacing: 12) {
        GroupBox("AI cleanup", layout: .rows) {
            // X4 — four independent switches (fast path is on exactly when the other three are off).
            SettingsToggleRow(title: AICleanupSettingsModel.fastPathTitle, detail: AICleanupSettingsModel.fastPathDetail,
                              isOn: Binding(get: { model.modes.fastPathOnly }, set: { model.setFastPathOnly($0) }),
                              identifier: "settings.models.llm.fastPath")
            SettingsToggleRow(title: AICleanupSettingsModel.perAppTitle, detail: AICleanupSettingsModel.perAppDetail,
                              isOn: Binding(get: { model.modes.perAppPolish }, set: { model.setPerAppPolish($0) }),
                              identifier: "settings.models.llm.perApp")
            if model.modes.perAppPolish {
                PolishAppsRow(model: model)
            }
            SettingsToggleRow(title: AICleanupSettingsModel.unsureTitle, detail: AICleanupSettingsModel.unsureDetail,
                              isOn: Binding(get: { model.modes.autoPolishWhenUnsure }, set: { model.setAutoPolish($0) }),
                              identifier: "settings.models.llm.unsure")
            SettingsToggleRow(title: AICleanupSettingsModel.everyTitle, detail: AICleanupSettingsModel.everyDetail,
                              isOn: Binding(get: { model.modes.everyDictation }, set: { model.setEveryDictation($0) }),
                              identifier: "settings.models.llm.every")
            RowView(model.model.displayName, detail: model.modelDetail) {
                if model.canDownload {
                    Button("Download") { model.download() }
                        .accessibilityIdentifier("settings.models.cleanupModel.download")
                } else {
                    StatusTag(model.resident ? "In memory" : (model.install == .downloaded ? "Ready" : "—"),
                              kind: model.install == .downloaded ? .good : .neutral)
                }
            }
            .accessibilityIdentifier("settings.models.cleanupModel")
        }
        .task { await model.refresh() }
        EditModelsGroup()   // X5 — Qwen3.5-2B / 4B for rewrite commands
        }
    }
}

// MARK: - X5 · Settings › Models "Rewrite models" (download / delete / use)

@MainActor
public final class EditModelsSettingsModel: ObservableObject {
    public let manager: any LocalModelManaging
    @Published public private(set) var states: [String: LocalModelState] = [:]
    @Published public private(set) var activeID: String?
    @Published public private(set) var lastError: String?
    /// H16 — Ollama / LM Studio servers found on localhost (probed only when Settings asks).
    @Published public private(set) var servers: [LocalServerKind] = []
    @Published public private(set) var serverPin: LocalServerKind?
    private let settings: SettingsStore
    private let detectServers: @Sendable () async -> [LocalServerKind]
    private var token: UUID?

    public init(manager: any LocalModelManaging = EditModels.manager,
                settings: SettingsStore = UserDefaultsSettingsStore(),
                detectServers: @escaping @Sendable () async -> [LocalServerKind] = {
                    await LocalServerDetector().detect().map(\.kind)
                }) {
        self.manager = manager
        self.settings = settings
        self.detectServers = detectServers
        refresh()
        if let m = manager as? LocalModelManager {
            token = m.addObserver { [weak self] in Task { @MainActor in self?.refresh() } }
        }
    }

    deinit {
        if let token, let m = manager as? LocalModelManager { m.removeObserver(token) }
    }

    public var models: [LocalLLMModel] { manager.models }

    public func refresh() {
        states = Dictionary(uniqueKeysWithValues: manager.models.map { ($0.id, manager.state($0.id)) })
        activeID = manager.activeModel?.id
        serverPin = RewriteServerPin.current(settings)
    }

    /// Probes localhost only (no other host); the pinned server stays listed even when it is down.
    public func refreshServers() async {
        let found = await detectServers()
        var list = LocalServerKind.allCases.filter { found.contains($0) }
        if let pin = RewriteServerPin.current(settings), !list.contains(pin) { list.append(pin) }
        servers = list
        serverPin = RewriteServerPin.current(settings)
    }

    /// H16 — "use my Ollama / LM Studio" for rewrites (on), or back to the model on this Mac (off).
    public func useServer(_ kind: LocalServerKind, _ on: Bool) {
        if on { RewriteServerPin.set(kind, in: settings) }
        else if RewriteServerPin.current(settings) == kind { RewriteServerPin.set(nil, in: settings) }
        serverPin = RewriteServerPin.current(settings)
    }

    public func line(for model: LocalLLMModel) -> String {
        let rec = (manager as? LocalModelManager)?.recommended()?.id == model.id ? " · Recommended for this Mac" : ""
        switch states[model.id] ?? .notDownloaded {
        case .notDownloaded: return "\(model.sizeLabel) to download\(rec). Nothing downloads until you click."
        case .downloading(let p): return "Downloading… \(Int(p * 100))%"
        case .ready: return activeID == model.id ? "On this Mac · in use for rewrites" : "On this Mac"
        case .failed(let why): return why
        }
    }

    public func download(_ id: String) {
        let manager = self.manager
        Task { await manager.download(id); refresh() }
        refresh()
    }

    public func delete(_ id: String) {
        let manager = self.manager
        Task {
            do { try await manager.delete(id); lastError = nil } catch { lastError = "Couldn't delete it right now." }
            refresh()
        }
    }

    public func use(_ id: String) {
        manager.setPreferred(id)
        refresh()
    }
}

struct EditModelsGroup: View {
    @StateObject private var model = EditModelsSettingsModel()

    var body: some View {
        GroupBox("Rewrite models", layout: .rows) {
            ForEach(model.models) { m in
                RowView(m.displayName, detail: model.line(for: m)) {
                    HStack(spacing: 8) {
                        switch model.states[m.id] ?? .notDownloaded {
                        case .notDownloaded, .failed:
                            Button("Download") { model.download(m.id) }
                                .accessibilityIdentifier("settings.models.edit.\(m.id).download")
                        case .downloading(let p):
                            ProgressView(value: p).frame(width: 80)
                        case .ready:
                            if model.activeID != m.id {
                                Button("Use") { model.use(m.id) }
                                    .accessibilityIdentifier("settings.models.edit.\(m.id).use")
                            }
                            Button("Delete") { model.delete(m.id) }
                                .accessibilityIdentifier("settings.models.edit.\(m.id).delete")
                        }
                    }
                }
            }
        }
        .onAppear { model.refresh() }
        .task { await model.refreshServers() }
        if !model.servers.isEmpty {
            GroupBox("Your own model server", layout: .rows) {
                ForEach(model.servers, id: \.self) { kind in
                    SettingsToggleRow(title: "Use \(kind.displayName) for rewrites",
                                      detail: RewriteServerPin.detail(kind),
                                      isOn: Binding(get: { model.serverPin == kind },
                                                    set: { model.useServer(kind, $0) }),
                                      identifier: "settings.models.edit.server.\(kind.rawValue)")
                }
            }
        }
    }
}

/// H16 — the optional keyless "use my Ollama / LM Studio" path for rewrite commands: pins `.transform`
/// and `.question` to the localhost server provider (`local.<kind>`). Clearing removes only a
/// local-server pin; a provider the user pinned elsewhere is left alone. With no pin, rewrites run
/// on the downloaded Qwen model, then the rules.
public enum RewriteServerPin {
    public static let stages: [StageID] = [.transform, .question]

    static func providerID(_ kind: LocalServerKind) -> String { "local.\(kind.rawValue)" }

    public static func current(_ settings: SettingsStore) -> LocalServerKind? {
        guard let raw = settings.string(SettingsKeys.routingPrefix + StageID.transform.rawValue),
              case .provider(let id)? = ProviderChoice(rawValue: raw) else { return nil }
        return LocalServerKind.allCases.first { providerID($0) == id }
    }

    public static func set(_ kind: LocalServerKind?, in settings: SettingsStore) {
        for stage in stages {
            let key = SettingsKeys.routingPrefix + stage.rawValue
            if let kind {
                settings.set(ProviderChoice.provider(providerID(kind)).rawValue, for: key)
            } else if let raw = settings.string(key), case .provider(let id)? = ProviderChoice(rawValue: raw),
                      LocalServerKind.allCases.contains(where: { providerID($0) == id }) {
                settings.set(nil, for: key)
            }
        }
    }

    public static func detail(_ kind: LocalServerKind) -> String {
        "Runs rewrites on the model loaded in \(kind.displayName) on this Mac. No key needed."
    }
}

/// The apps that get Polish, by bundle ID; each row can be removed.
struct PolishAppsRow: View {
    @ObservedObject var model: AICleanupSettingsModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.modes.polishApps.sorted(), id: \.self) { id in
                HStack {
                    Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                        .map { FileManager.default.displayName(atPath: $0.path) } ?? id)
                    Spacer()
                    Button("Remove") { model.setPolish(id, false) }
                }
            }
            HStack {
                TextField("App bundle ID (e.g. com.apple.mail)", text: $draft)
                Button("Add") {
                    let id = draft.trimmingCharacters(in: .whitespaces)
                    if !id.isEmpty { model.setPolish(id, true); draft = "" }
                }
            }
        }
        .accessibilityIdentifier("settings.models.llm.polishApps")
    }
}
