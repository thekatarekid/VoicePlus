import Engine
import Foundation
import Shared

// R7.1 — Today / Timeline (`DESIGN.md` §9.1): what the app is ready to do right now, what still
// needs a hand, and what was said recently — in that order, because readiness and pending recovery
// are what a person opens this window for (V3 §9.4).
//
// The readiness strip is computed from cached state and is *never* blank: §9.1 forbids a loading
// state for it. Only the Timeline list loads, and the Timeline's store does not exist yet (it is
// R8's `AmbientTimeline`), so this view model takes a reader and renders "Timeline is off" until
// one is installed — the honest empty, never a blank list with no explanation.

/// One row of the Timeline: time, source, transcript. R8 fills these in; the shape is fixed here so
/// the section's states can be built and tested before the store exists.
public struct TimelineRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Date
    public var source: String
    public var text: String

    public init(id: String = UUID().uuidString, time: Date, source: String, text: String) {
        self.id = id
        self.time = time
        self.source = source
        self.text = text
    }
}

/// What R8's ambient transcript store has to offer this section. Absent (nil) means ambient capture
/// has never run on this Mac, which is a different sentence from "nothing was said today".
public protocol AmbientTimelineReading: AnyObject, Sendable {
    func rows(matching query: String) async throws -> [TimelineRow]
    func delete(id: String) throws
    func deleteAll() throws
}

/// Today / Timeline. Pure state: no AppKit, no SwiftUI, so every rendering is assertable.
@MainActor
public final class TodaySectionViewModel: ObservableObject {
    /// One line of the readiness strip: a glyph, a word, and — where it is not ready — one action.
    /// Colour is never the only signal (`DESIGN.md` §12.9), which is why `word` is not optional.
    public struct ReadinessRow: Identifiable, Equatable, Sendable {
        public var id: String
        public var glyph: String
        public var label: String
        public var word: String
        public var detail: String
        public var actionTitle: String?
        public var isReady: Bool
    }

    @Published public private(set) var readiness: [ReadinessRow] = []
    @Published public private(set) var held: [HeldItem] = []
    /// Per-row failures on the held list: a re-insert that failed keeps its row and gains one line
    /// (`DESIGN.md` §9.1), rather than the section flipping to an error.
    @Published public private(set) var heldRowErrors: [UUID: String] = [:]
    @Published public private(set) var timelineRows: [TimelineRow] = []
    @Published public private(set) var timeline: SectionState = .loading()
    @Published public private(set) var banner: SectionBanner?
    @Published public var search = ""

    private let deps: OnboardingDependencies
    private let mute: any MuteStore
    private let audio: AudioInputSettingsViewModel
    private let reader: (any AmbientTimelineReading)?
    private let ambientCaptureOn: () -> Bool
    private let heldProvider: () -> [HeldItem]
    private let heldAction: (HeldItem, HeldAction) -> HeldActionResult

    public init(deps: OnboardingDependencies,
                audio: AudioInputSettingsViewModel? = nil,
                mute: any MuteStore = UserDefaultsMuteStore(),
                reader: (any AmbientTimelineReading)? = nil,
                ambientCaptureOn: @escaping () -> Bool,
                heldProvider: @escaping () -> [HeldItem] = { [] },
                heldAction: @escaping (HeldItem, HeldAction) -> HeldActionResult = { _, _ in .unavailable }) {
        self.deps = deps
        self.audio = audio ?? AudioInputSettingsViewModel()
        self.mute = mute
        self.reader = reader
        self.ambientCaptureOn = ambientCaptureOn
        self.heldProvider = heldProvider
        self.heldAction = heldAction
        refreshReadiness()
        refreshHeld()
    }

    // MARK: Readiness strip — cached state only, so it renders on the first frame

    public func refreshReadiness() {
        readiness = [keyRow, microphoneRow, modelRow, muteRow]
    }

    /// Resolved the way `GeneralSettingsViewModel` resolves it — the binding key the hotkey service
    /// actually reads wins over the older `SettingsKeys.hotkey` mirror.
    public var dictationKey: HotkeyChoice {
        deps.settingsStore.string(HotkeyService.bindingDefaultsKey).flatMap(HotkeyChoice.init(rawValue:))
            ?? deps.settingsStore.string(SettingsKeys.hotkey).flatMap(HotkeyChoice.init(rawValue:))
            ?? .default
    }

    public var dictationKeyName: String { dictationKey.title }

    private var keyRow: ReadinessRow {
        let note = dictationKey.permissionNote
        let needsPermission = deps.hotkeyRequiresPermission != nil
        return ReadinessRow(id: "key", glyph: "keyboard", label: "Dictation key",
                            word: needsPermission ? "Needs permission" : "Ready",
                            detail: needsPermission ? note : "Hold \(dictationKeyName) and say something.",
                            actionTitle: needsPermission ? SectionCopy.openSystemSettings : nil,
                            isReady: !needsPermission)
    }

    private var microphoneRow: ReadinessRow {
        let status = deps.permissions.status(of: .microphone)
        if status == .denied || status == .awaitingUserAction {
            return ReadinessRow(id: "microphone", glyph: "mic.slash", label: "Microphone",
                                word: "Off", detail: SectionCopy.microphoneOff,
                                actionTitle: SectionCopy.openSystemSettings, isReady: false)
        }
        return ReadinessRow(id: "microphone", glyph: "mic", label: "Microphone",
                            word: audio.devices.isEmpty ? "None" : "Ready", detail: audio.note,
                            actionTitle: audio.devices.isEmpty ? SectionCopy.chooseMicrophone : nil,
                            isReady: !audio.devices.isEmpty)
    }

    private var modelRow: ReadinessRow {
        if deps.models.isStackInstalled {
            return ReadinessRow(id: "model", glyph: "checkmark.seal", label: "Speech model",
                                word: "Ready", detail: "Installed and running on this Mac.", isReady: true)
        }
        switch deps.models.stackReadiness {
        case .ready:
            return ReadinessRow(id: "model", glyph: "checkmark.seal", label: "Speech model",
                                word: "Ready", detail: "Installed and running on this Mac.", isReady: true)
        case .fallback(let name, _):
            return ReadinessRow(id: "model", glyph: "arrow.down.circle", label: "Speech model",
                                word: "Installing",
                                detail: "Using \(name) until the stack finishes — \(ByteText.short(deps.models.remainingStackBytes)) to go.",
                                isReady: false)
        case .unavailable(let reason):
            return ReadinessRow(id: "model", glyph: "exclamationmark.triangle", label: "Speech model",
                                word: "Not ready", detail: reason,
                                actionTitle: "Open Settings", isReady: false)
        }
    }

    private var muteRow: ReadinessRow {
        let muted = mute.loadMuted()
        return ReadinessRow(id: "mute", glyph: muted ? "mic.slash.circle" : "mic.circle",
                            label: "Mute", word: muted ? "Muted" : "Not muted",
                            detail: muted ? "The microphone stays shut until you unmute — it survives a relaunch."
                                          : "Dictation can open the microphone.",
                            actionTitle: muted ? "Unmute" : nil, isReady: !muted)
    }

    /// Everything in the readiness strip that is not ready, for the "needs a hand" count.
    public var blockers: [ReadinessRow] { readiness.filter { !$0.isReady } }

    // MARK: Needs you — the held queue (§9.1, R2.3/R2.4)

    public func refreshHeld() {
        held = heldProvider()
        heldRowErrors = heldRowErrors.filter { id, _ in held.contains { $0.id == id } }
    }

    public func perform(_ action: HeldAction, on item: HeldItem) {
        switch heldAction(item, action) {
        case .inserted, .copied, .discarded:
            heldRowErrors[item.id] = nil
        case .unavailable, .unknownItem:
            heldRowErrors[item.id] = SectionCopy.heldRowFailed
        }
        refreshHeld()
    }

    public var heldState: SectionState {
        held.isEmpty
            ? .empty("Nothing is waiting", detail: "Text that couldn't be typed waits here with Insert here, Copy and Discard.")
            : .content
    }

    // MARK: Timeline

    /// `DESIGN.md` §9.1's two distinct empties, its one loading row, and its banner error.
    public func reloadTimeline() async {
        guard ambientCaptureOn() else {
            timelineRows = []
            timeline = .empty(SectionCopy.timelineOff, detail: SectionCopy.timelineOffDetail, action: SectionCopy.openPrivacy)
            return
        }
        guard let reader else {
            timelineRows = []
            timeline = .empty(SectionCopy.timelineOff, detail: SectionCopy.timelineOffDetail, action: SectionCopy.openPrivacy)
            return
        }
        timeline = .loading()
        do {
            let rows = try await reader.rows(matching: search)
            timelineRows = rows
            banner = nil
            timeline = rows.isEmpty
                ? .empty(SectionCopy.nothingDictated, detail: SectionCopy.nothingDictatedDetail(key: dictationKeyName))
                : .content
        } catch {
            // Partial data keeps its content and gains a banner; no data at all is the error state.
            if timelineRows.isEmpty {
                timeline = .error(SectionCopy.timelineUnreadable, action: SectionCopy.openPrivacy)
            } else {
                timeline = .content
                banner = SectionBanner(headline: SectionCopy.timelineUnreadable,
                                       actionTitle: SectionCopy.openPrivacy, diagnostics: "\(error)")
            }
        }
    }

    public func delete(rowID: String) {
        guard let reader else { return }
        do {
            try reader.delete(id: rowID)
            timelineRows.removeAll { $0.id == rowID }
            if timelineRows.isEmpty {
                timeline = .empty(SectionCopy.nothingDictated, detail: SectionCopy.nothingDictatedDetail(key: dictationKeyName))
            }
        } catch {
            banner = SectionBanner(headline: "That row wasn't deleted", actionTitle: SectionCopy.tryAgain, diagnostics: "\(error)")
        }
    }

    public func deleteAllTimeline() {
        guard let reader else { return }
        do {
            try reader.deleteAll()
            timelineRows = []
            timeline = .empty(SectionCopy.nothingDictated, detail: SectionCopy.nothingDictatedDetail(key: dictationKeyName))
        } catch {
            banner = SectionBanner(headline: "Some of it is still here", actionTitle: SectionCopy.tryAgain, diagnostics: "\(error)")
        }
    }
}
