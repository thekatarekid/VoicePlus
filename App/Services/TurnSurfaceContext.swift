import Engine
import Foundation
import Injection
import Pipeline
import Shared

/// INT-wiring — the turn's surface, shell and context candidates, gathered once off the main
/// thread at key-down and bound to the app the turn started in.
///
/// - N9: the focused field's evidence goes through `SurfaceResolver`; the shell probe (N13 / F26)
///   adds pty evidence only when the field alone is terminal or undecided (an IDE's editor with a
///   terminal tab elsewhere stays a code editor).
/// - N11: `surface()` and `candidates()` feed the context rubric that builds the boost list.
///   Candidates are the N7 snapshot's typed terms (data, never instructions) plus, on a terminal,
///   the shell's commands and the current folder's names.
/// - N13: `augment` writes the `ShellContext` into the run's `StageContext` for the command-line
///   grammar and the path matcher.
///
/// Nothing is persisted. `begin` never blocks; readers wait at most `readyTimeout`.
public final class TurnSurfaceContext: @unchecked Sendable {
    public struct Resolved: Equatable, Sendable {
        public var bundleID: String
        public var pid: Int32
        public var surface: SurfaceResolution
        public var shell: ShellContext?
        /// The shell's pty evidence changed the field-only answer (the run records it upstream).
        public var shellDecided: Bool
        /// H17 — the focused field around the caret, as read at key-down (nil: no field read).
        /// A secure field carries `isSecure` and no text.
        public var nearCaret: NearCaretContext? = nil
    }

    /// H17 — what the focused field shows around the caret, read once at key-down. Data, never
    /// instructions; in memory only (never persisted, never logged as text).
    public struct NearCaretContext: Equatable, Sendable {
        /// Text before the caret, at most `CaretWindow.defaultWindow` UTF-16 units.
        public var before: String
        /// Text after the caret (selection excluded), same window.
        public var after: String
        public var fieldLabel: String?
        public var windowTitle: String?
        public var appName: String
        public var surfaceKind: SurfaceKind
        public var isSecure: Bool

        public init(before: String, after: String, fieldLabel: String? = nil, windowTitle: String? = nil,
                    appName: String = "", surfaceKind: SurfaceKind, isSecure: Bool = false) {
            self.before = before; self.after = after; self.fieldLabel = fieldLabel
            self.windowTitle = windowTitle; self.appName = appName
            self.surfaceKind = surfaceKind; self.isSecure = isSecure
        }

        public var isEmpty: Bool { before.isEmpty && after.isEmpty }
    }

    private let field: (FocusSnapshot) -> FieldContext?
    private let shell: (Int32) -> ShellContext?
    private let snapshot: TurnContextSnapshot?
    private let queue = DispatchQueue(label: "voiceplus.turn-surface", qos: .userInitiated)
    private let cond = NSCondition()
    private var generation = 0
    private var pending = false
    private var resolved: Resolved?
    public var readyTimeout: TimeInterval = 0.35

    /// - Parameters:
    ///   - field: reads the focused field of the app (production: `FieldContextReader`).
    ///   - shell: the focused shell of a terminal app pid (production: `ShellContextProvider`).
    public init(field: @escaping (FocusSnapshot) -> FieldContext?,
                shell: @escaping (Int32) -> ShellContext?,
                snapshot: TurnContextSnapshot?) {
        self.field = field; self.shell = shell; self.snapshot = snapshot
    }

    /// Key-down: resolve on a background queue. `completion` runs there once the answer is ready
    /// — and not at all for a superseded turn, or when there is nothing to resolve (no app, own
    /// process; `isBegun` is then false and the caller prepares as before).
    public func begin(app: FocusSnapshot?, completion: (() -> Void)? = nil) {
        cond.lock()
        generation += 1
        let gen = generation
        resolved = nil
        guard let app, !OwnProcess.owns(app) else {
            pending = false; cond.broadcast(); cond.unlock(); return
        }
        pending = true
        cond.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let value = Self.resolve(app: app, field: self.field(app), shell: { self.shell(app.pid) })
            self.cond.lock()
            let current = gen == self.generation
            if current { self.resolved = value; self.pending = false; self.cond.broadcast() }
            self.cond.unlock()
            if current { completion?() }
        }
    }

    /// The turn ended: readers fall back to "no surface" until the next `begin`.
    public func end() {
        cond.lock(); generation += 1; resolved = nil; pending = false; cond.broadcast(); cond.unlock()
    }

    /// A turn has begun and not ended (never blocks).
    public var isBegun: Bool { cond.lock(); defer { cond.unlock() }; return pending || resolved != nil }

    /// The turn's resolution, waiting at most `readyTimeout` for an in-flight one.
    public func current() -> Resolved? {
        cond.lock(); defer { cond.unlock() }
        let until = Date().addingTimeInterval(readyTimeout)
        while pending { if !cond.wait(until: until) { break } }
        return resolved
    }

    public func surface() -> SurfaceResolution? { current()?.surface }

    /// H17 — the focused field around the caret (nil before key-down's read lands or with no field).
    public func nearCaret() -> NearCaretContext? { current()?.nearCaret }

    /// N11 — this turn's candidates: snapshot terms (start app only, `.screenWindow`, Lab-gated in
    /// the boost) + H17 near-caret field terms (`.screenNear` with caret distance) + the shell
    /// lexicon on a terminal. A secure field gives nothing at all.
    public func candidates(now: Date = Date()) -> [ContextCandidate] {
        let r = current()
        if let r, r.surface.kind == .secure || r.nearCaret?.isSecure == true { return [] }
        var out: [ContextCandidate] = []
        if let near = r?.nearCaret { out += Self.nearCandidates(near, now: now) }
        if let snapshot, case .contents(let contents?) = snapshot.lookup(frontmost: nil) {
            out += contents.candidates().map(Self.candidate)
        }
        if let r, r.surface.kind == .terminal, let shell = r.shell {
            out += ContextCandidates.shell(shell, observedAt: now)
        }
        return out
    }

    /// H17 — near-caret candidates only (the repair stage's evidence).
    public func nearCaretCandidates(now: Date = Date()) -> [ContextCandidate] {
        guard let near = current()?.nearCaret else { return [] }
        return Self.nearCandidates(near, now: now)
    }

    /// N13 — the landing's stage context gains the turn's shell (terminal surfaces only), and the
    /// shell-decided surface when the field alone could not tell.
    public func augment(_ ctx: StageContext, bundleID: String?) -> StageContext {
        guard let r = current() else { return ctx }
        Self.installRepairPhonetics
        return Self.write(r, into: ctx, bundleID: bundleID)
    }

    /// H19 — the repair stage hears with Double Metaphone (installed once, process-wide).
    static let installRepairPhonetics: Void = {
        ContextRepairStage.install(phonetic: TurnSurfaceContext.phoneticCodes)
    }()

    @Sendable static func phoneticCodes(_ word: String) -> [String] {
        let c = DoubleMetaphone.encode(word)
        return [c.primary] + (c.secondary.map { [$0] } ?? [])
    }

    /// H19 — the near-caret terms as the repair stage's evidence (vocabulary only; secure → none).
    static func repairEvidence(_ near: NearCaretContext?, now: Date = Date()) -> ContextRepairEvidence? {
        guard let near else { return nil }
        let terms = nearCandidates(near, now: now).compactMap { c -> ContextRepairEvidence.Term? in
            guard let d = c.caretDistance else { return nil }
            let kind: ContextRepairEvidence.Term.Kind
            if c.text.contains(" "), c.text == c.text.lowercased(), c.heardAliases.isEmpty { kind = .phrase }
            else if c.evidence >= 1 { kind = .entity }
            else { kind = .word }
            return .init(text: c.text, aliases: c.heardAliases, distance: d, kind: kind)
        }
        return terms.isEmpty ? nil : ContextRepairEvidence(terms: terms)
    }

    // MARK: - Pure parts (tests)

    static func resolve(app: FocusSnapshot, field: FieldContext?, shell: () -> ShellContext?) -> Resolved {
        var r = resolveSurface(app: app, field: field, shell: shell)
        r.nearCaret = field.map { near(app: app, field: $0, surface: r.surface) }
        return r
    }

    /// H17 — the near-caret context of `field`. Secure → flagged, no text.
    static func near(app: FocusSnapshot, field: FieldContext, surface: SurfaceResolution) -> NearCaretContext {
        let secure = surface.kind == .secure || field.axSubrole == "AXSecureTextField" || field.axRole == "AXSecureTextField"
        let label = field.hints.first { !$0.isEmpty && !$0.hasPrefix("_") }
        guard !secure else {
            return NearCaretContext(before: "", after: "", fieldLabel: nil, windowTitle: nil, appName: app.appName,
                                    surfaceKind: surface.kind, isSecure: true)
        }
        return NearCaretContext(before: CaretWindow.tail(of: field.textBeforeCursor, window: CaretWindow.defaultWindow),
                                after: CaretWindow.head(of: field.textAfterCursor, window: CaretWindow.defaultWindow),
                                fieldLabel: label, windowTitle: field.documentTitle, appName: app.appName,
                                surfaceKind: surface.kind, isSecure: false)
    }

    static func nearCandidates(_ near: NearCaretContext, now: Date) -> [ContextCandidate] {
        guard !near.isSecure, near.surfaceKind != .secure, !near.isEmpty else { return [] }
        return ContextCandidates.nearCaret(before: near.before, after: near.after, observedAt: now)
    }

    static func resolveSurface(app: FocusSnapshot, field: FieldContext?, shell: () -> ShellContext?) -> Resolved {
        let base = field ?? FieldContext(appBundleID: app.bundleID, caret: .unknown)
        let fieldOnly = base.surface
        // The field already says what it is (and it is not a shell): no process walk.
        if fieldOnly.kind != .terminal, !fieldOnly.isFallback, fieldOnly.confidence >= 0.5 {
            return Resolved(bundleID: app.bundleID, pid: app.pid, surface: fieldOnly, shell: nil, shellDecided: false)
        }
        guard let sh = shell() else {
            return Resolved(bundleID: app.bundleID, pid: app.pid, surface: fieldOnly, shell: nil, shellDecided: false)
        }
        if fieldOnly.kind == .terminal {
            return Resolved(bundleID: app.bundleID, pid: app.pid, surface: fieldOnly, shell: sh, shellDecided: false)
        }
        var evidence = base.surfaceEvidence
        evidence.shell = sh
        let withShell = SurfaceResolver.resolve(evidence)
        return Resolved(bundleID: app.bundleID, pid: app.pid, surface: withShell,
                        shell: withShell.kind == .terminal ? sh : nil,
                        shellDecided: withShell.kind == .terminal)
    }

    static func write(_ r: Resolved, into context: StageContext, bundleID: String?) -> StageContext {
        // Bound to the start app: a landing in another app gets nothing from this turn.
        if let bundleID, !bundleID.isEmpty, bundleID != r.bundleID { return context }
        var ctx = context
        // H19 — near-caret vocabulary for the context repair stage (nothing for a secure field).
        if r.surface.kind != .secure, let evidence = repairEvidence(r.nearCaret) { evidence.write(into: &ctx) }
        guard r.surface.kind == .terminal, let shell = r.shell else { return ctx }
        shell.write(into: &ctx)
        if r.shellDecided { FieldContext.write(r.surface, into: &ctx) }
        return ctx
    }

    static func candidate(_ c: SnapshotTermCandidate) -> ContextCandidate {
        let type: CandidateType
        switch c.kind {
        case .link: type = .link
        case .file: type = .path
        case .tech: type = .techTerm
        case .name: type = .person
        case .word: type = .word
        }
        return ContextCandidate(text: c.text, type: type, source: .screenWindow, observedAt: c.observedAt,
                                evidence: min(1, max(0, c.salience)), onScreenNow: c.source != .documentTail)
    }
}
