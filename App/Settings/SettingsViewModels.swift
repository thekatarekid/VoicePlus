import AppKit
import Combine
import Engine
import Foundation
import GRDB
import Pipeline
import Shared

// MARK: - Hotkey

/// Hotkey choices offered in Settings.
///
/// Every case maps 1:1 onto a `HotkeyBinding.Kind` **by raw value**, which is what makes the picker
/// real. Until 1.6.8 this enum drifted from the binding — it offered an `f5` the binding could not
/// express and wrote to its own key, so choosing here changed nothing. It now writes the binding
/// key `HotkeyService` reads, and the running service picks the change up live.
public enum HotkeyChoice: String, CaseIterable, Identifiable, Sendable {
    case rightOption, leftOption, rightCommand, rightControl, fn
    case controlOptionD, controlOptionA
    public var id: String { rawValue }

    public var binding: HotkeyBinding.Kind { HotkeyBinding.Kind(rawValue: rawValue) ?? HotkeyService.defaultBinding.kind }

    public init(binding: HotkeyBinding.Kind) { self = HotkeyChoice(rawValue: binding.rawValue) ?? .default }

    public var title: String {
        switch binding.style {
        case .bareModifier: return "\(binding.displayName) (hold)"
        case .chord: return "\(binding.displayName) (hold)"
        }
    }

    /// The one line that makes the trade-off legible in the picker. With the default backends there
    /// is nothing to trade — which is the point, and worth saying out loud on a screen that used to
    /// send people to Input Monitoring.
    public var permissionNote: String {
        switch binding.style {
        case .bareModifier:
            return "Watched through a global key monitor — no extra permission."
        case .chord:
            return "Registered as a system hotkey — no extra permission."
        }
    }

    /// V4.51 (owner decision, build doc §0): fn / 🌐, the same default `HotkeyService` listens on.
    /// It was Right ⌥ through 1.10, which made Settings and Today name a key the service no longer
    /// used (wave 1 I1 hand-off).
    public static let `default` = HotkeyChoice(rawValue: HotkeyService.defaultBinding.kind.rawValue) ?? .fn

    /// The key as every hint names it ("fn / 🌐", "Right Option").
    public var label: String { binding.label }
}

/// What the **act key** (Bet 5's second key, the one that opens a voice-command session) is bound
/// to — including "nothing at all", which until 1.7.11 was not expressible.
///
/// One control, not two. A separate key picker and an on/off toggle would let a user pick a key and
/// still have a dead feature, or switch Actions on with no key; folding "Off" into the picker makes
/// the state legible in a single line of the menu and a single row in Settings.
public enum ActKeyChoice: Hashable, Identifiable, Sendable {
    /// Actions is switched off: the key is never armed and nothing it does reaches the act domain.
    case off
    case key(HotkeyChoice)

    public var id: String { rawValue }

    public var rawValue: String {
        switch self {
        case .off: return "off"
        case .key(let choice): return choice.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == "off" { self = .off; return }
        guard let choice = HotkeyChoice(rawValue: rawValue) else { return nil }
        self = .key(choice)
    }

    public var title: String {
        switch self {
        case .off: return "Off"
        case .key(let choice): return choice.title
        }
    }

    public var hotkeyChoice: HotkeyChoice? {
        if case .key(let choice) = self { return choice }
        return nil
    }

    /// Off first: it is the default, and the first thing a reader of the picker should see is that
    /// switching the feature off is an option.
    public static var allCases: [ActKeyChoice] { [.off] + HotkeyChoice.allCases.map(ActKeyChoice.key) }

    /// Off. Actions needs a cloud provider pinned for `act.planner` before it can do anything at
    /// all, so an armed-by-default act key can only ever swallow a keypress and report that the
    /// provider is missing. See `ActKeySettings`.
    public static let `default`: ActKeyChoice = .off

    /// What the act key falls back to when the user switches Actions on without ever having picked
    /// a key. Right ⌘ — the pre-1.7.11 default, kept so an upgrade lands where it used to.
    public static let suggestedKey: HotkeyChoice = .rightCommand
}

@MainActor
public final class GeneralSettingsViewModel: ObservableObject {
    /// Writes both keys: its own (`SettingsKeys.hotkey`, kept so nothing that reads it breaks) and
    /// the one `HotkeyService` actually loads its binding from. A running service observes
    /// `UserDefaults.didChangeNotification` and re-arms, so the change takes effect on release of
    /// the pop-up rather than at the next launch.
    @Published public var hotkey: HotkeyChoice {
        didSet {
            store.set(hotkey.rawValue, for: SettingsKeys.hotkey)
            store.set(hotkey.binding.rawValue, for: HotkeyService.bindingDefaultsKey)
            refreshKeyStatus()
        }
    }
    /// P4.2 — the act key, including Off. Writes the same `actHotkeyBinding` key `HotkeyService`
    /// loads the second service's binding from, plus the switch the arming rule reads, so the
    /// running app picks both up on its next tick rather than at the next launch.
    @Published public var actKey: ActKeyChoice {
        didSet {
            if let choice = actKey.hotkeyChoice {
                store.set(choice.binding.rawValue, for: HotkeyService.actBindingDefaultsKey)
            }
            ActKeySettings.setEnabled(actKey != .off, store: store)
        }
    }

    /// The escape hatch, and the only setting in the app that can make VoicePlus need Input
    /// Monitoring. Off by default and stays off unless a user with a broken global monitor turns it
    /// on deliberately.
    @Published public var forceEventTap: Bool {
        didSet { store.set(forceEventTap, for: HotkeyService.forceEventTapDefaultsKey) }
    }

    /// What the current choice costs, stated where the choice is made.
    public var hotkeyPermissionNote: String {
        forceEventTap
            ? "Legacy event tap: needs Input Monitoring in Privacy & Security, and macOS only hands that one over when VoicePlus next launches — so you'll be asked to quit and reopen."
            : hotkey.permissionNote
    }
    /// True when the act key would land on the same physical key as dictation. Not an error the
    /// picker refuses — the user may be mid-way through swapping both — but a state the UI has to
    /// say out loud, because the consequence (the act key silently does nothing) is invisible.
    public var actKeyCollidesWithDictation: Bool { actKey == .key(hotkey) }

    /// What the current act-key choice actually means, said where the choice is made.
    public var actKeyNote: String {
        guard let choice = actKey.hotkeyChoice else {
            return "Off. Nothing is listening on a second key. Actions needs a provider pinned for “Actions (voice commands)” under Models before it can do anything, so it ships off."
        }
        if actKeyCollidesWithDictation {
            return "\(choice.binding.displayName) is already your dictation key. Dictation wins — the Actions key stays inert until you pick a different one."
        }
        return "Hold \(choice.binding.displayName) and say a command. Needs a provider pinned for “Actions (voice commands)” under Models."
    }

    /// P5 — the persistent indicator near the notch. Default ON.
    @Published public var presenceIndicator: Bool {
        didSet { PresenceSettings.setEnabled(presenceIndicator, store: store) }
    }
    /// Quiet states only — `listening`, `processing` and `muted` always draw, full screen or not.
    @Published public var presenceHideInFullScreen: Bool {
        didSet { PresenceSettings.setHidesInFullScreen(presenceHideInFullScreen, store: store) }
    }

    // MARK: S7g · General (design §8.6)

    /// Design §5 step 4: 900 ms default, 600 / 1500 or manual review. Read by `TurnController`.
    @Published public var previewDwell: PreviewDwell {
        didSet { TurnSettings.setPreviewDwell(previewDwell, store: store) }
    }
    /// Off by default; never a success sound before a verified insertion (`SoundCuePolicy`).
    @Published public var soundCues: Bool {
        didSet { SoundCueSettings.setEnabled(soundCues, store: store) }
    }
    /// D6 (V4.17) — read by `UtteranceLander` at every landing.
    @Published public var spacing: SpacingPreference {
        didSet { FormattingSettings.setSpacing(spacing, store: store) }
    }
    /// D3 (V4.2) — how text lands when the caret could not be read.
    @Published public var unknownCaretStyle: UnknownCaretStyle {
        didSet { FormattingSettings.setUnknownCaretStyle(unknownCaretStyle, store: store) }
    }

    // MARK: S7g · Shortcuts

    /// "Double-tap to latch" (design §8.6). On by default.
    @Published public var latchDoubleTap: Bool {
        didSet { LatchGestureSettings.setEnabled(latchDoubleTap, store: store) }
    }
    /// B2 (V4.33) — "Insert after a pause of", 1–5 s. Written through `LatchSettings`, which clamps
    /// and posts its change notification so a latched session re-times without a restart.
    @Published public var latchPauseSeconds: TimeInterval {
        didSet {
            let clamped = LatchSettings.clamp(latchPauseSeconds)
            guard clamped == latchPauseSeconds else { latchPauseSeconds = clamped; return }
            guard clamped != oldValue else { return }
            LatchSettings.setPauseSeconds(clamped, store: store)
        }
    }
    /// G1 (V4.28) — in Latch, a bare drag draws a box. Never applies to hold.
    @Published public var drawWithoutKey: Bool {
        didSet { DeixisSettings.setDrawsWithoutKey(drawWithoutKey, store: store) }
    }
    /// I1 — macOS's own 🌐 action when it fights an fn binding; nil otherwise. Read fresh on every
    /// `refreshKeyStatus()` (the user may have just changed it in System Settings).
    @Published public private(set) var fnConflict: FnKeyConflict?

    // MARK: S7g · Appearance (windows only; the pill stays dark)

    @Published public var theme: WindowTheme {
        didSet {
            AppearanceSettings.setTheme(theme, store: store)
            applyTheme(theme)
        }
    }
    @Published public var reduceMotion: Bool {
        didSet { AppearanceSettings.setReducesMotion(reduceMotion, store: store) }
    }
    @Published public var textSize: WindowTextSize {
        didSet { AppearanceSettings.setTextSize(textSize, store: store) }
    }

    private let store: SettingsStore
    private let fnConflictReader: (HotkeyBinding.Kind) -> FnKeyConflict?
    private let keyboardSettingsOpener: () -> Void
    private let applyTheme: @MainActor (WindowTheme) -> Void

    /// `fnConflict`, `openKeyboardSettings` and `applyTheme` default to the live system; tests and
    /// the window pass `OnboardingDependencies`' readers or recorders.
    public init(store: SettingsStore,
                fnConflict: @escaping (HotkeyBinding.Kind) -> FnKeyConflict? = { HotkeyService.fnConflict(for: HotkeyBinding(kind: $0)) },
                openKeyboardSettings: @escaping () -> Void = { NSWorkspace.shared.open(FnKeyConflict.keyboardSettingsURL) },
                applyTheme: @escaping @MainActor (WindowTheme) -> Void = { AppearanceSettings.apply($0) }) {
        self.store = store
        self.fnConflictReader = fnConflict
        self.keyboardSettingsOpener = openKeyboardSettings
        self.applyTheme = applyTheme
        // The binding key wins: it is what the menu-bar submenu writes and what the service reads,
        // so a user who changed the key from the menu sees that choice reflected here.
        hotkey = store.string(HotkeyService.bindingDefaultsKey).flatMap(HotkeyChoice.init(rawValue:))
            ?? store.string(SettingsKeys.hotkey).flatMap(HotkeyChoice.init(rawValue:))
            ?? .default
        let actBinding = store.string(HotkeyService.actBindingDefaultsKey)
            .flatMap(HotkeyChoice.init(rawValue:)) ?? ActKeyChoice.suggestedKey
        actKey = ActKeySettings.isEnabled(store) ? .key(actBinding) : .off
        forceEventTap = store.bool(HotkeyService.forceEventTapDefaultsKey) ?? false
        presenceIndicator = PresenceSettings.isEnabled(store)
        presenceHideInFullScreen = PresenceSettings.hidesInFullScreen(store)
        previewDwell = TurnSettings.previewDwell(store)
        soundCues = SoundCueSettings.isEnabled(store)
        spacing = FormattingSettings.spacing(store)
        unknownCaretStyle = FormattingSettings.unknownCaretStyle(store)
        latchDoubleTap = LatchGestureSettings.isEnabled(store)
        latchPauseSeconds = LatchSettings.pauseSeconds(store)
        drawWithoutKey = DeixisSettings.drawsWithoutKey(store)
        theme = AppearanceSettings.theme(store)
        reduceMotion = AppearanceSettings.reducesMotion(store)
        textSize = AppearanceSettings.textSize(store)
        self.fnConflict = fnConflict(hotkey.binding)
        // The window is built when it first opens, so this is where a remembered theme reaches it.
        applyTheme(theme)
    }

    /// Re-reads the key's own state: the fn system action can change behind the app's back.
    public func refreshKeyStatus() { fnConflict = fnConflictReader(hotkey.binding) }

    /// I1 — System Settings › Keyboard ("Press 🌐 key to").
    public func openKeyboardSettings() { keyboardSettingsOpener() }

    /// The prototype's General "Shortcut" row button and the Shortcuts page's key cap.
    public var hotkeyLabel: String { hotkey.label }

    /// Applies a key the recorder captured, or keeps the previous one (design §8.6: "A conflict
    /// keeps your previous shortcut active"). Returns what happened, for the row to say.
    @discardableResult
    public func apply(_ capture: ShortcutCapture) -> ShortcutChange? {
        guard let change = ShortcutRecorder.resolve(capture, current: hotkey.binding, actKey: actKey) else { return nil }
        if case .changed(_, let to) = change { hotkey = HotkeyChoice(binding: to) }
        return change
    }
}

// MARK: - Models / providers per stage

/// What runs a pipeline stage. `auto` = local first, paid only where enabled and the stage benefits (Part 4.6).
///
/// R6.1: `local` carried a `ModelTier`, so this picker listed "Local · Fast", "Local · Balanced" and
/// "Local · Best" — the tier picker again, in Settings, offering two entries that are fallbacks
/// (TDT-CTC 110M) or a placeholder (Whisper) rather than choices. There is one local stack now, so
/// there is one local option.
public enum ProviderChoice: Hashable, Sendable, Identifiable {
    case auto
    case local
    case provider(String)   // provider id from P1.10 (e.g. "openrouter", "chatgpt-oauth", "claude-cli")

    public var id: String { rawValue }
    public var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .local: return "local"
        case .provider(let p): return "provider:\(p)"
        }
    }
    public init?(rawValue: String) {
        if rawValue == "auto" { self = .auto; return }
        // Any `local:*` is a setting written by a build that still had tiers. It is read as "local"
        // and left at that: nothing on disk is rewritten, and the stored value keeps working.
        if rawValue == "local" || rawValue.hasPrefix("local:") { self = .local; return }
        if rawValue.hasPrefix("provider:") { self = .provider(String(rawValue.dropFirst(9))); return }
        return nil
    }
    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .local: return "Local (on this Mac)"
        case .provider(let p): return p
        }
    }
}

/// Stages the user can route. The gatekeeper is always local (routing rule 1) so it is not listed.
public struct RoutableStage: Identifiable, Hashable, Sendable {
    public let id: StageID
    public let title: String
    public let acceptsProviders: Bool
    /// Whether a local model can serve this stage. False for the act planner, which has no local
    /// implementation at all: offering "Local (on this Mac)" there would be a second way to be told
    /// to do something that cannot work.
    public let acceptsLocal: Bool

    public init(id: StageID, title: String, acceptsProviders: Bool, acceptsLocal: Bool = true) {
        self.id = id
        self.title = title
        self.acceptsProviders = acceptsProviders
        self.acceptsLocal = acceptsLocal
    }

    public static let all: [RoutableStage] = [
        .init(id: .asr, title: "Transcription", acceptsProviders: false),
        .init(id: .formatterEmail, title: "Email formatting", acceptsProviders: true),
        .init(id: .formatterChat, title: "Chat formatting", acceptsProviders: true),
        .init(id: .formatterCode, title: "Code formatting", acceptsProviders: true),
        .init(id: .formatterProse, title: "Prose formatting", acceptsProviders: true),
        .init(id: .style, title: "Style", acceptsProviders: true),
        // 1.7.11 — the act planner was routable in every sense except the one that mattered: the
        // pill told users to set a model for Actions "in Settings" and there was no such row, so
        // the only way to configure it was a `defaults write` of this exact key. It reads
        // `routing.act.planner` through the same `SettingsKeys.routingPrefix` as every stage above,
        // so listing it here is all that was ever missing. Appended, not inserted: the routing
        // tests address this array by index.
        .init(id: ProviderPlanner.stage, title: "Actions (voice commands)",
              acceptsProviders: true, acceptsLocal: false),
    ]
}

@MainActor
public final class ModelsSettingsViewModel: ObservableObject {
    @Published public private(set) var routing: [StageID: ProviderChoice] = [:]
    @Published public var connectedProviders: [String]
    private let store: SettingsStore
    public let models: ModelManaging

    /// Whether Qwen refinement is on, which is the only thing that puts a refinement model on this
    /// screen. Read by flag *id* — see `ModelStack.refinementFlagID`.
    private let qwenRefinementEnabled: Bool

    public init(store: SettingsStore, models: ModelManaging, connectedProviders: [String] = [],
                flags: FeatureFlagService? = nil) {
        self.qwenRefinementEnabled = flags?.isEnabled(id: ModelStack.refinementFlagID) ?? false
        self.store = store
        self.models = models
        self.connectedProviders = connectedProviders
        for stage in RoutableStage.all {
            if let raw = store.string(SettingsKeys.routingPrefix + stage.id.rawValue), let c = ProviderChoice(rawValue: raw) {
                routing[stage.id] = c
            }
        }
    }

    public func choice(for stage: StageID) -> ProviderChoice { routing[stage] ?? .auto }

    public func options(for stage: RoutableStage) -> [ProviderChoice] {
        var out: [ProviderChoice] = [.auto]
        if stage.acceptsLocal { out.append(.local) }
        if stage.acceptsProviders { out += connectedProviders.map(ProviderChoice.provider) }
        return out
    }

    public func set(_ choice: ProviderChoice, for stage: StageID) {
        if choice == .auto { routing[stage] = nil } else { routing[stage] = choice }
        store.set(choice == .auto ? nil : choice.rawValue, for: SettingsKeys.routingPrefix + stage.rawValue)
    }

    public func resetToAuto() { for s in RoutableStage.all { set(.auto, for: s.id) } }

    /// The speech models this screen may name. Fallbacks (TDT-CTC 110M, the Whisper placeholder)
    /// are deliberately absent: they are what the engine walks down to, not something anyone
    /// chooses, and listing them was the last remnant of the tier picker. A refinement model shows
    /// up only while refinement is switched on.
    public var visibleModelIDs: [ModelID] { ModelCatalog.userVisible(qwenRefinementEnabled: qwenRefinementEnabled) }

    public var visibleModelNames: [String] { visibleModelIDs.map { ModelCatalog.descriptor($0).displayName } }

    /// One line for the Models tab: what transcription runs on, and whether it is here yet.
    public var speechModelSummary: String {
        let names = visibleModelNames.joined(separator: " + ")
        if models.isStackInstalled { return "\(names) — installed." }
        return "\(names) — \(ByteText.short(models.remainingStackBytes)) still to download."
    }
}

// MARK: - Personas

@MainActor
public final class PersonasViewModel: ObservableObject {
    @Published public private(set) var personas: [PersonaRecord] = []
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database; reload() }

    public func reload() {
        personas = (try? database?.reader.read { try PersonaRecord.order(Column("appBundleID")).fetchAll($0) }) ?? []
    }

    /// Upserts by bundle ID; empty instructions delete the persona.
    public func save(appBundleID: String, instructions: String) {
        let bundle = appBundleID.trimmingCharacters(in: .whitespaces)
        guard !bundle.isEmpty, let database else { return }
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { delete(appBundleID: bundle); return }
        let existing = try? database.persona(forApp: bundle)
        let record = PersonaRecord(id: existing?.id ?? UUID().uuidString, appBundleID: bundle, instructions: text)
        try? database.save(record)
        reload()
    }

    public func delete(appBundleID: String) {
        _ = try? database?.writer.write { try PersonaRecord.filter(Column("appBundleID") == appBundleID).deleteAll($0) }
        reload()
    }
}

// MARK: - Dictionary

@MainActor
public final class DictionaryViewModel: ObservableObject {
    @Published public private(set) var terms: [DictionaryRecord] = []
    @Published public var filter = ""
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database; reload() }

    public var filtered: [DictionaryRecord] {
        filter.isEmpty ? terms : terms.filter { $0.term.localizedCaseInsensitiveContains(filter) }
    }

    public func reload() { terms = (try? database?.dictionaryTerms()) ?? [] }

    @discardableResult
    public func add(term: String, spokenForms: String = "") -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !terms.contains(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) else { return false }
        try? database?.save(DictionaryRecord(term: t, spokenForms: spokenForms))
        reload()
        return true
    }

    public func remove(id: String) { try? database?.deleteDictionaryTerm(id: id); reload() }

    public func importContacts(store: ContactsStoreProtocol, settings: SettingsStore) async -> ContactsImportOffer.Outcome {
        let outcome = await ContactsImportOffer(store: store, database: database, settings: settings).accept()
        reload()
        return outcome
    }
}

// MARK: - Flags

@MainActor
public final class FlagsViewModel: ObservableObject {
    public struct Row: Identifiable, Equatable { public let flag: FeatureFlag; public var enabled: Bool; public var overridden: Bool; public var id: String { flag.id } }
    @Published public private(set) var rows: [Row] = []
    private let service: FeatureFlagService
    public init(service: FeatureFlagService) { self.service = service; reload() }

    public func reload() {
        rows = service.knownFlags.map { Row(flag: $0, enabled: service.isEnabled($0), overridden: service.override(for: $0) != nil) }
    }
    public func set(_ enabled: Bool, for flag: FeatureFlag) {
        try? service.setOverride(enabled == flag.defaultOn ? nil : enabled, for: flag); reload()
    }
    public func resetAll() { try? service.resetAll(); reload() }
}

// MARK: - Data panel (placeholder listing; P1.11 owns the full panel)

@MainActor
public final class DataPanelViewModel: ObservableObject {
    @Published public private(set) var entries: [NetworkLogRecord] = []
    @Published public private(set) var bytesOutToday = 0
    private let database: AppDatabase?
    public init(database: AppDatabase?) { self.database = database; reload() }

    public func reload() {
        entries = (try? database?.networkLog(limit: 200)) ?? []
        let dayStart = Calendar.current.startOfDay(for: Date())
        bytesOutToday = (try? database?.bytesEgressed(since: dayStart)) ?? 0
    }
}

// MARK: - Microphone

/// The microphone picker and the recording diagnostic, in one place because they answer the same
/// question: *which* mic is this, and can I prove what it captured?
///
/// Both read and write the keys the engine already owns — `InputSelectionPolicy.preferredUIDKey`
/// and `UtteranceRecorder.defaultsKey` in `UserDefaults.standard` — so nothing here is a second
/// source of truth for a setting the capture source reads.
@MainActor
public final class AudioInputSettingsViewModel: ObservableObject {
    /// Sentinel for "let VoicePlus decide", which is the default and what most people should keep.
    public static let automatic = ""

    @Published public private(set) var devices: [AudioDeviceInfo] = []
    @Published public private(set) var systemDefault: AudioDeviceInfo?

    /// A device UID, or `automatic`.
    @Published public var selection: String {
        didSet {
            policy.preferredUID = selection == Self.automatic ? nil : selection
            objectWillChange.send()
        }
    }

    /// Opt-in local audio capture. Off unless the owner turns it on, and loud about being on.
    @Published public var saveRecordings: Bool {
        didSet { UtteranceRecorder.setEnabled(saveRecordings, defaults) }
    }

    private let defaults: UserDefaults
    private let policy: InputSelectionPolicy

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.policy = InputSelectionPolicy(defaults: defaults)
        self.selection = policy.preferredUID ?? Self.automatic
        self.saveRecordings = UtteranceRecorder.isEnabled(defaults)
        refresh()
    }

    public func refresh() {
        devices = AudioDeviceEnumerator.inputDevices()
        systemDefault = AudioDeviceEnumerator.defaultInputDevice()
        // A device that was unplugged since the choice was made would otherwise show a blank picker.
        if selection != Self.automatic, !devices.contains(where: { $0.uid == selection }) {
            selection = Self.automatic
        }
    }

    public func title(for device: AudioDeviceInfo) -> String {
        var t = device.name
        if device.uid == systemDefault?.uid { t += " (system input)" }
        if BluetoothInputDetector.mode(for: device).isNarrowbandSpeech { t += " — low quality" }
        return t
    }

    /// What the automatic choice resolves to *right now*, including the case the whole rule exists
    /// for. Said in the picker, because a silent substitution is the thing being fixed.
    public var note: String {
        let decision = policy.decide(from: devices, systemDefault: systemDefault)
        if selection != Self.automatic {
            guard let chosen = devices.first(where: { $0.uid == selection }) else {
                return "That microphone isn't connected. VoicePlus is choosing automatically until it is."
            }
            if BluetoothInputDetector.mode(for: chosen).isNarrowbandSpeech {
                return "\(chosen.name) is a Bluetooth headset mic: macOS runs it at \(Int(chosen.sampleRate)) Hz "
                     + "over a phone-call link, which noticeably hurts accuracy. Switch to Automatic to use the Mac's mic instead."
            }
            return "Dictation always uses \(chosen.name)."
        }
        if let avoided = decision.avoidedNarrowbandBluetooth, let using = decision.device {
            return "\(avoided.name) is your system input, but its mic runs at \(Int(avoided.sampleRate)) Hz over "
                 + "Bluetooth — phone-call quality. VoicePlus is using \(using.name) instead, which is more accurate. "
                 + "Pick \(avoided.name) above if you'd rather have it."
        }
        guard let using = decision.device else { return "No microphone is connected." }
        return "Using \(using.name). VoicePlus follows your system input, except for Bluetooth headset mics, "
             + "which macOS drops to phone-call quality."
    }

    // MARK: recordings

    public var recordingsDirectory: URL { UtteranceRecorder.directory() }

    /// Counts whole utterances, not files, so the number matches what a person would count.
    public var recordingsSummary: String {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        let count = Set(files.map(UtteranceRecorder.stamp(of:))).count
        guard count > 0 else { return "No recordings saved yet." }
        // J1 (V4.52): the retention in force for *this* model's defaults — `Keep all` (0) reads as
        // "All of them are kept.", never "the most recent 0".
        let retain = UtteranceRecorder.retention(defaults)
        let policy = retain > 0 ? "Only the most recent \(retain) are kept." : "All of them are kept."
        return "\(count) recording\(count == 1 ? "" : "s") saved on this Mac. \(policy)"
    }

    public func revealRecordings() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([recordingsDirectory])
    }

    public func deleteRecordings() {
        try? FileManager.default.removeItem(at: recordingsDirectory)
        objectWillChange.send()
    }
}
