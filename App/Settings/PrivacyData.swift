import Engine
import Foundation
import GRDB
import Shared

// S7f — scoped deletion (design §8.5: "Delete controls state scope and count; partial deletion lists
// what remains"). Each scope is one kind of thing VoicePlus keeps on this Mac. A delete is always
// followed by a recount, so the page reports what is actually still there — never the count it
// expected to remove.

/// One kind of retained data, in the order the page lists them.
public enum PrivacyDataScope: String, CaseIterable, Identifiable, Sendable {
    /// J1 — the saved audio of dictations (`Recordings/`).
    case recordings
    /// The text of past dictations (`dictation_history`) and Today's settled turns.
    case dictationHistory
    /// Held text waiting for Insert here / Copy / Discard. Often the only copy.
    case heldText
    /// Ambient capture's transcript and its search index (R8).
    case ambientTranscripts
    /// The network log (`network_log`). Refused attempts live in memory only.
    case networkActivity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .recordings: return "Recordings"
        case .dictationHistory: return "Dictation history"
        case .heldText: return "Held text"
        case .ambientTranscripts: return "Ambient transcripts"
        case .networkActivity: return "Network activity log"
        }
    }

    /// "20 recordings", "1 dictation", "2 held texts" …
    public func noun(_ count: Int) -> String {
        let one = count == 1
        switch self {
        case .recordings: return "\(count) recording\(one ? "" : "s")"
        case .dictationHistory: return "\(count) dictation\(one ? "" : "s")"
        case .heldText: return "\(count) held text\(one ? "" : "s")"
        case .ambientTranscripts: return "\(count) ambient entr\(one ? "y" : "ies")"
        case .networkActivity: return "\(count) row\(one ? "" : "s") of network activity"
        }
    }

    /// What deleting this scope alone leaves untouched — the confirmation names it so a scoped delete
    /// is never mistaken for "delete everything".
    public var leavesAlone: String {
        switch self {
        case .recordings: return "Dictation history, held text and network activity stay."
        case .dictationHistory: return "Today’s recent list is cleared too. Held text, recordings and learned words stay."
        case .heldText: return "This is the only copy of that text. History and recordings stay."
        case .ambientTranscripts: return "The Timeline’s search index is cleared too. Dictation history stays."
        case .networkActivity: return "Refused requests are kept in memory only and clear when VoicePlus quits."
        }
    }
}

/// How much one scope holds.
public struct PrivacyScopeCount: Equatable, Sendable {
    public var items: Int
    /// On-disk size, where the scope is files.
    public var bytes: Int64?

    public init(items: Int, bytes: Int64? = nil) {
        self.items = items
        self.bytes = bytes
    }

    public static let zero = PrivacyScopeCount(items: 0)
}

/// Everything the page can count, read at one moment. A scope that could not be counted is absent
/// from `counts` and present in `failures` — it is never shown as zero.
public struct PrivacyInventory: Equatable, Sendable {
    public var counts: [PrivacyDataScope: PrivacyScopeCount] = [:]
    public var failures: [PrivacyDataScope: String] = [:]

    public init(counts: [PrivacyDataScope: PrivacyScopeCount] = [:], failures: [PrivacyDataScope: String] = [:]) {
        self.counts = counts
        self.failures = failures
    }

    public func count(_ scope: PrivacyDataScope) -> PrivacyScopeCount? { counts[scope] }

    /// "20 recordings · 19.6 MB", "Nothing to delete.", or the can't-count line.
    public func line(_ scope: PrivacyDataScope) -> String {
        guard let count = counts[scope] else { return PrivacyCopy.uncounted }
        guard count.items > 0 else { return PrivacyCopy.nothingToDelete }
        let size = count.bytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
        return scope.noun(count.items) + size
    }

    /// True only when every scope was counted and each is empty.
    public var isEmpty: Bool {
        failures.isEmpty && PrivacyDataScope.allCases.allSatisfy { (counts[$0]?.items ?? 1) == 0 }
    }
}

/// What a deletion left behind in one scope: counted after the delete, with the items named.
public struct PrivacyRemainder: Identifiable, Equatable, Sendable {
    public var scope: PrivacyDataScope
    /// nil when the scope could not be recounted — then nothing is claimed about it.
    public var count: Int?
    /// Up to `listLimit` named items ("Recording from 18 Sep, 12:42").
    public var items: [String]
    /// Raw cause, for Copy diagnostics only.
    public var reason: String?

    public static let listLimit = 10

    public var id: String { scope.rawValue }

    public init(scope: PrivacyDataScope, count: Int?, items: [String] = [], reason: String? = nil) {
        self.scope = scope
        self.count = count
        self.items = Array(items.prefix(Self.listLimit))
        self.reason = reason
    }

    /// "3 recordings are still on this Mac" / "Recordings couldn’t be checked after deleting".
    public var line: String {
        guard let count else { return "\(scope.title) couldn’t be checked after deleting." }
        return "\(scope.noun(count)) \(count == 1 ? "is" : "are") still on this Mac."
    }
}

/// The data behind the scopes. Counting and deleting are synchronous and local.
public protocol PrivacyDataStoring: AnyObject {
    func count(_ scope: PrivacyDataScope) throws -> PrivacyScopeCount
    /// Deletes everything in `scope`, then recounts. `nil` = nothing is left.
    func delete(_ scope: PrivacyDataScope) -> PrivacyRemainder?
}

public extension PrivacyDataStoring {
    func inventory() -> PrivacyInventory {
        var inventory = PrivacyInventory()
        for scope in PrivacyDataScope.allCases {
            do { inventory.counts[scope] = try count(scope) }
            catch { inventory.failures[scope] = "\(error)" }
        }
        return inventory
    }
}

// MARK: - Live store

/// The real data: the recordings folder, the app database, the turn store and the ambient store.
public final class LivePrivacyDataStore: PrivacyDataStoring {
    private let database: AppDatabase?
    private let recordingsDirectory: URL
    private let ambient: () -> AmbientTranscriptStore?
    private let turns: () -> TurnStore?
    private let deleteNetworkLog: (() throws -> Int)?
    private let remove: (URL) throws -> Void

    /// `deleteNetworkLog`, when given, replaces the log delete and returns the rows still there.
    public init(database: AppDatabase?,
                recordingsDirectory: URL = UtteranceRecorder.directory(),
                ambient: (() -> AmbientTranscriptStore?)? = nil,
                turns: @escaping () -> TurnStore? = { TurnStore.current },
                deleteNetworkLog: (() throws -> Int)? = nil,
                remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.database = database
        self.recordingsDirectory = recordingsDirectory
        let built = AmbientStoreBox(database: database)
        self.ambient = ambient ?? { built.store }
        self.turns = turns
        self.deleteNetworkLog = deleteNetworkLog
        self.remove = remove
    }

    public func count(_ scope: PrivacyDataScope) throws -> PrivacyScopeCount {
        switch scope {
        case .recordings:
            let usage = UtteranceRecorder.usage(of: recordingsDirectory)
            return PrivacyScopeCount(items: usage.utterances, bytes: usage.bytes)
        case .dictationHistory:
            guard let database else { return .zero }
            return PrivacyScopeCount(items: try database.reader.read { try DictationRecord.fetchCount($0) })
        case .heldText:
            return PrivacyScopeCount(items: held().count)
        case .ambientTranscripts:
            return PrivacyScopeCount(items: ambient()?.entries().count ?? 0)
        case .networkActivity:
            guard let database else { return .zero }
            return PrivacyScopeCount(items: try database.reader.read { try NetworkLogRecord.fetchCount($0) })
        }
    }

    public func delete(_ scope: PrivacyDataScope) -> PrivacyRemainder? {
        switch scope {
        case .recordings: return deleteRecordings()
        case .dictationHistory: return deleteHistory()
        case .heldText: return deleteHeld()
        case .ambientTranscripts: return deleteAmbient()
        case .networkActivity: return deleteLog()
        }
    }

    // MARK: Recordings — only the recorder's own files, one utterance at a time

    private func deleteRecordings() -> PrivacyRemainder? {
        let files = PrivacyRecordingFiles.files(in: recordingsDirectory)
        var reasons: [String] = []
        for file in files {
            do { try remove(file) } catch { reasons.append("\(file.lastPathComponent): \(error)") }
        }
        let left = PrivacyRecordingFiles.files(in: recordingsDirectory)
        guard !left.isEmpty else { return nil }
        let stamps = Array(Set(left.map(UtteranceRecorder.stamp(of:)))).sorted(by: >)
        return PrivacyRemainder(scope: .recordings, count: stamps.count,
                                items: stamps.map { PrivacyRecordingFiles.describe(stamp: $0) },
                                reason: reasons.joined(separator: "\n"))
    }

    // MARK: Dictation history — the history table and Today's settled turns, never held text

    private func deleteHistory() -> PrivacyRemainder? {
        var reason: String?
        if let database {
            do { _ = try database.writer.write { try DictationRecord.deleteAll($0) } }
            catch { reason = "\(error)" }
            try? TurnDiagnostics(database: database).deleteAll() // V5 Q13: per-turn diagnostics go with history
        }
        if let store = turns() {
            for entry in store.recent(limit: 100_000) where Self.isSettledHistory(entry) { store.remove(entry.id) }
            store.flush()
        }
        let rows: Int?
        if let database {
            rows = try? database.reader.read { try DictationRecord.fetchCount($0) }
        } else {
            rows = 0
        }
        let turnsLeft = turns()?.recent(limit: 100_000).filter(Self.isSettledHistory).count ?? 0
        guard let rows else {
            return PrivacyRemainder(scope: .dictationHistory, count: nil, reason: reason)
        }
        guard rows + turnsLeft > 0 else { return nil }
        var items: [String] = []
        if rows > 0 { items.append("\(PrivacyDataScope.dictationHistory.noun(rows)) in history") }
        if turnsLeft > 0 { items.append("\(turnsLeft) entr\(turnsLeft == 1 ? "y" : "ies") in Today’s recent list") }
        return PrivacyRemainder(scope: .dictationHistory, count: rows + turnsLeft, items: items, reason: reason)
    }

    /// A turn that is over and not waiting for the user: history, not recovery.
    static func isSettledHistory(_ entry: TurnEntry) -> Bool { !entry.stage.isLive && !entry.isRecoverable }

    // MARK: Held text

    private func held() -> [TurnEntry] { turns()?.recoverable(limit: 10_000) ?? [] }

    private func deleteHeld() -> PrivacyRemainder? {
        guard let store = turns() else { return nil }
        for entry in held() { store.remove(entry.id) }
        store.flush()
        let left = held()
        guard !left.isEmpty else { return nil }
        return PrivacyRemainder(scope: .heldText, count: left.count, items: left.map(Self.describe))
    }

    static func describe(_ entry: TurnEntry) -> String {
        let time = PrivacyCopy.dateTime(entry.record.startedAt)
        if let app = entry.record.destination.appName, !app.isEmpty { return "Held text for \(app) from \(time)" }
        return "Held text from \(time)"
    }

    // MARK: Ambient transcripts

    private func deleteAmbient() -> PrivacyRemainder? {
        guard let store = ambient() else { return nil }
        var reason: String?
        do { try store.deleteAll() } catch { reason = "\(error)" }
        let left = store.entries()
        guard !left.isEmpty else { return nil }
        let days = Set(left.map { Calendar.current.startOfDay(for: $0.capturedAt) }).sorted(by: >)
        return PrivacyRemainder(scope: .ambientTranscripts, count: left.count,
                                items: days.map { "Ambient transcript from \(PrivacyCopy.day($0))" }, reason: reason)
    }

    // MARK: Network log

    private func deleteLog() -> PrivacyRemainder? {
        if let deleteNetworkLog {
            do {
                let left = try deleteNetworkLog()
                return left == 0 ? nil : PrivacyRemainder(scope: .networkActivity, count: left,
                                                          items: [PrivacyDataScope.networkActivity.noun(left)])
            } catch {
                return PrivacyRemainder(scope: .networkActivity, count: nil, reason: "\(error)")
            }
        }
        guard let database else { return nil }
        var reason: String?
        do { _ = try database.writer.write { try NetworkLogRecord.deleteAll($0) } }
        catch { reason = "\(error)" }
        guard let left = try? database.reader.read({ try NetworkLogRecord.fetchCount($0) }) else {
            return PrivacyRemainder(scope: .networkActivity, count: nil, reason: reason)
        }
        return left == 0 ? nil : PrivacyRemainder(scope: .networkActivity, count: left,
                                                  items: [PrivacyDataScope.networkActivity.noun(left)], reason: reason)
    }
}

/// Builds the ambient store once, on first use, over the real ambient directory — the same one the
/// Timeline reads. Building it writes nothing.
private final class AmbientStoreBox {
    private let database: AppDatabase?
    private lazy var built = AmbientTranscriptStore(database: database, retention: { AmbientRetentionPolicy() })
    init(database: AppDatabase?) { self.database = database }
    var store: AmbientTranscriptStore? { built }
}

/// The recorder's own files (`<stamp>-raw.wav`, `<stamp>-processed.wav`, `<stamp>.json`, stamp
/// `yyyy-MM-dd-HHmmss-SSS`) — the rule `UtteranceRecorder` counts and prunes by, so a delete never
/// touches anything else someone put in that folder.
public enum PrivacyRecordingFiles {
    public static func files(in directory: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return all.filter(isRecordingFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func isRecordingFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        for suffix in ["-raw.wav", "-processed.wav", ".json"] where name.hasSuffix(suffix) {
            return isStamp(name.dropLast(suffix.count))
        }
        return false
    }

    static func isStamp(_ s: Substring) -> Bool {
        let shape = Array("dddd-dd-dd-dddddd-ddd")
        let chars = Array(s)
        guard chars.count == shape.count else { return false }
        return zip(chars, shape).allSatisfy { c, want in want == "d" ? (c.isASCII && c.isNumber) : c == want }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// "Recording from 18 Sep, 12:42" — a date, never a file name (DESIGN.md §7.1).
    public static func describe(stamp: String) -> String {
        guard let date = stampFormatter.date(from: stamp) else { return "A recording" }
        return "Recording from \(PrivacyCopy.dateTime(date))"
    }
}
