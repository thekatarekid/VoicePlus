import Pipeline
import Shared
import SwiftUI

/// P2.6 — spoken snippets: trigger phrase → expansion. Backed by `SnippetStoring` (DB in the app).
@MainActor
public final class SnippetsViewModel: ObservableObject {
    @Published public private(set) var snippets: [Snippet] = []
    @Published public var lastError: String?
    public let store: any SnippetStoring
    public init(store: any SnippetStoring) { self.store = store; reload() }

    public func reload() { snippets = (try? store.all()) ?? [] }

    /// Adds or updates (by id) a snippet; validation errors surface in `lastError`.
    @discardableResult
    public func save(id: String? = nil, trigger: String, body: String) -> Bool {
        do {
            try store.upsert(Snippet(id: id ?? UUID().uuidString, trigger: trigger.trimmingCharacters(in: .whitespaces), body: body))
            lastError = nil; reload(); return true
        } catch { lastError = Self.describe(error); return false }
    }

    public func delete(id: String) { try? store.delete(id: id); reload() }

    static func describe(_ e: Error) -> String {
        if let s = e as? SnippetError { return "\(s)".replacingOccurrences(of: "(", with: " (") }
        return "\(e)"
    }
}

struct SnippetsSettingsTab: View {
    @ObservedObject var model: SnippetsViewModel
    @State private var editingID: String?
    @State private var trigger = ""
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Say the trigger exactly and the expansion is typed instead. Example: “my address” → your street address.")
                .font(.caption).foregroundStyle(.secondary)
            List(model.snippets) { s in
                VStack(alignment: .leading) {
                    Text(s.trigger).font(.callout.weight(.semibold))
                    Text(s.body).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }
                .contextMenu { Button("Delete") { model.delete(id: s.id) } }
                .onTapGesture { editingID = s.id; trigger = s.trigger; body_ = s.body }
            }
            TextField("Trigger phrase (e.g. my address)", text: $trigger)
            TextEditor(text: $body_).frame(height: 60).border(.quaternary)
            HStack {
                if let err = model.lastError { Text(err).font(.caption).foregroundStyle(.red) }
                Spacer()
                if editingID != nil { Button("New") { editingID = nil; trigger = ""; body_ = "" } }
                Button(editingID == nil ? "Add" : "Save") {
                    if model.save(id: editingID, trigger: trigger, body: body_) { editingID = nil; trigger = ""; body_ = "" }
                }
            }
        }
    }
}

/// P1.5.2 — silent-correction switches: global + per app. Pure over `SettingsStore`.
@MainActor
public final class CorrectionSettingsViewModel: ObservableObject {
    @Published public var enabled: Bool { didSet { store.set(enabled, for: CorrectionSettings.enabledKey) } }
    @Published public private(set) var disabledApps: [String]
    private let store: SettingsStore
    private static let listKey = "corrections.off.list"

    public init(store: SettingsStore) {
        self.store = store
        enabled = store.bool(CorrectionSettings.enabledKey) ?? true
        disabledApps = (store.string(Self.listKey) ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    public func disable(app bundleID: String) {
        let b = bundleID.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        CorrectionSettings.setEnabled(false, for: b, store: store)
        if !disabledApps.contains(b) { disabledApps.append(b) }
        persistList()
    }

    public func enable(app bundleID: String) {
        CorrectionSettings.setEnabled(true, for: bundleID, store: store)
        disabledApps.removeAll { $0 == bundleID }
        persistList()
    }

    private func persistList() { store.set(disabledApps.joined(separator: ","), for: Self.listKey) }
}

struct CorrectionSettingsSection: View {
    @ObservedObject var model: CorrectionSettingsViewModel
    @State private var newApp = ""
    var body: some View {
        Section("Silent corrections") {
            Toggle("Fix preview words silently after landing (dual-path)", isOn: $model.enabled)
            ForEach(model.disabledApps, id: \.self) { app in
                HStack { Text(app).font(.caption.monospaced()); Spacer(); Button("Enable") { model.enable(app: app) } }
            }
            HStack {
                TextField("Turn off in app (bundle ID)", text: $newApp)
                Button("Turn off") { model.disable(app: newApp); newApp = "" }.disabled(newApp.isEmpty)
            }
        }
    }
}

/// P2.5 — auto-draft from style learnings (the user's edits are never overwritten).
extension PersonasViewModel {
    public func autoDraft(appBundleID: String, database: AppDatabase?) -> String? {
        guard let database, !appBundleID.isEmpty else { return nil }
        let manager = PersonaManager(store: DatabasePersonaStore(database: database), styles: DatabaseStyleProfileStore(database: database))
        return try? manager.draftText(for: appBundleID)
    }
}
