import Engine
import Foundation
import Providers
import Shared
import SwiftUI

// V5 M22 (+M24) — the Meetings provider picker. Every backend already exists in `Providers/`:
// the on-device model (D2 llama.cpp, the default), the user's subscription through the `claude` /
// `codex` CLIs or "Sign in with ChatGPT" (M22), and a BYO key, Ollama or LM Studio (M24). What is
// new is only this picker and the pin it writes: one choice pins both meeting stages
// (`routing.meeting.notes` and `routing.meeting.ask` = `provider:<id>`), which `RoutingMeetingGenerator`
// reads; "On this Mac" removes the pins. A backend that is not set up is listed, disabled, with what
// to do; nothing is downloaded, signed in or sent from here.

public enum MeetingBackendKind: String, CaseIterable, Sendable {
    case local, claudeCLI, codexCLI, chatGPT, ollama, lmStudio, apiKey

    /// The kind a registered provider id belongs to; nil for providers meetings do not offer
    /// (the rules fallback, cloud ASR, the cleanup model).
    public static func of(_ id: ProviderID) -> MeetingBackendKind? {
        switch id.rawValue {
        case MeetingLocalLLMProvider.providerID.rawValue: return .local
        case "cli.claude": return .claudeCLI
        case "cli.codex": return .codexCLI
        case "oauth.chatgpt": return .chatGPT
        case "local.ollama": return .ollama
        case "local.lmStudio": return .lmStudio
        default: return id.rawValue.hasPrefix("api.") ? .apiKey : nil
        }
    }

    public var title: String {
        switch self {
        case .local: return "On this Mac"
        case .claudeCLI: return "Claude (claude CLI)"
        case .codexCLI: return "Codex (codex CLI)"
        case .chatGPT: return "ChatGPT (your subscription)"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .apiKey: return "Your API key"
        }
    }

    /// What to do when the backend is not set up.
    public var setupHint: String {
        switch self {
        case .local: return "Download the on-device model in Settings › Models."
        case .claudeCLI: return "Install Claude Code and sign in; VoicePlus finds the claude command."
        case .codexCLI: return "Install the Codex CLI and sign in; VoicePlus finds the codex command."
        case .chatGPT: return "Sign in with ChatGPT in Settings › Providers."
        case .ollama: return "Start Ollama, then look again."
        case .lmStudio: return "Start LM Studio's local server, then look again."
        case .apiKey: return "Add a key in Settings › Providers."
        }
    }
}

public struct MeetingBackendOption: Identifiable, Equatable, Sendable {
    /// "local" for the on-device model, else the provider id (`cli.claude`, `api.openrouter`…).
    public var id: String
    public var kind: MeetingBackendKind
    public var title: String
    public var detail: String
    public var isAvailable: Bool
    /// False when the transcript leaves this Mac (CLI, ChatGPT, a key).
    public var staysOnMac: Bool

    public static let localID = "local"

    public var providerID: ProviderID? { id == Self.localID ? nil : ProviderID(rawValue: id) }
}

/// What both meeting stages are pinned to.
public enum MeetingBackendSelection: Equatable, Sendable {
    case option(String)
    /// The two stages were pinned separately in Settings › Providers.
    case mixed
}

public enum MeetingBackends {
    public static let stages: [StageID] = [.meetingNotes, .meetingAsk]

    /// Every backend the picker shows, set up or not: on-device first, then the subscriptions,
    /// then local servers, then each configured key (one "Your API key" row when there is none).
    public static func options(providers: [any Provider], localInstalled: Bool, localName: String) -> [MeetingBackendOption] {
        let byKind = Dictionary(grouping: providers.filter { MeetingBackendKind.of($0.id) != nil }) { MeetingBackendKind.of($0.id)! }
        var out = [MeetingBackendOption(id: MeetingBackendOption.localID, kind: .local, title: MeetingBackendKind.local.title,
                                        detail: localInstalled ? localName : MeetingBackendKind.local.setupHint,
                                        isAvailable: localInstalled, staysOnMac: true)]
        for kind in [MeetingBackendKind.claudeCLI, .codexCLI, .chatGPT, .ollama, .lmStudio, .apiKey] {
            let found = (byKind[kind] ?? []).sorted { $0.id.rawValue < $1.id.rawValue }
            if found.isEmpty {
                out.append(MeetingBackendOption(id: placeholderID(kind), kind: kind, title: kind.title, detail: kind.setupHint,
                                                isAvailable: false, staysOnMac: kind == .ollama || kind == .lmStudio))
            }
            for p in found {
                out.append(MeetingBackendOption(id: p.id.rawValue, kind: kind,
                                                title: kind == .apiKey ? p.displayName : kind.title,
                                                detail: p.privacyClass == .cloud ? "Transcript excerpts are sent to \(p.displayName)."
                                                                                 : "\(p.displayName), on this Mac.",
                                                isAvailable: true, staysOnMac: p.privacyClass != .cloud))
            }
        }
        return out
    }

    /// Ids for rows with nothing behind them; never written as a pin.
    static func placeholderID(_ kind: MeetingBackendKind) -> String { "setup.\(kind.rawValue)" }

    static func pin(for stage: StageID, in settings: SettingsStore) -> String {
        guard let raw = settings.string(SettingsKeys.routingPrefix + stage.rawValue),
              case .provider(let id)? = ProviderChoice(rawValue: raw) else { return MeetingBackendOption.localID }
        return id
    }

    public static func selection(_ settings: SettingsStore) -> MeetingBackendSelection {
        let pins = Set(stages.map { pin(for: $0, in: settings) })
        return pins.count == 1 ? .option(pins.first!) : .mixed
    }

    /// Pins both meeting stages to `option` (on-device clears the pins). Unavailable rows do nothing.
    @discardableResult
    public static func choose(_ option: MeetingBackendOption, settings: SettingsStore) -> Bool {
        guard option.isAvailable else { return false }
        for stage in stages {
            settings.set(option.providerID.map { ProviderChoice.provider($0.rawValue).rawValue }, for: SettingsKeys.routingPrefix + stage.rawValue)
        }
        return true
    }
}

extension MeetingIntelligence {
    /// V5 M22 — the picker's rows from what is registered in the routing table now.
    public func backendOptions() -> [MeetingBackendOption] {
        guard let routing = routingTable else { return [] }
        let local = routing.provider(MeetingLocalLLMProvider.providerID) as? MeetingLocalLLMProvider
        return MeetingBackends.options(providers: routing.allProviders, localInstalled: local?.isInstalled ?? false,
                                       localName: local?.displayName ?? "On-device model")
    }

    public var backendSelection: MeetingBackendSelection {
        settingsStore.map(MeetingBackends.selection) ?? .option(MeetingBackendOption.localID)
    }

    @discardableResult
    public func chooseBackend(_ option: MeetingBackendOption) -> Bool {
        guard let settings = settingsStore else { return false }
        return MeetingBackends.choose(option, settings: settings)
    }

    /// "Look again": Ollama / LM Studio started after launch are registered for meetings
    /// (a meeting-sized timeout; nothing else is re-discovered).
    public func discoverLocalServers(detect: () async -> [LocalServerInfo] = { await LocalServerDetector().detect() }) async {
        guard let routing = routingTable else { return }
        for info in await detect() where routing.provider(ProviderID(rawValue: "local.\(info.kind.rawValue)")) == nil {
            routing.register(LocalServerProvider(info: info, timeout: MeetingLocalLLMProvider.deadline))
        }
    }
}

// MARK: - Picker

@MainActor
final class MeetingsBackendModel: ObservableObject {
    @Published private(set) var options: [MeetingBackendOption] = []
    @Published private(set) var selection: MeetingBackendSelection = .option(MeetingBackendOption.localID)
    @Published private(set) var looking = false
    let intelligence: MeetingIntelligence
    let onChange: () -> Void

    init(intelligence: MeetingIntelligence = .shared, onChange: @escaping () -> Void = {}) {
        self.intelligence = intelligence
        self.onChange = onChange
        reload()
    }

    func reload() {
        options = intelligence.backendOptions()
        selection = intelligence.backendSelection
    }

    var selectedID: String {
        get { if case .option(let id) = selection { return id }; return "" }
        set {
            guard let option = options.first(where: { $0.id == newValue }), intelligence.chooseBackend(option) else { return }
            reload()
            onChange()
        }
    }

    var selected: MeetingBackendOption? { options.first { $0.id == selectedID } }

    func lookAgain() async {
        looking = true
        defer { looking = false }
        await intelligence.discoverLocalServers()
        reload()
    }
}

enum MeetingsBackendCopy {
    static let label = "Notes and Ask use"
    static let mixed = "Set separately in Settings › Providers"
    static let lookAgain = "Look again"
    static func notSetUp(_ n: Int) -> String { n == 1 ? "1 more option to set up" : "\(n) more options to set up" }
}

/// "Notes and Ask use: [On this Mac ▾]" — on the Ask tab and Ask across meetings.
struct MeetingsBackendPicker: View {
    @StateObject private var model: MeetingsBackendModel

    init(onChange: @escaping () -> Void = {}) {
        _model = StateObject(wrappedValue: MeetingsBackendModel(onChange: onChange))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.s) {
                Picker(MeetingsBackendCopy.label, selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) {
                    if model.selection == .mixed { Text(MeetingsBackendCopy.mixed).tag("") }
                    ForEach(model.options) { option in
                        Text(option.title).tag(option.id).disabled(!option.isAvailable)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("meetings.backend.picker")
                Button(MeetingsBackendCopy.lookAgain) { Task { await model.lookAgain() } }
                    .buttonStyle(.link)
                    .disabled(model.looking)
                    .accessibilityIdentifier("meetings.backend.lookAgain")
            }
            if let detail = model.selected?.detail {
                Text(detail).windowFont(Tokens.Typography.meta).foregroundStyle(WindowColor.secondaryInk)
            }
            let unset = model.options.filter { !$0.isAvailable }
            if !unset.isEmpty {
                DisclosureGroup(MeetingsBackendCopy.notSetUp(unset.count)) {
                    Text(unset.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
                        .windowFont(Tokens.Typography.meta)
                        .foregroundStyle(WindowColor.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .windowFont(Tokens.Typography.meta)
                .accessibilityIdentifier("meetings.backend.setup")
            }
        }
        .onAppear { model.reload() }
    }
}
