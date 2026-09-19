import Actions
import Foundation

// S12 — outbound action preview (design_v1 §8.8): before an action leaves this Mac for someone else
// (a message, an email, a comment, a submitted form), the user sees where it goes and what will
// happen, and it runs only on an explicit Send / Confirm. A dictation is never sent just because it
// was inserted, and nothing presses Enter or Send on its own: no timer, no insertion, no focus change
// can confirm a preview.

// MARK: - The preview

/// What the confirmation card shows: the destination and the proposed action, in words.
public struct ActionPreview: Equatable, Sendable {
    /// The consent / catalogue action id ("chat.send", "ax.click").
    public let actionID: String
    /// Where it goes: the app the action runs in ("Slack", "Mail"). `nil` when unknown.
    public let destination: String?
    /// The proposed action ("Send message").
    public let proposedAction: String
    /// The primary button ("Send").
    public let confirmLabel: String
    /// True when the action delivers something to other people or services.
    public let isOutbound: Bool

    public init(actionID: String, destination: String?, proposedAction: String, confirmLabel: String, isOutbound: Bool) {
        self.actionID = actionID
        let name = destination?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.destination = name.isEmpty ? nil : name
        self.proposedAction = proposedAction
        self.confirmLabel = confirmLabel
        self.isOutbound = isOutbound
    }

    /// The card for a pending consent confirmation, named for `destination`.
    public init(card: ConfirmationCard, destination: String?) {
        let described = ActionPreviewPolicy.describe(actionID: card.actionID, title: card.title)
        self.init(actionID: card.actionID, destination: destination, proposedAction: described.action,
                  confirmLabel: described.confirm, isOutbound: described.outbound)
    }

    public static let cancelLabel = "Cancel"
    public static let spokenHint = "Say “confirm” or click"
    /// Said on every outbound preview: inserting a dictation is never a send.
    public static let insertionNote = "Inserted text is never sent on its own."

    /// "Send message · Slack" — the proposed action, then the destination.
    public var headline: String {
        destination.map { "\(proposedAction) · \($0)" } ?? proposedAction
    }

    /// Problem — Action: what has not happened yet, and the one control that makes it happen.
    public var detail: String {
        isOutbound ? "Nothing is sent until you choose \(confirmLabel)." : "Nothing happens until you choose \(confirmLabel)."
    }

    /// The small print under the buttons.
    public var footnote: String {
        isOutbound ? "\(Self.insertionNote) \(Self.spokenHint)." : "\(Self.spokenHint)."
    }
}

// MARK: - Policy

/// Which actions are outbound, how they are named, and the catalogue gate that makes every outbound
/// catalogue action wait for its preview.
public enum ActionPreviewPolicy {
    /// Known outbound ids → (proposed action, confirm label).
    public static let outboundNames: [String: (action: String, confirm: String)] = [
        "chat.send": ("Send message", "Send"),
        "chat.click_send": ("Send message", "Send"),
        "slack.send_message": ("Send message", "Send"),
        "mail.send_mail": ("Send email", "Send"),
        "mail.click_send": ("Send email", "Send"),
        "gmail.send": ("Send email", "Send"),
        "gmail.send_internal": ("Send email", "Send"),
        "mail.click_schedule": ("Schedule email", "Schedule"),
        "mac.click_submit": ("Submit form", "Submit"),
        "browser.click_comment": ("Post comment", "Post"),
        "github.comment": ("Post comment", "Post"),
        "linear.comment": ("Post comment", "Post"),
        "linear.create_issue": ("Create issue", "Create"),
        "notion.create_page": ("Create page", "Create"),
        "calendar.create_event": ("Create event and send invites", "Create"),
        "github.create_pr": ("Open pull request", "Open"),
        "github.merge_pr": ("Merge pull request", "Merge"),
        "git.push": ("Push commits", "Push"),
        "git.force_push": ("Force-push commits", "Push"),
    ]

    /// Button names whose click sends something out. "Reply", "Forward" and "Share" only open a
    /// compose window or a sheet, so they are not here.
    static let outboundButtonWords: Set<String> = ["send", "submit", "comment", "post", "publish", "tweet"]
    /// Shortcuts that send in a chat or mail window.
    static let sendingKeys: Set<String> = ["return", "enter", "cmd+return", "cmd+enter", "cmd+shift+d"]

    /// Whether a catalogue entry delivers something to other people.
    public static func isOutbound(_ entry: CatalogEntry) -> Bool {
        if outboundNames[entry.id] != nil { return true }
        switch entry.kind {
        case .click:
            return firstWordIsOutbound(entry.params["name"] ?? "")
        case .shortcut:
            // Return sends only where the app is a chat or mail window; a bare "press enter" that
            // applies everywhere is an explicit keystroke command, not a send.
            let keys = (entry.params["keys"] ?? "").lowercased()
            let sendingApps: Set<ActionCategory> = [.chat, .mail]
            return sendingKeys.contains(keys) && !entry.apps.isEmpty && Set(entry.apps).isSubset(of: sendingApps)
        default:
            return false
        }
    }

    /// The same catalogue with every outbound entry raised to `.irreversible`, so `ConsentEngine`
    /// holds it behind a confirmation card — the preview — instead of running it first and offering
    /// an undo afterwards. Nothing else changes.
    public static func previewingOutbound(_ catalog: ActionCatalog) -> ActionCatalog {
        ActionCatalog(entries: catalog.entries.map { e in
            guard isOutbound(e), e.reversibility != .irreversible else { return e }
            return CatalogEntry(id: e.id, phrasings: e.phrasings, category: e.category, reversibility: .irreversible,
                                kind: e.kind, params: e.params, apps: e.apps)
        })
    }

    /// Names a pending action from its id and card title (the title is the catalogue target or the
    /// agent's step title, e.g. "click Send").
    public static func describe(actionID: String, title: String) -> (action: String, confirm: String, outbound: Bool) {
        if let known = outboundNames[actionID] { return (known.action, known.confirm, true) }
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if let verb = words.first(where: { outboundButtonWords.contains($0) }) {
            return (sentence(title), verb.capitalized, true)
        }
        let id = actionID.lowercased()
        if id.contains("send") || id.contains("submit") || id.contains("post") || id.contains("publish") {
            return (sentence(title), "Send", true)
        }
        return (sentence(title), "Confirm", false)
    }

    private static func firstWordIsOutbound(_ name: String) -> Bool {
        guard let first = name.lowercased().split(whereSeparator: { !$0.isLetter }).first else { return false }
        return outboundButtonWords.contains(String(first))
    }

    /// "click Send" → "Click Send"; underscores read as spaces; never empty.
    static func sentence(_ title: String) -> String {
        let t = title.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return "Run this action" }
        return first.uppercased() + t.dropFirst()
    }
}

// MARK: - The gate

/// One pending preview. It runs only on an explicit confirm — a click or the spoken confirm grammar —
/// and resolves once. Time passing, a dictation landing in the destination, or a focus change never
/// confirm it: there is no automatic Enter or Send.
public struct ActionPreviewGate: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case confirmClicked
        case cancelClicked
        /// A spoken answer while the card is up; only `ConfirmationCard`'s exact grammar counts.
        case spoken(String)
        /// A dictation was inserted into the destination. Never a send.
        case dictationInserted
        /// Time passed with the card up. Never a send, never a silent cancel.
        case timePassed(TimeInterval)
        /// The destination lost focus. The card stays; the user still decides.
        case focusChanged
    }

    public enum State: Equatable, Sendable { case pending, confirmed, cancelled }

    public enum Decision: Equatable, Sendable {
        /// Run the action now (exactly once).
        case run
        case cancel
        case keepWaiting
    }

    public let preview: ActionPreview
    public private(set) var state: State = .pending

    public init(preview: ActionPreview) { self.preview = preview }

    public mutating func handle(_ event: Event) -> Decision {
        guard state == .pending else { return .keepWaiting }
        switch event {
        case .confirmClicked:
            state = .confirmed
            return .run
        case .cancelClicked:
            state = .cancelled
            return .cancel
        case .spoken(let words):
            if ConfirmationCard.isSpokenConfirm(words) { state = .confirmed; return .run }
            if ConfirmationCard.isSpokenCancel(words) { state = .cancelled; return .cancel }
            return .keepWaiting
        case .dictationInserted, .timePassed, .focusChanged:
            return .keepWaiting
        }
    }
}
