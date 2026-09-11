import Engine
import Foundation
import Shared

// R7.1 — Meetings (`DESIGN.md` §9.2): the transcripts, and the switch that decides whether they are
// captured. Meeting capture stays opt-in and stays off by default; this section never asks macOS for
// Calendar access on its own — it *reads* the status and offers the opt-in, exactly as
// `MeetingCoordinator` requires (the launch-time dialog storm this gate fixed is documented there).

/// Meetings. The store is a plain `MeetingStore` (JSON on disk), so this needs nothing from the
/// composition root but the settings store and a Calendar status read.
@MainActor
public final class MeetingsSectionViewModel: ObservableObject {
    @Published public private(set) var meetings: [MeetingRecord] = []
    @Published public private(set) var state: SectionState = .loading()
    @Published public private(set) var banner: SectionBanner?
    /// Meetings whose `meeting.json` would not decode: the row stays, with Delete (`DESIGN.md` §9.2).
    @Published public private(set) var unreadableIDs: [String] = []
    @Published public private(set) var selected: MeetingRecord?
    @Published public private(set) var transcript: SectionState = .content
    @Published public var search = ""

    private let store: MeetingStore
    private let settings: (any SettingsStore)?
    private let calendarAuthorized: () -> Bool
    private let setCaptureEnabled: (Bool) -> Void
    /// Injected so a test can make the list slow, empty or broken without a filesystem.
    private let list: (MeetingStore) async throws -> (records: [MeetingRecord], unreadable: [String])

    public init(store: MeetingStore = MeetingStore(),
                settings: (any SettingsStore)?,
                calendarAuthorized: @escaping () -> Bool = { EventKitCalendarSignal().isAuthorized },
                setCaptureEnabled: ((Bool) -> Void)? = nil,
                list: ((MeetingStore) async throws -> (records: [MeetingRecord], unreadable: [String]))? = nil) {
        self.store = store
        self.settings = settings
        self.calendarAuthorized = calendarAuthorized
        let settingsStore = settings
        self.setCaptureEnabled = setCaptureEnabled ?? { on in
            settingsStore?.set(on, for: SettingsKeys.meetingCaptureEnabled)
        }
        self.list = list ?? { store in (records: store.list(), unreadable: MeetingsSectionViewModel.unreadable(in: store)) }
    }

    /// Directories that exist but do not decode. Counted separately so the section can show the rows
    /// it *can* read and put the failures in their own rows.
    static func unreadable(in store: MeetingStore) -> [String] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
        return ids.filter { (try? store.load(id: $0)) == nil }.sorted()
    }

    public var isCaptureEnabled: Bool {
        get { settings?.bool(SettingsKeys.meetingCaptureEnabled) ?? false }
        set {
            setCaptureEnabled(newValue)
            objectWillChange.send()
            Task { await reload() }
        }
    }

    public var isCalendarAuthorized: Bool { calendarAuthorized() }

    public var filtered: [MeetingRecord] {
        guard !search.isEmpty else { return meetings }
        let needle = search.lowercased()
        return meetings.filter {
            $0.title.lowercased().contains(needle)
                || $0.transcript.utterances.contains { $0.text.lowercased().contains(needle) }
        }
    }

    public func select(_ record: MeetingRecord?) {
        selected = record
        transcript = record.map { $0.transcript.utterances.isEmpty
            ? SectionState.empty("No words in this transcript", detail: "The meeting was captured but nothing was transcribed.")
            : SectionState.content } ?? .content
    }

    /// `DESIGN.md` §9.2's four renderings, in the order the user's situation decides them.
    public func reload() async {
        state = .loading()
        do {
            let result = try await list(store)
            meetings = result.records
            unreadableIDs = result.unreadable
            banner = result.unreadable.isEmpty
                ? nil
                : SectionBanner(headline: "\(result.unreadable.count) meeting\(result.unreadable.count == 1 ? "" : "s") can't be read",
                                actionTitle: SectionCopy.copyDiagnostics,
                                diagnostics: result.unreadable.joined(separator: "\n"))
            state = resolved()
        } catch {
            meetings = []
            state = .error(SectionCopy.meetingsUnreadable, action: SectionCopy.copyDiagnostics)
            banner = nil
        }
    }

    private func resolved() -> SectionState {
        if !meetings.isEmpty { return .content }
        if !isCaptureEnabled {
            return .empty(SectionCopy.meetingCaptureOff, detail: SectionCopy.meetingCaptureOffDetail, action: "Turn on meeting capture")
        }
        if !isCalendarAuthorized {
            return .empty(SectionCopy.calendarOff, detail: "System Settings › Privacy & Security › Calendars", action: SectionCopy.openSystemSettings)
        }
        return .empty(SectionCopy.noMeetings, detail: "A call VoicePlus records shows up here, transcript and all.")
    }

    public func delete(id: String) {
        do {
            try store.delete(id: id)
            meetings.removeAll { $0.id == id }
            unreadableIDs.removeAll { $0 == id }
            if selected?.id == id { selected = nil }
            state = resolved()
        } catch {
            banner = SectionBanner(headline: "That meeting wasn't deleted", actionTitle: SectionCopy.tryAgain, diagnostics: "\(error)")
        }
    }

    public func markdown(for record: MeetingRecord) -> String { record.markdown }
}
