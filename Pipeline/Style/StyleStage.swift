import Foundation
import Shared

/// P1.7 T7 — applies the per-app `StyleProfile` (learned, or cold-start by category) to the
/// formatted spans. Deliberately conservative: only capitalization of the first word and the
/// terminal period are touched, only on high-confidence spans, and only when the profile is
/// confident (or the cold-start prior is decisive). Code/terminal categories are verbatim.
///
/// Bet 9: low-confidence spans are flagged `needsRepair`, never rewritten, and a low-confidence
/// first/last span disables the corresponding edit entirely.
public struct StyleStage: PipelineStage {
    public let id: StageID = .style
    public let store: any StyleProfileStore
    /// `StageContext.extra` key; "false" disables the stage for one run.
    public static let enabledKey = "style.enabled"
    /// `StageContext.extra` key; lets a caller inject profile JSON directly (tests, Lab).
    public static let profileJSONKey = "style.profileJSON"
    /// Rates at/below this are treated as "user does not do this"; at/above `1 - threshold` as "always".
    public static let decisionThreshold = 0.3

    public init(store: any StyleProfileStore = InMemoryStyleProfileStore()) { self.store = store }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        var cells = spans.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.touched(by: id) }
        guard context.extra[Self.enabledKey] != "false", Self.caretAllowsStyle(context), !cells.isEmpty else { return cells }
        // N25 — the surface preset can pin either edit; `.learned` keeps the profile's rate.
        let profile = SurfacePresets.applying(SurfacePresets.active(in: context), to: try resolveProfile(context: context))
        guard profile.category != .code, profile.category != .terminal,
              context.register != .code, context.register != .terminal else { return cells }
        Self.applyCapitalization(&cells, profile: profile, by: id)
        Self.applyTerminalPeriod(&cells, profile: profile, by: id)
        return cells
    }

    /// D2 — the learned profile's two edits (first-word capital, terminal period) are sentence
    /// edits. They run only where the caret is known to sit at the end of the field right after a
    /// sentence end (`endOfField` after `.!?`). Every other caret state the run carries switches
    /// the stage off: mid-sentence, text after the caret, an empty field (D3 decides its capital
    /// and its full-clause period there; a cold-start prior would re-add a period to "Sounds
    /// good"), and `unknown` (no field context could be read). A run with no caret reading at all
    /// (the Lab, a test without a field) is unaffected.
    static func caretAllowsStyle(_ context: StageContext) -> Bool {
        guard let kind = context.extra[FieldContext.Keys.caret] else { return true }
        guard kind == CaretState.Kind.endOfField.rawValue else { return false }
        return ContinuationPlanner.endsSentence(context.extra[FieldContext.Keys.textBefore] ?? "")
    }

    func resolveProfile(context: StageContext) throws -> StyleProfile {
        if let json = context.extra[Self.profileJSONKey], let p = try? StyleProfile.decode(json: json) { return p }
        let bundle = context.appBundleID ?? ""
        if !bundle.isEmpty, let stored = try store.profile(for: bundle) { return stored }
        let category = bundle.isEmpty ? AppCategoryTable.category(for: context.register)
                                      : AppCategoryTable.category(for: bundle)
        return StyleProfile.coldStart(appBundleID: bundle, category: category)
    }

    // MARK: - Edits

    static func applyCapitalization(_ cells: inout [TranscriptSpan], profile: StyleProfile, by id: StageID) {
        guard let i = cells.firstIndex(where: { !$0.text.isEmpty }), !cells[i].isLowConfidence else { return }
        let word = cells[i].text
        guard let first = word.first, first.isLetter else { return }
        if profile.capitalizationRate <= decisionThreshold, first.isUppercase, Self.isSafeToLowercase(word) {
            cells[i].text = first.lowercased() + word.dropFirst()
        } else if profile.capitalizationRate >= 1 - decisionThreshold, first.isLowercase {
            cells[i].text = first.uppercased() + word.dropFirst()
        }
    }

    /// Don't lowercase "I", acronyms, or mixed-case identifiers (iPhone is already lowercase-first).
    static func isSafeToLowercase(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: .punctuationCharacters)
        if core == "I" || core.hasPrefix("I'") { return false }
        let letters = core.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return false } // acronym
        if letters.dropFirst().contains(where: \.isUppercase) { return false }   // CamelCase / proper noun hint
        return true
    }

    static func applyTerminalPeriod(_ cells: inout [TranscriptSpan], profile: StyleProfile, by id: StageID) {
        guard let i = cells.lastIndex(where: { !$0.text.isEmpty }), !cells[i].isLowConfidence else { return }
        let text = cells[i].text
        if profile.terminalPeriodRate <= decisionThreshold {
            // D2 — a period the user dictated ("full stop") is never a style decision.
            guard cells[i].punctuationOrigin != .spoken else { return }
            guard text.hasSuffix("."), !text.hasSuffix(".."), !text.hasSuffix("…") else { return }
            let core = text.dropLast()
            // Leave abbreviations / numbers ("etc.", "3.") alone when the period is part of a token.
            guard let last = core.last, last.isLetter, !Self.looksLikeAbbreviation(String(core)) else { return }
            cells[i].text = String(core)
        } else if profile.terminalPeriodRate >= 1 - decisionThreshold {
            guard let last = text.last, last.isLetter || last.isNumber || last == "\"" || last == ")" else { return }
            cells[i].text = text + "."
        }
    }

    static let abbreviations: Set<String> = ["etc", "eg", "ie", "vs", "mr", "mrs", "ms", "dr", "st", "jr", "sr", "inc", "ltd", "approx"]
    static func looksLikeAbbreviation(_ token: String) -> Bool {
        let w = token.split(separator: " ").last.map(String.init) ?? token
        return abbreviations.contains(w.lowercased().replacingOccurrences(of: ".", with: ""))
    }
}
