import Foundation
import Shared
#if canImport(AppKit)
import AppKit
import ApplicationServices
#endif

// V5 M11 — the call app's active-speaker highlight, read through Accessibility (the permission the
// app already holds for text insertion). Zoom, Microsoft Teams and Google Meet (in a browser window
// titled "Meet") label the highlighted tile with the person's name; the label's wording varies by
// app and version, so parsing is a list of patterns (`ActiveSpeakerParsing`), tested on strings —
// the live tree walk needs a real call (T1). Read-only; strings are data, only a name is taken.
// OCR fallback: not shipped (it would need the Screen Recording opt-in, M11 says only then).

public enum ActiveSpeakerParsing {
    static let patterns: [NSRegularExpression] = [
        // "Priya Sharma, active speaker" / "Priya Sharma - Active speaker" / "Priya Sharma is speaking"
        #"^\s*(.{2,60}?)\s*(?:,|-|–|\(|is)\s*(?:the\s+)?(?:active speaker|currently speaking|speaking now|is speaking|speaking|talking)\)?\s*$"#,
        // "Active speaker: Priya Sharma" / "Speaking: Priya"
        #"^\s*(?:active speaker|speaking now|speaking|talking)\s*[:\-–]\s*(.{2,60}?)\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static let notNames: Set<String> = ["you", "me", "someone", "no one", "nobody", "unknown", "participant", "guest"]

    /// The first name an active-speaker label in `strings` carries.
    public static func name(in strings: [String]) -> String? {
        for s in strings where s.count <= 120 {
            let ns = s as NSString
            for re in patterns {
                guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
                let n = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if n.count >= 2, !notNames.contains(n.lowercased()), n.first?.isLetter == true { return n }
            }
        }
        return nil
    }

    /// Call apps by bundle id; browsers count only for a window titled like Google Meet.
    public static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
    ]
    public static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                               "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"]
}

#if canImport(AppKit)
/// Walks the call app's windows (bounded: 2,500 elements, depth 30) for an active-speaker label.
public struct AXActiveSpeakerSource: ActiveSpeakerSource {
    public var maxElements = 2_500
    public var maxDepth = 30
    public init() {}

    public func activeSpeaker() -> ActiveSpeakerReading? {
        guard AXIsProcessTrusted() else { return nil }
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            if let name = ActiveSpeakerParsing.callApps[id] {
                if let who = scan(pid: app.processIdentifier, windowTitle: nil) { return ActiveSpeakerReading(name: who, app: name) }
            } else if ActiveSpeakerParsing.browsers.contains(id), app.isActive,
                      let who = scan(pid: app.processIdentifier, windowTitle: "Meet") {
                return ActiveSpeakerReading(name: who, app: "Meet")
            }
        }
        return nil
    }

    func scan(pid: pid_t, windowTitle: String?) -> String? {
        let root = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        var budget = maxElements
        for w in list {
            if let windowTitle, !(string(w, kAXTitleAttribute)?.contains(windowTitle) ?? false) { continue }
            var strings: [String] = []
            collect(w, depth: 0, budget: &budget, into: &strings)
            if let n = ActiveSpeakerParsing.name(in: strings) { return n }
        }
        return nil
    }

    private func collect(_ e: AXUIElement, depth: Int, budget: inout Int, into out: inout [String]) {
        guard depth <= maxDepth, budget > 0 else { return }
        budget -= 1
        for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let s = string(e, attr), !s.isEmpty { out.append(s) }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return }
        for k in kids where budget > 0 { collect(k, depth: depth + 1, budget: &budget, into: &out) }
    }

    private func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
#endif
