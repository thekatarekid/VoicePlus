import Actions
import AppKit
import Combine
import Shared
import SwiftUI

/// S2 — one deixis box drawn this turn, as the pill's chip shows it: the crop's thumbnail (nil without
/// Screen Recording) and a short label. Owner decision (build doc §0): the chip sits in the text lane,
/// under the transcript and above the tape lane; never in the character bay.
public struct PillDeixisChip: Identifiable, Equatable {
    public let id: UUID
    public var label: String
    public var thumbnail: CGImage?
    public var pending: Bool

    public init(id: UUID, label: String, thumbnail: CGImage? = nil, pending: Bool = false) {
        self.id = id
        self.label = label
        self.thumbnail = thumbnail
        self.pending = pending
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.label == b.label && a.pending == b.pending && a.thumbnail === b.thumbnail
    }

    /// Longest label drawn beside the thumbnail.
    public static let labelLimit = 24

    /// A chip for a box: the text inside it (AX or OCR), else the element's label, else "Box N".
    public static func make(_ region: DeixisRegion, index: Int, image: CGImage?) -> PillDeixisChip {
        let text = region.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let raw = !text.isEmpty ? text : (region.element?.label ?? "")
        let label: String
        if raw.isEmpty {
            label = "Box \(index)"
        } else if raw.count > labelLimit {
            label = String(raw.prefix(labelLimit)).trimmingCharacters(in: .whitespaces) + "…"
        } else {
            label = raw
        }
        return PillDeixisChip(id: region.id, label: label, thumbnail: image, pending: region.isPending)
    }
}

/// S2 — where a pill button goes, as a pure table the composition root executes (design §5, §6, the
/// prototype's `pillAction`). The held row's Insert here / Copy / Discard, Dismiss and the transform
/// ghost's Undo never get here: `PillViewModel.perform` handles them first.
public enum PillActionEffect: Equatable, Sendable {
    /// "Insert text" on a manual or reviewed final preview: skip the rest of the dwell.
    case insertNow
    /// "Cancel" on the final preview (nothing was written).
    case cancelPreview
    /// "Cancel" on the 10 s finishing offer.
    case cancelFinishing
    /// "Use available text" on the 10 s finishing offer.
    case useAvailableText
    /// "Review all": pause the dwell for review; the row turns into review mode (Insert text / Cancel).
    case pauseForReview
    /// "Finish" on the latched row: stop the latch and finish like a key tap.
    case finishLatch
    /// "Undo" on the undo row (R2): range-safe undo, the turn controller's.
    case undo
    /// "Unmute" (I2): explicit unmute only.
    case unmute
    /// Copy this row's text to the clipboard (E0 "Copy text").
    case copy(String)
    /// Open a window destination: Today's turn detail (Check text, Review result, Review text, Review
    /// word), Voice (Check microphone, Choose microphone), Models, Privacy (Review permissions), Meetings.
    case open(PillDestinationScreen)
    /// "Stop" on the meeting row.
    case stopMeeting
    case none

    /// The turn's own buttons: S3's `TurnWiring` routes these to the turn controller. The composition
    /// root carries out the rest.
    public var isTurnEffect: Bool {
        switch self {
        case .insertNow, .cancelPreview, .cancelFinishing, .useAvailableText, .pauseForReview, .undo, .finishLatch:
            return true
        case .unmute, .copy, .open, .stopMeeting, .none:
            return false
        }
    }
}

public enum PillDestinationScreen: String, Equatable, Sendable {
    case today, voice, models, privacy, meetings
}

public enum PillActionRoute {
    public static func effect(for action: PillActionKind, shown: PillState, text: String) -> PillActionEffect {
        switch action {
        case .commit: return .insertNow
        case .cancel:
            if case .finalPreview = shown { return .cancelPreview }
            return .cancelFinishing
        case .useAvailable: return .useAvailableText
        case .reviewAll: return .pauseForReview
        case .finish: return .finishLatch
        case .undo: return .undo
        case .unmute: return .unmute
        case .copy: return text.isEmpty ? .none : .copy(text)
        case .check, .review: return .open(.today)
        case .voice: return .open(.voice)
        case .models: return .open(.models)
        case .permissions: return .open(.privacy)
        case .meeting, .pause, .resume: return .open(.meetings)
        case .stop: return .stopMeeting
        case .insert, .discard, .dismiss, .editDraft, .doneEditing, .cancelEditing: return .none
        }
    }
}

/// Observable bridge between the reducer (pure) and SwiftUI.
public final class PillViewModel: ObservableObject {
    @Published public private(set) var state: PillState = .hidden
    @Published public private(set) var waveform = WaveformModel()
    /// Latched (V3 §4.7). While set, live engine states are drawn as the design's latched pill with
    /// its timer, so an engine tick can never overwrite the latch timer (B4 hand-off).
    @Published public var latched = false {
        didSet { if !latched { turn.latchElapsed = nil } }
    }
    /// P2.3 — transform ghost + morph; the ghost's Undo is the design's undo row action.
    @Published public var ghost: TransformGhost?
    @Published public var morph: MorphAnimationModel?
    /// W3H — S12's rows for the transform on screen (`TransformLanding.rows`); drawn only while they
    /// match the transform stage shown (`drawnTransformRows`, the W3H region below).
    @Published public var transformRows: TransformPreviewRows?
    /// P6.3 — script indicator ("EN" / "हि" / "EN·हि"); empty = hidden. Drawn in the status row.
    @Published public var scriptBadge: String = ""
    /// S2 — everything about the turn the state does not carry (destination, timer, live words…).
    @Published public private(set) var turn = PillTurnContext()
    /// S2 — deixis boxes of this turn (owner addition: the chip in the text lane).
    @Published public private(set) var deixisChips: [PillDeixisChip] = []
    /// A one-line note for the turn ("Screen text isn't available"), drawn in the chip row so it never
    /// replaces the live words.
    @Published public private(set) var laneNote: String?
    /// The pointer is on the pill (hover pauses the final preview's dwell; S3 reads it).
    @Published public private(set) var pointerInside = false
    /// Keyboard or VoiceOver focus is on the pill's text lane or actions (focus pauses the final
    /// preview's dwell like hover; S3 reads it through `onKeyboardFocusChange`).
    @Published public private(set) var focusInside = false
    /// The pill pieces that hold focus now (`PillFocusReport` element names).
    private var focusedElements: Set<String> = []
    /// When the drawn Spool pose began; persists across same-pose updates so reels never reset.
    @Published public private(set) var spoolStartedAt = Date()
    /// Advances once a second while a timer or the finishing offer is on screen.
    @Published public private(set) var clockTick = Date()
    /// S4 — Spool's mouth on screen (the tape flight's source). The first time the pill's Spool is drawn
    /// in a window, the live tape flight installs itself on this pill (App/Overlay/TapeFlight*).
    lazy var spoolAnchors = SpoolAnchorTracker { [weak self] _ in
        if let self { TapeFlightWiring.installLive(on: self) }
    }

    public var onGhostAction: ((TransformGhost.Action) -> Void)?
    /// R2.4 — Insert here / Copy / Discard from the held row.
    public var onHeldAction: ((HeldPillInfo, HeldAction) -> Void)?
    /// S2 — every other pill button (Finish, Insert text, Cancel, Check text, Unmute, Open Models…).
    /// Dismiss and the held actions are handled here; everything else goes to the composition root / S3.
    public var onAction: ((PillActionKind, PillState) -> Void)?
    /// S2 — hover entered / left the pill (S3 freezes the preview dwell while inside).
    public var onPointerInsideChange: ((Bool) -> Void)?
    /// S3 — keyboard or VoiceOver focus entered / left the pill's text lane and actions (S3 freezes
    /// the preview dwell while it is inside, design §11).
    public var onKeyboardFocusChange: ((Bool) -> Void)?
    /// Every engine state the pill was fed, after it reduced it — the S3 turn controller's *admitted*
    /// stream, which is not the whole engine story (after key-up it holds back `.finalizing`,
    /// `.landed` and `.idle`). FX2: so the presence chin no longer listens here; it binds to
    /// `DictationCoordinator.engineStates`, unfiltered, and to its turn ends.
    public var onEngineState: ((EngineState) -> Void)?
    /// The configured dictation key as hints name it; read whenever content is built.
    public var keyLabel: () -> String = { HotkeyBinding.default.label }
    /// The destination's display name at key-down ("Mail"); asked once per turn.
    public var destinationProvider: (() -> String?)?

    private var reducer = PillStateReducer()
    /// S5b — every write to `state` goes through `route(_:)`; nothing sets it directly.
    private var presenter = PillPresenter()
    private var holdTimer: Timer?
    /// Retracts a delivery / notice row after its dwell (only rows with a `.minimum` rule).
    private var deliveryTimer: Timer?
    private var ticker: Timer?
    private var drawnSpoolKey = ""
    /// Injectable clock so tests can drive dwell without sleeping.
    public var now: () -> Date = Date.init
    private var cancellables: Set<AnyCancellable> = []
    private var lastCapturedLevel: Date?
    private var capturedLevelsAreLive: Bool {
        guard let lastCapturedLevel else { return false }
        return Date().timeIntervalSince(lastCapturedLevel) < 0.5
    }

    public init() {}

    // MARK: Engine feed

    public func bind(engineState: AnyPublisher<EngineState, Never>, audioLevel: AnyPublisher<Float, Never>? = nil) {
        cancellables.removeAll()
        engineState.receive(on: DispatchQueue.main).sink { [weak self] s in self?.apply(s) }.store(in: &cancellables)
        audioLevel?.receive(on: DispatchQueue.main).sink { [weak self] level in self?.push(capturedLevel: level) }
            .store(in: &cancellables)
    }

    /// A level measured from captured audio; drives the tape (S1.6: silence draws a flat tape).
    public func push(capturedLevel level: Float) {
        lastCapturedLevel = Date()
        waveform.push(level: level)
    }

    /// The capture level Spool's tape follows, 0…1.
    public var captureLevel: Double { Double(waveform.bars.last ?? 0) }

    public func apply(_ engineState: EngineState) {
        var new = reducer.reduce(engineState)
        if case .listening(let level) = engineState, !capturedLevelsAreLive { waveform.push(level: level) }
        if case .idle = engineState {
            waveform.reset()
            lastCapturedLevel = nil
        }
        if case .preview(let text) = new { turn.liveText = text }
        if latched, Self.isLiveCapture(new) {
            // A segment's outcome row is not cut short by level ticks under the open microphone: a
            // timed row goes back to the latched row after its dwell; a sticky one stays until the
            // user acts or the next segment's words arrive (capture outranks held recovery, design §6).
            if Self.isOutcomeRow(state), !Self.nextSegmentSpoke(new, over: state) {
                onEngineState?(engineState)
                return
            }
            new = .latched(elapsed: turn.latchElapsed ?? 0)
        }
        route(new)
        onEngineState?(engineState)
    }

    /// A segment's outcome row, drawn after its landing: what a latch tick must not replace. (The
    /// final preview and the write are the turn controller's; it keeps engine states off the pill.)
    static func isOutcomeRow(_ state: PillState) -> Bool {
        switch state {
        case .landed, .landedPartial, .held, .error, .cancelled, .undoAvailable:
            return true
        default:
            return false
        }
    }

    /// New words while a sticky row is up in latch: the next segment takes the pill back.
    static func nextSegmentSpoke(_ new: PillState, over shown: PillState) -> Bool {
        guard PillDwell.staysUntilAction(shown), case .preview(let text) = new else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isLiveCapture(_ state: PillState) -> Bool {
        switch state {
        case .listening, .preview, .listeningQuiet: return true
        default: return false
        }
    }

    public func hide() {
        reducer.hide()
        ghost = nil
        morph = nil
        route(.hidden)
    }

    /// Show a state the engine reducer does not produce. A `.preview` line presented while capture is
    /// open becomes the turn's lane note (it never replaces the live words); with no capture open it
    /// is a transient notice that fades on its own.
    public func present(_ state: PillState) {
        switch state {
        case .preview(let text) where turn.captureOpen:
            laneNote = text
        case .preview:
            route(state)
            scheduleDeliveryRetraction(after: PillDwell.transientNotice)
        case .latched(let elapsed):
            turn.latchElapsed = elapsed
            // The timer tick updates the clock; it never replaces a segment's outcome row, whose own
            // dwell (or the user) returns the pill to the latched row with this elapsed time.
            if latched, Self.isOutcomeRow(self.state) { return }
            route(state)
        default:
            route(state)
        }
    }

    /// R2.4 — one `DeliveryOutcome`, one row. Verified rows retract after their dwell; unconfirmed,
    /// partial, held and failed rows stay until the user acts (design §10).
    @discardableResult
    public func present(delivery: DeliveryOutcome, text: String, destination: String = "",
                        heldID: UUID = UUID()) -> PillState {
        let next = PillDeliveryRouter.state(for: delivery, text: text, destination: destination, heldID: heldID)
        if !text.isEmpty { turn.liveText = text }
        let name = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { turn.destination = name }
        route(next)
        scheduleRetractionIfTimed(next)
        return next
    }

    /// A notice row nothing else will take down (R2.5's repair suggestions): retracted after its own
    /// dwell when it has one, left up until the user acts when it does not.
    public func presentNotice(_ state: PillState) {
        route(state)
        scheduleRetractionIfTimed(state)
    }

    /// S3 — the final payload's spans and the text rendered from them (`text`; the spans' own
    /// rendering when nil). S5 — the marks are mapped onto that text through formatting
    /// (`UncertaintyMarkMapper`, design §7), never by matching words, and "N words to review" counts
    /// exactly the marks drawn; a rewrite that marked a phrase reads "Review this phrase" (T05).
    public func setFinalSpans(_ spans: [TranscriptSpan], text: String? = nil) {
        let low = spans.filter(\.isLowConfidence)
        turn.uncertainWords = Set(low.flatMap { $0.text.split(whereSeparator: \.isWhitespace) }
            .map { PillTextLane.normalized(String($0)) }.filter { !$0.isEmpty })
        finalSpans = spans
        payloadText = text
        resolvedMarks = []
        markCache = nil
        let mapping = markMapping(for: text ?? spans.renderedText)
        turn.uncertainCount = mapping.count
        turn.needsPhraseReview = mapping.needsPhraseReview
        WordMarksWiring.adoptIfNeeded(self)
    }

    // MARK: S5 — uncertainty marks and review (design §7)

    /// The final payload's spans as published (formatted; confidence carried through every stage).
    public private(set) var finalSpans: [TranscriptSpan] = []
    /// The payload text `finalSpans` were rendered into, when the turn said so: marks on it need no
    /// `belongs` check (a whole-result rewrite shares no words with its spans, T05).
    private var payloadText: String?
    /// Marks the user resolved on this turn (kept, or a spelling chosen): no longer drawn.
    @Published public private(set) var resolvedMarks: Set<Int> = []
    private var markCache: MarkMapping?
    /// A dotted word was clicked or activated: its mark, the turn's marks, the word's screen rect.
    public var onReviewMark: ((UncertainMark, MarkMapping, CGRect?) -> Void)?
    /// "Review all" opened the Review surface for the final text.
    public var onReviewAll: ((MarkMapping) -> Void)?

    /// Where the marks go in `text` (the final payload on screen). Nothing for a text the spans did not
    /// produce (another turn's words, a notice): `UncertaintyMarkMapper.belongs`.
    public func markMapping(for text: String) -> MarkMapping {
        if let cache = markCache, cache.text == text { return cache.removing(resolvedMarks) }
        let available = finalSpans.contains { UncertaintyMarkMapper.carriesConfidence($0) }
        let produced = payloadText == text || UncertaintyMarkMapper.belongs(finalSpans, to: text)
        let mapping = !text.isEmpty && produced
            ? UncertaintyMarkMapper.map(source: finalSpans, finalText: text)
            : MarkMapping(text: text, marks: [], confidenceAvailable: available)
        markCache = mapping   // one text at a time; redrawn every second while a timer is up
        return mapping.removing(resolvedMarks)
    }

    /// The marks drawn in the text lane: final text only, never live words.
    public func marks(for words: PillContent.Words) -> MarkMapping {
        guard case .final(let text) = words else { return .empty }
        return markMapping(for: text)
    }

    /// A dotted word was clicked (or activated from the keyboard / VoiceOver).
    public func reviewMark(_ id: Int, anchor: CGRect? = nil) {
        if case .finalPreview = state { beginEditingMark(id); return }
        let mapping = marks(for: content().words)
        guard let mark = mapping.mark(id: id) else { return }
        onReviewMark?(mark, mapping, anchor)
    }

    /// Kept or corrected: the mark clears for this turn only.
    public func resolveMarks(_ ids: Set<Int>) {
        guard !ids.isSubset(of: resolvedMarks) else { return }
        resolvedMarks.formUnion(ids)
    }

    /// The Review surface closed: the row leaves review mode (the dwell resumes, design §5 / F2).
    public func endReview() { turn.reviewing = false }

    // MARK: V3 in-notch editing

    @Published public private(set) var isEditingDraft = false
    @Published public var draftText = "" {
        didSet {
            guard isEditingDraft else { return }
            onDraftPause?(.emptyDraft, draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    @Published public private(set) var editingMarkID: Int?
    @Published public private(set) var hasMarkedText = false
    public var onDraftPause: ((DwellPause, Bool) -> Void)?
    public var onApplyDraft: ((String, MarkMapping, [TranscriptSpan]) -> Bool)?
    public var onLearnDraft: ((String, String) -> Void)?
    public var onApplyRetainedDraft: ((PillState, String, String, MarkMapping) -> Bool)?
    public var onHeldDraftApplied: ((UUID, String) -> Void)?
    private var originalDraft = ""
    private var originalMapping = MarkMapping.empty
    private var mouseFocusedElements: Set<String> = []
    private var destinationEdit: ((String) -> Bool)?

    public func suggestion(for mark: UncertainMark) -> String? {
        mark.alternatives.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0 != mark.text }
    }

    /// Review a landed word in the same notch editor. The callback owns target/range validation.
    public func beginDestinationEditing(_ mark: UncertainMark, apply: @escaping (String) -> Bool) {
        present(.correcting)
        turn.liveText = mark.text
        originalDraft = mark.text
        var local = mark
        local.range = 0..<mark.text.utf16.count
        originalMapping = MarkMapping(text: mark.text, marks: [local], confidenceAvailable: true)
        markCache = originalMapping
        payloadText = mark.text
        draftText = mark.text
        destinationEdit = apply
        editingMarkID = mark.id
        isEditingDraft = true
    }

    public func beginEditingDraft() {
        guard !isEditingDraft, !actionText.isEmpty else { return }
        switch state {
        case .finalPreview, .held, .error: break
        default: return
        }
        onDraftPause?(.review, true)
        originalDraft = actionText
        originalMapping = markMapping(for: originalDraft)
        draftText = originalDraft
        isEditingDraft = true
    }

    public func beginEditingMark(_ id: Int) {
        beginEditingDraft()
        guard isEditingDraft, originalMapping.mark(id: id) != nil else { return }
        editingMarkID = id
    }

    @discardableResult
    public func applyDraftEdits() -> Bool {
        guard isEditingDraft else { return true }
        guard !hasMarkedText, !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let edited = draftText
        if edited != originalDraft {
            var mapping = DraftRevision.mapping(originalMapping, edited: edited)
            let spans = DraftRevision.spans(for: mapping, source: finalSpans)
            mapping = DraftRevision.indexing(mapping, spans: spans)
            switch state {
            case .finalPreview:
                guard onApplyDraft?(edited, mapping, spans) ?? false else { return false }
            case .held(var info):
                guard onApplyRetainedDraft?(state, originalDraft, edited, mapping) ?? false else { return false }
                info.text = edited
                onHeldDraftApplied?(info.id, edited)
                route(.held(info))
            case .correcting:
                guard destinationEdit?(edited) ?? false else { return false }
            case .error:
                guard onApplyRetainedDraft?(state, originalDraft, edited, mapping) ?? false else { return false }
                turn.liveText = edited
            default: return false
            }
            finalSpans = spans
            payloadText = edited
            resolvedMarks = []
            markCache = mapping
            turn.uncertainCount = mapping.count
            turn.needsPhraseReview = mapping.needsPhraseReview
            onLearnDraft?(originalDraft, edited)
        }
        let wasDestination = destinationEdit != nil
        finishDraftEditing()
        if wasDestination { hide() }
        return true
    }

    public func cancelDraftEdits() {
        guard isEditingDraft else { return }
        draftText = originalDraft
        let wasDestination = destinationEdit != nil
        finishDraftEditing()
        if wasDestination { hide() }
    }

    private func finishDraftEditing() {
        isEditingDraft = false
        destinationEdit = nil
        editingMarkID = nil
        hasMarkedText = false
        onDraftPause?(.composition, false)
        onDraftPause?(.emptyDraft, false)
        onDraftPause?(.review, false)
    }

    public func setCompositionActive(_ active: Bool) {
        let wasComposing = hasMarkedText
        hasMarkedText = active
        onDraftPause?(.composition, active)
        if wasComposing, !active, !pointerInside, !focusInside, isEditingDraft { _ = applyDraftEdits() }
    }

    public func acceptSuggestion(markID: Int, replacement: String) {
        guard case .finalPreview = state, !hasMarkedText,
              let mark = markMapping(for: actionText).mark(id: markID),
              mark.alternatives.contains(replacement) else { return }
        beginEditingDraft()
        draftText = (originalDraft as NSString).replacingCharacters(in: NSRange(mark.range), with: replacement)
        _ = applyDraftEdits()
    }

    /// G3 → S2 — the boxes drawn this turn, with their crops.
    public func showDeixis(_ regions: [DeixisRegion], image: (DeixisRegion) -> CGImage?) {
        deixisChips = regions.enumerated().map { PillDeixisChip.make($0.element, index: $0.offset + 1, image: image($0.element)) }
        turn.chipCount = deixisChips.count
    }

    /// A one-line note for the turn's chip row (deixis notices).
    public func showLaneNote(_ line: String?) { laneNote = line }

    public func setPointerInside(_ inside: Bool) {
        guard inside != pointerInside else { return }
        pointerInside = inside
        if !inside {
            _ = applyDraftEdits()
            focusedElements.subtract(mouseFocusedElements)
            mouseFocusedElements.removeAll()
            let focused = !focusedElements.isEmpty
            if focused != focusInside { focusInside = focused; onKeyboardFocusChange?(focused) }
        }
        onPointerInsideChange?(inside)
    }

    /// One piece of the pill (`element`) gained or lost keyboard / VoiceOver focus. The pill is
    /// focused while any piece is; `onKeyboardFocusChange` fires only when that changes.
    public func noteKeyboardInteraction() {
        mouseFocusedElements.removeAll()
        if isEditingDraft, !pointerInside { setFocus(true, element: "draft.editor") }
    }

    public func setFocus(_ focused: Bool, element: String = "pill") {
        if focused {
            focusedElements.insert(element)
            if pointerInside { mouseFocusedElements.insert(element) }
        } else {
            focusedElements.remove(element)
            mouseFocusedElements.remove(element)
        }
        let inside = !focusedElements.isEmpty
        guard inside != focusInside else { return }
        focusInside = inside
        onKeyboardFocusChange?(inside)
    }

    // MARK: Content

    /// The rendered pill for the current state at `date`.
    public func content(at date: Date? = nil) -> PillContent {
        var result = PillContent.make(state, context: context(at: date)).drawingTransform(drawnTransformRows)
        if !isEditingDraft, !actionText.isEmpty {
            switch state {
            case .held, .error: result.buttons.insert(PillButton("Edit draft", .editDraft), at: 0)
            default: break
            }
        }
        if isEditingDraft {
            result.buttons = [PillButton("Done", .doneEditing), PillButton("Cancel edits", .cancelEditing)]
            if destinationEdit != nil, laneNote != nil { result.buttons.append(PillButton("Copy correction", .copy)) }
            result.helper = hasMarkedText ? "Finish typing before inserting" : "Done or ⌘Return applies edits"
        }
        return result
    }

    func context(at date: Date? = nil) -> PillTurnContext {
        var c = turn
        c.now = date ?? now()
        c.keyLabel = keyLabel()
        if case .transform = state, let after = ghost?.after { c.liveText = after }
        return c
    }

    /// The text a Copy / Review action on the current row acts on.
    public var actionText: String {
        if isEditingDraft { return draftText }
        switch state {
        case .held(let info): return info.text
        case .landed(let info): return info.text
        case .landedPartial(let text), .inserting(let text): return text
        case .finalPreview(let info): return info.text
        default: return turn.liveText
        }
    }

    // MARK: Actions

    /// A pill button was pressed.
    public func perform(_ action: PillActionKind) {
        switch action {
        case .editDraft: beginEditingDraft(); return
        case .doneEditing: _ = applyDraftEdits(); return
        case .cancelEditing: cancelDraftEdits(); return
        case .commit: guard applyDraftEdits(), !hasMarkedText else { return }
        case .reviewAll:
            if case .finalPreview = state { beginEditingDraft(); return }
        default: break
        }
        let shown = state
        if case .held(let info) = shown, let held = action.heldAction {
            onHeldAction?(info, held)
            return
        }
        if case .transform = shown, action == .undo, onGhostAction != nil {
            onGhostAction?(.undo)
            return
        }
        switch action {
        case .dismiss:
            dismissNotice()
        case .reviewAll:
            // Opening Review pauses auto-insertion (design §4, §5); the row shows Insert text / Cancel
            // so a paused payload is never stranded.
            turn.reviewing = true
            onAction?(action, shown)
            // S5 — the Review surface: the whole final text with its marks.
            if case .finalPreview(let info) = shown { onReviewAll?(markMapping(for: info.text)) }
        default:
            onAction?(action, shown)
            // A row the user acted on comes down; the handler has taken the next step.
            if PillDwell.staysUntilAction(shown), [.check, .review, .copy, .models, .permissions].contains(action) {
                dismissNotice()
            }
        }
    }

    /// Take the current notice down now (the user dealt with it).
    public func dismissNotice() { retractDelivery(immediately: true) }

    /// Test seam and timer callback: take a delivery / notice row down. No-op for live and in-flight
    /// states, so a new utterance that started in the meantime is never yanked off screen. While
    /// latched the pill returns to the latched row instead of retracting under an open microphone.
    public func retractDelivery(immediately: Bool = false) {
        deliveryTimer?.invalidate()
        deliveryTimer = nil
        switch state {
        case .landed, .held, .error, .landedPartial, .unavailable, .muted, .cancelled, .undoAvailable, .preview:
            if case .preview = state, turn.captureOpen { return }
            reducer.hide()
            ghost = nil
            morph = nil
            if latched, turn.captureOpen {
                // The landed segment's words go with its row; words of the next segment that
                // arrived during the dwell stay on the latched row.
                if turn.liveText == actionText { turn.liveText = "" }
                if immediately { _ = presenter.dismiss(now: now()) }
                route(.latched(elapsed: turn.latchElapsed ?? 0))
                return
            }
            if immediately { apply(decision: presenter.dismiss(now: now())) } else { route(.hidden) }
        default: break
        }
    }

    private func scheduleRetractionIfTimed(_ state: PillState) {
        guard case .minimum(let dwell) = PillDwell.rule(for: state) else {
            deliveryTimer?.invalidate()
            deliveryTimer = nil
            return
        }
        scheduleDeliveryRetraction(after: dwell)
    }

    private func scheduleDeliveryRetraction(after dwell: TimeInterval) {
        deliveryTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.05, dwell + 0.05), repeats: false) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread { self.retractDelivery() } else { DispatchQueue.main.async { self.retractDelivery() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        deliveryTimer = timer
    }

    // MARK: The gate

    /// The single write path to `state`. A visible state lands immediately; a retraction waits out
    /// the current state's `PillDwell` rule so a notice can never flash past.
    private func route(_ next: PillState) {
        // Mute outranks every other row (design §6 state priority) and leaves only on an explicit
        // Unmute (`dismissNotice`): the cancellation the mute itself triggers, a late notice or a stray
        // engine tick never replaces it.
        if case .muted = state, next.isVisible, next != .muted { return }
        apply(decision: presenter.request(next, now: now()))
    }

    /// Test seam and timer callback: let a held retraction through once its deadline has passed.
    public func flushPillHold() { apply(decision: presenter.flush(now: now())) }

    private func apply(decision: PillPresenter.Decision) {
        switch decision {
        case .show(let shown):
            holdTimer?.invalidate()
            holdTimer = nil
            noteTransition(to: shown)
            state = shown
            noteSpool()
            updateTicker()
        case .hold(let until):
            scheduleHold(until: until)
        case .unchanged:
            break
        }
    }

    /// Keeps the turn context in step with what is drawn.
    private func noteTransition(to next: PillState) {
        switch next {
        case .finalPreview, .held, .error, .correcting: break
        default: if isEditingDraft { finishDraftEditing() }
        }
        let t = now()
        switch next {
        case .hidden:
            turn = PillTurnContext()
            deixisChips = []
            laneNote = nil
            if pointerInside { setPointerInside(false) }
            if focusInside { focusedElements.removeAll(); setFocus(false) }
            return
        case .idle, .starting:
            // Key-down: a new turn unless this is still the same turn's pre-capture.
            if turn.startedAt == nil || !(Self.isPreCapture(state) || turn.captureOpen) { beginTurn(at: t) }
            turn.captureOpen = false
        case .listening, .listeningQuiet, .latched, .warning:
            // Capture after anything but pre-capture or capture (a landed / held / error row still up)
            // is the next turn: fresh clock, fresh words, destination asked again.
            if turn.startedAt == nil || !(Self.isPreCapture(state) || turn.captureOpen) { beginTurn(at: t) }
            turn.captureOpen = true
            turn.finishingSince = nil
        case .preview:
            break
        case .landing, .finishing:
            turn.captureOpen = false
            if turn.finishingSince == nil { turn.finishingSince = t }
        case .finalPreview(let info):
            turn.captureOpen = false
            turn.finishingSince = nil
            turn.liveText = info.text
            turn.uncertainCount = info.uncertainCount
            turn.needsPhraseReview = info.needsPhraseReview
            if let d = info.destination, !d.isEmpty { turn.destination = d }
        case .inserting(let text):
            turn.captureOpen = false
            turn.liveText = text
        case .cancelled:
            turn.captureOpen = false
        default:
            break
        }
        if turn.startedAt == nil, Self.isTurnState(next) { beginTurn(at: t) }
    }

    static func isPreCapture(_ state: PillState) -> Bool {
        switch state {
        case .idle, .starting: return true
        default: return false
        }
    }

    static func isTurnState(_ state: PillState) -> Bool {
        switch state {
        case .hidden, .ready, .muted, .unavailable, .meeting: return false
        default: return true
        }
    }

    private func beginTurn(at t: Date) {
        let keepLatch = turn.latchElapsed
        turn = PillTurnContext(destination: destinationProvider?() ?? nil, startedAt: t, now: t)
        turn.latchElapsed = latched ? keepLatch : nil
        // Boxes drawn before the key went down (latch "draw without a key") belong to this turn.
        turn.chipCount = deixisChips.count
        laneNote = nil
    }

    private func noteSpool() {
        let key = content().spoolKey
        guard key != drawnSpoolKey else { return }
        drawnSpoolKey = key
        spoolStartedAt = now()
    }

    /// Timer states and the finishing offer need the clock to move while nothing else changes.
    private func updateTicker() {
        let wantsClock: Bool
        switch state {
        case .listening, .listeningQuiet, .latched, .warning, .finishing, .landing: wantsClock = true
        default: wantsClock = false
        }
        guard wantsClock else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.clockTick = self.now()
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func scheduleHold(until: Date) {
        holdTimer?.invalidate()
        holdTimer = nil
        // "Until the user acts": nothing flushes it; an action or a new visible state replaces it.
        guard until != .distantFuture else { return }
        let delay = max(0.02, until.timeIntervalSince(now()))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread { self.flushPillHold() } else { DispatchQueue.main.async { self.flushPillHold() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }
}

// MARK: - The pill

/// S2 — the Spool pill (design §4, DESIGN.md §8): status row (status · destination / timer), text
/// lane (newest two lines, leading fade, dotted uncertain words), the deixis chip row, the tape lane
/// and Spool drawn by `SpoolView` in the 132 pt bay on the right, the helper / key-hint row, and the
/// full-width action row on 204 pt states. No text is ever laid out under the character.
public struct PillView: View {
    @ObservedObject var model: PillViewModel
    let size: CGSize
    let attached: Bool

    public init(model: PillViewModel, size: CGSize = NotchGeometry.activeSize, attached: Bool = true) {
        self.model = model
        self.size = size
        self.attached = attached
    }

    public var body: some View {
        let _ = model.clockTick   // re-render once a second while a timer is on screen
        let content = model.content()
        Group {
            if content.isHidden {
                Color.clear
            } else if content.isHint {
                PillHintView(text: content.status, attached: attached)
            } else {
                PillBody(model: model, content: content, size: size, attached: attached)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .onHover { model.setPointerInside($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PillSpeech.containerLabel(content))   // S10: never live words or the ticking timer
        .accessibilityIdentifier("pill.\(model.state.caseName)")
        .pillAnnouncements(model)                                 // S10: start, stop, final, delivery
    }
}

/// I1 — the text-only hover hint: no dot, no brand prefix, no "Ready", no cassette.
struct PillHintView: View {
    let text: String
    let attached: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Tokens.Pill.Token.ink.color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tokens.Pill.Token.background.color)
            .clipShape(UnevenRoundedRectangle(cornerRadii: attached
                ? RectangleCornerRadii(bottomLeading: Tokens.Radius.presenceHint, bottomTrailing: Tokens.Radius.presenceHint)
                : RectangleCornerRadii(topLeading: Tokens.Radius.presenceHint, bottomLeading: Tokens.Radius.presenceHint,
                                       bottomTrailing: Tokens.Radius.presenceHint, topTrailing: Tokens.Radius.presenceHint)))
    }
}

struct PillBody: View {
    @ObservedObject var model: PillViewModel
    let content: PillContent
    let size: CGSize
    let attached: Bool
    /// S10 — Reduce Motion (system or Settings › Appearance).
    @ObservedObject var motion = MotionPreference.shared

    private var lanes: PillLaneLayout {
        PillLaneLayout(size: size, hasChip: hasChipRow, hasActions: content.hasActions)
    }

    private var hasChipRow: Bool {
        guard PillViewModel.isTurnState(model.state) else { return false }
        return !model.deixisChips.isEmpty || model.laneNote != nil
    }

    var body: some View {
        let lanes = self.lanes
        let lines = wordLines(width: lanes.wordsLane.width, maxLines: lanes.lineCount)
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(cornerRadii: Tokens.Radius.pillCorners(attached: attached))
                .fill(Tokens.Pill.Token.background.color)
            if content.showsSpool, let key = SpoolStateKey(rawValue: content.spoolKey) {
                SpoolView(key: key, stateStartedAt: model.spoolStartedAt, level: model.captureLevel, style: .pill,
                          anchorTracker: model.spoolAnchors)   // S4: the tape flight's mouth anchor
                    .frame(width: size.width, height: PillLaneLayout.sceneHeight)
                    .allowsHitTesting(false)
            }
            statusRow.place(lanes.statusRow)
                .accessibilitySortPriority(PillReadingOrder.priority(.status))   // S10
            if let transform = PillTransformLane.Model(rows: model.drawnTransformRows, lineCount: lanes.lineCount) {
                PillTransformLane(model: transform).place(lanes.wordsLane)   // W3H: S12 before / after
                    .accessibilitySortPriority(PillReadingOrder.priority(.words))   // S10
            } else {
                PillWordsLane(lines: lines, words: content.words, marks: model.marks(for: content.words),   // S5
                              onReview: { model.reviewMark($0, anchor: $1) },
                              onFocus: { model.setFocus($0, element: $1) })   // S3: focus pauses the dwell
                    .place(lanes.wordsLane)
                    .accessibilitySortPriority(PillReadingOrder.priority(.words))   // S10
            }
            if let chipRow = lanes.chipRow {
                PillChipRow(chips: model.deixisChips, note: model.laneNote).place(chipRow)
                    .accessibilitySortPriority(PillReadingOrder.priority(.chips))   // S10
            }
            if let key = SpoolStateKey(rawValue: content.spoolKey), motion.policy.showsLevelReadout(for: key) {
                // S10 — Reduce Motion: a numeric level stands in for the tape's capture motion.
                PillLevelReadout(level: model.captureLevel).place(LevelReadout.rect(in: lanes))
                    .accessibilitySortPriority(PillReadingOrder.priority(.levelReadout))
            }
            helperRow(overflow: overflowLabel(lines)).place(lanes.helperRow)
                .accessibilitySortPriority(PillReadingOrder.priority(.helper))   // S10
            if let actionRow = lanes.actionRow {
                PillActionRow(buttons: content.buttons, perform: { model.perform($0) },
                              onFocus: { model.setFocus($0, element: $1) })   // S3: focus pauses the dwell
                    .place(actionRow)
                    .accessibilitySortPriority(PillReadingOrder.priority(.actions))   // S10
            }
        }
        .clipShape(UnevenRoundedRectangle(cornerRadii: Tokens.Radius.pillCorners(attached: attached)))
        .animation(motion.policy.transition, value: content.designKey)   // S10: none under Reduce Motion
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(content.status)
                .font(Tokens.Typography.pillStatus.font())
                .foregroundStyle(content.tone == .warn ? Tokens.Pill.Token.attention.color : Tokens.Pill.Token.secondaryInk.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("pill.status")
            Spacer(minLength: 4)
            if !model.scriptBadge.isEmpty {
                Text(model.scriptBadge)
                    .font(Tokens.Typography.key.font())
                    .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                    .accessibilityIdentifier("pill.script")
            }
            if let trailing = content.trailing.text {
                Text(trailing)
                    .font((content.trailing.isTimer ? Tokens.Typography.pillTimer : Tokens.Typography.pillStatus).font())
                    .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                    .lineLimit(1)
                    .accessibilityIdentifier("pill.trailing")
            }
        }
    }

    private func helperRow(overflow: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(content.helper)
                .font(Tokens.Typography.pillStatus.font())
                .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("pill.helper")
            Spacer(minLength: 4)
            if content.escapeHint {
                HStack(spacing: 4) {
                    PillKeyCap(label: "Esc")
                    Text("· cancel").font(Tokens.Typography.pillStatus.font())
                }
                .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                .accessibilityLabel(PillDeck.escapeHint)
            } else if let overflow {
                Button(overflow) { model.perform(.reviewAll) }
                    .buttonStyle(.plain)
                    .font(Tokens.Typography.pillStatus.font())
                    .foregroundStyle(Tokens.Pill.Token.ink.color)
                    .accessibilityIdentifier("pill.action.reviewAll")
            }
        }
    }

    /// The text lane's lines, broken in the real font at the lane width.
    private func wordLines(width: CGFloat, maxLines: Int) -> PillTextLane.Lines? {
        guard let text = content.words.text, !text.isEmpty else { return nil }
        let font = Tokens.Typography.pillTranscript.nsFont()
        return PillTextLane.tail(text, width: width, maxLines: maxLines) { s in
            ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    /// "42 words · Review all" when the final payload does not fit its two lines.
    private func overflowLabel(_ lines: PillTextLane.Lines?) -> String? {
        guard case .final = content.words, let lines, lines.clippedLeading else { return nil }
        return PillTextLane.reviewAllLabel(wordCount: lines.wordCount)
    }
}

extension PillContent.Trailing {
    var isTimer: Bool { if case .timer = self { return true }; return false }
}

private extension View {
    /// Pins a row to its rect in the pill's top-left coordinate space.
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .padding(.leading, rect.minX)
            .padding(.top, rect.minY)
    }
}

/// The text lane: natural-language words, the newest lines only, a leading fade when earlier lines
/// scrolled away, and a 2 px dotted underline 3 px below the baseline on every wrapped fragment of an
/// uncertain word or phrase. S5: the marks come from `MarkMapping` (spans aligned through formatting),
/// placed on whole grapheme clusters (S10), and each opens word review on click or from VoiceOver.
struct PillWordsLane: View {
    let lines: PillTextLane.Lines?
    let words: PillContent.Words
    /// S5 — the final text's marks (`PillViewModel.marks(for:)`); empty for live or fixed words.
    var marks: MarkMapping = .empty
    var onReview: (Int, CGRect?) -> Void = { _, _ in }
    /// S3 — keyboard / VoiceOver focus on a line or an uncertain word (`PillFocusReport`).
    var onFocus: ((Bool, String) -> Void)? = nil

    var body: some View {
        let fragments = markFragments
        VStack(alignment: .leading, spacing: 0) {
            if let lines {
                ForEach(Array(lines.lines.enumerated()), id: \.offset) { index, line in
                    let onLine = fragments.filter { $0.line == index }
                    ZStack(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                        Text(line)
                            .font(Tokens.Typography.pillTranscript.font())
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .pillFocusReport("words.line.\(index)", onFocus)
                        if !onLine.isEmpty {
                            PillMarkUnderlines(fragments: onLine)
                                .alignmentGuide(.firstTextBaseline) { _ in -MarkStyle.baselineOffset }
                        }
                    }
                    .frame(height: PillLaneLayout.lineHeight, alignment: .leading)
                    .overlay(alignment: .topLeading) { targets(onLine) }
                    .mask(fadeMask(first: index == 0 && lines.clippedLeading))
                }
            }
        }
        .accessibilityIdentifier("pill.words")
    }

    /// The marks' pieces on the drawn lines, measured in the lane's font.
    private var markFragments: [MarkFragment] {
        guard case .final(let text) = words, let lines, !marks.isEmpty else { return [] }
        let font = Tokens.Typography.pillTranscript.nsFont()
        return MarkFragments.layout(text: text, lines: lines.lines, marks: marks.marks) { s in
            ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    @ViewBuilder
    private func targets(_ fragments: [MarkFragment]) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(fragments.enumerated()), id: \.offset) { _, fragment in
                if let mark = marks.mark(id: fragment.markID) {
                    PillMarkTarget(mark: mark, width: fragment.width, height: PillLaneLayout.lineHeight) { rect in
                        onReview(mark.id, rect)
                    }
                    .pillFocusReport("words.mark.\(mark.id).\(fragment.line)", onFocus)
                    .offset(x: fragment.x)
                }
            }
        }
    }

    private var ink: Color {
        if case .fixed = words { return Tokens.Pill.Token.secondaryInk.color }
        return Tokens.Pill.Token.ink.color
    }

    private func fadeMask(first: Bool) -> some View {
        LinearGradient(stops: first
                        ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)]
                        : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// The deixis chip row: thumbnails in the design's tag style (`Radius.keyCap`, `key` type,
/// `Pill.controlBorder` outline), plus the turn's one-line note.
struct PillChipRow: View {
    let chips: [PillDeixisChip]
    let note: String?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                HStack(spacing: 4) {
                    if let image = chip.thumbnail {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 22, height: 12)
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Tokens.Pill.Token.controlBorder.color, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                            .frame(width: 22, height: 12)
                    }
                    Text(chip.label).font(Tokens.Typography.key.font()).lineLimit(1)
                }
                .padding(.horizontal, 4)
                .frame(height: PillLaneLayout.chipHeight)
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.keyCap)
                    .strokeBorder(Tokens.Pill.Token.controlBorder.color, lineWidth: 1))
                .opacity(chip.pending ? 0.6 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Box: \(chip.label)")
                .accessibilityIdentifier("pill.chip")
            }
            if let note {
                Text(note).font(Tokens.Typography.pillStatus.font()).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("pill.note")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
    }
}

/// The full-width action row (204 pt states): primary filled, the rest outlined; labelled, never
/// icon-only (design §11).
struct PillActionRow: View {
    let buttons: [PillButton]
    let perform: (PillActionKind) -> Void
    /// S3 — keyboard / VoiceOver focus on a button (`PillFocusReport`): it pauses the preview dwell.
    var onFocus: ((Bool, String) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            ForEach(buttons) { button in
                Button { perform(button.action) } label: {
                    Text(button.label)
                        .font(Tokens.Typography.pillStatus.font())
                        .padding(.horizontal, 10)
                        .frame(minHeight: Tokens.ControlSize.compactMinimumHeight)
                        .foregroundStyle(button.primary ? Tokens.Pill.Token.onPrimary.color : Tokens.Pill.Token.ink.color)
                        .background(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                            .fill(button.primary ? Tokens.Pill.Token.primary.color : Tokens.Pill.Token.control.color))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                            .strokeBorder(button.primary ? Color.clear : Tokens.Pill.Token.controlBorder.color, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(button.identifier)
                .pillFocusReport("action.\(button.identifier)", onFocus)
                // S10 — reading order: left to right, the primary recovery first as drawn.
                .accessibilitySortPriority(PillReadingOrder.actionPriority(index: buttons.firstIndex(of: button) ?? 0,
                                                                           count: buttons.count))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)   // S10
    }
}

/// A key cap ("Esc", "fn / 🌐") in the `key` type.
struct PillKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Tokens.Typography.key.font())
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.keyCap)
                .strokeBorder(Tokens.Pill.Token.controlBorder.color, lineWidth: 1))
    }
}

// MARK: - W3H · transform before / after rows (S12 R1 / R2; design §4, §6, §8.8)
//
// S12's `TransformPreviewRows` drawn in the pill's own anatomy: R1 while the edit runs (the instruction,
// "Microphone closed · original text unchanged"), R1's edited final preview (the original struck
// through over the edited text, nothing replaced yet; Replace text / Cancel only in manual review), and
// R2 "✓ Updated in <app>" with the edited text and Undo. The rows come from the transform landing
// (AppDelegate's W3H block publishes `PillViewModel.transformRows`); this region only decides which
// rows describe the stage on screen and how they are laid out.

/// Which of S12's rows the pill draws for the transform stage it shows. Rows left over from another
/// phase (the previous edit's "Updated", a preview that was cancelled) are never drawn over a stage
/// they do not describe.
public enum PillTransformRows {
    public static func drawn(for state: PillState, rows: TransformPreviewRows?) -> TransformPreviewRows? {
        guard case .transform(let info) = state, let rows else { return nil }
        switch info.stage {
        case .editing:
            return rows.designStateKey == "editing" && rows.before == nil ? rows : nil
        case .notice:
            // R1's edited final preview: S12's reducer shows it as a notice line while it dwells.
            return rows.designStateKey == "editing" && rows.before != nil ? rows : nil
        case .done(let changed):
            return changed > 0 && rows.designStateKey == "undo" ? rows : nil
        case .warm:
            return nil
        }
    }
}

extension PillViewModel {
    /// S12's rows for the transform on screen, when they describe it.
    public var drawnTransformRows: TransformPreviewRows? { PillTransformRows.drawn(for: state, rows: transformRows) }
}

extension PillContent {
    /// The transform's own status, words, helper and buttons (S12 `TransformPreviewRows`) in place of
    /// the reducer's one-line summary ("Preview · removed → added"). The words are drawn live-styled:
    /// an edit carries no confidence marks and no "Review all". Nil rows change nothing.
    public func drawingTransform(_ rows: TransformPreviewRows?) -> PillContent {
        guard let rows else { return self }
        var content = self
        content.status = rows.status
        content.helper = rows.helper
        content.words = rows.text.isEmpty ? .none : .live(rows.text)
        content.buttons = rows.buttons.compactMap { button in
            PillActionKind(rawValue: button.action).map { PillButton(button.label, $0, primary: button.primary) }
        }
        content.spoolKey = rows.designStateKey
        return content
    }
}

/// The text lane of R1's edited preview: the original, struck through in secondary ink, over the
/// edited text in ink. Both start two words before the first difference (a leading "…" when earlier
/// words are unchanged), so the lane shows the change rather than the unchanged start of a long
/// selection. One line each; when a deixis chip row takes the second line, the edited text alone.
struct PillTransformLane: View {
    struct Model: Equatable {
        var before: String?
        var after: String

        init?(rows: TransformPreviewRows?, lineCount: Int) {
            guard let rows, let original = rows.before else { return nil }
            let lines = Self.excerpt(before: original, after: rows.text)
            before = lineCount >= 2 ? lines.before : nil
            after = lines.after
        }

        /// Both texts from `lead` words before the first word that differs.
        static func excerpt(before: String, after: String, lead: Int = 2) -> (before: String, after: String) {
            let old = before.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            let new = after.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            var same = 0
            while same < min(old.count, new.count), old[same] == new[same] { same += 1 }
            let start = max(0, same - lead)
            let prefix = start > 0 ? "…" : ""
            return (prefix + old[start...].joined(separator: " "), prefix + new[start...].joined(separator: " "))
        }
    }

    let model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let before = model.before {
                Text(before)
                    .font(Tokens.Typography.pillTranscript.font())
                    .strikethrough(true, color: Tokens.Pill.Token.secondaryInk.color)
                    .foregroundStyle(Tokens.Pill.Token.secondaryInk.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: PillLaneLayout.lineHeight, alignment: .leading)
                    .accessibilityLabel("Original: \(before)")
                    .accessibilityIdentifier("pill.transform.before")
            }
            Text(model.after)
                .font(Tokens.Typography.pillTranscript.font())
                .foregroundStyle(Tokens.Pill.Token.ink.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: PillLaneLayout.lineHeight, alignment: .leading)
                .accessibilityLabel("Edited: \(model.after)")
                .accessibilityIdentifier("pill.transform.after")
        }
        .accessibilityIdentifier("pill.words")
    }
}
