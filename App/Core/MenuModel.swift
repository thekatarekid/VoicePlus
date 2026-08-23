import Foundation
import Shared

/// Pure data behind the status-item dropdown (T4).
public struct MenuModel: Equatable, Sendable {
    public var zeroEditCount: Int
    public var totalCount: Int
    public var wordsToday: Int
    public var activeModel: String
    public var micName: String
    public var micStatus: MicQuality.Verdict?
    public var paused: Bool
    public var handsFree: Bool
    public var hotkeyName: String
    public var launchAtLogin: Bool

    public init(zeroEditCount: Int = 0, totalCount: Int = 0, wordsToday: Int = 0, activeModel: String = "Mock engine",
                micName: String = "Default microphone", micStatus: MicQuality.Verdict? = nil, paused: Bool = false,
                handsFree: Bool = false, hotkeyName: String = HotkeyBinding.default.kind.displayName,
                launchAtLogin: Bool = false) {
        self.zeroEditCount = zeroEditCount
        self.totalCount = totalCount
        self.wordsToday = wordsToday
        self.activeModel = activeModel
        self.micName = micName
        self.micStatus = micStatus
        self.paused = paused
        self.handsFree = handsFree
        self.hotkeyName = hotkeyName
        self.launchAtLogin = launchAtLogin
    }

    public var zeroEditLine: String {
        guard totalCount > 0 else { return "Zero-edit: no dictations yet" }
        let pct = Int((Double(zeroEditCount) / Double(totalCount) * 100).rounded())
        return "Zero-edit: \(zeroEditCount)/\(totalCount) (\(pct)%)"
    }

    public var wordsLine: String { "Words today: \(wordsToday)" }
    public var modelLine: String { "Model: \(activeModel)" }

    public var micLine: String {
        let suffix: String
        switch micStatus {
        case .good?: suffix = " ✓"
        case .poor?: suffix = " — weak signal"
        case .bad?: suffix = " — check mic"
        case nil: suffix = ""
        }
        return "Mic: \(micName)\(suffix)"
    }

    public var pauseTitle: String { paused ? "Resume VoicePlus" : "Pause VoicePlus" }
    public var statusSymbol: String { paused ? "mic.slash" : (handsFree ? "mic.badge.plus" : "mic") }

    /// Counts derived from dictation history. `now` is injectable for tests.
    public static func stats(from dictations: [DictationRecord], now: Date = Date(), calendar: Calendar = .current)
        -> (zeroEdit: Int, total: Int, wordsToday: Int) {
        let total = dictations.count
        let zeroEdit = dictations.filter { !$0.edited }.count
        let words = dictations
            .filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
            .reduce(0) { $0 + $1.finalText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
        return (zeroEdit, total, words)
    }

    public static func load(from db: AppDatabase, now: Date = Date()) -> (zeroEdit: Int, total: Int, wordsToday: Int) {
        let records = (try? db.recentDictations(limit: 5000)) ?? []
        return stats(from: records, now: now)
    }
}
