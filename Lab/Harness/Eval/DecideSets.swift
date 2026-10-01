import Foundation

// V5 L6 — evaluation sets for the decision layer (`lab eval --stage decide`).
//
// There is no public device-directed speech set (V5 §L6). Two stand-ins:
// * **people talking to people** — AMI / NOTSOFAR meeting utterances. Nobody in a meeting is talking
//   to the user's computer, so every one is labelled `ignore` (`DecideSetBuilder.ignoreSet`); the bar
//   is AMI → ignore ≥ 95 % (O4 "Done when").
// * **talking to the computer** — `Fixtures/public/ambient-commands/manifest.json`, 150 scripted lines
//   across the six capabilities, labels drafted here and confirmed by the owner on T1.
// Decide items are text-only: the utterance is `reference` (or `input`), the expected owner is `label`.
// These are testing sets, never training data (rule 0.1: convert, don't train).

public enum DecideSetBuilder {
    /// Meeting sets whose utterances become `ignore` items.
    public static let meetingSets = ["ami", "notsofar1"]
    /// The scripted command set (committed under `Fixtures/public/`).
    public static let commandSet = "ambient-commands"
    /// The owners a decide label may name (`UtteranceOwner` raw values; Lab cannot import Shared's enum
    /// by name without coupling the harness to the app, so they are listed and checked here).
    public static let owners: Set<String> = ["dictate", "edit", "act", "note", "ask", "ignore"]

    /// `<set>-decide`: every utterance of a meeting transcript manifest, labelled `ignore`.
    /// Utterances shorter than `minWords` (back-channels like "mm") are kept — they are exactly what
    /// ambient must ignore — unless `minWords` is raised.
    public static func ignoreSet(from meeting: EvalManifest, minWords: Int = 1, limit: Int? = nil) -> EvalManifest {
        var items: [EvalItem] = []
        for item in meeting.items {
            let text = (item.input ?? item.reference).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.split(separator: " ").count >= minWords else { continue }
            items.append(EvalItem(id: item.id, reference: text, tags: ["meeting", meeting.set] + item.tags.filter { $0 != "meeting" },
                                  label: "ignore"))
            if let limit, items.count >= limit { break }
        }
        return EvalManifest(set: "\(meeting.set)-decide", language: meeting.language, audioRoot: meeting.audioRoot,
                            licence: meeting.licence, source: "V5 L6: \(meeting.set) utterances labelled ignore (people talking to people)",
                            items: items)
    }

    /// Labels that are not an owner — a manifest typo would otherwise score as a silent miss.
    public static func invalidLabels(_ manifest: EvalManifest) -> [String] {
        manifest.items.compactMap { $0.label }.filter { !owners.contains($0) }
    }

    /// Writes `<cache>/<set>/manifest.json` (beside the audio cache, never committed).
    @discardableResult
    public static func write(_ manifest: EvalManifest, paths: EvalPaths) throws -> URL {
        let dir = paths.cacheDirectory.appendingPathComponent(manifest.set, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("manifest.json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: url)
        return url
    }
}
