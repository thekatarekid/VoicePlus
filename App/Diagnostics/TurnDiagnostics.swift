import Foundation
import GRDB

// V5 Q13 — persisted per-turn diagnostics (SQLite table `turn_diagnostics`, 7-day retention, local
// only). Records *why* the pill/panel did what it did and how text landed, so misfires (P-items, O3
// decisions) are diagnosable after the fact. By construction it never stores dictated text: every
// event carries only enums, short reason codes, geometry, app bundle ids, timings and probabilities.
// Reason strings are clipped to `TurnDiagnostics.maxReasonLength` so a caller cannot smuggle a
// transcript in through a reason.
//
// O3's `UtteranceDecision` is not in `Shared/` yet; `TurnDiagnosticsEvent.Decision` mirrors its
// fields (owner, confidence, band, reason, questionProbabilities) and is what O3 maps into.

/// A screen point (AppKit global coordinates).
public struct DiagnosticsPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
}

/// A screen rectangle (AppKit global coordinates).
public struct DiagnosticsRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ r: CGRect) {
        self.init(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.width), height: Double(r.height))
    }
}

/// One diagnostic fact about one turn. No case carries dictated text.
public enum TurnDiagnosticsEvent: Codable, Equatable, Sendable {
    /// The pill was shown (or re-placed): why, and where the mouse was.
    case pillDisplay(reason: String, mouse: DiagnosticsPoint?, frame: DiagnosticsRect?)
    /// A panel `orderFront` / `orderOut` with its reason.
    case orderFront(window: String, reason: String)
    case orderOut(window: String, reason: String)
    /// Capture paused / resumed: reason, pointer and the pill frame at that moment.
    case pause(reason: String, pointer: DiagnosticsPoint?, frame: DiagnosticsRect?)
    case resume(reason: String, pointer: DiagnosticsPoint?, frame: DiagnosticsRect?)
    /// How the text landed (K-items): verdict, target app, method, settle duration.
    case landing(verdict: String, appBundleID: String?, method: String, settleMs: Int?)
    /// O3's one decision per utterance.
    case decision(Decision)

    public struct Decision: Codable, Equatable, Sendable {
        public var owner: String
        public var confidence: Double
        public var band: String?
        public var reason: String
        /// Per-question probabilities (question id → p).
        public var questionProbabilities: [String: Double]
        public init(owner: String, confidence: Double, band: String? = nil, reason: String,
                    questionProbabilities: [String: Double] = [:]) {
            self.owner = owner; self.confidence = confidence; self.band = band
            self.reason = reason; self.questionProbabilities = questionProbabilities
        }
    }

    /// Column value for `kind`.
    public var kind: String {
        switch self {
        case .pillDisplay: "pillDisplay"
        case .orderFront: "orderFront"
        case .orderOut: "orderOut"
        case .pause: "pause"
        case .resume: "resume"
        case .landing: "landing"
        case .decision: "decision"
        }
    }

    /// The same event with every free-form string clipped.
    func clipped(_ n: Int) -> TurnDiagnosticsEvent {
        func c(_ s: String) -> String { s.count > n ? String(s.prefix(n)) : s }
        func c(_ s: String?) -> String? { s.map(c) }
        switch self {
        case let .pillDisplay(r, m, f): return .pillDisplay(reason: c(r), mouse: m, frame: f)
        case let .orderFront(w, r): return .orderFront(window: c(w), reason: c(r))
        case let .orderOut(w, r): return .orderOut(window: c(w), reason: c(r))
        case let .pause(r, p, f): return .pause(reason: c(r), pointer: p, frame: f)
        case let .resume(r, p, f): return .resume(reason: c(r), pointer: p, frame: f)
        case let .landing(v, a, m, s): return .landing(verdict: c(v), appBundleID: c(a), method: c(m), settleMs: s)
        case var .decision(d):
            d.owner = c(d.owner); d.band = c(d.band); d.reason = c(d.reason)
            d.questionProbabilities = Dictionary(uniqueKeysWithValues: d.questionProbabilities.map { (c($0.key), $0.value) })
            return .decision(d)
        }
    }
}

/// One stored row.
public struct TurnDiagnosticsEntry: Codable, Equatable, Sendable {
    public var id: Int64?
    public var turnID: String
    public var at: Date
    public var event: TurnDiagnosticsEvent
}

/// The store. Thread-safe (GRDB serialises writes). Never throws to callers on the hot path:
/// diagnostics must not break dictation.
public final class TurnDiagnostics: Sendable {
    public static let table = "turn_diagnostics"
    public static let retention: TimeInterval = 7 * 24 * 3600
    public static let maxReasonLength = 120

    private let writer: any DatabaseWriter
    private let clock: @Sendable () -> Date

    public init(writer: any DatabaseWriter, clock: @escaping @Sendable () -> Date = Date.init) throws {
        self.writer = writer
        self.clock = clock
        try writer.write { db in try Self.ensureSchema(db) }
        try sweep()
    }

    /// Additive schema owned by this module (does not touch `AppDatabase`'s migrator).
    static func ensureSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS \(table) (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                turnID TEXT NOT NULL,
                at DATETIME NOT NULL,
                kind TEXT NOT NULL,
                payloadJSON TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS \(table)_at ON \(table)(at);
            CREATE INDEX IF NOT EXISTS \(table)_turn ON \(table)(turnID);
            """)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e
    }()

    /// Appends one event for `turnID`. Failures are swallowed (logged nowhere — local only).
    public func record(_ event: TurnDiagnosticsEvent, turn turnID: String, at date: Date? = nil) {
        let event = event.clipped(Self.maxReasonLength)
        let when = date ?? clock()
        guard let data = try? Self.encoder.encode(event), let json = String(data: data, encoding: .utf8) else { return }
        try? writer.write { db in
            try db.execute(sql: "INSERT INTO \(Self.table) (turnID, at, kind, payloadJSON) VALUES (?, ?, ?, ?)",
                           arguments: [turnID, when, event.kind, json])
        }
    }

    /// Deletes everything older than the 7-day retention window. Returns rows removed.
    @discardableResult
    public func sweep(now: Date? = nil) throws -> Int {
        let cutoff = (now ?? clock()).addingTimeInterval(-Self.retention)
        return try writer.write { db in
            try db.execute(sql: "DELETE FROM \(Self.table) WHERE at < ?", arguments: [cutoff])
            return db.changesCount
        }
    }

    /// All retained entries, oldest first (optionally one turn).
    public func entries(turn turnID: String? = nil) throws -> [TurnDiagnosticsEntry] {
        try writer.read { db in
            let rows: [Row]
            if let turnID {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM \(Self.table) WHERE turnID = ? ORDER BY at, id", arguments: [turnID])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM \(Self.table) ORDER BY at, id")
            }
            return rows.compactMap { row in
                let json: String = row["payloadJSON"]
                guard let event = try? JSONDecoder().decode(TurnDiagnosticsEvent.self, from: Data(json.utf8)) else { return nil }
                return TurnDiagnosticsEntry(id: row["id"], turnID: row["turnID"], at: row["at"], event: event)
            }
        }
    }

    /// Deletes everything (Privacy › delete data).
    public func deleteAll() throws {
        try writer.write { db in try db.execute(sql: "DELETE FROM \(Self.table)") }
    }

    // MARK: Export (owner-triggered from Settings › Privacy only)

    /// JSON export grouped by turn. Called only from an explicit user action.
    public func exportJSON(generatedAt: Date? = nil) throws -> Data {
        try sweep()
        let all = try entries()
        var order: [String] = []
        var byTurn: [String: [TurnDiagnosticsEntry]] = [:]
        for e in all {
            if byTurn[e.turnID] == nil { order.append(e.turnID) }
            byTurn[e.turnID, default: []].append(e)
        }
        let doc = ExportDocument(
            generatedAt: generatedAt ?? clock(),
            retentionDays: Int(Self.retention / 86_400),
            turns: order.map { ExportDocument.Turn(turnID: $0, events: byTurn[$0]!.map {
                ExportDocument.Event(at: $0.at, kind: $0.event.kind, event: $0.event)
            }) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(doc)
    }

    /// Writes the export to `url` (the save panel's choice).
    public func exportJSON(to url: URL) throws {
        try exportJSON().write(to: url, options: .atomic)
    }

    /// "VoicePlus Turn Diagnostics 2026-10-01 1042.json".
    public static func exportFileName(at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "VoicePlus Turn Diagnostics \(f.string(from: date)).json"
    }

    struct ExportDocument: Codable {
        struct Event: Codable { var at: Date; var kind: String; var event: TurnDiagnosticsEvent }
        struct Turn: Codable { var turnID: String; var events: [Event] }
        var generatedAt: Date
        var retentionDays: Int
        var turns: [Turn]
    }
}
