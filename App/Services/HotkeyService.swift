import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Shared

// MARK: - Addressing a tap without a pointer

/// Resolves the integer token a live CGEvent tap carries in its `userInfo` back to the service that
/// created it.
///
/// Until 1.6.6 the tap's `userInfo` was `Unmanaged.passUnretained(self).toOpaque()` — a raw pointer
/// to an object the tap does not own, in a class with no `deinit`. Nothing but luck kept the run
/// loop from calling into freed memory: both `HotkeyService` instances happen to be stored
/// properties of `AppDelegate` and live for the whole process. Any future owner with a shorter life
/// (a settings sheet that makes one to preview a binding, a re-created service after a binding
/// change) turned that into a use-after-free reachable from any keypress.
///
/// A token cannot dangle. A retired token resolves to nil; a freed pointer resolves to a crash.
/// That difference is the entire reason for the indirection — and it is what lets
/// `HotkeyTapRegistry.isLive(_:)` make "teardown leaves nothing callable" an assertion instead of a
/// hope.
enum HotkeyTapRegistry {
    /// Weak, so a service that is released while a tap is somehow still installed resolves to nil
    /// rather than being resurrected by its own callback.
    private final class Entry {
        weak var service: HotkeyService?
        init(_ service: HotkeyService) { self.service = service }
    }

    private static let lock = NSLock()
    /// Starts at 1: `UnsafeMutableRawPointer(bitPattern:)` is nil for 0, and a nil `userInfo` is
    /// indistinguishable from "no context".
    private static var nextToken = 1
    private static var entries: [Int: Entry] = [:]

    static func register(_ service: HotkeyService) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let token = nextToken
        nextToken += 1
        entries[token] = Entry(service)
        return token
    }

    static func retire(_ token: Int) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: token)
    }

    static func service(for token: Int) -> HotkeyService? {
        lock.lock()
        defer { lock.unlock() }
        return entries[token]?.service
    }

    /// Would a callback carrying this token still reach a service? False the instant the tap that
    /// owns it is torn down, and false forever after.
    static func isLive(_ token: Int) -> Bool { service(for: token) != nil }
}

// MARK: - The backend seam

/// A hotkey source that has been installed and hooked up to the main run loop, addressed only
/// through closures so no CF object, Carbon ref or `NSEvent` monitor token escapes `HotkeyService`.
public struct InstalledHotkeySource {
    /// Only the event-tap backend has a real enable/disable; the monitor and Carbon backends
    /// implement this as a no-op and rely on `HotkeyService.isPaused`.
    public var setEnabled: (Bool) -> Void
    /// Uninstall completely. Must be safe to call twice.
    public var invalidate: () -> Void

    public init(setEnabled: @escaping (Bool) -> Void, invalidate: @escaping () -> Void) {
        self.setEnabled = setEnabled
        self.invalidate = invalidate
    }
}

/// Kept so the 1.6.7 tests and `StubEventTap` read unchanged. The type is no longer tap-specific.
public typealias InstalledEventTap = InstalledHotkeySource

/// Everything `HotkeyService.start()` needs from the system, in one injectable value.
///
/// A `swift test` process cannot create a working event tap and has no run loop pumping AppKit, so
/// without this seam the arm → re-arm → stop lifecycle — the part that went wrong in 1.6.6 — would
/// be the one part of the hotkey path with no test at all.
///
/// `install` takes only the token on purpose: the backend that needs the binding (Carbon, which has
/// to know *which* chord to register) reads it back off the registry, so every backend has the same
/// one-argument shape and `StubEventTap` did not have to change.
public struct HotkeyBackend {
    /// Which mechanism this is — the thing that decides the permission cost.
    public var kind: HotkeyBackendKind
    /// Is the permission this backend needs (if any) in place? `{ true }` for the permission-free
    /// backends.
    public var preflight: () -> Bool
    /// Install the source whose callbacks carry `token`. nil when it could not be created.
    public var install: (_ token: Int) -> InstalledHotkeySource?

    public init(kind: HotkeyBackendKind = .eventTap, preflight: @escaping () -> Bool,
                install: @escaping (Int) -> InstalledHotkeySource?) {
        self.kind = kind
        self.preflight = preflight
        self.install = install
    }

    /// `NSEvent` global + local `flagsChanged` monitors. The shipping default. Needs no permission.
    public static let globalMonitor = HotkeyBackend(kind: .globalMonitor, preflight: { true },
                                                    install: HotkeyService.installGlobalMonitor)

    /// Carbon `RegisterEventHotKey`. Chords only. Needs no permission.
    public static let carbon = HotkeyBackend(kind: .carbon, preflight: { true },
                                             install: HotkeyService.installCarbonHotKey)

    /// The 1.6.7 mechanism: a `.listenOnly` CGEvent tap, gated on Input Monitoring. Reachable only
    /// through the `hotkeyForceEventTap` escape hatch.
    public static let eventTap = HotkeyBackend(kind: .eventTap, preflight: { CGPreflightListenEventAccess() },
                                               install: HotkeyService.installSystemTap)

    /// The production backend for a binding.
    public static func system(for binding: HotkeyBinding, forceEventTap: Bool = false) -> HotkeyBackend {
        switch HotkeyBackendSelector.kind(for: binding, forceEventTap: forceEventTap) {
        case .globalMonitor: return .globalMonitor
        case .carbon: return .carbon
        case .eventTap: return .eventTap
        }
    }

    /// Retained so existing call sites that just want "whatever production uses" keep working; the
    /// service picks per binding at every `start()` unless a test has pinned one.
    public static var system: HotkeyBackend { .globalMonitor }
}

/// Kept so the 1.6.7 tests read unchanged.
public typealias EventTapInstaller = HotkeyBackend

/// Records installs and teardowns instead of touching the system. Lives beside the real backends
/// (like `MockHotkeyArming` beside `CapabilityWatcher`) so the tests need no event tap.
public final class StubEventTap {
    public var preflightResult = true
    public var installSucceeds = true
    /// What the stub claims to be. Selection tests set this to prove which mechanism was chosen.
    public var kind: HotkeyBackendKind = .eventTap
    public private(set) var installed: [Int] = []
    public private(set) var invalidated: [Int] = []
    public private(set) var enableCalls: [(token: Int, enabled: Bool)] = []

    public init() {}

    /// Tokens whose source was created and never invalidated. Must never exceed 1 for one service.
    public var liveTaps: [Int] { installed.filter { !invalidated.contains($0) } }

    public var installer: HotkeyBackend {
        HotkeyBackend(kind: kind, preflight: { [weak self] in self?.preflightResult ?? false }) { [weak self] token in
            guard let self, self.installSucceeds else { return nil }
            self.installed.append(token)
            return InstalledHotkeySource(
                setEnabled: { [weak self] on in self?.enableCalls.append((token, on)) },
                invalidate: { [weak self] in
                    guard let self, !self.invalidated.contains(token) else { return }
                    self.invalidated.append(token)
                }
            )
        }
    }
}

// MARK: - Reading macOS's own fn / 🌐 action

/// Reads `AppleFnUsageType` (`com.apple.HIToolbox`). nil when no value is stored.
public struct FnUsageReader {
    public var read: () -> Int?

    public init(read: @escaping () -> Int?) { self.read = read }

    /// The live system value. Synchronizes first, so a change the user just made in System
    /// Settings › Keyboard is seen without a relaunch.
    public static let system = FnUsageReader {
        let domain = FnKeySystemAction.defaultsDomain as CFString
        CFPreferencesAppSynchronize(domain)
        return FnUsageReader.integer(CFPreferencesCopyAppValue(FnKeySystemAction.defaultsKey as CFString, domain))
    }

    /// The same key read from a given defaults store — how the tests fake the system domain.
    public static func defaults(_ defaults: UserDefaults) -> FnUsageReader {
        FnUsageReader { integer(defaults.object(forKey: FnKeySystemAction.defaultsKey)) }
    }

    /// `defaults write … -int 2` stores a number; a hand-edited plist may hold a string.
    static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

// MARK: - Telling Carbon hot keys apart

/// Which registration a `kEventHotKeyPressed` / `kEventHotKeyReleased` event belongs to.
enum CarbonHotKeyEvent {
    static func id(of event: EventRef) -> EventHotKeyID? {
        var id = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        return status == noErr ? id : nil
    }

    /// Is this event for the registration made with `signature` and `token`?
    static func matches(_ id: EventHotKeyID?, signature: OSType, token: Int) -> Bool {
        guard let id else { return false }
        return id.signature == signature && Int(id.id) == token
    }
}

// MARK: - The service

/// Global dictation-key listener (T3), feeding `HotkeyStateMachine`.
///
/// ## Which mechanism, and what it costs
/// Until 1.6.7 there was exactly one: a `.listenOnly` `CGEvent` tap, the single global-input API
/// gated on `kTCCServiceListenEvent`. That one choice is where the whole Input Monitoring
/// requirement came from — the extra pane, the switch macOS honours only after a forced
/// quit-and-relaunch, and the stale-grant dead end that cost four rounds of debugging. None of the
/// comparable apps on the reporting machine (Claude, Wispr Flow, Gemini, Spokenly, Muesli) appear in
/// that pane, and none of them use that API.
///
/// `start()` now picks a backend from the binding (`HotkeyBackendSelector`):
/// * a bare modifier → `NSEvent` global + local `flagsChanged` monitors, **no permission**;
/// * a chord → Carbon `RegisterEventHotKey`, **no permission**;
/// * the event tap only when the `hotkeyForceEventTap` escape hatch is set.
///
/// ## Thread and lifetime discipline (unchanged, and still the reason for the token)
/// * Callbacks touch no Swift object directly: they copy the scalars they need and hand them, plus
///   the token, to `deliver(token:…)`. A token cannot dangle; a retired one resolves to nil, where a
///   freed pointer would resolve to a crash.
/// * `deliver` re-resolves the token and applies the event **on the main thread**. `NSEvent`
///   monitors and Carbon handlers already run there, so for the two default backends the hop is a
///   no-op — but it is what keeps the tap path correct too.
/// * There is exactly one live source per service: `start()` tears down any leftover before creating
///   one, and `stop()`/`deinit` invalidate it *and* retire the token.
public final class HotkeyService {
    public static let bindingDefaultsKey = "hotkeyBinding"
    /// P4.2 — the second (act) key persists under its own key; default Right ⌘.
    public static let actBindingDefaultsKey = "actHotkeyBinding"
    /// Escape hatch: force the pre-1.6.8 `.listenOnly` CGEvent tap. The only setting that can make
    /// VoicePlus need Input Monitoring, and nothing in the shipped UI turns it on.
    public static let forceEventTapDefaultsKey = "hotkeyForceEventTap"
    /// X1 (owner round 4) — the dictation key when nothing is stored: Option, left or right (hold =
    /// dictate, double tap = hands-free). Stored bindings always win; the act key passes its own
    /// default (Right ⌘).
    public static let defaultBinding = HotkeyBinding(kind: .option)
    /// X1 — set once a stored fn binding has been moved to Option (owner round 4). After that a
    /// user who picks fn again keeps it.
    public static let optionMigrationDefaultsKey = "hotkeyOptionMigrationV1"

    /// X1, run eagerly and once per install: a legacy stored fn moves to Option, and the flag is set
    /// **whether or not anything is stored**.
    ///
    /// 1.15.1 ran this lazily inside `storedBinding`, after a `guard` that returned early when
    /// nothing was stored — so an install that never stored a key kept the flag unset, and the
    /// first value ever written (the owner picking fn / 🌐 in Settings) was taken for a legacy fn
    /// and rewritten to Option by the `didChangeNotification` reload. The owner saw "fn / 🌐 is now
    /// your dictation key" while Option kept dictating. Now the migration runs before any service
    /// reads or observes the key, and `storedBinding` is a pure read, so a user's write is final.
    /// Returns true when it rewrote a stored fn.
    @discardableResult
    public static func migrateLegacyBindingIfNeeded(defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: optionMigrationDefaultsKey) else { return false }
        let legacyFn = defaults.string(forKey: bindingDefaultsKey) == HotkeyBinding.Kind.fn.rawValue
        if legacyFn {
            Log.app.notice("hotkey: dictation key moves from fn to Option (owner round 4)")
            defaults.set(HotkeyBinding.Kind.option.rawValue, forKey: bindingDefaultsKey)
        }
        defaults.set(true, forKey: optionMigrationDefaultsKey)
        return legacyFn
    }

    public var onAction: ((HotkeyStateMachine.Action) -> Void)?
    /// Whether this service should hold a live source at all. Read fresh on every arming tick, so
    /// a Settings-side switch tears the source down (and puts it back) without a relaunch.
    ///
    /// The dictation key leaves this at `true` forever — it is the product. The act key hangs it on
    /// `ActKeySettings.isEnabled`, which is how "turn Actions off entirely" reaches the mechanism
    /// rather than just the delivery point.
    public var isWanted: () -> Bool = { true }
    /// X3-taps — does the notch show something that is not a live capture as the key goes down?
    /// Over such a surface a press up to ~0.8 s is a dismissing tap. The dictation key reads the
    /// pill's published visibility; any other key (the act key) never treats a press as over it.
    public var surfaceShowing: () -> Bool
    public private(set) var machine: HotkeyStateMachine
    public private(set) var binding: HotkeyBinding
    public private(set) var isRunning = false
    public var isPaused = false

    /// Swappable so the lifecycle is testable without any system API. When nil (production), the
    /// backend is chosen from the binding at every `start()`; a non-nil value pins it.
    public var installer: HotkeyBackend?

    /// The mechanism the live source is using, or the one `start()` would choose. This is the value
    /// that decides whether Input Monitoring is needed at all.
    public var backendKind: HotkeyBackendKind {
        activeBackendKind ?? selectedBackend.kind
    }
    private var activeBackendKind: HotkeyBackendKind?

    /// What the *selection rule* says this binding needs, ignoring any backend a test has pinned.
    /// `setBinding` compares this rather than `backendKind` so a modifier → chord change re-installs
    /// even when the source is a stub, which is the case the lifecycle tests exercise.
    private var ruledBackendKind: HotkeyBackendKind {
        HotkeyBackendSelector.kind(for: binding, forceEventTap: forcesEventTap)
    }

    /// The permission the current binding costs. nil for everything the shipped picker offers.
    public var requiredPermission: Permission? { backendKind.requiredPermission }

    /// `HotkeyArming`: the user has switched this key off, so the watcher must not arm it.
    public var isDisabledByUser: Bool { !isWanted() }

    /// Whether the legacy event tap has been forced on for this service.
    public var forcesEventTap: Bool { defaults.bool(forKey: Self.forceEventTapDefaultsKey) }

    /// What this install's dictation key costs in permissions, without constructing a service.
    ///
    /// One source of truth for the two places that have to know before a `HotkeyService` exists:
    /// onboarding (which permissions to walk) and the Settings copy. nil for every binding the
    /// shipped picker can produce.
    public static func currentRequiredPermission(defaults: UserDefaults = .standard,
                                                 bindingKey: String = HotkeyService.bindingDefaultsKey) -> Permission? {
        let binding = storedBinding(defaults: defaults, key: bindingKey) ?? defaultBinding
        return HotkeyBackendSelector.requiredPermission(for: binding,
                                                        forceEventTap: defaults.bool(forKey: forceEventTapDefaultsKey))
    }

    private var selectedBackend: HotkeyBackend {
        installer ?? .system(for: binding, forceEventTap: forcesEventTap)
    }

    // MARK: Naming the key (V4.51)

    /// The bound key as every hint names it ("fn / 🌐").
    public var label: String { binding.label }

    /// "Hold or Double Tap fn / 🌐 to dictate" — "Hold fn / 🌐 to dictate" with Latch off.
    public func readyHint(latchEnabled: Bool = true) -> String { binding.readyHint(latchEnabled: latchEnabled) }

    // MARK: fn / 🌐 system-action conflict (V4.51)

    /// Where `AppleFnUsageType` is read from. Swappable so tests use a throwaway defaults suite.
    public var fnUsage: FnUsageReader = .system

    /// What macOS does on its own when 🌐 is pressed, read fresh on every call (the user may have
    /// just changed it in System Settings).
    public var fnSystemAction: FnKeySystemAction { FnKeySystemAction(usageType: fnUsage.read()) }

    /// True when the dictation key is fn and macOS also acts on it (`AppleFnUsageType != 0`, or
    /// no value stored). S7g / S8 render `fnConflict` with an "Open Keyboard settings" button.
    public var fnSystemActionConflict: Bool { fnConflict != nil }

    /// The prompt to show, or nil when there is nothing to warn about.
    public var fnConflict: FnKeyConflict? { Self.fnConflict(for: binding, reader: fnUsage) }

    /// The same answer before a service exists (onboarding asks before arming anything).
    public static func fnConflict(for binding: HotkeyBinding, reader: FnUsageReader = .system) -> FnKeyConflict? {
        guard binding.kind == .fn else { return nil }
        return FnKeyConflict(FnKeySystemAction(usageType: reader.read()))
    }

    /// fn `flagsChanged` edges this service has received, whatever the binding. Onboarding's key
    /// test (`FnKeyProbe`) reads "never saw one" as "this keyboard does not report fn".
    public private(set) var fnEventsSeen = 0
    /// Called on the main thread for every fn edge the source delivers.
    public var onFnEvent: (() -> Void)?

    private var installedSource: InstalledHotkeySource?
    /// The token the live source carries, or nil while disarmed. Internal so the tests can prove
    /// that a torn-down source's token no longer resolves.
    private(set) var tapToken: Int?

    private let defaults: UserDefaults
    private let bindingKey: String
    private var defaultsObserver: NSObjectProtocol?

    /// How many events the *source* has delivered since it was last armed. `CGEvent.tapCreate`
    /// returns a valid-looking port with no Input Monitoring at all, so "armed" is not "working" and
    /// this counter is the only thing that can tell them apart for the tap backend.
    public private(set) var eventsReceived = 0
    /// When the current source was installed; nil while disarmed.
    public private(set) var armedAt: Date?
    /// How many times a source has been installed in this process — asserted by the tests that a
    /// grant observed by the poll arms exactly once and never stacks a second source.
    public private(set) var armCount = 0
    /// Injectable for tests.
    public var clock: () -> Date = Date.init
    /// Seconds since the *system* last saw a `flagsChanged` event, from the HID event source. Needs
    /// no permission of any kind, which is what makes it usable as the control in the liveness test:
    /// silence from our source only means something if the system itself saw modifier activity.
    public var systemModifierIdle: () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged)
    }

    // MARK: K02 — lost key-up (design §5, §13 scenario 9)

    /// How often the real modifier state is read while a bare-modifier key is down.
    public static let releasePollInterval: TimeInterval = 0.25
    /// Consecutive polls that must see the key up before its key-up counts as lost. The first poll
    /// can race a real key-up still queued on the main thread; one interval later it cannot.
    public static let releasePollStrikes = 2
    /// The dictation key's release never arrived and was synthesized from the modifier state (after
    /// the machine's own `.finalize` / `.cancelCapture` went to `onAction`): the turn posts K02.
    public var onLostKeyUp: (() -> Void)?
    /// The session's current modifier flag word (`CGEventFlags` bits). Needs no permission.
    public var modifierFlags: () -> UInt64 = { CGEventSource.flagsState(.combinedSessionState).rawValue }
    /// Seconds since boot, the clock `NSEvent` / `CGEvent` timestamps use, for the synthesized key-up.
    public var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Polls in a row that saw the key up while the machine still thought it was down.
    /// X1 — did a key, a mouse button or a scroll happen in the last `seconds`? Read when a held
    /// dictation key comes up and on the 250 ms poll, so Option + anything cancels silently even
    /// without the event tap. Tests replace it.
    /// nil: the system's own counters, but only for a running service on a system backend — a
    /// service a test drives by hand never reads the real keyboard.
    public var otherInputWithin: ((TimeInterval) -> Bool)?
    /// H5 — Secure Event Input at key-down (app name only). Live: `IsSecureEventInputEnabled()` and
    /// the frontmost app's name; tests inject their own.
    public var secureInputProbe: () -> HotkeySecureInput = HotkeyService.liveSecureInput
    /// H5 — every finished press, after its notice line is logged. Tests read it; nothing else.
    public var onPressLogged: ((HotkeyPressRecord) -> Void)?
    public private(set) var lastPressRecord: HotkeyPressRecord?
    private var pressLog = HotkeyPressLog()

    /// H5 — the live probe. Main thread (it asks `NSWorkspace` for the app name only when on).
    public static func liveSecureInput() -> HotkeySecureInput {
        guard IsSecureEventInputEnabled() else { return .off }
        return HotkeySecureInput(on: true, app: NSWorkspace.shared.frontmostApplication?.localizedName)
    }
    /// X2 — while the Option event tap feeds this service, flag words from the passive monitors
    /// are ignored (the tap drops a second press the monitors never see).
    public var tapFeeds = false

    /// X2 — the live Option tap, while armed.
    public private(set) var optionTap: OptionKeyEventTap?
    /// X2 — the Option tap could not be armed (no Accessibility, or macOS refused it): the passive
    /// monitors serve the key and Claude may still see a double tap.
    public private(set) var optionTapUnavailable = false
    /// X2 — told once per arm failure; the wiring shows `OptionTapFallbackNotice` (once ever).
    public var onOptionTapUnavailable: (() -> Void)?

    /// X2 — arms the active Option tap for the dictation key on a system backend.
    private func armOptionTap() {
        disarmOptionTap()
        guard isRunning, installer == nil, bindingKey == Self.bindingDefaultsKey, binding.kind.isOption else { return }
        record(OptionKeyEventTap.install(for: self))
    }

    /// X2 — applies an install outcome. Internal so tests can drive the untrusted/refused paths.
    func record(_ outcome: OptionKeyEventTap.InstallOutcome) {
        switch outcome {
        case .armed(let tap):
            optionTap = tap
            tapFeeds = true
            optionTapUnavailable = false
            awaitingAccessibilityForOptionTap = false
            stopWatchingAccessibility()
        case .untrusted:
            // First launch: Accessibility is granted during onboarding, after the key is armed.
            // Not a failure yet — arm when the grant lands; the one-time notice is not spent.
            optionTapUnavailable = true
            awaitingAccessibilityForOptionTap = true
            Log.app.notice("hotkey: Option event tap waits for Accessibility — passive monitors meanwhile")
            watchAccessibility()
        case .refused:
            optionTapUnavailable = true
            awaitingAccessibilityForOptionTap = false
            stopWatchingAccessibility()
            Log.app.notice("hotkey: Option event tap unavailable — passive monitors only (Claude may see a double tap)")
            onOptionTapUnavailable?()
        }
    }

    /// X2 — Accessibility was not granted when the key was armed; the tap arms once it is.
    public private(set) var awaitingAccessibilityForOptionTap = false
    private var accessibilityObserver: NSObjectProtocol?
    private var accessibilityRetries: [DispatchWorkItem] = []

    /// X2 — re-try the Option tap after an Accessibility change (no-op unless it is waiting).
    public func retryOptionTapIfWaiting() {
        guard awaitingAccessibilityForOptionTap, optionTap == nil else { return }
        armOptionTap()
    }

    private func watchAccessibility() {
        guard accessibilityObserver == nil else { return }
        // HIServices posts this when the trust list changes; its cached answer lags a little, so
        // re-try shortly after as well as at once.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleAccessibilityRetries()
        }
    }

    private func scheduleAccessibilityRetries() {
        accessibilityRetries.forEach { $0.cancel() }
        accessibilityRetries = [0.0, 0.5, 2.0].map { delay in
            let item = DispatchWorkItem { [weak self] in self?.retryOptionTapIfWaiting() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    private func stopWatchingAccessibility() {
        accessibilityRetries.forEach { $0.cancel() }
        accessibilityRetries = []
        if let accessibilityObserver { DistributedNotificationCenter.default().removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
    }

    private func disarmOptionTap() {
        optionTap?.invalidate()
        optionTap = nil
        tapFeeds = false
        awaitingAccessibilityForOptionTap = false
        stopWatchingAccessibility()
    }

    public static func systemOtherInputWithin(_ seconds: TimeInterval) -> Bool {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds }
    }

    private var releaseUpStrikes = 0
    private var releasePoll: Timer?

    /// The poll is due: a live source serves a bare modifier that the machine holds down.
    var wantsReleasePoll: Bool {
        isRunning && binding.style == .bareModifier && machineHoldsKey
    }

    /// The machine believes the key is down (a press, a latched stop press, a chorded press).
    var machineHoldsKey: Bool {
        switch machine.phase {
        case .keyDown, .latchedKeyDown, .chorded, .folded: return true
        case .idle, .latched: return false
        }
    }

    public init(defaults: UserDefaults = .standard, timing: HotkeyStateMachine.Timing = .default,
                bindingKey: String = HotkeyService.bindingDefaultsKey,
                defaultBinding: HotkeyBinding = HotkeyService.defaultBinding) {
        self.defaults = defaults
        self.bindingKey = bindingKey
        self.machine = HotkeyStateMachine(timing: timing)
        // Before the first read and long before `observeDefaults`: a later user write is never
        // mistaken for a legacy fn (see `migrateLegacyBindingIfNeeded`).
        if bindingKey == Self.bindingDefaultsKey { Self.migrateLegacyBindingIfNeeded(defaults: defaults) }
        binding = Self.storedBinding(defaults: defaults, key: bindingKey) ?? defaultBinding
        surfaceShowing = bindingKey == HotkeyService.bindingDefaultsKey ? { PillSurfaceVisibility.isShowing } : { false }
    }

    /// Reads the persisted binding. A pure read: it never writes, so calling it from the
    /// `didChangeNotification` reload cannot rewrite what the user just picked (the X1 migration
    /// lives in `migrateLegacyBindingIfNeeded`).
    ///
    /// Every 1.6.7 install has one of the five bare-modifier raw values here, and all five survive
    /// verbatim — a user who picked Right ⌥ keeps Right ⌥, and it now costs no permission. A value
    /// this build cannot parse (a future binding, a corrupted write) falls back to the default
    /// rather than leaving the service with no binding at all.
    static func storedBinding(defaults: UserDefaults, key: String) -> HotkeyBinding? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        guard let kind = HotkeyBinding.Kind(rawValue: raw) else {
            Log.app.warning("hotkey: stored binding \"\(raw)\" is not one this build knows — using the default")
            return nil
        }
        return HotkeyBinding(kind: kind)
    }

    /// The source outlives the object unless something tears it down, and a run loop holding a port
    /// whose owner is gone is exactly the shape of a use-after-free. There was no `deinit` here
    /// until 1.6.7.
    deinit {
        releasePoll?.invalidate()
        teardownSource()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    public func setBinding(_ kind: HotkeyBinding.Kind) {
        let previousBackend = ruledBackendKind
        binding = HotkeyBinding(kind: kind)
        defaults.set(kind.rawValue, forKey: bindingKey)
        machine.reset()
        updateReleasePoll()
        // A chord and a bare modifier are served by different mechanisms, so a change between them
        // has to re-install, not just re-interpret. Same-mechanism changes need nothing.
        if isRunning, ruledBackendKind != previousBackend { rearm() } else if isRunning { armOptionTap() }
    }

    /// Re-read the binding from `UserDefaults` and apply it if it changed.
    ///
    /// The Settings picker and the menu-bar submenu write to the same key from different objects;
    /// before this, only the menu path reached the running service and a Settings change did nothing
    /// until the next launch.
    @discardableResult
    public func reloadBindingFromDefaults() -> Bool {
        guard let stored = Self.storedBinding(defaults: defaults, key: bindingKey), stored != binding else { return false }
        Log.app.notice("hotkey: binding changed externally to \(stored.kind.displayName)")
        setBinding(stored.kind)
        return true
    }

    /// Start watching `UserDefaults` so a Settings-side binding change takes effect immediately.
    /// Called by the app; harmless (and unobserved) in tests that never call it.
    public func observeDefaults() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in self?.reloadBindingFromDefaults() }
    }

    /// Feed a raw modifier event. Public so tests can synthesize `CGEvent`s without a source.
    /// Main thread only when it is reached from a backend — see `deliver(token:…)`.
    public func handle(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        guard !isPaused, let edge = binding.edge(keyCode: keyCode, flags: flags) else { return }
        apply(edge: edge, at: timestamp)
    }

    public func handle(event: CGEvent) {
        handle(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
               flags: event.flags.rawValue,
               timestamp: TimeInterval(event.timestamp) / 1_000_000_000)
    }

    /// Feed a chord press/release. The Carbon backend's only entry point: a chord has no flags word
    /// to classify, so `binding.edge(keyCode:flags:)` cannot serve it and deliberately returns nil.
    /// Public so tests can drive the state machine with synthetic Carbon edges.
    public func handleChord(down: Bool, timestamp: TimeInterval) {
        guard !isPaused, binding.style == .chord else { return }
        apply(edge: down ? .down : .up, at: timestamp)
    }

    private func apply(edge: HotkeyBinding.Edge, at timestamp: TimeInterval) {
        if edge == .up, binding.style == .bareModifier { pollOtherInput() }
        let actions: [HotkeyStateMachine.Action]
        switch edge {
        case .down:
            if !pressLog.isOpen { pressLog.keyDown(at: timestamp, secureInput: secureInputProbe()) }
            actions = machine.keyDown(at: timestamp, surfaceShowing: surfaceShowing())
        case .up:
            actions = machine.keyUp(at: timestamp)
            logPress(pressLog.end(at: timestamp, gesture: machine.lastGesture, actions: actions))
        }
        updateReleasePoll()
        emit(actions)
    }

    /// H5 — one notice line per press: sequence, duration, gesture, result, Secure Input. No text.
    private func logPress(_ record: HotkeyPressRecord?) {
        guard let record else { return }
        lastPressRecord = record
        Log.app.notice("\(record.line)")
        onPressLogged?(record)
    }

    private func emit(_ actions: [HotkeyStateMachine.Action]) {
        for action in actions {
            if action == .cancelCapture, machine.lastCancel == .chord, bindingKey == Self.bindingDefaultsKey {
                HotkeyGestureContext.markChordCancel()
            }
            onAction?(action)
        }
    }

    /// X1 — another key, a click or a scroll while the key is held: cancel silently, pass the
    /// combo through (nothing here consumes it). Fed by the Option event tap; public for tests.
    public func noteOtherInput(at timestamp: TimeInterval) {
        guard !isPaused else { return }
        let actions = machine.otherInput(at: timestamp)
        if !actions.isEmpty { Log.app.info("hotkey: \(binding.kind.displayName) + another input — cancelled silently") }
        updateReleasePoll()
        emit(actions)
    }

    /// X1 — the passive check: anything typed, clicked or scrolled since the key went down?
    @discardableResult
    public func pollOtherInput() -> Bool {
        let since: TimeInterval
        switch machine.phase {
        case .keyDown(let t), .latchedKeyDown(let t): since = t
        default: return false
        }
        let window = max(0, uptime() - since)
        let check = otherInputWithin ?? ((isRunning && installer == nil) ? Self.systemOtherInputWithin : nil)
        guard window > 0, let check, check(window) else { return false }
        noteOtherInput(at: uptime())
        return true
    }

    /// Called by the coordinator when the engine failed so a stuck key-down doesn't leave us "capturing".
    public func resetGesture() {
        logPress(pressLog.end(at: uptime(), gesture: machine.lastGesture, actions: [], result: "reset"))
        machine.reset()
        updateReleasePoll()
    }

    /// K02 — reads the real modifier state while the machine holds a bare-modifier key down. When
    /// `releasePollStrikes` reads in a row find the key up, its key-up was lost (a secure-input switch,
    /// an event-tap timeout): the machine ends the press as that key-up would (`lostKeyUp`, a hold
    /// finalizes and keeps its words, never Latch), then `onLostKeyUp` tells the turn. A later key-down
    /// starts a new turn instead of being dropped as key repeat. Returns true when it synthesized one.
    /// Driven by a 250 ms timer while the key is down, and on every tap-disabled event.
    @discardableResult
    public func checkForLostKeyUp() -> Bool {
        guard binding.style == .bareModifier, machineHoldsKey else {
            releaseUpStrikes = 0
            return false
        }
        guard modifierFlags() & binding.kind.flagMask == 0 else {
            releaseUpStrikes = 0
            return false
        }
        releaseUpStrikes += 1
        guard releaseUpStrikes >= Self.releasePollStrikes else { return false }
        releaseUpStrikes = 0
        let now = uptime()
        let actions = machine.lostKeyUp(at: now)
        logPress(pressLog.end(at: now, gesture: machine.lastGesture, actions: actions))
        updateReleasePoll()
        Log.app.notice("hotkey: \(binding.kind.displayName) is up but its key-up never arrived — ending the press (K02)")
        emit(actions)
        onLostKeyUp?()
        return true
    }

    /// Keeps the 250 ms poll running exactly while `wantsReleasePoll`. The timer reads the system's
    /// modifier state, so it runs only with a system backend (`installer == nil`); tests call
    /// `checkForLostKeyUp()` with their own `modifierFlags`.
    private func updateReleasePoll() {
        guard wantsReleasePoll else {
            releasePoll?.invalidate()
            releasePoll = nil
            releaseUpStrikes = 0
            return
        }
        guard releasePoll == nil, installer == nil, Thread.isMainThread else { return }
        let timer = Timer(timeInterval: Self.releasePollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.pollOtherInput() { self.checkForLostKeyUp() }
        }
        RunLoop.main.add(timer, forMode: .common)
        releasePoll = timer
    }

    // MARK: Source lifecycle

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        // A disarmed service is not observing `UserDefaults` (that starts below), so a binding
        // written while it was switched off has not reached it. Re-read before choosing a backend:
        // arming with the stale binding is how "I set the Actions key to ⌃⌥A, turned Actions on,
        // and it still listens on Right ⌘" would happen.
        reloadBindingFromDefaults()
        // A half-torn state — a source installed while `isRunning` is false — must never survive into
        // a second creation. One service, one live source, always.
        teardownSource()
        let backend = selectedBackend
        guard backend.preflight() else {
            Log.app.warning("hotkey: \(backend.kind.rawValue) backend is not authorized (\(backend.kind.requiredPermission?.title ?? "no permission needed")); falling back to menu item")
            return false
        }
        let token = HotkeyTapRegistry.register(self)
        guard let source = backend.install(token) else {
            HotkeyTapRegistry.retire(token)
            Log.app.error("hotkey: \(backend.kind.rawValue) backend would not install")
            return false
        }
        installedSource = source
        tapToken = token
        activeBackendKind = backend.kind
        // Armed services watch their own binding key, so a change made in Settings (a different
        // object, writing the same `UserDefaults`) reaches the live service instead of waiting for
        // the next launch. Idempotent; removed in `deinit`.
        observeDefaults()
        isRunning = true
        eventsReceived = 0
        armedAt = clock()
        armCount += 1
        armOptionTap()
        // `.notice` (not `.info`): info-level lines are memory-only and had already aged out by the
        // time the 1.6.5 report was diagnosed, so the whole question "was the source ever armed?" had
        // to be answered from tccd's log instead of ours. Arming is rare; persist it.
        Log.app.notice("hotkey: armed (#\(armCount)) via \(backend.kind.rawValue) for \(binding.kind.displayName) — needs \(backend.kind.requiredPermission?.title ?? "no permission")")
        return true
    }

    /// Tear the source down. Invalidating it and retiring the token (rather than only dropping the
    /// references) is what guarantees a later `start()` cannot leave a second live source behind and
    /// that an event already queued on the run loop reaches nothing.
    public func stop() {
        teardownSource()
        isRunning = false
        armedAt = nil
        eventsReceived = 0
        machine.reset()
        updateReleasePoll()
    }

    /// Idempotent, and safe from `deinit`.
    private func teardownSource() {
        disarmOptionTap()
        installedSource?.setEnabled(false)
        installedSource?.invalidate()
        installedSource = nil
        if let tapToken { HotkeyTapRegistry.retire(tapToken) }
        tapToken = nil
        activeBackendKind = nil
    }

    /// Drop the current source and create a fresh one. Used when the liveness probe says the source
    /// is armed but deaf, and when a binding change moves to a different backend.
    @discardableResult
    public func rearm() -> Bool {
        stop()
        return start()
    }

    /// Is the armed source actually receiving events? See `TapLiveness`.
    ///
    /// Only meaningful for the two backends that observe `flagsChanged`. The Carbon backend fires
    /// only on its own chord, so "no events while the system saw modifier keys" says nothing about
    /// it and must never be read as deafness.
    public var livenessVerdict: TapLiveness.Verdict {
        guard isRunning, let armedAt, backendKind != .carbon else { return .unknown }
        return TapLiveness.verdict(armedFor: clock().timeIntervalSince(armedAt),
                                   eventsSinceArmed: eventsReceived,
                                   systemModifierIdle: systemModifierIdle())
    }

    // MARK: The callback path

    /// The one place a backend callback becomes state. Called on the backend's callback thread.
    ///
    /// A callback for a source that has been torn down resolves to nil and does nothing — a
    /// dictionary miss, never a touch of freed memory, because a token is not a pointer. The hop
    /// re-resolves rather than capturing the service, so a source torn down *between* the callback
    /// and the next main-queue turn delivers nothing either.
    static func deliver(token: Int, keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        guard let service = HotkeyTapRegistry.service(for: token) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                HotkeyTapRegistry.service(for: token)?.receiveModifier(keyCode: keyCode, flags: flags,
                                                                      timestamp: timestamp)
            }
            return
        }
        service.receiveModifier(keyCode: keyCode, flags: flags, timestamp: timestamp)
    }

    /// The Carbon equivalent of `deliver`. `kEventHotKeyPressed` / `kEventHotKeyReleased` carry no
    /// key code or flag word — the chord identity *is* the registration — so this path is separate.
    static func deliverChord(token: Int, down: Bool, timestamp: TimeInterval) {
        guard let service = HotkeyTapRegistry.service(for: token) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                HotkeyTapRegistry.service(for: token)?.receiveChord(down: down, timestamp: timestamp)
            }
            return
        }
        service.receiveChord(down: down, timestamp: timestamp)
    }

    /// macOS disables a tap that took too long or that the user's input disturbed. Re-enabling it is
    /// the documented recovery, and it happens on the main thread like everything else.
    static func reenable(token: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { HotkeyService.reenable(token: token) }
            return
        }
        guard let service = HotkeyTapRegistry.service(for: token), let source = service.installedSource else { return }
        Log.app.notice("hotkey: tap was disabled by the system — re-enabling")
        source.setEnabled(true)
        // K02 — the key-up may have been one of the events the disabled tap dropped.
        service.checkForLostKeyUp()
    }

    /// The chord a token's service is bound to, for the Carbon installer. nil when the binding is a
    /// bare modifier — which is what stops a bare modifier from ever being handed to
    /// `RegisterEventHotKey`, the call that accepts it and then never fires.
    static func chord(for token: Int) -> HotkeyBinding.Chord? {
        HotkeyTapRegistry.service(for: token)?.binding.kind.chord
    }

    /// Counts the event for the liveness probe, then runs the gesture recogniser. Main thread only.
    private func receiveModifier(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        if tapFeeds { return }
        receiveTapped(keyCode: keyCode, flags: flags, timestamp: timestamp)
    }

    /// X2 — a flag word from the Option event tap (it also sees the presses it drops).
    public func receiveTapped(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        eventsReceived += 1
        noteFnEvent(keyCode: keyCode)
        handle(keyCode: keyCode, flags: flags, timestamp: timestamp)
    }

    /// Counts fn edges for the key test. Internal so tests can feed it without a source.
    func noteFnEvent(keyCode: Int64) {
        guard keyCode == HotkeyBinding.Kind.fn.keyCode else { return }
        fnEventsSeen += 1
        onFnEvent?()
    }

    private func receiveChord(down: Bool, timestamp: TimeInterval) {
        eventsReceived += 1
        handleChord(down: down, timestamp: timestamp)
    }

    // MARK: Backend 1 — NSEvent monitors (the default; no permission)

    /// Global + local `flagsChanged` monitors.
    ///
    /// Measured from a zero-grant throwaway bundle on macOS 26.6.2: the global monitor installs and
    /// delivers real modifier transitions from a background `LSUIElement` process while another app
    /// is frontmost, with `AXIsProcessTrusted()` and `CGPreflightListenEventAccess()` both false and
    /// no TCC record for the bundle id at all. In the same process, at the same instant, a
    /// `.listenOnly` tap reported `tapIsEnabled == false` and received nothing.
    ///
    /// The **local** monitor is not optional. A global monitor by definition excludes our own
    /// process, so without it the dictation key would go dead whenever a VoicePlus window (Settings,
    /// onboarding) was frontmost — something the old event tap, which sees every app including ours,
    /// did not do. It needs no permission either.
    static func installGlobalMonitor(token: Int) -> InstalledHotkeySource? {
        let deliver: (NSEvent) -> Void = { event in
            HotkeyService.deliver(token: token,
                                  keyCode: Int64(event.keyCode),
                                  flags: UInt64(event.modifierFlags.rawValue),
                                  timestamp: event.timestamp)
        }
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: deliver) else {
            return nil
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            deliver(event)
            return event    // never swallow: the modifier still belongs to whatever has focus
        }
        var removed = false
        return InstalledHotkeySource(
            setEnabled: { _ in },   // NSEvent monitors have no enable/disable; `isPaused` gates delivery
            invalidate: {
                guard !removed else { return }
                removed = true
                NSEvent.removeMonitor(global)
                if let local { NSEvent.removeMonitor(local) }
            }
        )
    }

    // MARK: Backend 2 — Carbon RegisterEventHotKey (chords; no permission)

    /// Registers the service's chord with the Window Server through Carbon.
    ///
    /// Measured at zero grants: `InstallEventHandler` and `RegisterEventHotKey` both return
    /// `status = 0`, and re-registering the same chord returns `-9878` (`eventHotKeyExistsErr`) —
    /// which is what proves the first registration was genuinely system-wide rather than a local
    /// no-op. Both `kEventHotKeyPressed` and `kEventHotKeyReleased` are requested, which is what
    /// makes hold-to-talk possible on a chord.
    ///
    /// It refuses a bare modifier by construction. `RegisterEventHotKey(kVK_RightOption, 0)` returns
    /// `status = 0` with a valid ref and then never fires — measured, 0 callbacks across real
    /// modifier transitions. A backend that trusted the return code would look installed and be
    /// silently dead.
    static func installCarbonHotKey(token: Int) -> InstalledHotkeySource? {
        guard let chord = HotkeyService.chord(for: token) else {
            Log.app.error("hotkey: refusing to register a bare modifier with Carbon — it returns noErr and never fires")
            return nil
        }
        guard let handlerRef = installCarbonChordHandler(token: token) else { return nil }
        var hotKeyRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: carbonSignature, id: UInt32(token))
        let status = RegisterEventHotKey(chord.keyCode, chord.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            // -9878 is `eventHotKeyExistsErr`: someone else owns this chord system-wide.
            Log.app.error("hotkey: RegisterEventHotKey failed (\(status)) — the chord may already be taken")
            RemoveEventHandler(handlerRef)
            return nil
        }
        var removed = false
        return InstalledHotkeySource(
            setEnabled: { _ in },
            invalidate: {
                guard !removed else { return }
                removed = true
                UnregisterEventHotKey(hotKeyRef)
                RemoveEventHandler(handlerRef)
            }
        )
    }

    /// 'VOIC' — the signature on every chord this service registers.
    static let carbonSignature = OSType(0x564F_4943)

    /// The chord's press/release handler on the application target.
    ///
    /// Every Carbon hot key in the process — the dictation chord, the act key's chord, Escape during
    /// a turn (`EscapeHotkey`) — is dispatched to every handler installed on the application target,
    /// newest first, and a handler that returns `noErr` ends the dispatch. Until 1.11 this handler
    /// answered `noErr` for *any* hot key, so whichever handler was newest swallowed the others'
    /// presses (and an Escape release would have read as a chord key-up). It now answers only for
    /// its own registration and passes everything else on with `eventNotHandledErr`.
    ///
    /// Non-capturing, like the tap callback: the token in `userData` is the whole context. Split
    /// from the registration so the dispatch can be tested without registering a system hot key.
    static func installCarbonChordHandler(token: Int) -> EventHandlerRef? {
        var handlerRef: EventHandlerRef?
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            let token = Int(bitPattern: userData)
            guard let event,
                  CarbonHotKeyEvent.matches(CarbonHotKeyEvent.id(of: event),
                                            signature: HotkeyService.carbonSignature, token: token) else {
                return OSStatus(eventNotHandledErr)
            }
            HotkeyService.deliverChord(token: token,
                                       down: GetEventKind(event) == UInt32(kEventHotKeyPressed),
                                       timestamp: ProcessInfo.processInfo.systemUptime)
            return noErr
        }, 2, &specs, UnsafeMutableRawPointer(bitPattern: token), &handlerRef)
        guard handlerStatus == noErr, let handlerRef else {
            Log.app.error("hotkey: InstallEventHandler failed (\(handlerStatus))")
            return nil
        }
        return handlerRef
    }

    // MARK: Backend 3 — the legacy CGEvent tap (escape hatch; costs Input Monitoring)

    /// The pre-1.6.8 installer. The callback below is intentionally non-capturing: a capturing
    /// closure cannot be converted to `CGEventTapCallBack`, and there is nothing to capture — the
    /// token is the whole context.
    ///
    /// It now refuses an unauthorized tap outright. `CGEvent.tapIsEnabled(tap:)` returns false
    /// immediately after `tapEnable` for a tap the process is not entitled to create (measured, both
    /// with and without the grant) — a deterministic, permission-free authorization check that
    /// replaces "arm, wait 20 s, count events" for the arm-time half of the question.
    static func installSystemTap(token: Int) -> InstalledHotkeySource? {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let token = Int(bitPattern: userInfo)
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    HotkeyService.reenable(token: token)
                } else {
                    HotkeyService.deliver(token: token,
                                          keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                          flags: event.flags.rawValue,
                                          timestamp: EventClock.seconds(eventTimestamp: event.timestamp, uptime: ProcessInfo.processInfo.systemUptime))
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: UnsafeMutableRawPointer(bitPattern: token)
        ) else { return nil }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let teardown = {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
            CFMachPortInvalidate(tap)
        }
        guard CGEvent.tapIsEnabled(tap: tap) else {
            Log.app.error("hotkey: the event tap was created but macOS left it disabled — Input Monitoring is not in force for this build")
            teardown()
            return nil
        }
        var invalidated = false
        return InstalledHotkeySource(
            setEnabled: { CGEvent.tapEnable(tap: tap, enable: $0) },
            invalidate: {
                guard !invalidated else { return }
                invalidated = true
                teardown()
            }
        )
    }
}
