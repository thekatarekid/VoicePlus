import Foundation
import Shared

/// V5 E6 — who the text is for, out of what the accessibility tree shows.
///
/// * Mail (Apple Mail, Outlook, Gmail web…): the compose window's **To** and **Cc** fields.
/// * Chat (Slack, WhatsApp, Messages, Discord…): the **channel / chat title**, from the window or
///   page title, else the conversation heading.
///
/// Pure: the app layer reads the raw strings (`ThreadParticipantsReading`), this turns them into
/// names. The result goes to `StageContext.extra["thread.participants"]`, where `PersonaManager`
/// applies a per-recipient override. Screen text is data: names are matched, never interpreted.
public enum ThreadParticipants {
    /// Most participants carried for one utterance.
    public static let limit = 12
    /// A name longer than this is not a name (a pasted paragraph in a To field).
    public static let maxNameLength = 80

    /// One labelled field of the compose window: its label (`To:`, `Cc`, `To recipients`) and the
    /// text it holds (the field value, or its recipient tokens joined by commas).
    public struct LabelledField: Equatable, Sendable {
        public var label: String
        public var value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    /// What the app layer could read for the focused window.
    public struct Observation: Equatable, Sendable {
        public var fields: [LabelledField]
        /// The window title (native apps) or the web document title (browsers).
        public var title: String?
        /// The conversation header (an `AXHeading` near the top of the window), when the title is
        /// just the app name (WhatsApp, Messages).
        public var heading: String?
        public init(fields: [LabelledField] = [], title: String? = nil, heading: String? = nil) {
            self.fields = fields; self.title = title; self.heading = heading
        }
    }

    /// Labels that mean "this field holds recipients". Bcc is deliberately left out: a blind copy
    /// is not who the text addresses.
    static let recipientLabels: Set<String> = ["to", "cc", "to recipients", "cc recipients", "recipients", "send to"]

    public static func isRecipientLabel(_ label: String) -> Bool {
        let l = label.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
        return recipientLabels.contains(l)
    }

    /// The participants for a field in `category`. `[]` for categories without a thread.
    public static func extract(category: AppCategory, observation: Observation) -> [String] {
        switch category {
        case .mail: return dedupe(observation.fields.filter { isRecipientLabel($0.label) }.flatMap { recipients(in: $0.value) })
        case .chat:
            if let title = observation.title.flatMap(chatTitle(from:)) { return [title] }
            if let heading = observation.heading.flatMap(chatTitle(from:)) { return [heading] }
            return []
        case .code, .terminal, .prose: return []
        }
    }

    /// "Priya Kothari <priya@x.io>, rao@uni.edu; Sam" → three names. Empty pieces and
    /// over-long pieces are dropped.
    public static func recipients(in value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= maxNameLength }
    }

    /// App names and generic views a title segment can be, which are not a conversation.
    static let notAConversation: Set<String> = [
        "slack", "whatsapp", "discord", "messages", "telegram", "signal", "microsoft teams", "teams",
        "google chat", "messenger", "skype", "element", "beeper", "imessage", "chat",
        "home", "activity", "threads", "direct messages", "dms", "chats", "inbox", "later", "unreads",
        "mentions & reactions", "saved items", "search", "new message", "all channels", "all dms",
        "zoom", "zoom meeting", "zoom workplace", "facetime", "chatgpt", "claude", "google chrome", "safari", "arc",
        "brave", "microsoft edge", "firefox",
    ]

    /// The conversation in a window title: "general (Channel) - Acme - Slack" → "general",
    /// "Slack | Priya Kothari (DM) | Acme" → "Priya Kothari", "(3) WhatsApp" → nil.
    public static func chatTitle(from title: String) -> String? {
        let segments = title.components(separatedBy: CharacterSet(charactersIn: "|–—"))
            .flatMap { $0.components(separatedBy: " - ") }
            .map(clean)
            .filter { !$0.isEmpty }
        let candidate = segments.first { !notAConversation.contains($0.lowercased()) }
        guard let name = candidate, name.count <= maxNameLength else { return nil }
        return name
    }

    /// Strips unread counts and Slack's kind suffixes; keeps a leading `#` off channel names.
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^[\*•]?\s*\(\d+\+?\)\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\((channel|dm|private channel|group|private)\)$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^[#@]"#, with: "", options: .regularExpression)
        // "!general" / "*general" unread markers some clients prepend.
        s = s.replacingOccurrences(of: #"^[!\*]\s*"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First occurrence wins, compared case-insensitively; capped at `limit`.
    static func dedupe(_ names: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for n in names where seen.insert(n.lowercased()).inserted {
            out.append(n)
            if out.count == limit { break }
        }
        return out
    }
}
