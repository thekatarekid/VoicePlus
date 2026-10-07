import Foundation
import Pipeline

/// Context Writer §2.1 — the email record: subject, recipients and the quoted message's sender,
/// from the compose window's title, its labelled recipient fields (`ThreadParticipants`) and the
/// quoted block in the document tail. Reply vs new comes from the same facts, never from a guess.
enum EmailFacts {
    /// Title segments that are the client, not a subject.
    static let notASubject: Set<String> = [
        "mail", "gmail", "outlook", "new message", "inbox", "untitled", "compose", "drafts", "sent", "mail - outlook",
        "superhuman", "spark", "hey", "fastmail", "proton mail", "yahoo mail", "new mail", "reply", "forward",
    ]

    /// Apple Mail titles its compose window with the subject; Gmail's document title is
    /// `Subject - me@x.io - Gmail`. The first segment that is not the client or the app name.
    static func subject(windowTitle: String?, documentTitle: String?, appName: String?) -> String? {
        for title in [windowTitle, documentTitle].compactMap({ $0 }) {
            let segments = title.components(separatedBy: CharacterSet(charactersIn: "—–|"))
                .flatMap { $0.components(separatedBy: " - ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for segment in segments {
                let key = segment.lowercased()
                if notASubject.contains(key) || key == appName?.lowercased() || segment.contains("@") { continue }
                if segment.count <= 200 { return segment }
            }
        }
        return nil
    }

    // Greedy up to the *last* comma before "wrote:": the name follows the date, which has commas of its own.
    private static let wrotePattern = try! NSRegularExpression(
        pattern: #"(?:^|\n)\s*(?:On|Am|Le|El)\b[^\n]{0,120},\s*([^\n<,]{1,80}?)\s*(?:<[^>\n]*>)?\s*(?:wrote|schrieb|a écrit|escribió):"#,
        options: [])
    private static let fromPattern = try! NSRegularExpression(
        pattern: #"(?:^|\n)\s*(?:From|Von|De):\s*([^\n<]{1,80}?)\s*(?:<[^>\n]*>)?\s*$"#,
        options: [.anchorsMatchLines])

    /// `On 6 Oct 2026, at 09:12, Rahul Mehta <rahul@x.io> wrote:` → `Rahul Mehta`; `From: Name` likewise.
    static func quotedFrom(in text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in [wrotePattern, fromPattern] {
            // The last quoted header is the message being answered (the tail reads oldest → newest).
            if let m = pattern.matches(in: text, range: range).last, let r = Range(m.range(at: 1), in: text) {
                let name = text[r].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",\"")))
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    static let replyPrefixes = ["re:", "fwd:", "fw:", "aw:", "wg:", "sv:", "vs:", "tr:"]

    static func isReply(subject: String?, quotedFrom: String?, tail: String?) -> Bool {
        if quotedFrom != nil { return true }
        if let s = subject?.lowercased(), replyPrefixes.contains(where: { s.hasPrefix($0) }) { return true }
        if let t = tail, t.contains("-----Original Message-----") || t.contains(" wrote:") { return true }
        return false
    }

    /// To and Cc from the labelled fields when the observation is available; otherwise the merged
    /// participant list is `to` (the field reader keeps no labels).
    static func recipients(observation: ThreadParticipants.Observation?, participants: [String]) -> (to: String?, cc: String?) {
        if let observation {
            func names(_ labels: [String]) -> String? {
                let v = observation.fields.filter { labels.contains(normalize($0.label)) }
                    .flatMap { ThreadParticipants.recipients(in: $0.value) }
                return v.isEmpty ? nil : v.joined(separator: ", ")
            }
            let to = names(["to", "to recipients", "recipients", "send to"])
            let cc = names(["cc", "cc recipients"])
            if to != nil || cc != nil { return (to, cc) }
        }
        return (participants.isEmpty ? nil : participants.joined(separator: ", "), nil)
    }

    private static func normalize(_ label: String) -> String {
        label.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":")))
    }
}
