import Foundation

// S7f — the Privacy page's first two groups as data (design §8.5): the permission rows
// (microphone, typing access, optional context = Screen Recording, G2), hard mute, and the
// on-device-versus-service disclosure. Pure functions of the checker and the settings, so every row
// the page can show is a test on this toolchain; the view only draws what these return.

/// One access row: what the permission is for, its state as a word *and* a tag (never colour
/// alone), and at most one action.
public struct PrivacyAccessRow: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Ask macOS (a promptable permission that was never asked).
        case request
        /// Send the user to System Settings › Privacy & Security.
        case openSettings
        /// An optional permission: state the scope first, then ask (design §8.5 "Explain the scope
        /// before enabling").
        case explainThenRequest
    }

    public enum Tag: String, Equatable, Sendable { case good, warn, neutral }

    public var id: String
    public var title: String
    public var detail: String
    public var status: String
    public var tag: Tag
    public var action: Action
    public var actionTitle: String?

    public init(id: String, title: String, detail: String, status: String, tag: Tag,
                action: Action = .none, actionTitle: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.tag = tag
        self.action = action
        self.actionTitle = actionTitle
    }
}

public enum PrivacyAccess {
    /// Microphone, typing access, then the optional Screen Recording row. `permissions` nil (a test
    /// or headless window) reads as "not asked", never as granted.
    public static func rows(permissions: OnboardingPermissionChecking?,
                            screenRecordingGranted: Bool,
                            screenRecordingRequested: Bool) -> [PrivacyAccessRow] {
        [microphone(permissions?.status(of: .microphone) ?? .notDetermined),
         typing(permissions?.status(of: .accessibility) ?? .notDetermined),
         context(granted: screenRecordingGranted, requested: screenRecordingRequested)]
    }

    public static func microphone(_ status: OnboardingPermissionStatus) -> PrivacyAccessRow {
        let id = "privacy.access.microphone"
        switch status {
        case .granted:
            return PrivacyAccessRow(id: id, title: PrivacyCopy.microphoneTitle, detail: PrivacyCopy.microphoneGranted,
                                    status: PrivacyCopy.allowed, tag: .good)
        case .notDetermined:
            // Promptable: asking is the only way VoicePlus ever appears in that pane (P6).
            return PrivacyAccessRow(id: id, title: PrivacyCopy.microphoneTitle, detail: PrivacyCopy.microphoneNotAsked,
                                    status: PrivacyCopy.notAsked, tag: .neutral,
                                    action: .request, actionTitle: PrivacyCopy.allow)
        case .denied:
            return PrivacyAccessRow(id: id, title: PrivacyCopy.microphoneTitle, detail: PrivacyCopy.microphoneDenied,
                                    status: PrivacyCopy.off, tag: .warn,
                                    action: .openSettings, actionTitle: PrivacyCopy.openSystemSettings)
        case .awaitingUserAction:
            return PrivacyAccessRow(id: id, title: PrivacyCopy.microphoneTitle, detail: PrivacyCopy.microphoneWaiting,
                                    status: PrivacyCopy.waiting, tag: .warn,
                                    action: .openSettings, actionTitle: PrivacyCopy.openSystemSettings)
        }
    }

    /// Accessibility is not promptable: every state but granted goes to System Settings.
    public static func typing(_ status: OnboardingPermissionStatus) -> PrivacyAccessRow {
        let id = "privacy.access.typing"
        if status == .granted {
            return PrivacyAccessRow(id: id, title: PrivacyCopy.typingTitle, detail: PrivacyCopy.typingGranted,
                                    status: PrivacyCopy.allowed, tag: .good)
        }
        return PrivacyAccessRow(id: id, title: PrivacyCopy.typingTitle, detail: PrivacyCopy.typingOff,
                                status: status == .awaitingUserAction ? PrivacyCopy.waiting : PrivacyCopy.off, tag: .warn,
                                action: .openSettings, actionTitle: PrivacyCopy.openSystemSettings)
    }

    /// G2 — Screen Recording is optional: it never shows as a problem (no warn tag), and it is asked
    /// at most once (`DeixisSettings.screenRecordingRequested`, shared with the deixis box).
    public static func context(granted: Bool, requested: Bool) -> PrivacyAccessRow {
        let id = "privacy.access.context"
        let title = PrivacyCopy.contextTitle
        if granted {
            return PrivacyAccessRow(id: id, title: title, detail: PrivacyCopy.contextGranted,
                                    status: PrivacyCopy.allowed, tag: .good,
                                    action: .openSettings, actionTitle: PrivacyCopy.openSystemSettings)
        }
        if requested {
            return PrivacyAccessRow(id: id, title: title, detail: PrivacyCopy.contextDenied,
                                    status: PrivacyCopy.notAllowed, tag: .neutral,
                                    action: .openSettings, actionTitle: PrivacyCopy.openSystemSettings)
        }
        return PrivacyAccessRow(id: id, title: title, detail: OptionalPermission.screenRecording.rationale,
                                status: PrivacyCopy.optionalOff, tag: .neutral,
                                action: .explainThenRequest, actionTitle: PrivacyCopy.enable)
    }

    /// The design's "Dictation processing" row: speech is recognised on this Mac, always
    /// (`RoutableStage` `.asr` accepts no provider).
    public static let processing = PrivacyAccessRow(id: "privacy.access.processing", title: PrivacyCopy.processingTitle,
                                                    detail: PrivacyCopy.processingDetail,
                                                    status: PrivacyCopy.onThisMac, tag: .good)
}

// MARK: - Hard mute

/// The live hard mute (`MuteController`), as the Privacy page needs it: read, set, observe.
public protocol PrivacyMuteControlling: AnyObject {
    var isMuted: Bool { get }
    func setMuted(_ muted: Bool)
    /// Called with the current value at once, then on every change from any surface (menu bar,
    /// pill, this page).
    func observeMuted(_ handler: @escaping (Bool) -> Void)
}

extension MuteController: PrivacyMuteControlling {
    public func setMuted(_ muted: Bool) {
        if muted { mute() } else { unmute() }
    }

    public func observeMuted(_ handler: @escaping (Bool) -> Void) {
        observe { handler($0.muted) }
    }
}

/// Where the composition root hands the Privacy page the app's one `MuteController`
/// (`PrivacyWiring.mute = container.latchController.mute`). Until it is set, the page reads the
/// persisted mute (`UserDefaultsMuteStore`) and says where the control is instead of offering a
/// switch that could not close the microphone.
@MainActor
public enum PrivacyWiring {
    public static var mute: (any PrivacyMuteControlling)?
}

// MARK: - On this Mac or a service

/// One line of the disclosure: a step and where it runs. `onDevice` is the only thing a tag colours.
public struct PrivacyProcessingRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: String
    public var onDevice: Bool
}

public enum PrivacyProcessing {
    /// Speech first (always on this Mac), then every step pinned to a service, then one row for the
    /// rest. Only an explicit `provider:` pin sends anything (`RoutingTableProviderRouting`: "Auto
    /// and Local keep every stage on device"), so Auto is reported as on this Mac, truthfully.
    public static func rows(settings: SettingsStore?) -> [PrivacyProcessingRow] {
        var rows = [PrivacyProcessingRow(id: "privacy.processing.speech", title: PrivacyCopy.speechTitle,
                                         detail: PrivacyCopy.speechDetail, status: PrivacyCopy.onThisMac, onDevice: true)]
        let services = serviceStages(settings: settings)
        for (stage, provider) in services {
            rows.append(PrivacyProcessingRow(id: "privacy.processing.\(stage.id.rawValue)", title: stage.title,
                                             detail: PrivacyCopy.serviceDetail(provider: provider),
                                             status: provider, onDevice: false))
        }
        rows.append(PrivacyProcessingRow(id: "privacy.processing.local", title: PrivacyCopy.localStagesTitle,
                                         detail: services.isEmpty ? PrivacyCopy.localStagesDetail : PrivacyCopy.otherStagesDetail,
                                         status: PrivacyCopy.onThisMac, onDevice: true))
        return rows
    }

    /// The routable steps (never transcription) pinned to a provider, in Settings' order.
    public static func serviceStages(settings: SettingsStore?) -> [(stage: RoutableStage, provider: String)] {
        RoutableStage.all.compactMap { stage in
            guard stage.acceptsProviders,
                  let raw = settings?.string(SettingsKeys.routingPrefix + stage.id.rawValue),
                  case .provider(let id)? = ProviderChoice(rawValue: raw) else { return nil }
            return (stage, id)
        }
    }

    /// Sync (design §8.5 "optional sync"): off when there is no sync service, not paired without a
    /// shared key, otherwise what travels and how.
    public static func sync(available: Bool, paired: Bool) -> PrivacyProcessingRow {
        let id = "privacy.processing.sync"
        guard available else {
            return PrivacyProcessingRow(id: id, title: PrivacyCopy.syncTitle, detail: PrivacyCopy.syncUnavailableDetail,
                                        status: PrivacyCopy.syncOff, onDevice: true)
        }
        guard paired else {
            return PrivacyProcessingRow(id: id, title: PrivacyCopy.syncTitle, detail: PrivacyCopy.syncNotPairedDetail,
                                        status: PrivacyCopy.syncNotPaired, onDevice: true)
        }
        return PrivacyProcessingRow(id: id, title: PrivacyCopy.syncTitle, detail: PrivacyCopy.syncPairedDetail,
                                    status: PrivacyCopy.syncPaired, onDevice: false)
    }
}
