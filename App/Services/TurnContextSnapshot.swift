import Actions
import Engine
import Foundation
import Injection
import Shared

// MARK: - N7 — one bounded context snapshot per turn
//
// Started at key-down (while the user speaks), tied to the app and window the turn started in,
// cut off by a hard ~250 ms budget, read once and shared by every consumer that wants screen
// context (biasing harvest, deixis, cleanup prompt, the N9 resolver, L1's rubric). Thrown away on
// an app switch, on landing and when it goes idle. No read at all when the app's "contextual
// reading" rule is off. Screen text is data, never instructions.

/// The app/window a turn snapshot is bound to.
public struct TurnContextTarget: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    public var window: AXWindowID?
    public init(pid: Int32, bundleID: String, window: AXWindowID? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.window = window
    }
}

/// E2 — the typed candidate classes the rubric scores.
public enum SnapshotTermKind: String, Sendable, Codable, CaseIterable {
    case name, file, tech, link, word
}

/// Where in the snapshot a candidate came from (the rubric maps this to a source weight).
public enum SnapshotTermSource: String, Sendable, Codable, CaseIterable {
    case title, visible, documentTail, artifact
}

/// One typed screen-term candidate for L1's rubric (E2): text, class, source, salience, distance
/// (tree depth; 0 = window title) and freshness (`observedAt`).
public struct SnapshotTermCandidate: Equatable, Sendable {
    public var text: String
    public var kind: SnapshotTermKind
    public var source: SnapshotTermSource
    public var salience: Double
    public var distance: Int
    public var observedAt: Date
    public init(text: String, kind: SnapshotTermKind, source: SnapshotTermSource, salience: Double,
                distance: Int, observedAt: Date) {
        self.text = text; self.kind = kind; self.source = source
        self.salience = salience; self.distance = distance; self.observedAt = observedAt
    }
}

/// What one bounded read produced.
public struct TurnContextContents: Sendable {
    public var target: TurnContextTarget
    public var content: WindowContent
    public var documentTail: String?
    public var startedAt: Date
    public var readMs: Int

    public init(target: TurnContextTarget, content: WindowContent, documentTail: String? = nil,
                startedAt: Date, readMs: Int) {
        self.target = target; self.content = content; self.documentTail = documentTail
        self.startedAt = startedAt; self.readMs = readMs
    }

    public var interrupted: Bool { content.interrupted }

    /// Biasing source (same shape `AXReaderWindowText.visibleStrings` always produced): title at full
    /// salience, body blocks decaying with depth, then the bounded document tail.
    public func visibleStrings(maxBlocks: Int = 200, tailSalience: Double = 0.5) -> [(String, Double)] {
        var out: [(String, Double)] = []
        if let title = content.title, !title.isEmpty { out.append((title, 1.0)) }
        for block in content.blocks.prefix(maxBlocks) where !block.text.isEmpty {
            out.append((block.text, max(0.4, 1.0 - Double(block.depth) * 0.08)))
        }
        if let documentTail, !documentTail.isEmpty { out.append((documentTail, tailSalience)) }
        return out
    }

    /// Referent artifacts (same heuristic as `AXReferentContext.visibleArtifacts`).
    public func visibleArtifacts(maxBlocks: Int = 80) -> [VisibleArtifact] {
        var out: [VisibleArtifact] = []
        if let title = content.title, !title.isEmpty {
            out.append(VisibleArtifact(title: title, kind: .window, salience: 1.0))
        }
        for block in content.blocks.prefix(maxBlocks) {
            let line = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.count <= 120 else { continue }
            if let kind = AXReferentContext.artifactKind(for: line, role: block.role) {
                out.append(VisibleArtifact(title: line, kind: kind, salience: max(0.3, 1.0 - Double(block.depth) * 0.1)))
            }
        }
        return out
    }

    public func windowText(limit: Int = 2000) -> String? {
        let text = content.text
        return text.isEmpty ? nil : String(text.prefix(limit))
    }

    /// E2 — typed candidates, deduplicated case-insensitively (highest salience wins), capped.
    public func candidates(cap: Int = 150) -> [SnapshotTermCandidate] {
        let at = content.readAt
        var best: [String: SnapshotTermCandidate] = [:]
        func add(_ text: String, _ source: SnapshotTermSource, _ salience: Double, _ distance: Int) {
            for (term, strength) in EntityExtractor.extractWeighted(from: text, maxTerms: 400) {
                let c = SnapshotTermCandidate(text: term, kind: Self.classify(term), source: source,
                                              salience: salience * strength, distance: distance, observedAt: at)
                let key = term.lowercased()
                if let old = best[key], old.salience >= c.salience { continue }
                best[key] = c
            }
        }
        if let title = content.title, !title.isEmpty { add(title, .title, 1.0, 0) }
        for artifact in visibleArtifacts() where artifact.kind != .window {
            let c = SnapshotTermCandidate(text: artifact.title, kind: artifact.kind == .link ? .link : .file,
                                          source: .artifact, salience: artifact.salience, distance: 1, observedAt: at)
            let key = artifact.title.lowercased()
            if (best[key]?.salience ?? -1) < c.salience { best[key] = c }
        }
        for block in content.blocks.prefix(200) where !block.text.isEmpty {
            add(block.text, .visible, max(0.4, 1.0 - Double(block.depth) * 0.08), block.depth)
        }
        if let documentTail, !documentTail.isEmpty { add(documentTail, .documentTail, 0.5, Int.max / 2) }
        return best.values
            .sorted { $0.salience != $1.salience ? $0.salience > $1.salience : $0.text < $1.text }
            .prefix(max(0, cap)).map { $0 }
    }

    private static let fileExtensions: Set<String> = [
        "key", "ppt", "pptx", "xls", "xlsx", "csv", "numbers", "png", "jpg", "jpeg", "gif", "heic", "svg", "pdf",
        "doc", "docx", "pages", "md", "txt", "rtf", "swift", "py", "js", "ts", "tsx", "jsx", "json", "yml", "yaml",
        "sh", "rb", "go", "rs", "c", "h", "m", "cpp", "java", "kt", "html", "css", "toml", "lock", "zip", "dmg",
    ]
    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "app", "co", "in", "uk", "de", "edu", "gov", "me", "so", "xyz",
    ]

    /// E2 term classes: link, file, tech, name, word.
    public static func classify(_ term: String) -> SnapshotTermKind {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || t.contains("@") && t.contains(".") { return .link }
        let ext = (lower as NSString).pathExtension
        if !t.contains(" ") {
            if lower.contains("."), topLevelDomains.contains(ext), !fileExtensions.contains(ext) { return .link }
            if !ext.isEmpty, fileExtensions.contains(ext) { return .file }
            if t.contains("/") || t.hasPrefix("~") { return .file }
        }
        let letters = t.filter(\.isLetter)
        let hasDigit = t.contains(where: \.isNumber)
        let hasSymbol = t.contains { "_-.:#$=<>{}()[]".contains($0) }
        let innerCaps = t.dropFirst().contains(where: \.isUppercase) && t.contains(where: \.isLowercase) && !t.contains(" ")
        let allCaps = letters.count >= 2 && letters == letters.uppercased() && !t.contains(" ")
        if hasSymbol || innerCaps || allCaps || (hasDigit && !letters.isEmpty) { return .tech }
        let words = t.split(separator: " ")
        if !words.isEmpty, words.count <= 3,
           words.allSatisfy({ w in w.first?.isUppercase == true && w.allSatisfy { $0.isLetter || $0 == "'" } }) {
            return .name
        }
        return .word
    }
}

/// The bounded reader behind a snapshot (the AX implementation below; mocks in tests).
public protocol TurnContextReading: AnyObject {
    /// Reads the target's window under `deadline`, checking `cancellation` per node.
    func read(target: TurnContextTarget, deadline: Date, cancellation: AXReadCancellation) -> TurnContextContents?
}

/// Production reader: visible text of the start window (≈800 nodes), then — budget permitting —
/// the document tail (2 k chars), both under the same deadline, through the shared cached reader
/// (so a concurrent walk of the same window is joined, never duplicated).
public final class AXTurnContextReader: TurnContextReading {
    private let reader: AXReading
    public var maxNodes = 800
    public var maxCharacters = 50_000
    public var documentTailCharacters = 2_000
    private let enableAccessibility: ((Int32) -> Void)?

    public init(reader: AXReading, enableAccessibility: ((Int32) -> Void)? = nil) {
        self.reader = reader
        self.enableAccessibility = enableAccessibility
    }

    public func read(target: TurnContextTarget, deadline: Date, cancellation: AXReadCancellation) -> TurnContextContents? {
        let started = Date()
        enableAccessibility?(target.pid)
        let visible = AXReadOptions(limits: .turnSnapshot(deadline: deadline, maxNodes: maxNodes, maxCharacters: maxCharacters),
                                    cancellation: cancellation)
        let content: WindowContent
        do {
            if let window = target.window { content = try reader.readWindow(window, options: visible) }
            else { content = try reader.readFocusedWindow(pid: target.pid, options: visible) }
        } catch { return nil }
        var tail: String?
        if !content.interrupted, documentTailCharacters > 0, Date() < deadline, !cancellation.isCancelled {
            var limits = AXReadLimits.turnSnapshot(deadline: deadline, maxNodes: maxNodes, maxCharacters: documentTailCharacters)
            limits.maxCharacters = documentTailCharacters
            let options = AXReadOptions(includeScrollback: true, limits: limits, truncation: .keepTail, cancellation: cancellation)
            if let doc = try? reader.readWindow(content.window, options: options), !doc.interrupted {
                let text = doc.text
                if !text.isEmpty { tail = text.count > documentTailCharacters ? String(text.suffix(documentTailCharacters)) : text }
            }
        }
        var bound = target
        bound.window = content.window
        return TurnContextContents(target: bound, content: content, documentTail: tail, startedAt: started,
                                   readMs: Int(Date().timeIntervalSince(started) * 1000))
    }
}

/// N7 — the per-turn snapshot. Thread-safe; `start` never blocks the caller.
public final class TurnContextSnapshot: @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case reading
        case ready
        /// No read was made (contextual reading off, own process, no reader).
        case skipped(String)
        /// Thrown away mid-turn (app switch, cancel): consumers get nothing, never a live read.
        case discarded(String)
    }

    /// What a consumer gets.
    public enum Lookup {
        /// No turn is in progress: the caller may do its own (bounded) read.
        case noTurn
        /// A turn is in progress; this is everything it read (nil = nothing / not allowed).
        case contents(TurnContextContents?)
    }

    /// Timing/size of the last read, for logs and the Q13 row.
    public struct Stats: Equatable, Sendable {
        public var readMs: Int
        public var nodes: Int
        public var interrupted: Bool
        public var timedOutWaiting: Bool
    }

    public var budget: TimeInterval = 0.25
    /// A consumer waits at most until `start + budget + landingSlack` for the read to finish.
    public var landingSlack: TimeInterval = 0.15
    /// A snapshot older than this is idle (a turn never ended): treated as no turn.
    public var maxAge: TimeInterval = 180

    private let reader: TurnContextReading?
    private let contextualReading: (String) -> Bool
    private let now: () -> Date
    private let cond = NSCondition()

    private var generation = 0
    private var phase: Phase = .idle
    private var target: TurnContextTarget?
    private var startedAt: Date?
    private var result: TurnContextContents?
    private var cancellation: AXReadCancellation?
    /// Windows with a walk still running (a stuck walk from an earlier turn blocks a second one).
    private var walking: Set<Int32> = []
    public private(set) var lastStats: Stats?
    /// Reads actually started (test hook: "no read when contextual reading is off").
    public private(set) var readsStarted = 0

    public init(reader: TurnContextReading?,
                contextualReading: @escaping (String) -> Bool = { ContextualReadingRule.allows($0) },
                now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.contextualReading = contextualReading
        self.now = now
    }

    public var currentPhase: Phase { cond.lock(); defer { cond.unlock() }; return phase }
    public var currentTarget: TurnContextTarget? { cond.lock(); defer { cond.unlock() }; return target }

    /// Key-down. Binds the turn to `app`/`window`, and — only when the app's contextual-reading rule
    /// allows it — starts one bounded read in the background. Returns whether a read started.
    @discardableResult
    public func start(app: FocusSnapshot?, window: AXWindowID? = nil) -> Bool {
        cond.lock()
        cancellation?.cancel()
        generation += 1
        let gen = generation
        result = nil
        startedAt = now()
        guard let app else {
            target = nil; phase = .skipped("noApp"); cond.broadcast(); cond.unlock(); return false
        }
        let bound = TurnContextTarget(pid: app.pid, bundleID: app.bundleID, window: window)
        target = bound
        if OwnProcess.owns(app) { phase = .skipped("ownProcess"); cond.broadcast(); cond.unlock(); return false }
        guard let reader else { phase = .skipped("noReader"); cond.broadcast(); cond.unlock(); return false }
        // The privacy rule is checked *before* any read (F4).
        guard contextualReading(app.bundleID) else {
            phase = .skipped("contextualReadingOff"); cond.broadcast(); cond.unlock(); return false
        }
        guard !walking.contains(app.pid) else {
            phase = .skipped("walkInFlight"); cond.broadcast(); cond.unlock(); return false
        }
        let token = AXReadCancellation()
        cancellation = token
        phase = .reading
        walking.insert(app.pid)
        readsStarted += 1
        let deadline = startedAt!.addingTimeInterval(budget)
        cond.unlock()

        // A dedicated thread per turn: a stuck AX call can never starve GCD, and a busy GCD pool can
        // never delay the key-down read.
        let thread = Thread { [weak self] in
            let contents = reader.read(target: bound, deadline: deadline, cancellation: token)
            guard let self else { return }
            self.cond.lock()
            self.walking.remove(bound.pid)
            if gen == self.generation, self.phase == .reading {
                self.result = contents
                self.phase = .ready
                if let contents {
                    self.target?.window = contents.content.window
                    self.lastStats = Stats(readMs: contents.readMs, nodes: contents.content.nodesVisited,
                                           interrupted: contents.interrupted, timedOutWaiting: false)
                }
            }
            self.cond.broadcast()
            self.cond.unlock()
            if let contents {
                Log.app.debug("turn context: \(contents.readMs) ms, \(contents.content.nodesVisited) nodes\(contents.interrupted ? ", cut at deadline" : "")")
            }
        }
        thread.name = "voiceplus.turn-context"
        thread.qualityOfService = .userInitiated
        thread.start()
        return true
    }

    /// Landing-time lookup. `frontmost` is the app focused now: a different app than the one the
    /// turn started in discards the snapshot (nothing is read from the wrong app). Waits at most
    /// until `start + budget + landingSlack` for an in-flight read, then gives up (and cancels it).
    public func lookup(frontmost: FocusSnapshot?, bundleID: String? = nil) -> Lookup {
        cond.lock(); defer { cond.unlock() }
        guard let startedAt, phase != .idle else { return .noTurn }
        if now().timeIntervalSince(startedAt) > maxAge { resetLocked(); return .noTurn }
        if case .discarded = phase { return .contents(nil) }
        if case .skipped = phase { return .contents(nil) }
        if let target, let frontmost, !OwnProcess.owns(frontmost), frontmost.pid != target.pid {
            discardLocked("appChanged")
            return .contents(nil)
        }
        if let target, let bundleID, !bundleID.isEmpty, bundleID != target.bundleID {
            discardLocked("appChanged")
            return .contents(nil)
        }
        let until = startedAt.addingTimeInterval(budget + landingSlack)
        while phase == .reading {
            if !cond.wait(until: until), phase == .reading {
                cancellation?.cancel()
                phase = .ready
                result = nil
                lastStats = Stats(readMs: Int(now().timeIntervalSince(startedAt) * 1000), nodes: 0,
                                  interrupted: true, timedOutWaiting: true)
                Log.app.notice("turn context: read still running at the deadline; landing without screen context")
                break
            }
        }
        if case .discarded = phase { return .contents(nil) }
        return .contents(result)
    }

    /// Cancel / empty turn / app switch: throw it away. Consumers get nothing until the next start.
    public func discard(_ reason: String) {
        cond.lock(); discardLocked(reason); cond.broadcast(); cond.unlock()
    }

    /// The turn ended (landed or dropped): back to idle, so non-turn consumers read for themselves.
    public func end() {
        cond.lock(); resetLocked(); cond.broadcast(); cond.unlock()
    }

    private func discardLocked(_ reason: String) {
        guard phase != .idle else { return }
        cancellation?.cancel()
        result = nil
        phase = .discarded(reason)
        Log.app.debug("turn context discarded: \(reason)")
    }

    private func resetLocked() {
        cancellation?.cancel()
        cancellation = nil
        result = nil
        target = nil
        startedAt = nil
        phase = .idle
    }
}

/// N7 verify — open-turn counter behind `AppContainer.begin/endTurnContext`. A latched press can
/// begin turn 2 before turn 1 ends; only the end of the last open turn may reset the snapshot.
public final class TurnContextLease: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    public init() {}
    public var count: Int { lock.withLock { open } }
    public func begin() { lock.withLock { open += 1 } }
    /// Returns true when this end closed the last open turn (the caller resets the snapshot).
    @discardableResult
    public func end() -> Bool {
        lock.withLock { open = max(0, open - 1); return open == 0 }
    }
}
