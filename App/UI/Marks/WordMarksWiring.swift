import AppKit
import Combine
import Engine
import Foundation
import Injection
import Shared

// S5 — the glue: the pill's marks open word review (pausing the final preview's dwell, S3), choices
// made before insertion are applied to the verified range right after the text lands, landed marks
// go onto the destination through the support ladder, and every correction is range-guarded.

/// The dwell the Review surface pauses and resumes (S3's `TurnController`).
public protocol ReviewDwellControlling: AnyObject {
    func pauseDwell(_ reason: DwellPause)
    func resumeDwell(_ reason: DwellPause)
    func resetDwell()
}

extension TurnController: ReviewDwellControlling {}

/// The correction popover, as the coordinator drives it (`CorrectionPopoverController` live).
public protocol CorrectionPopoverPresenting: AnyObject {
    var onDecision: ((WordReviewDecision, CorrectionPopoverModel) -> Void)? { get set }
    var onCopy: ((String) -> Void)? { get set }
    var onNext: (() -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isShown: Bool { get }
    var model: CorrectionPopoverModel? { get }
    func show(_ model: CorrectionPopoverModel, anchoredTo word: CGRect, hasNext: Bool)
    func showTextChanged(replacement: String)
    func close()
}

extension CorrectionPopoverController: CorrectionPopoverPresenting {}

/// The Review surface "Review all" opens (`FinalTextReviewPanel` live).
public protocol FinalTextReviewPresenting: AnyObject {
    var onReviewMark: ((Int) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    var isShown: Bool { get }
    func show(_ model: FinalTextReviewModel, below anchor: CGRect)
    func update(_ mapping: MarkMapping)
    func close()
}

extension FinalTextReviewPanel: FinalTextReviewPresenting {}

/// The field the text just landed in.
public struct LandedField {
    public var geometry: MarkGeometrySource
    public var value: String?
    public var caret: Int?

    public init(geometry: MarkGeometrySource, value: String?, caret: Int?) {
        self.geometry = geometry
        self.value = value
        self.caret = caret
    }
}

/// Reads the destination right after an insert.
public protocol MarkDestinationReading: AnyObject {
    /// The frontmost app and its focused element's identity.
    func frontmost() -> FocusSnapshot?
    /// The focused field of `pid`: geometry source, value and caret.
    func landedField(pid: Int32) -> LandedField?
}

/// Live: `SystemAccess` for the app, AX on the focused element for the field.
public final class LiveMarkDestination: MarkDestinationReading {
    private let system: SystemAccess
    public init(system: SystemAccess) { self.system = system }

    public func frontmost() -> FocusSnapshot? { system.frontmostApp() }

    public func landedField(pid: Int32) -> LandedField? {
        guard let geometry = AXElementMarkGeometry.focused(in: pid) else { return nil }
        return LandedField(geometry: geometry, value: geometry.currentValue(), caret: geometry.selectedRange?.upperBound)
    }
}

public protocol DestinationMarkTracking: AnyObject {
    var session: DestinationMarkSession { get }
    var onCleared: ((MarkClearReason) -> Void)? { get set }
    func start()
    func stop()
    @discardableResult func revalidate() -> DestinationMarkSession.Phase
}

extension DestinationMarksTracker: DestinationMarkTracking {}

/// S5's coordinator. Main thread.
public final class WordMarksCoordinator {
    public let pill: PillViewModel
    public weak var dwell: ReviewDwellControlling?
    public let popover: CorrectionPopoverPresenting
    public let review: FinalTextReviewPresenting
    public var ladder: WordMarkLadder
    public var recorder: WordMarkCapabilityRecording?
    public var destination: MarkDestinationReading?
    public var spelling: SpellingMemory?
    public let clipboard: CorrectionClipboard
    public var store: TurnStore?
    /// The editor for a landing (range-guarded replace in the field the text landed in).
    public var makeEditor: (FocusSnapshot?) -> MarkTextEditing
    /// The tracker that keeps a session's overlay true; its overlay reports clicks to `openDestination`.
    public var makeTracker: (DestinationMarkSession, MarkGeometrySource, WordMarksCoordinator) -> DestinationMarkTracking
    /// A catalogue notice on the pill once the delivery row is done (D09 / D10).
    public var notice: (RecoveryEntry) -> Void
    /// Where "Review all" and keyboard-opened reviews anchor when no word rect is known.
    public var fallbackAnchor: () -> CGRect = {
        let p = NSEvent.mouseLocation
        return CGRect(x: p.x, y: p.y - 10, width: 1, height: 20)
    }

    // State.
    public private(set) var staged = StagedCorrections()
    /// The marks the staged choices belong to, by id, and the text they were made on.
    private var stagedMarks: [Int: UncertainMark] = [:]
    private var stagedText: String?
    public private(set) var tracker: DestinationMarkTracking?
    public private(set) var applier: WordCorrectionApplier?
    /// D09 once per app per session; the Apps pane's badge carries it from then on.
    public private(set) var unavailableNoticed: Set<String> = []
    private var reviewOrigin: CorrectionPopoverModel.Origin?
    private var queue: [UncertainMark] = []
    private var queueTotal = 0
    private var decidedDuringReview = false
    private var reviewAllOpen = false
    private var lastLanded: String?
    /// The payload text the current destination session came from (`TurnRecord.finalText`).
    private var sessionPayload: String?
    private var subscriptions: Set<AnyCancellable> = []

    public init(pill: PillViewModel, dwell: ReviewDwellControlling?, popover: CorrectionPopoverPresenting,
                review: FinalTextReviewPresenting, ladder: WordMarkLadder = WordMarkLadder(),
                recorder: WordMarkCapabilityRecording?, destination: MarkDestinationReading?,
                spelling: SpellingMemory?, clipboard: CorrectionClipboard, store: TurnStore?,
                makeEditor: @escaping (FocusSnapshot?) -> MarkTextEditing,
                makeTracker: @escaping (DestinationMarkSession, MarkGeometrySource, WordMarksCoordinator) -> DestinationMarkTracking,
                notice: @escaping (RecoveryEntry) -> Void) {
        self.pill = pill
        self.dwell = dwell
        self.popover = popover
        self.review = review
        self.ladder = ladder
        self.recorder = recorder
        self.destination = destination
        self.spelling = spelling
        self.clipboard = clipboard
        self.store = store
        self.makeEditor = makeEditor
        self.makeTracker = makeTracker
        self.notice = notice
    }

    /// Hooks the pill (dotted words, "Review all", delivery rows) and the popovers.
    public func bind() {
        pill.onReviewMark = { [weak self] mark, mapping, anchor in self?.openFromPill(mark, mapping: mapping, anchor: anchor) }
        pill.onReviewAll = { [weak self] mapping in self?.openReviewAll(mapping) }
        popover.onDecision = { [weak self] decision, model in self?.decided(decision, model: model) }
        popover.onCopy = { [weak self] text in self?.clipboard.copy(text) }
        popover.onNext = { [weak self] in self?.showNext() }
        popover.onClose = { [weak self] in self?.popoverClosed() }
        review.onReviewMark = { [weak self] id in self?.reviewFromPanel(id) }
        review.onClose = { [weak self] in self?.reviewAllClosed() }
        pill.$state
            .sink { [weak self] state in self?.pillChanged(state) }
            .store(in: &subscriptions)
        // D10's "Copy correction" on the pill notice copies the correction that could not be applied.
        let previous = pill.onAction
        pill.onAction = { [weak self] action, shown in
            if let self, action == .copy, case .error(let message) = shown,
               message == RecoveryCatalog.entry(.D10).headline, let text = self.unappliedCorrection {
                self.clipboard.copy(text)
                return
            }
            previous?(action, shown)
        }
    }

    /// The last correction the range guard refused (D10), for "Copy correction".
    public private(set) var unappliedCorrection: String?

    // MARK: In the pill (before insertion)

    /// A dotted word in the pill: in the final preview the dwell pauses (Review) while the popover is
    /// open; on a delivery row the word is reviewed where it landed.
    public func openFromPill(_ mark: UncertainMark, mapping: MarkMapping, anchor: CGRect?) {
        if case .finalPreview = pill.state {
            queue = []
            queueTotal = 1
            if !reviewAllOpen { decidedDuringReview = false }
            present(mark, origin: .preview, confidence: mapping.confidenceAvailable, anchor: anchor ?? fallbackAnchor())
            return
        }
        if let session = tracker?.session, let landed = session.marks.first(where: { $0.text == mark.text }) {
            openDestination(landed.id, box: anchor ?? fallbackAnchor())
        }
    }

    /// "Review all": the whole final text with its marks.
    public func openReviewAll(_ mapping: MarkMapping) {
        reviewAllOpen = true
        decidedDuringReview = false
        review.show(FinalTextReviewModel(mapping: mapping), below: fallbackAnchor())
    }

    private func reviewFromPanel(_ id: Int) {
        let mapping = pill.markMapping(for: pill.actionText)
        guard let mark = mapping.mark(id: id) else { return }
        queue = mapping.marks.filter { $0.id > id }
        queueTotal = mapping.marks.count
        present(mark, origin: .preview, confidence: mapping.confidenceAvailable, anchor: fallbackAnchor(),
                index: (mapping.marks.firstIndex { $0.id == id } ?? 0) + 1)
    }

    private func present(_ mark: UncertainMark, origin: CorrectionPopoverModel.Origin, confidence: Bool, anchor: CGRect,
                         index: Int = 1) {
        if origin == .preview, reviewOrigin == nil { dwell?.pauseDwell(.review) }
        reviewOrigin = origin
        let model = CorrectionPopoverModel(mark: mark, origin: origin, confidenceAvailable: confidence,
                                           position: queueTotal > 1 ? (index, queueTotal) : nil)
        popover.show(model, anchoredTo: anchor, hasNext: !queue.isEmpty)
    }

    private func showNext() {
        guard let origin = reviewOrigin, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        present(next, origin: origin, confidence: popover.model?.confidenceAvailable ?? true,
                anchor: fallbackAnchor(), index: queueTotal - queue.count)
    }

    // MARK: Decisions

    func decided(_ decision: WordReviewDecision, model: CorrectionPopoverModel) {
        switch model.origin {
        case .preview:
            guard decision != .dismiss else { return }
            staged.record(decision, for: model.mark.id)
            stagedMarks[model.mark.id] = model.mark
            stagedText = pill.actionText
            pill.resolveMarks([model.mark.id])
            decidedDuringReview = true
            review.update(pill.markMapping(for: pill.actionText))
            advanceOrClose()
        case .destination:
            guard let session = tracker?.session, let applier else {
                if case .replace(let text, _) = decision { popover.showTextChanged(replacement: text) } else { popover.close() }
                return
            }
            let result = applier.apply(decision, mark: model.mark, in: session)
            switch result {
            case .replaced, .kept:
                pill.resolveMarks([model.mark.id])
                updateRecord(for: session)
                tracker?.revalidate()
                popover.close()
            case .dismissed:
                break
            case .textChanged(let replacement):
                // D10 — nothing was replaced; the stale range goes; the correction can be copied.
                unappliedCorrection = replacement
                updateRecord(for: session)
                tracker?.revalidate()
                popover.showTextChanged(replacement: replacement)
            }
        }
    }

    private func advanceOrClose() {
        if queue.isEmpty { popover.close() } else { showNext() }
    }

    private func popoverClosed() {
        let origin = reviewOrigin
        reviewOrigin = nil
        queue = []
        if origin == .destination, case .correcting = pill.state { pill.hide() }
        guard origin == .preview, !reviewAllOpen else { return }
        resumePreview()
    }

    private func reviewAllClosed() {
        reviewAllOpen = false
        if popover.isShown { popover.close() }
        pill.endReview()
        resumePreview()
    }

    /// Review closed: the dwell resumes; a correction or Keep made during it starts it over (F2).
    private func resumePreview() {
        guard case .finalPreview = pill.state else { return }
        dwell?.resumeDwell(.review)
        if decidedDuringReview { dwell?.resetDwell() }
        decidedDuringReview = false
    }

    // MARK: In the destination (after insertion)

    private func pillChanged(_ state: PillState) {
        // The preview went (inserted, cancelled, held…) while its review was open: the review goes too.
        if case .finalPreview = state {} else if reviewOrigin == .preview || reviewAllOpen {
            if popover.isShown { popover.close() }
            if review.isShown { review.close() }
        }
        switch state {
        case .landed(let info):
            guard info.text != lastLanded else { return }
            lastLanded = info.text
            landed(text: info.text)
        case .finalPreview(let info):
            // A new payload: choices staged for another text are void (their turn went elsewhere).
            if let stagedText, stagedText != info.text { clearStaged() }
            lastLanded = nil
        case .held, .landedPartial, .cancelled:
            clearStaged()
        default:
            break
        }
    }

    /// The text landed (verified or not): apply staged choices through the range guard, keep Review
    /// and Today in step, and put the remaining marks on the destination when the ladder allows.
    public func landed(text: String) {
        let mapping = pill.markMapping(for: text)
        let pending = staged
        let marks = (mapping.marks + pending.resolved.compactMap { stagedMarks[$0] }).sorted { $0.id < $1.id }
        clearStaged()
        guard !marks.isEmpty else { return }
        tracker?.stop()
        tracker = nil
        guard let destination, let front = destination.frontmost() else { return }
        let tier = ladder.tier(for: front.bundleID)
        guard tier != .native else { return }   // VoicePlus's own fields draw their own marks.

        let field = destination.landedField(pid: front.pid)
        guard let field, let value = field.value,
              let range = LandedRangeLocator.locate(text: text, value: value, caret: field.caret) else {
            // The landed range cannot be verified: nothing is drawn and nothing is replaced. A chosen
            // spelling is copied instead (D10); a remembered one is still remembered.
            var copied: String?
            for (id, decision) in pending.decisions {
                guard case .replace(let replacement, let remember) = decision else { continue }
                if remember, let mark = marks.first(where: { $0.id == id }) {
                    spelling?.remember(heard: mark.heard.isEmpty ? mark.text : mark.heard, spelling: replacement, audioRange: 0...0)
                }
                copied = replacement
            }
            if let copied {
                unappliedCorrection = copied
                clipboard.copy(copied)
                notice(RecoveryCatalog.entry(.D10))
            } else if !mapping.isEmpty {
                noticeUnavailable(front.bundleID)
            }
            return
        }

        let session = DestinationMarkSession(bundleID: front.bundleID, tier: tier, landed: range, text: text, marks: marks)
        sessionPayload = text
        let applier = WordCorrectionApplier(editor: makeEditor(front), spelling: spelling)
        self.applier = applier
        for (id, decision) in pending.decisions {
            guard let mark = session.marks.first(where: { $0.id == id }) else { continue }
            if case .textChanged(let replacement) = applier.apply(decision, mark: mark, in: session) {
                unappliedCorrection = replacement
                clipboard.copy(replacement)
                notice(RecoveryCatalog.entry(.D10))
                break
            }
        }
        updateRecord(for: session)
        guard !session.marks.isEmpty, !session.phase.isCleared else { return }
        guard tier == .overlay else {
            noticeUnavailable(front.bundleID)
            return
        }
        let tracker = makeTracker(session, field.geometry, self)
        tracker.onCleared = { [weak self] reason in
            guard let self else { return }
            if reason == .noGeometry { self.noticeUnavailable(session.bundleID) }
            if self.tracker === tracker { self.tracker = nil }
        }
        self.tracker = tracker
        tracker.start()
    }

    /// A mark clicked in the destination: the popover opens at the word; the pill shows R0.
    public func openDestination(_ markID: Int, box: CGRect) {
        guard let session = tracker?.session, let mark = session.marks.first(where: { $0.id == markID }) else { return }
        if case .hidden = pill.state { pill.present(.correcting) }
        queue = []
        queueTotal = 1
        present(mark, origin: .destination, confidence: true, anchor: box)
    }

    private func noticeUnavailable(_ bundleID: String) {
        guard unavailableNoticed.insert(bundleID).inserted else { return }
        notice(RecoveryCatalog.entry(.D09))
    }

    private func clearStaged() {
        staged = StagedCorrections()
        stagedMarks = [:]
        stagedText = nil
    }

    /// Review and Today keep only the unresolved marks (corrected or kept words clear for this turn).
    /// Ranges are the payload's (`TurnRecord.finalText` is never revised), from the turn's full mapping.
    private func updateRecord(for session: DestinationMarkSession) {
        guard let store, let text = sessionPayload,
              let entry = store.recent(limit: 20).first(where: { $0.record.finalText == text }) else { return }
        let remaining = Set(session.marks.map(\.id))
        let ranges = UncertaintyMarkMapper.map(source: pill.finalSpans, finalText: text).marks
            .filter { remaining.contains($0.id) }.map(\.range)
        store.update(entry.id) { $0.uncertainSpans = ranges }
    }
}

// MARK: - Live wiring

public enum WordMarksWiring {
    /// The live coordinator (one per app).
    public private(set) static var current: WordMarksCoordinator?

    /// Called by the pill when a final payload arrives: installs the live coordinator once the turn
    /// controller exists (the composition root's S3 block), with no edit to the composition root.
    static func adoptIfNeeded(_ pill: PillViewModel) {
        guard current == nil, Thread.isMainThread, let turns = TurnWiring.current else { return }
        install(pill: pill, controller: turns.controller, store: turns.store)
    }

    @discardableResult
    public static func install(pill: PillViewModel, controller: TurnController, store: TurnStore?) -> WordMarksCoordinator {
        let system = controller.lander.system
        let spelling = controller.lander.correction?.correctionLog.map { CorrectionLogSpellingMemory(sink: $0) }
        let coordinator = WordMarksCoordinator(
            pill: pill, dwell: controller, popover: CorrectionPopoverController(), review: FinalTextReviewPanel(),
            recorder: DefaultsWordMarkCapabilityRecorder(), destination: LiveMarkDestination(system: system),
            spelling: spelling, clipboard: PasteboardCorrectionClipboard(), store: store,
            makeEditor: { FocusedFieldMarkEditor(system: system, landedIn: $0) },
            makeTracker: { session, geometry, coordinator in
                let overlay = DestinationMarksOverlay()
                let tracker = DestinationMarksTracker(session: session, geometry: geometry, overlay: overlay,
                                                      recorder: coordinator.recorder)
                overlay.onClick = { [weak coordinator] id, box in coordinator?.openDestination(id, box: box) }
                return tracker
            },
            notice: { [weak pill] entry in
                // After the delivery row's own dwell, and never over a turn that started since.
                DispatchQueue.main.asyncAfter(deadline: .now() + PillDwell.inserted + 0.25) {
                    guard let pill else { return }
                    switch pill.state {
                    case .hidden, .ready, .idle: pill.presentNotice(.error(message: entry.headline))
                    default: break
                    }
                }
            })
        coordinator.bind()
        current = coordinator
        return coordinator
    }
}
