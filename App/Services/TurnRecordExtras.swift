import Foundation
import Shared

// Round-3 §F confidence gate item 3 ("every turn explains itself") — T-schema.
//
// `turn_records` gains readable columns next to `recordJSON`: the surface kind and the signals
// that chose it, the field role, the write method, the verification verdict ("verified" /
// "unverified" / "not landed"), per-stage ms, the pre-boost raw text and the key-down / key-up
// times. `TurnRecord` (Shared) is untouched: these live beside it as `TurnRecordExtras`, which
// other lanes fill through `TurnStore.setExtras` (L2 stage timings and pre-boost text, L4 write
// method and verification, L6 surface kind and signals). What they leave empty is derived from
// the record itself (outcome → method/verification, capture timestamps → key times and stages).

/// The landing verdict as `turn_records.verification` stores it.
public enum TurnVerification: String, Codable, Sendable, CaseIterable {
    case verified
    case unverified
    case notLanded = "not landed"

    /// What a delivery outcome alone says. `nil` while no write was attempted.
    public static func from(_ outcome: DeliveryOutcome?) -> TurnVerification? {
        switch outcome {
        case .delivered(let verified, _)?: return verified ? .verified : .unverified
        case .partial?: return .unverified
        case .held?, .failed?: return .notLanded
        case nil: return nil
        }
    }
}

/// Per-turn facts kept beside `TurnRecord` in `turn_records`. Every field optional: a lane sets
/// only what it knows; `nil` means "not set" (and is filled from the record where it can be).
public struct TurnRecordExtras: Codable, Equatable, Sendable {
    /// L6 — the surface kind (section E), e.g. "chat", "doc", "terminal", "sheet", "canvas".
    public var surfaceKind: String?
    /// L6 — the signals that chose it (signal → value), e.g. ["role": "AXTextArea", "url": "…"].
    public var surfaceSignals: [String: String]?
    /// The field role (FieldRole raw value).
    public var fieldRole: String?
    /// L4 — the write method that landed the text ("ax", "paste", "keystroke", …).
    public var writeMethod: String?
    /// L4 — the readback verdict.
    public var verification: TurnVerification?
    /// L2 / L3 — per-stage milliseconds (stage → ms). Explicit values win over derived ones.
    public var stageMs: [String: Int]?
    /// L2 — the raw text before vocabulary boosting.
    public var preBoostRawText: String?
    /// Key-down / key-up (defaults: `record.startedAt` / `record.capture.captureClosed`).
    public var keyDownAt: Date?
    public var keyUpAt: Date?
    /// H25 — generic outcome keys (`TurnOutcome.write(into:)`): the outcome kind, its reason (a
    /// `NoteReason` raw value or "secure field"), the edit / action label, the intended app.
    public var outcomeKind: String?
    public var outcomeReason: String?
    public var outcomeAction: String?
    public var intendedApp: String?
    /// H25 Recent — the spoken edit command ("Make this formal"), shown as "Edit · <command>".
    public var editCommand: String?
    /// H25 Recent — the hands-free session this piece belongs to; one session is one Recent row.
    public var handsFreeSessionID: String?
    /// H12 — the selection edit's facts (route, command id, selection length, outcome, model; no text).
    public var edit: EditOutcomeRecord?

    public init(surfaceKind: String? = nil, surfaceSignals: [String: String]? = nil, fieldRole: String? = nil,
                writeMethod: String? = nil, verification: TurnVerification? = nil, stageMs: [String: Int]? = nil,
                preBoostRawText: String? = nil, keyDownAt: Date? = nil, keyUpAt: Date? = nil) {
        self.surfaceKind = surfaceKind; self.surfaceSignals = surfaceSignals; self.fieldRole = fieldRole
        self.writeMethod = writeMethod; self.verification = verification; self.stageMs = stageMs
        self.preBoostRawText = preBoostRawText; self.keyDownAt = keyDownAt; self.keyUpAt = keyUpAt
    }

    /// H25 — the outcome a producer recorded here, if any.
    public var recordedOutcome: TurnOutcome? { TurnOutcome.recorded(in: self) }

    public var isEmpty: Bool { self == TurnRecordExtras() }

    /// Adds one stage timing (negative clamps to 0).
    public mutating func setStage(_ stage: String, ms: Int) {
        var all = stageMs ?? [:]
        all[stage] = max(0, ms)
        stageMs = all
    }

    /// Stage names the store derives from `TurnRecord.capture` when no lane set them.
    public enum Stage {
        public static let captureOpen = "capture_open"
        public static let speech = "speech"
        public static let finalPass = "final_pass"
        public static let recognisedToTyped = "recognised_to_typed"
        /// N8 — the one pre-write check (focus, window, password field), including any pull-back.
        public static let preWriteCheck = "pre_write_check"
        /// N7 — context gathering at landing (augmenters over the turn snapshot + field read).
        public static let context = "context"
        /// Owner decision — raising and re-focusing the key-down window.
        public static let pullBack = "pull_back"
    }

    /// What the columns hold: the explicit values, completed from the record.
    public func resolved(for record: TurnRecord) -> TurnRecordExtras {
        var out = self
        if out.fieldRole == nil { out.fieldRole = record.destination.role }
        if out.verification == nil { out.verification = TurnVerification.from(record.outcome) }
        if out.writeMethod == nil {
            switch record.outcome {
            case .delivered(_, let method)?, .partial(let method)?: out.writeMethod = method
            default: break
            }
        }
        if out.keyDownAt == nil { out.keyDownAt = record.startedAt }
        if out.keyUpAt == nil { out.keyUpAt = record.capture.captureClosed }
        let c = record.capture
        func ms(_ a: Date?, _ b: Date?) -> Int? {
            guard let a, let b else { return nil }
            return max(0, Int((b.timeIntervalSince(a) * 1000).rounded()))
        }
        var derived: [String: Int] = [:]
        derived[Stage.captureOpen] = ms(record.startedAt, c.captureOpened)
        derived[Stage.speech] = ms(c.captureOpened, c.captureClosed)
        derived[Stage.finalPass] = ms(c.captureClosed, c.finalPublished)
        derived[Stage.recognisedToTyped] = ms(c.finalPublished, c.writeDispatched)
        let merged = derived.merging(out.stageMs ?? [:]) { _, explicit in explicit }
        out.stageMs = merged.isEmpty ? nil : merged
        return out
    }
}

extension TurnStore {
    /// The readable columns T-schema adds to `turn_records` (name, SQLite type).
    static let extraColumns: [(String, String)] = [
        ("surface_kind", "TEXT"), ("surface_signals_json", "TEXT"), ("field_role", "TEXT"),
        ("write_method", "TEXT"), ("verification", "TEXT"), ("stage_ms_json", "TEXT"),
        ("pre_boost_raw_text", "TEXT"), ("key_down_at", "DOUBLE"), ("key_up_at", "DOUBLE"),
        ("extras_json", "TEXT"),
    ]

    static func json<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
