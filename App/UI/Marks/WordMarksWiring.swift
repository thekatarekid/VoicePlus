import AppKit
import Combine
import Engine
import Foundation
import Injection
import Shared

// S5 — the glue: preview and landed marks both edit directly in the notch. Landed marks go onto the
// destination through the support ladder, and every correction is range-guarded.

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
    /// Where a landed mark anchors when no word rect is known.
    public var fallbackAnchor: () -> CGRect = {
        let p = NSEvent.mouseLocation
        return CGRect(x: p.x, y: p.y - 10, width: 1, height: 20)
    }

    // State.
    public private(set) var tracker: DestinationMarkTracking?
    public private(set) var applier: WordCorrectionApplier?
    /// D09 once per app per session; the Apps pane's badge carries it from then on.
    public private(set) var unavailableNoticed: Set<String> = []
    private var lastLanded: String?
    /// The payload text the current destination session came from (`TurnRecord.finalText`).
    private var sessionPayload: String?
    private var subscriptions: Set<AnyCancellable> = []

    public init(pill: PillViewModel, ladder: WordMarkLadder = WordMarkLadder(),
                recorder: WordMarkCapabilityRecording?, destination: MarkDestinationReading?,
                spelling: SpellingMemory?, clipboard: CorrectionClipboard, store: TurnStore?,
                makeEditor: @escaping (FocusSnapshot?) -> MarkTextEditing,
                makeTracker: @escaping (DestinationMarkSession, MarkGeometrySource, WordMarksCoordinator) -> DestinationMarkTracking,
                notice: @escaping (RecoveryEntry) -> Void) {
        self.pill = pill
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

    /// Hooks the pill's dotted words and delivery rows.
    public func bind() {
        pill.onReviewMark = { [weak self] mark, mapping, anchor in self?.openFromPill(mark, mapping: mapping, anchor: anchor) }
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
            pill.beginEditingMark(mark.id)
            return
        }
        if let session = tracker?.session, let landed = session.marks.first(where: { $0.text == mark.text }) {
            openDestination(landed.id, box: anchor ?? fallbackAnchor())
        }
    }

    // MARK: In the destination (after insertion)

    private func pillChanged(_ state: PillState) {
        switch state {
        case .landed(let info):
            guard info.text != lastLanded else { return }
            lastLanded = info.text
            landed(text: info.text)
        case .finalPreview:
            lastLanded = nil
        default:
            break
        }
    }

    /// The text landed (verified or not): put remaining marks on the destination when the ladder allows.
    public func landed(text: String) {
        let mapping = pill.markMapping(for: text)
        let marks = mapping.marks
        guard !marks.isEmpty else { return }
        tracker?.stop()
        tracker = nil
        guard let destination, let front = destination.frontmost() else { return }
        let tier = ladder.tier(for: front.bundleID)
        guard tier != .native else { return }   // VoicePlus's own fields draw their own marks.

        let field = destination.landedField(pid: front.pid)
        guard let field, let value = field.value,
              let range = LandedRangeLocator.locate(text: text, value: value, caret: field.caret) else {
            // The landed range cannot be verified: nothing is drawn and nothing is replaced.
            if !mapping.isEmpty { noticeUnavailable(front.bundleID) }
            return
        }

        let session = DestinationMarkSession(bundleID: front.bundleID, tier: tier, landed: range, text: text, marks: marks)
        sessionPayload = text
        let applier = WordCorrectionApplier(editor: makeEditor(front), spelling: spelling)
        self.applier = applier
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
        pill.beginDestinationEditing(mark) { [weak self, weak session] replacement in
            guard let self, let session, let applier = self.applier,
                  self.tracker?.session === session else { return false }
            let result = applier.apply(.replace(replacement, remember: false), mark: mark, in: session)
            switch result {
            case .replaced:
                self.pill.resolveMarks([mark.id])
                self.updateRecord(for: session)
                self.tracker?.revalidate()
                return true
            default:
                self.unappliedCorrection = replacement
                self.pill.showLaneNote("The text has changed. Copy this correction instead.")
                return false
            }
        }
    }

    /// A visible bracket suggestion applies immediately through the same destination range guard.
    public func acceptDestinationSuggestion(_ markID: Int, replacement: String) {
        guard let session = tracker?.session, let mark = session.marks.first(where: { $0.id == markID }),
              mark.alternatives.contains(replacement), let applier else { return }
        switch applier.apply(.replace(replacement, remember: false), mark: mark, in: session) {
        case .replaced:
            pill.onLearnDraft?(mark.text, replacement)
            pill.resolveMarks([mark.id])
            updateRecord(for: session)
            tracker?.revalidate()
        default:
            unappliedCorrection = replacement
            notice(RecoveryCatalog.entry(.D10))
        }
    }

    private func noticeUnavailable(_ bundleID: String) {
        guard unavailableNoticed.insert(bundleID).inserted else { return }
        notice(RecoveryCatalog.entry(.D09))
    }

    /// Review and Today keep only the unresolved marks (corrected or kept words clear for this turn).
    /// Ranges are the payload's (`TurnRecord.finalText` is never revised), from the turn's full mapping.
    /// A6 — mapped onto the stored text itself, so they index `finalText` as it is on disk
    /// (continuation whitespace included) whatever text the delivery row carried (`UncertainSpans`).
    private func updateRecord(for session: DestinationMarkSession) {
        guard let store, let text = sessionPayload, let entry = Self.recordEntry(for: text, in: store) else { return }
        let remaining = Set(session.marks.map(\.id))
        let ranges = UncertaintyMarkMapper.map(source: pill.finalSpans, finalText: entry.record.finalText).marks
            .filter { remaining.contains($0.id) }.map(\.range)
        store.update(entry.id) { $0.uncertainSpans = ranges }
    }

    /// The turn whose payload `text` is: by the exact text, else by the words once continuation
    /// whitespace is set aside (a delivery row may carry the payload trimmed; the record never is).
    static func recordEntry(for text: String, in store: TurnStore) -> TurnEntry? {
        let recent = store.recent(limit: 20)
        if let exact = recent.first(where: { $0.record.finalText == text }) { return exact }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        return recent.first { $0.record.finalText.trimmingCharacters(in: .whitespacesAndNewlines) == words }
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
            pill: pill,
            recorder: DefaultsWordMarkCapabilityRecorder(), destination: LiveMarkDestination(system: system),
            spelling: spelling, clipboard: PasteboardCorrectionClipboard(), store: store,
            makeEditor: { FocusedFieldMarkEditor(system: system, landedIn: $0) },
            makeTracker: { session, geometry, coordinator in
                let overlay = DestinationMarksOverlay()
                let tracker = DestinationMarksTracker(session: session, geometry: geometry, overlay: overlay,
                                                      recorder: coordinator.recorder)
                overlay.onClick = { [weak coordinator] id, box in coordinator?.openDestination(id, box: box) }
                overlay.onSuggestion = { [weak coordinator] id, replacement in
                    coordinator?.acceptDestinationSuggestion(id, replacement: replacement)
                }
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
