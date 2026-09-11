import Engine
import Foundation
import Lab
import Shared

// R7.2 — Privacy (`DESIGN.md` §9.5): what is captured, what is saved, what is transmitted — and the
// switch that turns each off. The standalone Data Panel window folds in here, kill switch included.
//
// The one sentence this section is never allowed to say is "zero bytes" (V3 §9.6). The empty state
// is scoped and dated: "Nothing has left this Mac in the last 30 days", over a window this view
// model actually queried.

/// Where the ambient-capture retention setting lives. R8.2 owns the enforcement; the preference is
/// here so the switch that promises it is not a placeholder.
public enum AmbientRetentionSettings {
    public static let daysKey = "ambient.retention.days"
    public static let defaultDays = 7
    public static let choices = [1, 7, 30, 90]

    public static func days(_ store: (any SettingsStore)?) -> Int {
        guard let raw = store?.string(daysKey), let days = Int(raw), choices.contains(days) else { return defaultDays }
        return days
    }

    public static func setDays(_ days: Int, store: (any SettingsStore)?) {
        store?.set(String(days), for: daysKey)
    }
}

/// Privacy. The egress log is the only part that loads; the switches render from settings at once.
@MainActor
public final class PrivacySectionViewModel: ObservableObject {
    /// How far back the log is read, and therefore the only period the empty state may claim.
    public static let windowDays = 30

    @Published public private(set) var records: [NetworkLogRecord] = []
    @Published public private(set) var bytesOutToday = 0
    @Published public private(set) var egress: SectionState = .loading()
    @Published public private(set) var saved: SectionState = .content
    @Published public private(set) var banner: SectionBanner?

    public let audio: AudioInputSettingsViewModel
    private let settings: (any SettingsStore)?
    private let flags: FeatureFlagService?
    private let gate: EgressGate
    private let load: (Date) async throws -> [NetworkLogRecord]
    private let bytesToday: (Date) throws -> Int
    private let deleteEverything: () throws -> Int

    public init(settings: (any SettingsStore)?,
                flags: FeatureFlagService?,
                gate: EgressGate = .shared,
                audio: AudioInputSettingsViewModel? = nil,
                database: AppDatabase? = nil,
                load: ((Date) async throws -> [NetworkLogRecord])? = nil,
                bytesToday: ((Date) throws -> Int)? = nil,
                deleteEverything: (() throws -> Int)? = nil) {
        self.settings = settings
        self.flags = flags
        self.gate = gate
        self.audio = audio ?? AudioInputSettingsViewModel()
        self.load = load ?? { since in
            guard let database else { return [] }
            return try database.networkLog(since: since, limit: 5_000)
        }
        self.bytesToday = bytesToday ?? { since in
            guard let database else { return 0 }
            return try database.bytesEgressed(since: since)
        }
        self.deleteEverything = deleteEverything ?? { 0 }
    }

    // MARK: Captured

    /// Ambient capture is the `directedSpeech` flag today — the real gate, not a new mirror of it.
    /// Default off (V3 §9.4, R8.1).
    public var ambientCapture: Bool {
        get { flags?.isEnabled(.directedSpeech) ?? false }
        set {
            try? flags?.setOverride(newValue, for: .directedSpeech)
            objectWillChange.send()
        }
    }

    public static let enrolledSpeakerOnlyNote =
        "Ambient capture only keeps what your enrolled voice said, as transcript. Nothing is typed anywhere, and it never reaches an injection path."

    public var retentionDays: Int {
        get { AmbientRetentionSettings.days(settings) }
        set {
            AmbientRetentionSettings.setDays(newValue, store: settings)
            objectWillChange.send()
        }
    }

    /// Audio retention is a *separate* switch from transcript retention (`DESIGN.md` §9.5), and it is
    /// the existing "save recordings" setting — the same key the recorder reads, not a second one.
    public var audioRetention: Bool {
        get { audio.saveRecordings }
        set { audio.saveRecordings = newValue; objectWillChange.send() }
    }

    // MARK: Transmitted

    public var killSwitch: Bool {
        get { gate.isKillSwitchOn }
        set { gate.isKillSwitchOn = newValue; objectWillChange.send() }
    }

    public var windowSentence: String {
        "Every request VoicePlus made in the last \(Self.windowDays) days, and how many bytes went each way."
    }

    public func reload(now: Date = Date()) async {
        egress = .loading()
        let since = now.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        do {
            records = try await load(since)
            bytesOutToday = (try? bytesToday(Calendar.current.startOfDay(for: now))) ?? 0
            banner = nil
            egress = records.isEmpty
                ? .empty(SectionCopy.nothingLeftThisMac, detail: SectionCopy.nothingLeftDetail)
                : .content
        } catch {
            if records.isEmpty {
                egress = .error(SectionCopy.egressUnreadable, action: SectionCopy.copyDiagnostics)
            } else {
                egress = .content
                banner = SectionBanner(headline: SectionCopy.egressUnreadable,
                                       actionTitle: SectionCopy.copyDiagnostics, diagnostics: "\(error)")
            }
        }
        refreshSaved()
    }

    // MARK: Saved

    public func refreshSaved() {
        saved = audio.saveRecordings
            ? .content
            : .empty(SectionCopy.nothingSaved, detail: SectionCopy.nothingSavedDetail)
    }

    /// What the confirmation sheet has to name before it deletes anything (`DESIGN.md` §9.5).
    public var deleteAllSummary: String {
        "This deletes every saved recording on this Mac and every row of the network log. It cannot be undone."
    }

    public func deleteAll() {
        audio.deleteRecordings()
        do {
            let remaining = try deleteEverything()
            banner = remaining == 0
                ? nil
                : SectionBanner(headline: SectionCopy.deleteAllPartial,
                                actionTitle: SectionCopy.tryAgain,
                                diagnostics: "\(remaining) row\(remaining == 1 ? "" : "s") could not be deleted")
        } catch {
            banner = SectionBanner(headline: SectionCopy.deleteAllPartial, actionTitle: SectionCopy.tryAgain, diagnostics: "\(error)")
        }
        refreshSaved()
    }
}
