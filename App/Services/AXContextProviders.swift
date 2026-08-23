import Actions
import Engine
import Foundation
import Injection
import Shared

/// P3.4 integration — `AXWindowReader`/`WindowContentCache` (via `SystemAccess`'s `AXReaderProviding`)
/// feeding Biasing's `ContextHarvester` and the transform/pipeline context.
///
/// One `AXReading` instance is captured at init so `LiveSystemAccess`'s `CachedAXReader`
/// (2 s TTL + observer invalidation) is actually shared across harvests.
public final class AXReaderWindowText: FocusedWindowTextProvider, @unchecked Sendable {
    private let system: SystemAccess
    private let reader: AXReading?
    public var maxBlocks = 200

    public init(system: SystemAccess) {
        self.system = system
        self.reader = (system as? AXReaderProviding)?.axReader
    }

    /// Focused-window content, visible portion only (cache-backed).
    public func content() -> WindowContent? {
        guard let reader, let front = system.frontmostApp() else { return nil }
        return try? reader.readFocusedWindow(pid: front.pid, options: .visible)
    }

    /// Biasing source: title at full salience, body blocks decaying with tree depth.
    public func visibleStrings() -> [(String, Double)] {
        guard let content = content() else { return [] }
        var out: [(String, Double)] = []
        if let title = content.title, !title.isEmpty { out.append((title, 1.0)) }
        for block in content.blocks.prefix(maxBlocks) where !block.text.isEmpty {
            out.append((block.text, max(0.4, 1.0 - Double(block.depth) * 0.08)))
        }
        return out
    }

    /// Flattened window text for `StageContext.extra` (transform / pipeline prompts).
    public func windowText(limit: Int = 2000) -> String? {
        guard let content = content() else { return nil }
        let text = content.text
        return text.isEmpty ? nil : String(text.prefix(limit))
    }
}

/// P3.5 integration — conversational referents ("her", "the deck") out of the AX window
/// content + the contacts store. Heuristic on purpose: titles that look like artifacts become
/// `VisibleArtifact`s; contact names become `Participant`s (gender unknown, so pronouns bind
/// only when a single candidate stands out — ambiguity falls to elicitation/clarifying text).
public final class AXReferentContext: ParticipantProviding, ArtifactProviding {
    private let text: AXReaderWindowText
    private let contacts: ContactsProvider?
    public var maxParticipants = 50

    public init(text: AXReaderWindowText, contacts: ContactsProvider? = nil) {
        self.text = text
        self.contacts = contacts
    }

    public func participants() -> ContextParticipants {
        guard let names = contacts?.contactNames(), !names.isEmpty else { return ContextParticipants() }
        return ContextParticipants(names.prefix(maxParticipants).map { Participant(name: $0, salience: 0.5) })
    }

    public func visibleArtifacts() -> [VisibleArtifact] {
        guard let content = text.content() else { return [] }
        var out: [VisibleArtifact] = []
        if let title = content.title, !title.isEmpty {
            out.append(VisibleArtifact(title: title, kind: .window, salience: 1.0))
        }
        for block in content.blocks.prefix(80) {
            let line = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.count <= 120 else { continue }
            if let kind = Self.artifactKind(for: line, role: block.role) {
                out.append(VisibleArtifact(title: line, kind: kind,
                                           salience: max(0.3, 1.0 - Double(block.depth) * 0.1)))
            }
        }
        return out
    }

    static func artifactKind(for text: String, role: String) -> ArtifactKind? {
        switch (text.lowercased() as NSString).pathExtension {
        case "key", "ppt", "pptx": return .deck
        case "xls", "xlsx", "csv", "numbers": return .spreadsheet
        case "png", "jpg", "jpeg", "gif", "heic", "svg": return .image
        case "pdf", "doc", "docx", "pages", "md", "txt", "rtf": return .document
        case "swift", "py", "js", "ts", "json", "yml", "yaml", "sh": return .file
        default: break
        }
        if role == "AXLink" { return .link }
        return nil
    }
}
