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

    /// N11 — this turn's candidates: snapshot terms (start app only) + the shell lexicon on a terminal.
    public func candidates(now: Date = Date()) -> [ContextCandidate] {
        var out: [ContextCandidate] = []
        if let snapshot, case .contents(let contents?) = snapshot.lookup(frontmost: nil) {
            out += contents.candidates().map(Self.candidate)
        }
        if let r = current(), r.surface.kind == .terminal, let shell = r.shell {
            out += ContextCandidates.shell(shell, observedAt: now)
        }
        return out
    }

    /// N13 — the landing's stage context gains the turn's shell (terminal surfaces only), and the
    /// shell-decided surface when the field alone could not tell.
    public func augment(_ ctx: StageContext, bundleID: String?) -> StageContext {
        guard let r = current() else { return ctx }
        return Self.write(r, into: ctx, bundleID: bundleID)
    }

    // MARK: - Pure parts (tests)

    static func resolve(app: FocusSnapshot, field: FieldContext?, shell: () -> ShellContext?) -> Resolved {
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
