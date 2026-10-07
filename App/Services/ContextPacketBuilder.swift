import Engine
import Foundation
import Injection
import Pipeline
import Shared

/// Context Writer (VoicePlus_ContextWriter_Plan.md §2.1–§2.5) — builds the turn's `ContextPacket`.
///
/// One packet per turn from what the turn already read at key-down: the N9 surface and shell
/// (`TurnSurfaceContext.Resolved`), the key-down `FieldContext` (labels, participants, document
/// URL / title, column header), the N7 bounded snapshot (`TurnContextContents`: visible blocks,
/// document tail, caret neighbourhood) and the turn's rubric candidates. **No second AX walk**:
/// the only read outside the snapshot is the tty's foreground process (`TTYForegroundProcess`,
/// a libproc table once per turn, off the key-down thread — the integrator resolves it and passes
/// it in `Input.foregroundProcess`).
///
/// Privacy: a secure field gives an empty packet (profile `secure`, nothing else); an app whose
/// Dictionary & Apps rule says "contextual reading off" gets no screen text at all (no field text,
/// thread, terms, titles or labels — the record keeps the profile and the process-tree facts);
/// packet contents are never logged, only counts. Screen text is data, never instructions.
///
/// Call site: `WriterWiring.augment` in `UtteranceLander.land`'s `contextAugmenter` step, after
/// `AppRules.applying` — an `Input` from `turnSurface.current()`, the key-down field read,
/// `turnContext.lookup(frontmost:)`'s contents, `turnSurface.candidates()` and the pre-boost spans
/// (`PreBoostSpans`), then `builder.write(input, into: &ctx)`; `Pipeline`'s `ContextWriterStage`
/// reads it back with `ContextPacket.read(from:)`. Only built when Correction resolves to a tier
/// for the run (the rubric and `HeardWords` are milliseconds, the database read one indexed query).
public final class ContextPacketBuilder: @unchecked Sendable {
    public struct Input {
        public var mode: WriterMode = .transcribe
        /// The app the turn started in (key-down `FocusSnapshot`).
        public var app: FocusSnapshot?
        /// N9 — the turn's surface, shell and near-caret window (`TurnSurfaceContext.current()`).
        public var resolved: TurnSurfaceContext.Resolved?
        /// The key-down field read (hints, participants, document URL / title, column header).
        /// nil → `resolved.nearCaret` alone describes the field.
        public var field: FieldContext?
        /// N7 — the turn snapshot's contents (nil: skipped, discarded or none).
        public var contents: TurnContextContents?
        /// N11 — `TurnSurfaceContext.candidates()` for this turn (the rubric's input).
        public var candidates: [ContextCandidate] = []
        /// The raw mail To / Cc observation when the integrator has it (splits `to` from `cc`).
        public var participantObservation: ThreadParticipants.Observation?
        /// `TTYForegroundProcess.live(resolved.shell)`, resolved once per turn off the key-down thread.
        public var foregroundProcess: String?
        /// The pre-boost 1-best spans (`PreBoostSpans.reconstruct`; the engine's spans when nothing
        /// was boosted). `heard.words` is `HeardWords.make(from:)` over them.
        public var spans: [TranscriptSpan] = []
        /// What the booster / repair pre-pass would have written (evidence only).
        public var boostedText: String?

        public init(mode: WriterMode = .transcribe, app: FocusSnapshot? = nil, resolved: TurnSurfaceContext.Resolved? = nil,
                    field: FieldContext? = nil, contents: TurnContextContents? = nil, candidates: [ContextCandidate] = [],
                    participantObservation: ThreadParticipants.Observation? = nil, foregroundProcess: String? = nil,
                    spans: [TranscriptSpan] = [], boostedText: String? = nil) {
            self.mode = mode; self.app = app; self.resolved = resolved; self.field = field; self.contents = contents
            self.candidates = candidates; self.participantObservation = participantObservation
            self.foregroundProcess = foregroundProcess; self.spans = spans; self.boostedText = boostedText
        }
    }

    public struct Limits: Sendable, Equatable {
        /// Characters of field text before / after the caret.
        public var textWindow = 600
        /// Characters of thread / document blocks (§2.2).
        public var threadCharacters = 1_500
        public var threadBlocks = 40
        /// Ranked screen terms (§2.3).
        public var screenTerms = 40
        /// Vocabulary matches (§2.4).
        public var vocabulary = 30
        public var recentDictations = 3
        public init() {}
    }

    public var limits = Limits()
    /// §2.4 — the phonetic vocabulary index (implemented in `Engine/Biasing`); nil → no matches.
    public var vocabulary: (any VocabularyMatching)?
    /// Last landed texts in an app, newest first (`PacketSources.recentDictations`).
    public var recentDictations: (_ personaKey: String) -> [String] = { _ in [] }
    /// The user's persona for an app (`PacketSources.persona`).
    public var persona: (_ personaKey: String) -> String? = { _ in nil }
    /// The dictation language (`PacketSources.language`).
    public var language: () -> String? = { nil }
    /// The per-app "contextual reading" rule (`AppRules`), checked before any screen text is used.
    public var contextualReading: (String?) -> Bool = { ContextualReadingRule.allows($0) }
    public var now: () -> Date = Date.init

    public init() {}

    /// The app's production sources: dictation history, personas and the language setting.
    public convenience init(database: AppDatabase?, personas: PersonaManager?, settings: SettingsStore?,
                            vocabulary: (any VocabularyMatching)? = nil) {
        self.init()
        self.recentDictations = PacketSources.recentDictations(database, limit: limits.recentDictations)
        self.persona = PacketSources.persona(personas)
        self.language = PacketSources.language(settings)
        self.vocabulary = vocabulary
    }

    // MARK: Build

    public func build(_ input: Input) -> ContextPacket {
        let bundleID = firstNonEmpty(input.resolved?.bundleID, input.app?.bundleID, input.field?.appBundleID)
        let appName = firstNonEmpty(input.app?.appName, input.resolved?.nearCaret?.appName)
        let surface = input.resolved?.surface ?? input.field?.surface
            ?? SurfaceResolution(kind: .prose, confidence: 0, isWebArea: false, signals: [], isFallback: true)
        let heard = Self.heard(input.spans, boosted: input.boostedText)

        // §2.1 secure: nothing is read, nothing is carried — not even the app.
        if Self.isSecure(input, surface: surface) {
            let packet = ContextPacket(mode: input.mode, destination: .init(profileID: "secure", surfaceKind: SurfaceKind.secure.id),
                                       heard: ContextPacket.Heard(raw: ""), isSecure: true)
            log(packet)
            return packet
        }

        let reading = contextualReading(bundleID)
        let near = input.resolved?.nearCaret
        let windowTitle = reading ? firstNonEmpty(input.contents?.content.title, near?.windowTitle, input.field?.documentTitle) : nil
        let url = reading ? input.field?.documentURL.flatMap(URL.init(string:)) : nil
        var host = url?.host?.lowercased() ?? (reading ? input.field?.subApp?.host : nil)
        if let h = host, h.hasPrefix("www.") { host = String(h.dropFirst(4)) }

        // Field text around the caret, bounded (H17 already bounded it; the packet's window is its own).
        let textBefore = reading ? tail(input.field?.textBeforeCursor ?? near?.before ?? "", limits.textWindow) : ""
        let textAfter = reading ? head(input.field?.textAfterCursor ?? near?.after ?? "", limits.textWindow) : ""

        let conversational = Self.isConversational(surface.kind)
        let tailText = reading ? Self.threadSource(input.contents, conversational: conversational, composerText: textBefore) : nil

        var facts = DestinationProfiles.Facts(surface: surface, bundleID: bundleID, appName: appName)
        facts.screenAllowed = reading
        facts.shell = input.resolved?.shell
        facts.foregroundProcess = input.foregroundProcess
        facts.heardWords = heard.words.map(\.text)
        if reading {
            facts.hints = input.field?.hints ?? near?.fieldLabel.map { [$0] } ?? []
            facts.host = host
            facts.urlPath = url?.path
            facts.windowTitle = windowTitle
            facts.documentTitle = input.field?.documentTitle
            facts.isMultiline = input.field?.isMultiline
            facts.textBefore = textBefore
            facts.tail = tailText
            facts.participants = input.field?.participants ?? []
            facts.observation = input.participantObservation
            facts.columnHeader = input.field?.columnHeader
            facts.headings = Self.headingsAboveCaret(input.contents)
        }
        let destination = DestinationProfiles.record(facts)

        var thread: [ContextPacket.ThreadBlock] = []
        if let tailText, !tailText.isEmpty {
            thread = ThreadBlocks.split(tailText, selfNames: [], limit: limits.threadCharacters, maxBlocks: limits.threadBlocks)
        }
        let screenTerms = reading ? Self.screenTerms(input.candidates, surface: surface, app: bundleID, now: now(), cap: limits.screenTerms) : []
        let vocabulary = self.vocabulary.map { Array($0.matches(heard: heard, limit: limits.vocabulary).prefix(limits.vocabulary)) } ?? []
        let personaKey = input.field?.personaKey ?? bundleID
        let recent = personaKey.map { Array(recentDictations($0).prefix(limits.recentDictations)) } ?? []

        let packet = ContextPacket(mode: input.mode, destination: destination, textBefore: textBefore, textAfter: textAfter,
                                   thread: thread, screenTerms: screenTerms, vocabulary: vocabulary, recentDictations: recent,
                                   persona: personaKey.flatMap(persona), language: language(), heard: heard, isSecure: false)
        log(packet)
        return packet
    }

    /// Builds the packet and writes it into the run's context (`ContextPacket.contextKey` / `modeKey`).
    @discardableResult
    public func write(_ input: Input, into context: inout StageContext) -> ContextPacket {
        let packet = build(input)
        packet.write(into: &context)
        return packet
    }

    // MARK: Parts

    /// §2.5 — the raw 1-best (`renderedText` of the pre-boost spans), its words with confidence and
    /// alternates (`HeardWords`), and the booster's text as evidence when it differs.
    static func heard(_ spans: [TranscriptSpan], boosted: String?) -> ContextPacket.Heard {
        let raw = spans.renderedText
        let boostedText = boosted?.trimmingCharacters(in: .whitespacesAndNewlines)
        let differs = boostedText.map { !$0.isEmpty && $0 != raw.trimmingCharacters(in: .whitespacesAndNewlines) } ?? false
        return ContextPacket.Heard(raw: raw, words: HeardWords.make(from: spans), boosted: differs ? boostedText : nil)
    }

    static func isSecure(_ input: Input, surface: SurfaceResolution) -> Bool {
        if surface.kind == .secure { return true }
        if input.resolved?.nearCaret?.isSecure == true { return true }
        if input.contents?.nearCaret?.secure == true { return true }
        if let f = input.field, f.axRole == FocusedElementInfo.secureRole || f.axSubrole == FocusedElementInfo.secureRole { return true }
        return false
    }

    static func isConversational(_ kind: SurfaceKind) -> Bool {
        kind == .chatComposer || kind == .emailBody
    }

    /// §2.2 — the text the thread blocks come from. A conversation reads the document tail (its
    /// newest messages), a document the neighbourhood around the caret; the composer's own text
    /// is cut off the end so it is not repeated as a thread block.
    static func threadSource(_ contents: TurnContextContents?, conversational: Bool, composerText: String) -> String? {
        guard let contents else { return nil }
        let near = contents.nearCaret?.readingOrderText
        let tail = contents.documentTail
        let body = contents.content.text
        var text: String?
        if conversational { text = tail ?? near ?? body } else { text = near ?? tail ?? body }
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let composer = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !composer.isEmpty, t.hasSuffix(composer) { t = String(t.dropLast(composer.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return t.isEmpty ? nil : t
    }

    /// H21 — headings read outward from the caret that sit before it, nearest first.
    static func headingsAboveCaret(_ contents: TurnContextContents?) -> [String] {
        guard let near = contents?.nearCaret else { return [] }
        var out: [String] = []
        for (i, block) in near.blocks.enumerated() where block.role == "AXHeading" {
            guard i < near.isBefore.count, near.isBefore[i] else { continue }
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 120 { out.append(text) }
        }
        return out
    }

    /// §2.3 — the rubric's prompt terms (screen + participants, Contacts never admitted), nearest
    /// the caret first, at most `cap`.
    static func screenTerms(_ candidates: [ContextCandidate], surface: SurfaceResolution, app: String?, now: Date, cap: Int) -> [String] {
        guard cap > 0, surface.kind != .secure else { return [] }
        let admitted = candidates.filter { $0.source != .contact }
        guard !admitted.isEmpty else { return [] }
        let ranked = ContextRubric.rank(candidates: admitted, surface: surface, now: now, app: app)
        var distance: [String: Int] = [:]
        for c in admitted {
            let key = c.text.lowercased()
            let d = c.caretDistance ?? Int.max
            if d < (distance[key] ?? Int.max) { distance[key] = d }
        }
        let terms = Array(ranked.promptTerms.prefix(cap))
        return terms.enumerated().sorted { a, b in
            let da = distance[a.element.lowercased()] ?? Int.max, db = distance[b.element.lowercased()] ?? Int.max
            return da != db ? da < db : a.offset < b.offset
        }.map(\.element)
    }

    private func log(_ p: ContextPacket) {
        // Counts only: no field text, thread, term or heard word ever reaches the log.
        Log.app.debug("context packet: \(p.destination.profileID) fields=\(p.destination.fields.count) before=\(p.textBefore.count) after=\(p.textAfter.count) thread=\(p.thread.count) terms=\(p.screenTerms.count) vocab=\(p.vocabulary.count) recent=\(p.recentDictations.count) words=\(p.heard.words.count)\(p.isSecure ? " secure" : "")")
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { $0 }.first { !$0.isEmpty }
    }

    private func tail(_ s: String, _ n: Int) -> String { s.count > n ? String(s.suffix(n)) : s }
    private func head(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }
}
