import Engine
import Foundation
import Pipeline
import Shared
import SwiftUI

// V5 P1–P7 — public dictionaries: wiring (called from AppContainer) and the Settings › Dictionary
// "Public word lists" group (status, licence notices, the explicit download button).

enum DictionaryWiring {
    /// P1 (Text Replacements on), P2 (local names → recent tier), P7 (typed entities → screen
    /// tier). Call once, on the main thread, while the harvester is being assembled.
    static func install(harvester: ContextHarvester, windowText: FocusedWindowTextProvider) {
        if Thread.isMainThread {
            PublicDictionaries.shared.useSystemTextReplacements()
        } else {
            DispatchQueue.main.async { PublicDictionaries.shared.useSystemTextReplacements() }
        }
        harvester.add(LocalNamesSource(apps: LiveInstalledAppNames(), attendees: LiveCalendarAttendees(),
                                       documents: OpenDocumentPaths(provider: LiveAXOpenDocuments())))
        let typer = EntityTyperHolder.shared
        harvester.add(TypedEntitySource(text: windowText, classifier: typer))
        // GLiNER2-small only when its weights are already on disk; never downloads here.
        if GLiNER2EntityTyper.weightsPresent() {
            Task.detached(priority: .utility) {
                if let model = await GLiNER2EntityTyper.load() { typer.setModel(model) }
            }
        }
    }

    /// P5 — the style pass, guarded so it never lowercases a likely entity.
    static func styleStage(store: any StyleProfileStore) -> any PipelineStage {
        EntityProtectingStage(StyleStage(store: store))
    }
}

/// The classifier `TypedEntitySource` holds: heuristic (contacts → person, apps → product) until a
/// GLiNER2 model is loaded, then model first.
final class EntityTyperHolder: EntityTypeClassifier, @unchecked Sendable {
    static let shared = EntityTyperHolder()
    private let lock = NSLock()
    private var model: GLiNER2EntityTyper?
    private var heuristic = HeuristicEntityTyper()
    private var heuristicBuiltAt: Date?

    func setModel(_ model: GLiNER2EntityTyper) { lock.withLock { self.model = model } }

    private func layered() -> LayeredEntityTyper {
        lock.withLock {
            if heuristicBuiltAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                heuristic = HeuristicEntityTyper(people: LiveContacts().contactNames(),
                                                 products: LiveInstalledAppNames().installedAppNames())
                heuristicBuiltAt = Date()
            }
            return LayeredEntityTyper(model: model, heuristic: heuristic)
        }
    }

    var isAvailable: Bool { true }
    func cachedType(for candidate: String) -> EntityType? { layered().cachedType(for: candidate) }
    func prepare(_ candidates: [String], context: String) async { await layered().prepare(candidates, context: context) }
}

// MARK: - Settings view

@MainActor
final class DictionaryPublicListsModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let entry: PublicDictionaryEntry
        var installed: Bool
        var id: String { entry.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var downloading: String?
    @Published private(set) var failure: String?
    @Published var showNotices = false

    init() { reload() }

    func reload() {
        rows = PublicDictionaryCatalog.all.map { Row(entry: $0, installed: $0.isInstalled) }
    }

    func status(_ row: Row) -> String {
        switch row.entry.delivery {
        case .bundled: return "Included"
        case .system: return row.installed ? "From macOS" : "Not available on this Mac"
        case .download: return row.installed ? "Downloaded" : "Not downloaded (\(Self.size(row.entry.approximateBytes)))"
        case .unavailable: return "Not available yet"
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Explicit user action only — nothing else in the app fetches a word list.
    func download(_ row: Row) {
        guard downloading == nil else { return }
        downloading = row.id
        failure = nil
        Task {
            do {
                _ = try await PublicDictionaryFetcher.fetch(row.entry)
                if row.entry.id == PublicDictionaryCatalog.scowl.id { PublicDictionaries.shared.setVocabulary(WordVocabulary.installed()) }
            } catch {
                failure = "Couldn't download \(row.entry.title). Check your connection and try again."
            }
            downloading = nil
            reload()
        }
    }
}

struct DictionaryPublicListsView: View {
    @StateObject private var model = DictionaryPublicListsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text("Public word lists")
                .windowFont(Tokens.Typography.body)
            Text("Fix the casing of names you already said (GitHub, iPhone) and keep unusual names as you said them. They never change what VoicePlus hears.")
                .windowFont(Tokens.Typography.meta)
                .foregroundStyle(WindowColor.secondaryInk)
            GroupBox(layout: .rows) {
                ForEach(model.rows) { row in
                    RowView(row.entry.title, detail: "\(model.status(row)) · \(row.entry.licence)") {
                        if row.entry.delivery == .download, !row.installed {
                            Button(model.downloading == row.id ? "Downloading…" : "Download") { model.download(row) }
                                .controlSize(.small)
                                .disabled(model.downloading != nil)
                                .accessibilityIdentifier("dictionary.publicLists.download.\(row.id)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("dictionary.publicLists")
            if let failure = model.failure {
                Text(failure)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
            }
            DisclosureGroup("Licences", isExpanded: $model.showNotices) {
                Text(PublicDictionaryCatalog.notices)
                    .windowFont(Tokens.Typography.meta)
                    .foregroundStyle(WindowColor.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("dictionary.publicLists.notices")
        }
    }
}
