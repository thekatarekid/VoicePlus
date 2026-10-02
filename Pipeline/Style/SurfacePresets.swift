import Foundation
import Shared

// N25 — 2-3 named presets per surface kind (Kivi's pattern, R3 §E), with per-app overrides.
//
// A preset is the user's choice of *voice* on one kind of surface; it never touches safety
// (line breaks, Return, secure fields — those belong to the surface and the write plan). The
// first preset of every kind is the default and is behaviour-neutral: learned style, cleanup as
// the mode says, the auto-drafted persona. The others pin the two style edits, swap the
// auto-drafted persona for a short instruction, or skip cleanup ("Exact").
//
// Selection travels in `StageContext.extra[SurfacePresets.selectionKey]` as `group=id;group=id`
// (the app rule writes it). Consumers resolve lazily with `SurfacePresets.active(in:)`, reading
// the surface kind the field-role wiring wrote — so the order the two are written in never matters.

public struct StylePreset: Equatable, Sendable, Identifiable {
    /// What a preset does to one of the two style edits.
    public enum Edit: String, Equatable, Sendable {
        /// The learned per-app profile decides (or its cold-start prior).
        case learned
        case always
        case never
    }

    public var id: String
    public var title: String
    public var detail: String
    /// Replaces an *auto-drafted* persona's text; a persona the user wrote is never replaced.
    public var instruction: String?
    public var capitalization: Edit
    public var trailingPeriod: Edit
    /// False skips the cleanup model for this run (N26 `cleanup.skip`, reason "preset").
    public var allowsCleanup: Bool

    public init(id: String, title: String, detail: String, instruction: String? = nil,
                capitalization: Edit = .learned, trailingPeriod: Edit = .learned, allowsCleanup: Bool = true) {
        self.id = id; self.title = title; self.detail = detail; self.instruction = instruction
        self.capitalization = capitalization; self.trailingPeriod = trailingPeriod; self.allowsCleanup = allowsCleanup
    }

    /// The default preset of every kind: changes nothing.
    public var isNeutral: Bool {
        instruction == nil && capitalization == .learned && trailingPeriod == .learned && allowsCleanup
    }
}

public enum SurfacePresets {
    /// `StageContext.extra` key: `group=presetID;group=presetID`.
    public static let selectionKey = "style.presets"

    /// The settings group a kind's presets are chosen under. Every form-field label shares one
    /// group. Secure fields and canvases are never typed into, so they have no presets.
    public static func group(for kind: SurfaceKind) -> String? {
        switch kind {
        case .secure, .canvas: return nil
        case .formField: return "formField"
        default: return kind.id
        }
    }

    /// Every group that has presets, in display order.
    public static let groups: [String] = [
        "prose", "emailBody", "chatComposer", "markdownEditor", "formField",
        "searchField", "urlBar", "spreadsheetCell", "codeEditor", "terminal",
    ]

    private static let exact = StylePreset(id: "exact", title: "Exact", detail: "As the rules wrote it; the cleanup model never runs.",
                                           allowsCleanup: false)

    /// The 2-3 presets for a group; the first is the default. Empty for an unknown group.
    public static func presets(forGroup group: String) -> [StylePreset] {
        switch group {
        case "prose":
            return [StylePreset(id: "natural", title: "Natural", detail: "Your learned style for this app."),
                    StylePreset(id: "polished", title: "Polished", detail: "Full sentences: capital first word, closing period.",
                                instruction: "Clear, polished prose in full sentences.", capitalization: .always, trailingPeriod: .always),
                    exact]
        case "emailBody":
            return [StylePreset(id: "professional", title: "Professional", detail: "Your learned email voice."),
                    StylePreset(id: "friendly", title: "Friendly", detail: "Warm and personal.",
                                instruction: "Warm, friendly email voice; plain words.", capitalization: .always, trailingPeriod: .always),
                    StylePreset(id: "concise", title: "Concise", detail: "Short and direct.",
                                instruction: "Concise, direct email voice; short sentences; no filler.",
                                capitalization: .always, trailingPeriod: .always)]
        case "chatComposer":
            return [StylePreset(id: "natural", title: "Natural", detail: "Your learned chat style."),
                    StylePreset(id: "casual", title: "Casual", detail: "lowercase, no closing period.",
                                instruction: "Relaxed chat voice; lowercase; no trailing periods.",
                                capitalization: .never, trailingPeriod: .never),
                    StylePreset(id: "polished", title: "Polished", detail: "Sentence case with a closing period.",
                                instruction: "Clear chat messages in full sentences.", capitalization: .always, trailingPeriod: .always)]
        case "markdownEditor":
            return [StylePreset(id: "natural", title: "Natural", detail: "Your learned style for this editor."),
                    StylePreset(id: "notes", title: "Notes", detail: "Short note-style lines.",
                                instruction: "Short, note-style lines; Markdown lists where the speaker lists things.",
                                trailingPeriod: .never),
                    exact]
        case "formField":
            return [StylePreset(id: "value", title: "Value", detail: "The value the label asks for."),
                    exact]
        case "searchField":
            return [StylePreset(id: "keywords", title: "Keywords", detail: "A search phrase."),
                    exact]
        case "urlBar":
            return [StylePreset(id: "address", title: "Address", detail: "A web address or a search phrase."),
                    exact]
        case "spreadsheetCell":
            return [StylePreset(id: "value", title: "Value", detail: "A cell value or a formula."),
                    StylePreset(id: "sentence", title: "Sentence", detail: "Text cells as full sentences.",
                                capitalization: .always, trailingPeriod: .always),
                    exact]
        case "codeEditor":
            return [StylePreset(id: "code", title: "Code", detail: "Identifiers and casing as spoken."),
                    exact]
        case "terminal":
            return [StylePreset(id: "command", title: "Command", detail: "A command; nothing is run for you."),
                    exact]
        default:
            return []
        }
    }

    public static func presets(for kind: SurfaceKind) -> [StylePreset] {
        group(for: kind).map(presets(forGroup:)) ?? []
    }

    public static func defaultPreset(forGroup group: String) -> StylePreset? { presets(forGroup: group).first }

    /// The preset named `id` in `group`, or nil when the group has no such preset.
    public static func preset(_ id: String, inGroup group: String) -> StylePreset? {
        presets(forGroup: group).first { $0.id == id }
    }

    // MARK: Selection in the run's context

    public static func encode(_ selection: [String: String]) -> String {
        selection.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    public static func decode(_ raw: String?) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (raw ?? "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, !kv[0].isEmpty, !kv[1].isEmpty { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// The preset for this run: the selection for the run's surface kind, else that kind's
    /// default. nil when no surface kind was recorded, or the kind has no presets.
    public static func active(in context: StageContext) -> StylePreset? {
        guard let kind = context.extra[FieldContext.Keys.surfaceKind].flatMap(SurfaceKind.init(id:)),
              let group = group(for: kind) else { return nil }
        if let id = decode(context.extra[selectionKey])[group], let p = preset(id, inGroup: group) { return p }
        return defaultPreset(forGroup: group)
    }

    /// `profile` with the preset's pinned edits applied (rates forced to 0 / 1).
    public static func applying(_ preset: StylePreset?, to profile: StyleProfile) -> StyleProfile {
        guard let preset else { return profile }
        var p = profile
        switch preset.capitalization {
        case .always: p.capitalizationRate = 1
        case .never: p.capitalizationRate = 0
        case .learned: break
        }
        switch preset.trailingPeriod {
        case .always: p.terminalPeriodRate = 1
        case .never: p.terminalPeriodRate = 0
        case .learned: break
        }
        return p
    }
}
