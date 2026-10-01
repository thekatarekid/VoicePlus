import Engine
import Foundation
import Pipeline
import Providers
import Shared
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
    @Published public private(set) var install: LocalLLMInstallState
    @Published public private(set) var resident = false

    public init(settings: SettingsStore = UserDefaultsSettingsStore(), model: LocalLLMModel = CleanupWiring.model,
                downloader: LocalLLMDownloader = LocalLLMDownloader(), residency: ModelResidency = .shared) {
        self.settings = settings
        self.model = model
        self.downloader = downloader
        self.residency = residency
        self.mode = CleanupWiring.mode(settings: settings)
        self.install = downloader.isInstalled(model) ? .downloaded : .notDownloaded
    }

    public func select(_ mode: CleanupMode) {
        settings.set(mode.rawValue, for: CleanupMode.settingsKey)
        self.mode = mode
        let residency = self.residency
        Task { await CleanupWiring.syncResidency(CleanupWiring.provider(model: model, residency: residency),
                                                 mode: mode, residency: residency) }
    }

    public var modeDetail: String { mode.detail }

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
        GroupBox("AI cleanup", layout: .rows) {
            SettingsPickerRow(title: "AI cleanup", detail: model.modeDetail,
                              selection: Binding(get: { model.mode }, set: { model.select($0) }),
                              options: CleanupMode.allCases, label: { $0.title },
                              identifier: "settings.models.cleanupMode")
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
    }
}
