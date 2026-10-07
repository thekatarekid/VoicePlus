import Foundation
import Shared

// MARK: - V5 I3 · "Why did it write that?"
//
// Per-turn stage diff: every post-processing stage of a dictation turn (ITN, dictionary, field-role
// formatting, cleanup, style …) is recorded as before → after text, in memory only, for the last
// `TurnTraceRecorder.capacity` (20) turns. The pill / menu "Why did it write that?" sheet reads it.
//
// - No persistence: nothing here is written to disk, the database, the log buffer or the Lab
//   results. Q13 keeps its counts; the cleanup stage's reason code (never text) is attached to the
//   cleanup step as a note.
// - A secure (password) field is never traced: the opening stage sees the field role and drops the
//   turn before anything is kept.
// - Recording wraps each stage in `TracedStage` (the stage id and register scoping are preserved,
//   so `ContractEnforcingStage` treats it exactly as the inner stage). The first wrapped stage opens
//   the turn; one runner runs one turn at a time, so later stages land in the open turn.

/// One stage's effect on the text.
public struct StageDiff: Sendable, Equatable, Identifiable {
    public var id: Int
    public var stage: StageID
    public var before: String
    public var after: String
    /// A reason code the stage reported (cleanup: `accepted`, `rejected:lengthRatio`, `skipped:noCue` …).
    public var note: String?

    public init(id: Int, stage: StageID, before: String, after: String, note: String? = nil) {
        self.id = id
        self.stage = stage
        self.before = before
        self.after = after
        self.note = note
    }

    public var changed: Bool { before != after }
    public var title: String { StageDiff.title(for: stage) }
    /// The four stages the sheet always lists, changed or not (ITN, cleanup, style, field role).
    public var isHeadline: Bool { StageDiff.headline.contains(stage) }

    static let fieldRoleStage: StageID = "formatter.fieldRole"
    static let headline: Set<StageID> = ["itn", "cleanup", "style", fieldRoleStage]

    /// Plain-language name for a stage id.
    public static func title(for stage: StageID) -> String {
        switch stage.rawValue {
        case "itn": return "Numbers, dates and units"
        case "cleanup": return "AI cleanup"
        case "writer.context": return "Context Writer"
        case "style": return "Style"
        case "formatter.fieldRole": return "Field formatting"
        case "formatter.fieldValue": return "Field value"
        case "formatter.email": return "Email formatting"
        case "formatter.chat": return "Chat formatting"
        case "formatter.code": return "Code formatting"
        case "formatter.prose": return "Punctuation and capitals"
        case "formatter.terminal": return "Terminal formatting"
        case "snippet": return "Snippet"
        case "wakeVerb": return "Wake word"
        case "dictionary.replacement": return "Dictionary replacements"
        case "dictionary.casing": return "Dictionary spelling"
        case "dictionary.transliteration": return "Transliteration"
        case "refine.qwen3": return "Second-pass recognition"
        case let id where id.hasPrefix("regressionGuard") || id.hasPrefix("regression"): return "Personal vocabulary"
        default: return stage.rawValue
        }
    }
}

/// One turn: what was heard, what each stage did, what was written.
public struct TurnTrace: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var appBundleID: String?
    public var fieldRole: FieldRole
    public var register: Utterance.Register
    /// The recognizer's text as the first stage received it.
    public var input: String
    public var steps: [StageDiff]

    public init(id: UUID = UUID(), date: Date = Date(), appBundleID: String? = nil, fieldRole: FieldRole = .unknown,
                register: Utterance.Register = .unknown, input: String, steps: [StageDiff] = []) {
        self.id = id
        self.date = date
        self.appBundleID = appBundleID
        self.fieldRole = fieldRole
        self.register = register
        self.input = input
        self.steps = steps
    }

    public var output: String { steps.last?.after ?? input }
    /// Steps that changed the text.
    public var changedSteps: [StageDiff] { steps.filter(\.changed) }
    /// What the sheet lists: every step that changed the text, plus the headline stages that ran
    /// without changing it (so "AI cleanup — no change (skipped: noCue)" is visible).
    public var explainedSteps: [StageDiff] { steps.filter { $0.changed || $0.isHeadline } }
}

/// In-memory ring of the last 20 turns.
public final class TurnTraceRecorder: @unchecked Sendable {
    public static let capacity = 20
    /// The app's recorder (the pipeline wrapper writes, the menu/sheet reads).
    public static let shared = TurnTraceRecorder()

    private let lock = NSLock()
    private var turns: [TurnTrace] = []      // oldest first
    private var openID: UUID?
    private var pendingNotes: [StageID: String] = [:]
    private let limit: Int
    private let now: @Sendable () -> Date
    /// Called (on the recording thread) whenever a turn is opened or a step lands.
    public var onChange: (@Sendable () -> Void)?

    public init(capacity: Int = TurnTraceRecorder.capacity, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = max(1, capacity)
        self.now = now
    }

    /// Newest first.
    public var recent: [TurnTrace] { lock.withLock { Array(turns.reversed()) } }
    public var latest: TurnTrace? { lock.withLock { turns.last } }
    public func trace(id: UUID) -> TurnTrace? { lock.withLock { turns.first { $0.id == id } } }

    /// Opens a turn. The oldest turn beyond the capacity is forgotten.
    @discardableResult
    public func begin(input: String, context: StageContext) -> UUID {
        let id = UUID()
        let turn = TurnTrace(id: id, date: now(), appBundleID: context.appBundleID,
                             fieldRole: FieldRole.classify(FieldContext(stageContext: context)),
                             register: context.register, input: input)
        lock.withLock {
            turns.append(turn)
            if turns.count > limit { turns.removeFirst(turns.count - limit) }
            openID = id
            pendingNotes = [:]
        }
        onChange?()
        return id
    }

    /// Stops recording into the open turn (a secure field) and forgets it.
    public func discardOpen() {
        lock.withLock {
            if let id = openID { turns.removeAll { $0.id == id } }
            openID = nil
            pendingNotes = [:]
        }
    }

    /// Appends one step to the open turn; ignored when no turn is open.
    public func record(stage: StageID, before: String, after: String) {
        let changed: Bool = lock.withLock {
            guard let id = openID, let i = turns.lastIndex(where: { $0.id == id }) else { return false }
            let note = pendingNotes.removeValue(forKey: stage)
            turns[i].steps.append(StageDiff(id: turns[i].steps.count, stage: stage, before: before, after: after, note: note))
            return true
        }
        if changed { onChange?() }
    }

    /// A reason code from inside a stage (reported before the step itself lands). Codes only.
    public func note(stage: StageID, code: String) {
        lock.withLock {
            guard openID != nil else { return }
            pendingNotes[stage] = String(code.prefix(60))
        }
    }

    public func clear() {
        lock.withLock { turns = []; openID = nil; pendingNotes = [:] }
        onChange?()
    }
}

/// Records one stage's before/after into a recorder. Same id as the wrapped stage.
public struct TracedStage: PipelineStage {
    public let inner: any PipelineStage
    public let recorder: TurnTraceRecorder
    /// The first stage of the chain opens a new turn.
    public let opensTurn: Bool
    public var id: StageID { inner.id }

    public init(_ inner: any PipelineStage, recorder: TurnTraceRecorder, opensTurn: Bool) {
        self.inner = inner
        self.recorder = recorder
        self.opensTurn = opensTurn
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        if opensTurn {
            if FieldRole.classify(FieldContext(stageContext: context)) == .secure {
                recorder.discardOpen()
            } else {
                recorder.begin(input: spans.renderedText, context: context)
            }
        }
        let out = try await inner.process(spans, context: context)
        recorder.record(stage: id, before: spans.renderedText, after: out.renderedText)
        return out
    }

    /// Wraps every stage; the first one opens the turn. Register scoping is kept.
    public static func wrapping(_ stages: [any PipelineStage], recorder: TurnTraceRecorder) -> [any PipelineStage] {
        stages.enumerated().map { i, stage in
            let traced = TracedStage(stage, recorder: recorder, opensTurn: i == 0)
            if let scoped = stage as? any RegisterScopedStage {
                return TracedScopedStage(traced: traced, applicableRegisters: scoped.applicableRegisters)
            }
            return traced
        }
    }
}

/// `TracedStage` over a `RegisterScopedStage`, so the runner still skips it by register.
public struct TracedScopedStage: RegisterScopedStage {
    public let traced: TracedStage
    public let applicableRegisters: Set<Utterance.Register>
    public var id: StageID { traced.id }
    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        try await traced.process(spans, context: context)
    }
}

// MARK: - Word diff for the sheet

/// Grouped runs of the Transform `WordDiff` (LCS on words) for display: kept / removed / added.
public enum StageDiffText {
    public enum Kind: Sendable, Equatable { case kept, removed, added }
    public struct Piece: Sendable, Equatable {
        public var kind: Kind
        public var text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }

    public static func pieces(before: String, after: String) -> [Piece] {
        // Bounded: a very long turn shows as "all removed, all added" instead of an O(n·m) table.
        let words = { (s: String) in s.split(whereSeparator: \.isWhitespace).count }
        guard words(before) * words(after) <= 250_000 else {
            return [Piece(.removed, before), Piece(.added, after)].filter { !$0.text.isEmpty }
        }
        var out: [Piece] = []
        func push(_ kind: Kind, _ word: String) {
            if let last = out.last, last.kind == kind { out[out.count - 1].text += " " + word }
            else { out.append(Piece(kind, word)) }
        }
        for op in WordDiff.compute(old: before, new: after).ops {
            switch op {
            case .equal(let w): push(.kept, w)
            case .delete(let w): push(.removed, w)
            case .insert(let w): push(.added, w)
            }
        }
        return out
    }
}
