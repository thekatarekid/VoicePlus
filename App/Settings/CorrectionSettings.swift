import Foundation
import Providers
import Shared

// Context Writer (VoicePlus_ContextWriter_Plan.md §5) — Settings › Models "Correction": Automatic ·
// Off · On this Mac · Cloud, the cloud model and its fallbacks, pinned providers, the (stored-only)
// send-audio switch and per-app overrides. Everything lives under `correction.*`; `cloudConfig` hands
// the stored values to `CloudWriterGenerator`. Distinct from `CorrectionSettings` (silent corrections,
// Settings › General), which predates the writer.
//
// **Automatic** (the default: the user never picked a tier, `correction.mode` absent) resolves per
// dictation from what this Mac has: **On this Mac** when a shared local instruct model is on disk and
// the device's `ResidencyPlan` allows the on-device LLM (`WriterWiring.installedLocalModel`), else
// **Off**. Automatic **never** resolves to Cloud: an OpenRouter key is a general provider credential
// (Settings › Providers) and storing it for another stage is not consent to send every dictation and
// the screen around the caret to OpenRouter (PRODUCT-SPEC T3, "speech never leaves the device unless
// enabled"). Cloud runs only when `correction.mode == cloud` or a per-app override says cloud. That
// also covers anyone whose explicit Off an older build stored as "nothing" (Automatic): no stored key
// can lead to egress. An explicit tier is honoured as chosen: "Cloud" without a key (or with egress
// to OpenRouter blocked), or "On this Mac" without a model, writes nothing (it never falls back to the
// other tier). A per-app override wins over both. `resolvedMode` is what `WriterWiring` runs.

public enum ContextCorrectionSettings {
    public enum Mode: String, CaseIterable, Identifiable, Codable, Sendable {
        case off, local, cloud
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: return "Off"
            case .local: return "On this Mac"
            case .cloud: return "Cloud"
            }
        }
    }

    public static let modeKey = "correction.mode"
    public static let cloudModelKey = "correction.cloudModel"
    public static let cloudFallbacksKey = "correction.cloudFallbacks"
    public static let providerOrderKey = "correction.providerOrder"
    public static let sendAudioKey = "correction.sendAudio"
    public static let perAppKey = "correction.perApp"
    public static let didChangeNotification = Notification.Name("VoicePlus.ContextCorrectionSettings.didChange")

    /// What `mode(_:)` reads when the user never picked a tier. What actually *runs* then is
    /// `automaticMode(_:)` (see the header): `resolvedMode(for:store:availability:)`.
    public static let defaultMode: Mode = .off

    /// The picker's four values: Automatic (nothing stored) or an explicit tier.
    public enum Choice: String, CaseIterable, Identifiable, Sendable {
        case automatic, off, local, cloud
        public var id: String { rawValue }
        /// The explicit tier (nil for Automatic).
        public var mode: Mode? {
            switch self {
            case .automatic: return nil
            case .off: return .off
            case .local: return .local
            case .cloud: return .cloud
            }
        }
        public init(_ mode: Mode?) {
            switch mode {
            case nil: self = .automatic
            case .off?: self = .off
            case .local?: self = .local
            case .cloud?: self = .cloud
            }
        }
        /// "Automatic: On this Mac" / "Automatic: Off" for Automatic (with what it resolves to), else
        /// the tier's title.
        public func title(resolved: Mode) -> String {
            mode?.title ?? "\(ContextCorrectionCopy.automaticTitle): \(resolved.title)"
        }
    }

    /// What this Mac can run right now: the inputs of Automatic and of an explicit tier.
    public struct Availability: Equatable, Sendable {
        /// An OpenRouter key is stored and egress to OpenRouter is allowed (the runtime rule:
        /// `WriterWiring.liveAvailability`). Read only by an explicit Cloud tier, never by Automatic.
        public var hasCloudKey: Bool
        /// A local instruct model (the shared Qwen) is on disk, the llama.cpp runtime is linked and the
        /// device's `ResidencyPlan` offers the on-device LLM.
        public var hasLocalModel: Bool
        public init(hasCloudKey: Bool, hasLocalModel: Bool) {
            self.hasCloudKey = hasCloudKey
            self.hasLocalModel = hasLocalModel
        }
        public static let none = Availability(hasCloudKey: false, hasLocalModel: false)

        /// Whether `mode` can run on this Mac now.
        public func supports(_ mode: Mode) -> Bool {
            switch mode {
            case .off: return true
            case .local: return hasLocalModel
            case .cloud: return hasCloudKey
            }
        }
    }

    /// Every stored value at once — what the page shows, what a test round-trips, what sync could carry.
    public struct Snapshot: Codable, Equatable, Sendable {
        /// The explicit tier; nil = Automatic (never chosen).
        public var mode: Mode?
        public var cloudModel: String
        public var cloudFallbacks: [String]
        public var providerOrder: [String]
        /// Stored only (plan §2.6): no audio is sent until the audio arm of the bake-off decides.
        public var sendAudio: Bool
        public var perApp: [String: Mode]

        public init(mode: Mode? = nil,
                    cloudModel: String = CloudWriterConfig.defaultModel,
                    cloudFallbacks: [String] = CloudWriterConfig.defaultFallbacks,
                    providerOrder: [String] = [],
                    sendAudio: Bool = false,
                    perApp: [String: Mode] = [:]) {
            self.mode = mode
            self.cloudModel = cloudModel
            self.cloudFallbacks = cloudFallbacks
            self.providerOrder = providerOrder
            self.sendAudio = sendAudio
            self.perApp = perApp
        }

        public static let defaults = Snapshot()

        public func encoded() -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        public static func decode(_ json: String?) -> Snapshot? {
            guard let json, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    // MARK: Reads (defaults included)

    public static func snapshot(_ store: SettingsStore?) -> Snapshot {
        Snapshot(mode: chosenMode(store), cloudModel: cloudModel(store), cloudFallbacks: cloudFallbacks(store),
                 providerOrder: providerOrder(store), sendAudio: sendsAudio(store), perApp: overrides(store))
    }

    /// The tier the user picked, or nil when they never did (Automatic).
    public static func chosenMode(_ store: SettingsStore?) -> Mode? {
        store?.string(modeKey).flatMap(Mode.init(rawValue:))
    }

    /// The picker's value: Automatic or the explicit tier.
    public static func choice(_ store: SettingsStore?) -> Choice { Choice(chosenMode(store)) }

    /// The stored tier; Automatic reads as `defaultMode` (Off) here. What runs: `resolvedMode`.
    public static func mode(_ store: SettingsStore?) -> Mode {
        chosenMode(store) ?? defaultMode
    }

    /// The stored tier for an app: its override when one is set, else the global tier (Automatic
    /// reads as Off). What runs: `resolvedMode(for:store:availability:)`.
    public static func mode(for bundleID: String?, store: SettingsStore?) -> Mode {
        if let bundleID, let override = overrides(store)[bundleID] { return override }
        return mode(store)
    }

    /// Automatic: On this Mac with a model this Mac's plan allows, else Off. Never Cloud (see the
    /// header): a stored key alone is not an opt-in to egress.
    public static func automaticMode(_ availability: Availability) -> Mode {
        availability.hasLocalModel ? .local : .off
    }

    /// The tier selected for an app before availability: override, else the explicit tier, else
    /// what Automatic resolves to.
    public static func selectedMode(for bundleID: String?, store: SettingsStore?, availability: Availability) -> Mode {
        if let bundleID, let override = overrides(store)[bundleID] { return override }
        return chosenMode(store) ?? automaticMode(availability)
    }

    /// What runs for one dictation in `bundleID`: the selected tier when this Mac can run it, else
    /// Off (an explicit Cloud without a key, or On this Mac without a model, writes nothing).
    public static func resolvedMode(for bundleID: String?, store: SettingsStore?, availability: Availability) -> Mode {
        let selected = selectedMode(for: bundleID, store: store, availability: availability)
        return availability.supports(selected) ? selected : .off
    }

    public static func cloudModel(_ store: SettingsStore?) -> String {
        let raw = store?.string(cloudModelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? CloudWriterConfig.defaultModel : raw
    }

    public static func cloudFallbacks(_ store: SettingsStore?) -> [String] {
        guard let raw = store?.string(cloudFallbacksKey) else { return CloudWriterConfig.defaultFallbacks }
        return decodeList(raw) ?? CloudWriterConfig.defaultFallbacks
    }

    public static func providerOrder(_ store: SettingsStore?) -> [String] {
        store?.string(providerOrderKey).flatMap(decodeList) ?? []
    }

    public static func sendsAudio(_ store: SettingsStore?) -> Bool { store?.bool(sendAudioKey) ?? false }

    public static func overrides(_ store: SettingsStore?) -> [String: Mode] {
        guard let raw = store?.string(perAppKey), let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Mode].self, from: data) else { return [:] }
        return map
    }

    /// What the cloud backend is built from.
    public static func cloudConfig(_ store: SettingsStore?) -> CloudWriterConfig {
        CloudWriterConfig(model: cloudModel(store), fallbackModels: cloudFallbacks(store), providerOrder: providerOrder(store))
    }

    // MARK: Writes

    public static func write(_ s: Snapshot, store: SettingsStore?) {
        setMode(s.mode, store: store)
        setCloudModel(s.cloudModel, store: store)
        setCloudFallbacks(s.cloudFallbacks, store: store)
        setProviderOrder(s.providerOrder, store: store)
        setSendsAudio(s.sendAudio, store: store)
        setOverrides(s.perApp, store: store)
    }

    /// nil = Automatic (the key is cleared); any tier, Off included, is stored as chosen.
    public static func setMode(_ m: Mode?, store: SettingsStore?) {
        store?.set(m?.rawValue, for: modeKey)
        changed()
    }

    public static func setChoice(_ c: Choice, store: SettingsStore?) { setMode(c.mode, store: store) }

    public static func setCloudModel(_ id: String, store: SettingsStore?) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        store?.set(trimmed.isEmpty || trimmed == CloudWriterConfig.defaultModel ? nil : trimmed, for: cloudModelKey)
        changed()
    }

    public static func setCloudFallbacks(_ ids: [String], store: SettingsStore?) {
        let clean = normalise(ids)
        store?.set(clean == CloudWriterConfig.defaultFallbacks ? nil : encodeList(clean), for: cloudFallbacksKey)
        changed()
    }

    public static func setProviderOrder(_ slugs: [String], store: SettingsStore?) {
        let clean = normalise(slugs)
        store?.set(clean.isEmpty ? nil : encodeList(clean), for: providerOrderKey)
        changed()
    }

    public static func setSendsAudio(_ on: Bool, store: SettingsStore?) {
        store?.set(on, for: sendAudioKey)
        changed()
    }

    /// `nil` removes the override; the app then follows the global mode.
    public static func setOverride(_ m: Mode?, for bundleID: String, store: SettingsStore?) {
        var map = overrides(store)
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        map[key] = m
        setOverrides(map, store: store)
    }

    public static func setOverrides(_ map: [String: Mode], store: SettingsStore?) {
        if map.isEmpty { store?.set(nil, for: perAppKey) }
        else {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            store?.set((try? e.encode(map)).map { String(decoding: $0, as: UTF8.self) }, for: perAppKey)
        }
        changed()
    }

    // MARK: Lists

    /// "a, b c" → ["a", "b", "c"]: what the page's text fields hold.
    public static func parseList(_ text: String) -> [String] {
        normalise(text.split(whereSeparator: { $0 == "," || $0.isNewline || $0 == " " }).map(String.init))
    }

    static func normalise(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Model ids ("deepseek/deepseek-v4.1-flash") are stored readable: no escaped slashes.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()

    static func encodeList(_ items: [String]) -> String {
        (try? Self.encoder.encode(items)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }

    static func decodeList(_ raw: String) -> [String]? {
        guard let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return normalise(list)
    }

    private static func changed() { NotificationCenter.default.post(name: didChangeNotification, object: nil) }
}

/// Copy for the Correction group, in one place so tests can hold the words.
public enum ContextCorrectionCopy {
    public static let title = "Correction"
    public static let modeTitle = "Correction"
    public static let modeDetail = "Fix names, spellings and formatting from what is on screen. Off sends and loads nothing."
    public static let automaticTitle = "Automatic"
    public static let automaticDetail = "The rewrite model on this Mac when one is downloaded and this Mac can run it, else off. Nothing leaves the Mac: Cloud runs only when you pick it."
    public static let localDetail = "The rewrite model on this Mac (Settings › Models › Rewrite models). Nothing leaves the Mac."
    public static let localMissing = "No rewrite model on this Mac yet: download one under Rewrite models."
    public static let cloudMissing = "No OpenRouter key yet: add one under Providers. Nothing is sent until then."
    public static let cloudBlocked = "Network egress to OpenRouter is blocked (Privacy). Nothing is sent until it is allowed again."
    public static let keyBlocked = "OpenRouter · key on file · egress blocked"
    /// AI cleanup's line while Correction is on (`AICleanupGroup`).
    public static let supersedesCleanupTitle = "Correction is on"
    public static func supersedesCleanup(_ mode: ContextCorrectionSettings.Mode) -> String {
        supersedesCleanup(title: mode.title)
    }
    /// With the picker's own words: "Correction (Automatic: On this Mac) replaces …".
    public static func supersedesCleanup(_ choice: ContextCorrectionSettings.Choice, resolved: ContextCorrectionSettings.Mode) -> String {
        supersedesCleanup(title: choice.title(resolved: resolved))
    }
    static func supersedesCleanup(title: String) -> String {
        "Correction (\(title)) replaces AI cleanup on every dictation it handles. These switches apply when Correction is off."
    }
    public static let openCorrection = "Correction settings"
    public static let cloudModelTitle = "Cloud model"
    public static let cloudModelDetail = "OpenRouter id. The bake-off picked the default."
    public static let fallbacksTitle = "Fallback models"
    public static let fallbacksDetail = "Tried in order when the first is down. Comma-separated ids."
    public static let providerOrderTitle = "Pinned providers"
    public static let providerOrderDetail = "OpenRouter provider slugs, fastest first. Empty lets OpenRouter pick by latency."
    public static let providerTitle = "Provider"
    public static let dataSentTitle = "Data sent in the last hour"
    public static let sendAudioTitle = "Send audio"
    public static let sendAudioDetail = "Not used yet. Stored for the audio arm of the bake-off; today only text leaves the Mac."
    public static let overridesTitle = "Per app"
    public static let overridesDetail = "An app's own tier, over the one above."
    public static let addOverrideTitle = "Add an app"
    public static let addOverridePlaceholder = "Bundle id, e.g. com.apple.mail"
    public static let add = "Add"
    public static let remove = "Remove"
    public static let testTitle = "Test with last dictation"
    public static let testDetail = "Runs the cloud writer on your most recent dictation and shows the result here. Nothing is typed anywhere."
    public static let test = "Test"
    public static let testRunning = "Writing…"
    public static let testNoDictation = "No dictation yet."
    public static let testNoKey = "Add an OpenRouter key under Providers first."
    public static let noKey = "No OpenRouter key"
    public static let keyPresent = "OpenRouter · key on file"
    public static let nothingSent = "Nothing"
    public static let footnote = "The writer reads the focused field through accessibility only, never secure fields, and treats screen text as data."
}
