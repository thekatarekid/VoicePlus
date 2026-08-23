import SwiftUI
import Shared
import Pipeline
import KeyboardCore

@main
struct VoicePlusMobileApp: App {
    @StateObject private var model = CompanionModel()
    var body: some Scene {
        WindowGroup { CompanionView().environmentObject(model) }
    }
}

/// Companion app: hosts the heavy pipeline (`PipelineRunner.standard()`) behind the
/// App-Group/Darwin-notification proxy, and edits the personas the keyboard shows.
/// NOTE: iOS only delivers Darwin notifications to a running process — the proxy answers while
/// the app is foregrounded or briefly backgrounded; otherwise the keyboard lands raw ASR text
/// after `KeyboardProxyNames.responseTimeout`.
@MainActor
final class CompanionModel: ObservableObject {
    @Published var personas = AppGroupStore.loadPersonas()
    @Published var served = 0
    @Published var speechAuthorized = false
    private var server: KeyboardProxyServer?
    private let runner = PipelineRunner.standard()

    init() { startProxy() }

    func startProxy() {
        guard let box = try? AppGroupStore.mailbox() else { return }
        let runner = self.runner
        let server = KeyboardProxyServer(mailbox: box, doorbell: DarwinDoorbell()) { [weak self] req in
            var ctx = StageContext(appBundleID: "ios.keyboard")
            if let p = req.persona { ctx.extra[PersonaManager.promptKey] = p }
            let out = (try? await runner.run(req.spans, context: ctx))?.spans ?? req.spans
            await MainActor.run { self?.served += 1 }
            return out
        }
        server.start(); self.server = server
        server.serviceOnce() // drain anything posted while we were not running
    }

    func requestSpeech() async { speechAuthorized = await SpeechRecognizerASR.requestAuthorization() }

    func add(title: String, text: String) {
        var entries = personas.entries.filter { $0.id != PersonaPicker.none.id }
        entries.append(.init(id: UUID().uuidString, title: title, text: text))
        personas = PersonaPicker(entries: entries, selectedID: personas.selectedID); AppGroupStore.savePersonas(personas)
    }
    func remove(_ id: String) {
        personas = PersonaPicker(entries: personas.entries.filter { $0.id != id && $0.id != PersonaPicker.none.id }, selectedID: personas.selectedID)
        AppGroupStore.savePersonas(personas)
    }
}

struct CompanionView: View {
    @EnvironmentObject var model: CompanionModel
    @State private var title = ""; @State private var text = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    Label(AppGroupStore.hasAppGroup ? "App Group ready" : "App Group missing (check entitlements)", systemImage: AppGroupStore.hasAppGroup ? "checkmark.circle" : "xmark.circle")
                    Button(model.speechAuthorized ? "Speech authorized" : "Authorize on-device speech") { Task { await model.requestSpeech() } }
                    Text("Settings → General → Keyboard → Keyboards → Add VoicePlus, then enable Allow Full Access.").font(.footnote)
                    Text("Pipeline requests served: \(model.served)").font(.footnote)
                }
                Section("Personas") {
                    ForEach(model.personas.entries.filter { $0.id != PersonaPicker.none.id }) { e in
                        VStack(alignment: .leading) { Text(e.title).bold(); Text(e.text).font(.footnote) }
                    }.onDelete { idx in
                        let list = model.personas.entries.filter { $0.id != PersonaPicker.none.id }
                        idx.map { list[$0].id }.forEach(model.remove)
                    }
                    TextField("Title (e.g. Work email)", text: $title)
                    TextField("Plain-English instruction", text: $text)
                    Button("Add persona") { model.add(title: title, text: text); title = ""; text = "" }.disabled(title.isEmpty || text.isEmpty)
                }
            }.navigationTitle("VoicePlus")
        }
    }
}
