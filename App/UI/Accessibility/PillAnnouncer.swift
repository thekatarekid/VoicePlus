import AppKit
import Combine
import Foundation

// S10 — what VoiceOver hears from the pill (design §11): the start of capture, its stop ("Microphone
// closed"), "Final text ready · N words to review", and the delivery result. Never a streaming token,
// a level tick, a timer tick or an animation: the artwork is hidden, and live words stay in the text
// lane for the user to read when they choose to.

/// One spoken line.
public struct PillAnnouncement: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Capture began (key down / latch): the pill's status ("Starting microphone…", "Listening").
        case start
        /// Capture closed ("Microphone closed · nothing inserted yet").
        case stop
        /// The final payload is showing: "Final text ready · N words to review".
        case final
        /// The one outcome of the write, or of the turn: inserted, not confirmed, partial, held,
        /// failed, cancelled.
        case delivery
        /// A state change that is none of the above but still needs saying once: latched, a
        /// microphone warning, mute, unavailable, a one-line notice, a meeting phase.
        case notice
    }

    public enum Priority: Equatable, Sendable {
        /// Queued behind what VoiceOver is saying.
        case medium
        /// Interrupts: problems the user must act on.
        case high
    }

    public var kind: Kind
    /// The line as the pill's copy writes it ("Final text ready · 1 word to review").
    public var text: String
    public var priority: Priority

    public init(_ kind: Kind, _ text: String, priority: Priority = .medium) {
        self.kind = kind
        self.text = text
        self.priority = priority
    }

    /// What VoiceOver is given: the status glyphs (⚠ ✓ ⊘ ●) dropped — the words already say it — and
    /// the " · " separator read as a pause.
    public var spoken: String { PillSpeech.spoken(text) }
}

/// Speech forms of pill copy.
public enum PillSpeech {
    /// Leading status glyphs the words already carry.
    static let glyphs: Set<Character> = ["⚠", "✓", "⊘", "●", "↺", "✕", "×"]

    public static func spoken(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, glyphs.contains(first) || first == "\u{FE0F}" || first == "\u{FE0E}" {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text.replacingOccurrences(of: PillCopy.statusSeparator, with: ", ")
    }

    /// The pill's accessibility label: the semantic state and the real outcome, never the live
    /// words or the ticking timer (those change every syllable / second and would be re-read on
    /// every change). The final payload and a state's fixed sentence are included.
    public static func containerLabel(_ content: PillContent) -> String {
        var parts = [spoken(content.status)]
        if case .destination(let name) = content.trailing { parts.append(name) }
        switch content.words {
        case .fixed(let sentence): parts.append(sentence)
        case .final(let text): parts.append(text)
        case .live, .none: break
        }
        parts.append(spoken(content.helper))
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// The announcement rules, as a pure state machine fed every state the pill draws (with the content
/// it renders, whether capture is open and whether a latch session is on). At most one line per
/// semantic event; a repeated event (the same state re-published, a level or timer tick, new live
/// words) says nothing.
public struct PillAnnouncer: Equatable, Sendable {
    /// Capture is open and its start has been announced.
    private var capturing = false
    /// The latch session has been announced; its later segments do not announce a new start.
    private var latchAnnounced = false
    /// The last event announced, so a re-published state never repeats it.
    private var lastEvent: String?

    public init() {}

    public mutating func next(_ state: PillState, content: PillContent, captureOpen: Bool,
                              latched: Bool = false) -> PillAnnouncement? {
        switch state {
        case .hidden, .ready:
            // The turn is over (or it is the hover hint): nothing to say; the next turn starts fresh.
            // Between latch segments the pill may retract while the session goes on: the latch is
            // not announced again for the next segment.
            let latchContinues = latched && latchAnnounced
            self = PillAnnouncer()
            latchAnnounced = latchContinues
            return nil

        case .idle, .starting, .listening, .listeningQuiet, .latched, .warning:
            return capture(state, content: content, latched: latched)

        case .preview:
            // Live words while capture is open: never announced. With no capture it is a notice.
            if captureOpen || capturing { return capture(state, content: content, latched: latched) }
            return once("notice:\(content.status)", .init(.notice, content.status))

        case .landing, .finishing:
            let wasCapturing = capturing
            capturing = false
            // A latched segment closing: the microphone stays open for the next one.
            if latched { return nil }
            latchAnnounced = false
            if case .finishing(true) = state {
                // Context Writer — "Writing" was already said when that face appeared.
                if content.status == WriterCopy.writingStatus { return nil }
                return once("stop:slow", .init(.notice, content.status))
            }
            guard wasCapturing else { return nil }
            return once("stop", .init(.stop, PillCopy.finishingHelper))

        case .finalPreview(let info):
            capturing = false
            var line = Self.finalReady
            // The count of marks drawn (S5 mapping); a T05 rewrite says "Review this phrase".
            if info.uncertainCount > 0 { line += PillCopy.statusSeparator + info.reviewLine }
            return once("final:\(info.uncertainCount):\(info.text)", .init(.final, line))

        case .inserting:
            // In flight; the result is what gets said.
            return nil

        case .landed, .landedPartial, .held, .error, .cancelled, .undoAvailable:
            // In latch, capture stays open under a segment's outcome row.
            if !captureOpen && !latched { capturing = false }
            return once("delivery:\(content.designKey):\(content.status)", outcome(.delivery, content))

        case .muted, .unavailable, .correcting, .editing, .transform:
            if !captureOpen { capturing = false }
            return once("notice:\(content.designKey):\(content.status)", outcome(.notice, content))

        case .meeting(let info):
            // The meeting clock ticks inside the row; only a phase change is said.
            return once("meeting:\(info.phase)", .init(.notice, content.status))
        }
    }

    /// "Final text ready" (design §11: final result availability, then the uncertainty count).
    public static let finalReady = "Final text ready"

    /// Context Writer (plan §4) — the writer's state changed for the turn on the pill. "Writing" is
    /// said once when the slow writer's face appears; "Polished N words" and "Not polished" are said
    /// with the landed row (its helper line), so nothing here repeats them.
    public mutating func writer(_ phase: PillWriterNote.Phase?) -> PillAnnouncement? {
        guard phase == .writing else { return nil }
        return once("writer:writing", .init(.notice, WriterCopy.writingAnnouncement))
    }

    // MARK: Pieces

    /// The first capture state of a capture is its start (a later latch segment is not a new
    /// start); latching and a microphone warning are said once each; every later capture state (a
    /// level tick, quiet ↔ listening, new words, the latch timer) says nothing.
    private mutating func capture(_ state: PillState, content: PillContent, latched: Bool) -> PillAnnouncement? {
        let latchedRow: Bool
        if case .latched = state { latchedRow = true } else { latchedRow = false }
        if !capturing {
            capturing = true
            if (latched || latchedRow) && latchAnnounced {
                // The next latch segment: the session is still on, and its outcome is new again.
                lastEvent = "capturing"
                return nil
            }
            latchAnnounced = latched || latchedRow
            return once("start:\(content.status)", .init(.start, content.status))
        }
        if latchedRow, !latchAnnounced {
            latchAnnounced = true
            return once("latched", .init(.notice, content.status))
        }
        if case .warning = state {
            return once("warning:\(content.status)", outcome(.notice, content))
        }
        // Back in plain capture after a warning or a segment's outcome row: the next warning or
        // outcome is new again.
        if lastEvent?.hasPrefix("warning:") == true || lastEvent?.hasPrefix("delivery:") == true
            || lastEvent?.hasPrefix("final:") == true {
            lastEvent = "capturing"
        }
        return nil
    }

    /// Status, then the state's fixed sentence and helper (its consequence) when it has them. The
    /// transcript itself is not read again.
    private func outcome(_ kind: PillAnnouncement.Kind, _ content: PillContent) -> PillAnnouncement {
        var parts = [content.status]
        if case .fixed(let sentence) = content.words { parts.append(sentence) }
        parts.append(content.helper)
        let text = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: PillCopy.statusSeparator)
        return PillAnnouncement(kind, text, priority: content.tone == .warn ? .high : .medium)
    }

    private mutating func once(_ event: String, _ announcement: PillAnnouncement) -> PillAnnouncement? {
        guard event != lastEvent, !announcement.text.isEmpty else { return nil }
        lastEvent = event
        return announcement
    }
}

/// Feeds a pill's states to a `PillAnnouncer` and posts each line to VoiceOver. One per pill model,
/// attached by the pill view (idempotent); tests attach their own with a recording `post`.
public final class PillAnnouncementCenter {
    public typealias Post = (PillAnnouncement) -> Void

    private var announcer = PillAnnouncer()
    private let post: Post
    private var subscription: AnyCancellable?
    public private(set) var posted: [PillAnnouncement] = []

    private static var live: [ObjectIdentifier: PillAnnouncementCenter] = [:]

    public init(model: PillViewModel, post: @escaping Post = PillAnnouncementCenter.voiceOver) {
        self.post = post
        // `$state` publishes its current value on subscription (a pill attached mid-turn still hears
        // it), then each new state before the property changes: the emitted value is the new state,
        // and the turn context it renders with is already current (`noteTransition` runs first).
        subscription = model.$state.sink { [weak self, weak model] state in
            guard let self, let model else { return }
            self.observe(state, content: PillContent.make(state, context: model.context()),
                         captureOpen: model.turn.captureOpen, latched: model.latched)
        }
        // Context Writer — "Writing" when the slow writer's face appears (the state stays finishing).
        writerSubscription = model.$turn.map { $0.writer?.phase }.removeDuplicates().sink { [weak self] phase in
            self?.observeWriter(phase)
        }
    }

    private var writerSubscription: AnyCancellable?

    public func observeWriter(_ phase: PillWriterNote.Phase?) {
        guard let line = announcer.writer(phase) else { return }
        posted.append(line)
        post(line)
    }

    /// The live pill's center, created on first use.
    @discardableResult
    public static func attach(to model: PillViewModel) -> PillAnnouncementCenter {
        let key = ObjectIdentifier(model)
        if let existing = live[key] { return existing }
        let center = PillAnnouncementCenter(model: model)
        live[key] = center
        return center
    }

    public func observe(_ state: PillState, content: PillContent, captureOpen: Bool, latched: Bool = false) {
        guard let line = announcer.next(state, content: content, captureOpen: captureOpen, latched: latched) else { return }
        posted.append(line)
        post(line)
    }

    /// `NSAccessibility` announcement from the app (the pill panel never takes focus, so the
    /// announcement is posted on the application element).
    public static let voiceOver: Post = { line in
        guard let app = NSApp else { return }
        let priority: NSAccessibilityPriorityLevel = line.priority == .high ? .high : .medium
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: line.spoken,
            .priority: priority.rawValue,
        ])
    }
}
