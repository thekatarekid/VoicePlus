import Engine
import Foundation
import Shared

// S7b — turn detail (design §8.1, prototype `case'turn'`; `DESIGN.md` §9.1): the final text
// (selectable, uncertain words marked), the uncertainty count, the original transcript when it
// differs (segmented Final text / Original transcript), the destination, the delivery evidence
// (method, verified or not), and Copy / Review / Delete — with the still held-tape Spool beside the
// delivery status (design §8.9).
//
// Renderings: loading "Opening saved text…"; empty — the fixture's turn empty ("No saved text
// here"); error "History can't be read" + Try again when the store can't be read; content, with
// S03 as a scoped banner (Copy text primary) when this turn's save failed and the words exist only
// in memory.

@MainActor
public final class TurnDetailModel: ObservableObject {
    /// The segmented switch over the text.
    public enum TextView: String, CaseIterable, Identifiable, Sendable {
        case final, original

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .final: return "Final text"
            case .original: return "Original transcript"
            }
        }
    }

    public let turnID: TurnID
    @Published public private(set) var state: SectionState = .loading(.turn, headline: TodayCopy.openingSavedText)
    @Published public private(set) var entry: TurnEntry?
    @Published public var textView: TextView = .final
    /// Review on an inserted turn: its uncertain words are listed and marked.
    @Published public private(set) var reviewing = false
    @Published public private(set) var notice: TodayNotice?
    @Published public var confirmingDelete = false
    /// The draft behind a held or partial turn (Review opens its recovery sheet). Read at `reload()`,
    /// never while a view is drawing.
    @Published public private(set) var draft: TodayDraft?
    public let retry = ScopedRetry()

    private weak var host: TodayDraftHost?

    public init(turnID: TurnID, host: TodayDraftHost) {
        self.turnID = turnID
        self.host = host
    }

    // MARK: Loading

    /// Reads the turn. Memory first (this session's turns are always there), then the store.
    public func reload() async {
        guard let reader = host?.turnReader() else {
            entry = nil
            state = .error(RecoveryCatalog.entry(.S01).rendered(hotkey: host?.hotkeyLabel ?? ""))
            return
        }
        if entry == nil { state = .loading(.turn, headline: TodayCopy.openingSavedText) }
        let id = turnID
        let result = await Task.detached(priority: .userInitiated) { Result { try reader.turnEntry(id) } }.value
        switch result {
        case .success(let found?) where TodayTag.of(found) != nil:
            entry = found
            draft = TodayDraft.isRecoverable(found) ? host?.draft(forTurn: id) : nil
            state = .content
            if !hasOriginal { textView = .final }
        case .success:
            // Gone (deleted, or history off and never kept), or still in flight.
            entry = nil
            draft = nil
            state = .empty(.turn, hotkey: host?.hotkeyLabel ?? "")
        case .failure:
            if entry == nil { state = .error(RecoveryCatalog.entry(.S01).rendered(hotkey: host?.hotkeyLabel ?? "")) }
        }
    }

    public func retryLoad() async { await retry.run { await self.reload() } }

    // MARK: What the page says

    private var record: TurnRecord? { entry?.record }

    /// "Can we meet with Mira on…" — the turn's own words; the fixture's "Friday check-in" is sample.
    public var title: String { record.map { TodayFormat.title($0.finalText) } ?? DesignScreen.turn.name }

    /// "Mail · Today, 12:42 · 9 words".
    public var subtitle: String { record.map { TodayFormat.turnSubtitle($0) } ?? "" }

    public var tag: TodayTag? { entry.flatMap(TodayTag.of) }


    /// S03 as a scoped banner: the save failed, the words exist only in this session.
    public var banner: SectionBanner? {
        guard let reader = host?.turnReader(), reader.saveFailed(turnID) else { return nil }
        return .recovery(RecoveryCatalog.entry(.S03))
    }

    /// The text the segmented switch shows. The original is offered only when it differs.
    public var displayedText: String {
        guard let record else { return "" }
        return textView == .original && hasOriginal ? record.rawText : record.finalText
    }

    /// Uncertainty marks apply to the final text only (their ranges are in its UTF-16 units).
    public var displayedSpans: [Range<Int>] {
        textView == .final ? (record?.uncertainSpans ?? []) : []
    }

    public var hasOriginal: Bool {
        guard let record else { return false }
        let raw = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty && raw != record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var uncertaintyCount: Int { record?.uncertainSpans.count ?? 0 }

    /// "1 word to review" · "No words to review".
    public var uncertaintyLine: String {
        switch uncertaintyCount {
        case 0: return "No words to review"
        case 1: return "1 word to review"
        case let n: return "\(n) words to review"
        }
    }

    public var uncertainWords: [String] {
        guard let record else { return [] }
        return TodayFormat.words(in: record.finalText, spans: record.uncertainSpans)
    }

    /// "Mail · Text area" — where the turn was aimed.
    public var destinationLine: String {
        guard let record else { return "" }
        let app = TodayFormat.destination(record)
        guard let role = record.destination.role else { return app }
        let field = RecoveryTarget(pid: 0, bundleID: "", appName: app, role: role,
                                   isSecure: record.destination.isSecure, isEditable: true).fieldKind
        return "\(app) · \(field)"
    }

    /// The delivery row: what happened, by which method, and whether readback confirmed it.
    public var deliveryDetail: String { record.map(Self.deliveryEvidence) ?? "" }

    /// The line beside the still held-tape Spool: the delivery status, or the held note for text
    /// that is still waiting (design §8.9 "Still held-tape pose alongside delivery status").
    public var statusLine: String {
        guard let entry else { return "" }
        let app = TodayFormat.appName(entry.record)
        switch TodayTag.of(entry) {
        case .held?: return SpoolSurfacePolicy.heldNote
        case .inserted?, .toReview?: return app.map { "✓ Inserted in \($0)" } ?? "✓ Inserted"
        case .unconfirmed?:
            return entry.record.outcome?.isPartial == true
                ? "⚠ \(RecoveryCatalog.entry(.D07).headline)" : "⚠ \(RecoveryCatalog.entry(.D06).headline)"
        case .undone?: return "Inserted, then undone"
        case .notInserted?, nil: return TodayTag.notInserted.label
        }
    }

    /// "Kept until resolved" / "Kept for this session only".
    public var retentionLabel: String {
        guard let entry else { return "" }
        return TodayRetention.of(entry, saveFailed: host?.turnReader()?.saveFailed(turnID) ?? false).label
    }

    /// Review exists when there is something to review: held or partial text (its recovery sheet),
    /// or uncertain words in the final text.
    public var canReview: Bool { draft != nil || uncertaintyCount > 0 }

    static func deliveryEvidence(_ record: TurnRecord) -> String {
        let app = TodayFormat.appName(record)
        let into = app.map { " in \($0)" } ?? ""
        guard let outcome = record.outcome else { return "Not inserted. Nothing was written." }
        switch outcome {
        case let .delivered(verified, method):
            let by = methodPhrase(method)
            return verified
                ? "Inserted\(into)\(by). Readback confirmed the text."
                : "Inserted\(into)\(by). Readback couldn’t confirm it — check the field before trying again."
        case .partial(let method):
            return "Only part may have been inserted\(into)\(methodPhrase(method)). Check the destination to avoid duplicate text."
        case .held(let reason):
            let entry = RecoveryCatalog.entry(forDeliveryReason: reason)
            return entry.id == .D01 ? "Your destination changed before insertion. Nothing was inserted."
                                    : "\(TodayFormat.sentence(entry.headline)) \(TodayCopy.nothingInserted)"
        case .failed(let reason):
            let entry = RecoveryCatalog.entry(forDeliveryReason: reason)
            return "\(TodayFormat.sentence(entry.headline)) \(entry.consequence)"
        }
    }

    /// " by paste" — the injection method in words, never its raw token.
    static func methodPhrase(_ method: String) -> String {
        switch method {
        case "ax": return " through Accessibility"
        case "keystroke": return " by typing"
        case "adapter": return " through the app’s adapter"
        case "paste": return " by paste"
        default: return ""
        }
    }

    // MARK: Actions

    /// Copy: acknowledged only when the pasteboard was read back. Copying a turn does not resolve a
    /// held draft — the recovery sheet does that.
    public func copy() {
        guard let host, let text = record?.finalText, !text.isEmpty else { return }
        notice = host.pasteboard.copyVerified(text) ? .copied : .problem(.D08)
    }

    /// Review: held or partial text opens its recovery sheet; otherwise the uncertain words are
    /// listed and marked.
    public func review() {
        if let draft {
            host?.presentRecovery(draft)
        } else if uncertaintyCount > 0 {
            textView = .final
            reviewing.toggle()
        }
    }

    /// Delete… always asks: it deletes the turn from this Mac.
    public func askDelete() { confirmingDelete = true }

    public func cancelDelete() { confirmingDelete = false }

    public func confirmDelete() {
        confirmingDelete = false
        host?.deleteTurn(turnID)
        host?.closeTurn()
    }

    public static let deleteHeadline = "Delete this dictation?"
    public static let deleteDetail = "Its text and delivery record will be deleted from this Mac. This can’t be undone."
    public static let deleteHeldDetail = "It is still held. Its text and delivery record will be deleted from this Mac. This can’t be undone."
}
