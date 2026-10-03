import Actions
import ApplicationServices
import Engine
import Foundation
import Injection
import Shared

/// P3.4 integration — `AXWindowReader`/`WindowContentCache` (via `SystemAccess`'s `AXReaderProviding`)
/// feeding Biasing's `ContextHarvester` and the transform/pipeline context.
///
/// One `AXReading` instance is captured at init so `LiveSystemAccess`'s `CachedAXReader`
/// (2 s TTL + observer invalidation) is actually shared across harvests.
public final class AXReaderWindowText: FocusedWindowTextProvider, @unchecked Sendable {
    private let system: SystemAccess
    private let reader: AXReading?
    public var maxBlocks = 200

    public init(system: SystemAccess) {
        self.system = system
        self.reader = (system as? AXReaderProviding)?.axReader
    }

    /// N7 — the turn's bounded snapshot. While a turn is in progress every read below is served
    /// from it (bound to the turn's starting app/window, ~250 ms budget); nothing is walked live.
    public var snapshot: TurnContextSnapshot?
    /// N7 — budget for a read made outside a turn (act stack, agent, settings previews).
    public var liveBudget: TimeInterval = 0.25
    public var liveMaxNodes = 800

    private enum Source { case turn(TurnContextContents?), live }

    private func source() -> Source {
        guard let snapshot else { return .live }
        switch snapshot.lookup(frontmost: system.frontmostApp()) {
        case .noTurn: return .live
        case .contents(let contents): return .turn(contents)
        }
    }

    /// Focused-window content, visible portion only: the turn snapshot during a turn, otherwise a
    /// bounded live read (deadline + node cap) of the frontmost app.
    public func content() -> WindowContent? {
        switch source() {
        case .turn(let contents): return contents?.content
        case .live: return liveContent()
        }
    }

    private func liveContent() -> WindowContent? {
        guard let reader, let front = system.frontmostApp() else { return nil }
        guard !OwnProcess.owns(front) else { return nil }
        guard ContextualReadingRule.allows(front.bundleID) else { return nil }
        // Q2 / E1 — Electron and Chromium build their AX tree only when asked (cached per pid).
        (system as? AppAccessibilityEnabling)?.enableAppAccessibility(pid: front.pid)
        let options = AXReadOptions(limits: .turnSnapshot(deadline: Date().addingTimeInterval(liveBudget), maxNodes: liveMaxNodes,
                                                          maxCharacters: 50_000))
        return try? reader.readFocusedWindow(pid: front.pid, options: options)
    }

    /// V5 E1 — how much of the document behind the visible part is read: the **tail**, bounded.
    /// A thread / document / terminal's latest text is what an utterance is most likely about.
    public var documentTailCharacters = 2_000
    /// Salience of the document tail (below the visible body: it is off screen).
    public var documentTailSalience = 0.5

    /// V5 E1 — the focused window's document text, scrollback included, keeping only the last
    /// `limit` characters. During a turn this is the snapshot's tail (never a second walk).
    /// `nil` when there is no reader or nothing to read.
    public func documentTail(of window: AXWindowID, limit: Int? = nil) -> String? {
        let cap = max(0, limit ?? documentTailCharacters)
        guard cap > 0 else { return nil }
        if case .turn(let contents) = source() {
            guard let tail = contents?.documentTail, contents?.content.window == window else { return nil }
            return tail.count > cap ? String(tail.suffix(cap)) : tail
        }
        guard let reader else { return nil }
        var limits = AXReadLimits.turnSnapshot(deadline: Date().addingTimeInterval(liveBudget), maxNodes: liveMaxNodes)
        limits.maxCharacters = cap
        let options = AXReadOptions(includeScrollback: true, limits: limits, truncation: .keepTail)
        guard let document = try? reader.readWindow(window, options: options), !document.interrupted else { return nil }
        let text = document.text
        guard !text.isEmpty else { return nil }
        return text.count > cap ? String(text.suffix(cap)) : text
    }

    /// Biasing source: title at full salience, body blocks decaying with tree depth, then (E1) the
    /// bounded document tail. Electron apps answer here because the read enables their AX tree
    /// first (Q2).
    public func visibleStrings() -> [(String, Double)] {
        switch source() {
        case .turn(let contents):
            return contents?.visibleStrings(maxBlocks: maxBlocks, tailSalience: documentTailSalience) ?? []
        case .live:
            guard let content = liveContent() else { return [] }
            let tail = documentTail(of: content.window)
            return TurnContextContents(target: TurnContextTarget(pid: content.window.pid, bundleID: ""), content: content,
                                       documentTail: tail, startedAt: content.readAt, readMs: 0)
                .visibleStrings(maxBlocks: maxBlocks, tailSalience: documentTailSalience)
        }
    }

    /// N7 / E2 — typed screen-term candidates for the rubric (snapshot during a turn).
    public func candidates(cap: Int = 150) -> [SnapshotTermCandidate] {
        switch source() {
        case .turn(let contents): return contents?.candidates(cap: cap) ?? []
        case .live:
            guard let content = liveContent() else { return [] }
            return TurnContextContents(target: TurnContextTarget(pid: content.window.pid, bundleID: ""), content: content,
                                       startedAt: content.readAt, readMs: 0).candidates(cap: cap)
        }
    }

    /// Flattened window text for `StageContext.extra` (transform / pipeline prompts).
    public func windowText(limit: Int = 2000) -> String? {
        guard let content = content() else { return nil }
        let text = content.text
        return text.isEmpty ? nil : String(text.prefix(limit))
    }
}

/// P3.5 integration — conversational referents ("her", "the deck") out of the AX window
/// content + the contacts store. Heuristic on purpose: titles that look like artifacts become
/// `VisibleArtifact`s; contact names become `Participant`s (gender unknown, so pronouns bind
/// only when a single candidate stands out — ambiguity falls to elicitation/clarifying text).
public final class AXReferentContext: ParticipantProviding, ArtifactProviding {
    private let text: AXReaderWindowText
    private let contacts: ContactsProvider?
    public var maxParticipants = 50

    public init(text: AXReaderWindowText, contacts: ContactsProvider? = nil) {
        self.text = text
        self.contacts = contacts
    }

    public func participants() -> ContextParticipants {
        guard let names = contacts?.contactNames(), !names.isEmpty else { return ContextParticipants() }
        return ContextParticipants(names.prefix(maxParticipants).map { Participant(name: $0, salience: 0.5) })
    }

    public func visibleArtifacts() -> [VisibleArtifact] {
        guard let content = text.content() else { return [] }
        return TurnContextContents(target: TurnContextTarget(pid: content.window.pid, bundleID: ""), content: content,
                                   startedAt: content.readAt, readMs: 0).visibleArtifacts()
    }

    static func artifactKind(for text: String, role: String) -> ArtifactKind? {
        switch (text.lowercased() as NSString).pathExtension {
        case "key", "ppt", "pptx": return .deck
        case "xls", "xlsx", "csv", "numbers": return .spreadsheet
        case "png", "jpg", "jpeg", "gif", "heic", "svg": return .image
        case "pdf", "doc", "docx", "pages", "md", "txt", "rtf": return .document
        case "swift", "py", "js", "ts", "json", "yml", "yaml", "sh": return .file
        default: break
        }
        if role == "AXLink" { return .link }
        return nil
    }
}

// MARK: - V5 B2 + E1 — ranked context into the cleanup prompt

/// The lander's augmenter step that puts the utterance's ranked-context prompt into
/// `StageContext.extra[ContextPromptKeys.prompt]` for D2's cleanup stage.
///
/// Runs **after** `AppRules.applying` so the destination app's rule is already known: with
/// contextual reading off for that app nothing is harvested at all (the key is removed and the
/// session is not rebuilt), the same promise `AppRule.apply` makes for the window text.
public enum ContextPromptAugmenter {
    public static func applying(
        after base: @escaping ([TranscriptSpan], StageContext) -> StageContext,
        session: ContextPromptSession,
        contextualReading: @escaping (String?) -> Bool = { ContextualReadingRule.allows($0) },
        now: @escaping () -> Date = Date.init
    ) -> ([TranscriptSpan], StageContext) -> StageContext {
        { spans, context in
            var ctx = base(spans, context)
            guard contextualReading(ctx.appBundleID) else {
                ctx.extra.removeValue(forKey: ContextPromptKeys.prompt)
                return ctx
            }
            session.write(into: &ctx, now: now())
            return ctx
        }
    }
}

/// N7 — the per-app "contextual reading" rule, checked before any screen read.
public enum ContextualReadingRule {
    public static func allows(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return AppRules.current().resolved(for: bundleID).contextualReading.value
    }
}

/// H21 — the outward-from-caret read over real `AXUIElement`s: the focused element of `pid` and its
/// parents. Own process refused (AXGuard); every call returns nil/empty when an app does not answer.
public final class LiveCaretNeighbourhoodAccess: CaretNeighbourhoodAccess {
    public init() {}

    public func focusedElement(pid: Int32) -> AXNodeRef? {
        guard AXIsProcessTrusted(), let app = AXGuard.application(pid: pid),
              let v = copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return ref(v as! AXUIElement)
    }

    public func parent(of node: AXNodeRef) -> AXNodeRef? {
        guard let e = element(node), let v = copy(e, kAXParentAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return ref(v as! AXUIElement)
    }

    public func children(of node: AXNodeRef) -> [AXNodeRef] {
        guard let e = element(node) else { return [] }
        return (copy(e, kAXChildrenAttribute) as? [AXUIElement] ?? []).map(ref)
    }

    public func role(of node: AXNodeRef) -> String {
        element(node).flatMap { copy($0, kAXRoleAttribute) as? String } ?? "unknown"
    }

    public func subrole(of node: AXNodeRef) -> String? {
        element(node).flatMap { copy($0, kAXSubroleAttribute) as? String }
    }

    public func text(of node: AXNodeRef) -> String? {
        guard let e = element(node) else { return nil }
        if let v = copy(e, kAXValueAttribute) as? String, !v.isEmpty { return v }
        return copy(e, kAXTitleAttribute) as? String
    }

    private func ref(_ e: AXUIElement) -> AXNodeRef { AXNodeRef(id: String(CFHash(e)), raw: e) }

    private func element(_ node: AXNodeRef) -> AXUIElement? {
        guard let raw = node.raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (raw as! AXUIElement)
    }

    private func copy(_ e: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
    }
}
