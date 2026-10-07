import Foundation
import Providers
import Shared
import SwiftUI

// Context Writer (plan §5) — the Settings › Models "Correction" group: one control (Off / On this
// Mac / Cloud), the cloud model id, the provider line, the data sent in the last hour (from the
// network log, bytes only), per-app overrides, and "Test with last dictation", which runs the cloud
// writer on the most recent history row and shows the result here. Nothing is injected.

@MainActor
public final class ContextCorrectionSettingsModel: ObservableObject {
    public typealias Writer = @Sendable (_ system: String, _ user: String) async throws -> String

    public enum TestState: Equatable {
        case idle, running, noDictation, noKey
        case done(String)
        case failed(String)
    }

    public struct Override: Identifiable, Equatable {
        public var bundleID: String
        public var mode: ContextCorrectionSettings.Mode
        public var id: String { bundleID }
    }

    private let store: SettingsStore
    private let database: AppDatabase?
    private let secrets: SecretStore
    private let writer: Writer?
    private let now: () -> Date

    @Published public var mode: ContextCorrectionSettings.Mode { didSet { ContextCorrectionSettings.setMode(mode, store: store) } }
    @Published public var cloudModel: String {
        didSet { ContextCorrectionSettings.setCloudModel(cloudModel, store: store) }
    }
    @Published public var fallbacksText: String {
        didSet { ContextCorrectionSettings.setCloudFallbacks(ContextCorrectionSettings.parseList(fallbacksText), store: store) }
    }
    @Published public var providerOrderText: String {
        didSet { ContextCorrectionSettings.setProviderOrder(ContextCorrectionSettings.parseList(providerOrderText), store: store) }
    }
    @Published public var sendAudio: Bool { didSet { ContextCorrectionSettings.setSendsAudio(sendAudio, store: store) } }
    @Published public private(set) var overrides: [Override] = []
    @Published public var newOverrideBundleID = ""
    @Published public private(set) var bytesLastHour = 0
    @Published public private(set) var hasKey = false
    @Published public private(set) var testState: TestState = .idle

    /// `writer` replaces the live cloud generator (tests); `now` fixes the "last hour" window.
    public init(store: SettingsStore, database: AppDatabase?, secrets: SecretStore = KeychainSecretStore(),
                writer: Writer? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.database = database
        self.secrets = secrets
        self.writer = writer
        self.now = now
        let s = ContextCorrectionSettings.snapshot(store)
        mode = s.mode
        cloudModel = s.cloudModel
        fallbacksText = s.cloudFallbacks.joined(separator: ", ")
        providerOrderText = s.providerOrder.joined(separator: ", ")
        sendAudio = s.sendAudio
        overrides = Self.sorted(s.perApp)
        refresh()
    }

    /// Re-reads the key and the hour's bytes (on appear and after a test).
    public func refresh() {
        hasKey = ((try? secrets.get(SecretKey.apiKey(APIEndpoint.openRouter.providerID))) ?? nil)?.isEmpty == false
        bytesLastHour = Self.writerBytes(in: database, since: now().addingTimeInterval(-3600))
    }

    /// Bytes out of every writer call (prewarm included) since `since`, from the network log.
    public static func writerBytes(in database: AppDatabase?, since: Date) -> Int {
        guard let database, let rows = try? database.networkLog(since: since, limit: 2000) else { return 0 }
        return rows.filter { $0.stage == CloudWriterGenerator.stage }.reduce(0) { $0 + $1.bytesOut + $1.bytesIn }
    }

    // MARK: Lines

    public var modeDetail: String {
        switch mode {
        case .off: return ContextCorrectionCopy.modeDetail
        case .local: return ContextCorrectionCopy.localDetail
        case .cloud: return ContextCorrectionCopy.modeDetail
        }
    }

    public var providerLine: String { hasKey ? ContextCorrectionCopy.keyPresent : ContextCorrectionCopy.noKey }

    public var dataSentLine: String {
        bytesLastHour == 0 ? ContextCorrectionCopy.nothingSent
            : ByteCountFormatter.string(fromByteCount: Int64(bytesLastHour), countStyle: .binary)
    }

    // MARK: Per-app overrides

    public func addOverride() {
        let id = newOverrideBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        setOverride(mode, for: id)
        newOverrideBundleID = ""
    }

    public func setOverride(_ m: ContextCorrectionSettings.Mode, for bundleID: String) {
        ContextCorrectionSettings.setOverride(m, for: bundleID, store: store)
        overrides = Self.sorted(ContextCorrectionSettings.overrides(store))
    }

    public func removeOverride(_ bundleID: String) {
        ContextCorrectionSettings.setOverride(nil, for: bundleID, store: store)
        overrides = Self.sorted(ContextCorrectionSettings.overrides(store))
    }

    private static func sorted(_ map: [String: ContextCorrectionSettings.Mode]) -> [Override] {
        map.map { Override(bundleID: $0.key, mode: $0.value) }.sorted { $0.bundleID < $1.bundleID }
    }

    // MARK: Test with last dictation

    /// Until `Pipeline`'s writer stage renders the real packet prompt, the test uses this plain
    /// transcribe instruction over the raw text alone (no screen, no thread).
    public static let testSystemPrompt = """
    You correct dictated text. Fix obvious recognition errors, punctuation and casing. Keep the user's \
    words and meaning; never add, answer or explain. Reply with the corrected text only.
    """

    public func testWithLastDictation() {
        guard testState != .running else { return }
        guard let database, let last = (try? database.recentDictations(limit: 1))?.first else { testState = .noDictation; return }
        let input = last.rawText.isEmpty ? last.finalText : last.rawText
        guard !input.isEmpty else { testState = .noDictation; return }
        guard writer != nil || hasKey else { testState = .noKey; return }
        let write = writer ?? liveWriter()
        testState = .running
        Task { [weak self] in
            do {
                let out = try await write(Self.testSystemPrompt, input)
                await MainActor.run { self?.finish(.done(out.trimmingCharacters(in: .whitespacesAndNewlines))) }
            } catch {
                await MainActor.run { self?.finish(.failed("\(error)")) }
            }
        }
    }

    private func finish(_ state: TestState) {
        testState = state
        refresh()
    }

    private func liveWriter() -> Writer {
        let generator = CloudWriterGenerator(config: ContextCorrectionSettings.cloudConfig(store), secrets: secrets,
                                             logger: database.map { DatabaseNetworkLogger(db: $0) })
        return { system, user in try await generator.write(system: system, user: user) }
    }
}

/// The group on Settings › Models.
struct CorrectionSettingsPage: View {
    @ObservedObject var model: ContextCorrectionSettingsModel

    var body: some View {
        GroupBox(ContextCorrectionCopy.title, layout: .rows) {
            SettingsPickerRow(title: ContextCorrectionCopy.modeTitle, detail: model.modeDetail,
                              selection: $model.mode, options: ContextCorrectionSettings.Mode.allCases,
                              label: { $0.title }, identifier: "settings.correction.mode")
            if model.mode == .cloud {
                field(ContextCorrectionCopy.cloudModelTitle, detail: ContextCorrectionCopy.cloudModelDetail,
                      text: $model.cloudModel, identifier: "settings.correction.cloudModel")
                field(ContextCorrectionCopy.fallbacksTitle, detail: ContextCorrectionCopy.fallbacksDetail,
                      text: $model.fallbacksText, identifier: "settings.correction.cloudFallbacks")
                field(ContextCorrectionCopy.providerOrderTitle, detail: ContextCorrectionCopy.providerOrderDetail,
                      text: $model.providerOrderText, identifier: "settings.correction.providerOrder")
                RowView(ContextCorrectionCopy.providerTitle, detail: model.providerLine)
                    .accessibilityIdentifier("settings.correction.provider")
                RowView(ContextCorrectionCopy.dataSentTitle, detail: model.dataSentLine)
                    .accessibilityIdentifier("settings.correction.dataSent")
                SettingsToggleRow(title: ContextCorrectionCopy.sendAudioTitle, detail: ContextCorrectionCopy.sendAudioDetail,
                                  isOn: $model.sendAudio, identifier: "settings.correction.sendAudio")
            }
            overrides
            test
        }
        .onAppear { model.refresh() }
    }

    private func field(_ title: String, detail: String, text: Binding<String>, identifier: String) -> some View {
        RowView(title, detail: detail) {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
    }

    @ViewBuilder private var overrides: some View {
        ForEach(model.overrides) { entry in
            RowView(entry.bundleID, detail: ContextCorrectionCopy.overridesDetail) {
                HStack(spacing: Tokens.Spacing.s) {
                    Picker(entry.bundleID, selection: Binding(get: { entry.mode }, set: { model.setOverride($0, for: entry.bundleID) })) {
                        ForEach(ContextCorrectionSettings.Mode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(entry.bundleID)
                    Button(ContextCorrectionCopy.remove) { model.removeOverride(entry.bundleID) }
                }
            }
            .accessibilityIdentifier("settings.correction.override.\(entry.bundleID)")
        }
        RowView(ContextCorrectionCopy.addOverrideTitle, detail: ContextCorrectionCopy.overridesTitle) {
            HStack(spacing: Tokens.Spacing.s) {
                TextField(ContextCorrectionCopy.addOverridePlaceholder, text: $model.newOverrideBundleID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { model.addOverride() }
                    .accessibilityIdentifier("settings.correction.override.bundleID")
                Button(ContextCorrectionCopy.add) { model.addOverride() }
                    .disabled(model.newOverrideBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("settings.correction.override.add")
            }
        }
    }

    @ViewBuilder private var test: some View {
        RowView(ContextCorrectionCopy.testTitle, detail: ContextCorrectionCopy.testDetail) {
            HStack(spacing: Tokens.Spacing.s) {
                if model.testState == .running { ProgressView().controlSize(.small) }
                Button(ContextCorrectionCopy.test) { model.testWithLastDictation() }
                    .disabled(model.testState == .running)
                    .accessibilityIdentifier("settings.correction.test")
            }
        }
        if let line = testLine {
            RowView(line.title, detail: line.detail)
                .accessibilityIdentifier("settings.correction.testResult")
        }
    }

    private var testLine: (title: String, detail: String)? {
        switch model.testState {
        case .idle: return nil
        case .running: return (ContextCorrectionCopy.testRunning, "")
        case .noDictation: return (ContextCorrectionCopy.testNoDictation, "")
        case .noKey: return (ContextCorrectionCopy.testNoKey, "")
        case .done(let text): return ("Result", text)
        case .failed(let why): return ("Failed", why)
        }
    }
}
