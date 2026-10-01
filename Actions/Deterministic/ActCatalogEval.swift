import Darwin
import Foundation
import Shared

// MARK: - V5 CU6 · Measure the 200 actions
//
// `Fixtures/public/act-catalog/paraphrases.json`: every catalogue phrasing (template argument filled
// in) plus 3 rule-based paraphrases (`make_paraphrases.py`). Each case runs on a fresh mock desktop
// (`ActCatalogEvalDesktop`: 15 apps whose AX trees expose the catalogue's own controls) through the
// act path the router uses — fuzzy catalogue, then CU4 retrieval + fuzzy confirm — and then through
// `ActionExecutor`. A hit is the expected action executed with a successful readback. A wrong action
// is counted separately (a misfire is worse than falling through to CUA-S1 / the planner).
// Targets: > 99 % on exact phrasings, > 90 % paraphrased. Failures are fixed in `catalog.json`.

public struct ActCatalogEvalCase: Codable, Equatable, Sendable {
    public var entry: String
    public var app: String
    public var phrasing: String
    public var text: String
    public var paraphrases: [String]
}

public struct ActCatalogEvalSet: Codable, Sendable {
    public var name: String
    public var note: String
    public var cases: [ActCatalogEvalCase]

    public static var defaultURL: URL? {
        AppPaths.fixturesDirectory()?.appendingPathComponent("public/act-catalog/paraphrases.json")
    }

    public static func load(_ url: URL? = defaultURL) throws -> ActCatalogEvalSet {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(ActCatalogEvalSet.self, from: Data(contentsOf: url))
    }
}

public struct ActCatalogEvalReport: Sendable {
    public enum Outcome: String, Codable, Sendable {
        case hit
        /// Routed to the expected action but the executor's readback failed.
        case executionFailed
        /// A different catalogue action would have run.
        case misfire
        /// No catalogue action: the utterance goes on to CUA-S1 / the planner.
        case fellThrough
    }
    public struct Row: Codable, Equatable, Sendable {
        public let entry: String
        public let text: String
        public let paraphrase: Bool
        public let outcome: Outcome
        public let routedTo: String?
        /// "fuzzy" (the catalogue matcher alone) or "retrieval" (CU4 confirm).
        public let layer: String?
    }
    public let set: String
    public let embedder: String
    public let rows: [Row]

    public static let exactTarget = 0.99
    public static let paraphraseTarget = 0.90

    func rate(paraphrase: Bool) -> Double {
        let rs = rows.filter { $0.paraphrase == paraphrase }
        return rs.isEmpty ? 0 : Double(rs.filter { $0.outcome == .hit }.count) / Double(rs.count)
    }
    public var exactHitRate: Double { rate(paraphrase: false) }
    public var paraphraseHitRate: Double { rate(paraphrase: true) }
    public var misfires: [Row] { rows.filter { $0.outcome == .misfire } }
    public var failures: [Row] { rows.filter { $0.outcome != .hit } }
    public var meetsTargets: Bool { exactHitRate > Self.exactTarget && paraphraseHitRate > Self.paraphraseTarget }

    public var summaryLine: String {
        let e = rows.filter { !$0.paraphrase }.count, p = rows.count - e
        return String(format: "CU6 %@ [%@]: exact %.2f%% of %d, paraphrased %.2f%% of %d, misfires %d",
                      set, embedder, exactHitRate * 100, e, paraphraseHitRate * 100, p, misfires.count)
    }

    /// The V1-style result file: `Lab/results/<date>-<set>-<embedder>.json` (set, stage, model, date,
    /// peak RSS, summary, failures).
    public func write(to directory: URL, date: Date = Date()) throws -> URL {
        struct Summary: Encodable { let exact: Double; let paraphrased: Double; let misfires: Int; let cases: Int; let meetsTargets: Bool }
        struct Doc: Encodable {
            let set: String; let stage: String; let model: String; let date: String; let peakRSSBytes: Int64
            let summary: Summary; let failures: [Row]
        }
        let day = Self.day(date)
        let doc = Doc(set: set, stage: "act", model: "catalog+\(embedder)", date: day, peakRSSBytes: Self.peakRSS(),
                      summary: Summary(exact: exactHitRate, paraphrased: paraphraseHitRate, misfires: misfires.count,
                                       cases: rows.count, meetsTargets: meetsTargets),
                      failures: failures)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(day)-\(set)-\(embedder).json")
        try enc.encode(doc).write(to: url)
        return url
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func peakRSS() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Int64(usage.ru_maxrss)   // bytes on macOS
    }
}

public enum ActCatalogEval {
    /// Run every case (exact + paraphrases). `retrieval` nil → the fuzzy catalogue alone.
    public static func run(_ set: ActCatalogEvalSet, catalog: ActionCatalog,
                           retrieval: CatalogRetrievalIndex?) async -> ActCatalogEvalReport {
        let parser = ActIntentParser(catalog: catalog, activation: ActDomainState(active: true))
        let embedder = await retrieval?.embedder.name ?? "none"
        var rows: [ActCatalogEvalReport.Row] = []
        for c in set.cases {
            for (text, isParaphrase) in [(c.text, false)] + c.paraphrases.map({ ($0, true) }) {
                rows.append(await evaluate(text, expected: c.entry, app: c.app, paraphrase: isParaphrase,
                                           parser: parser, catalog: catalog, retrieval: retrieval))
            }
        }
        return ActCatalogEvalReport(set: set.name, embedder: embedder, rows: rows)
    }

    static func evaluate(_ text: String, expected: String, app: String, paraphrase: Bool, parser: ActIntentParser,
                         catalog: ActionCatalog, retrieval: CatalogRetrievalIndex?) async -> ActCatalogEvalReport.Row {
        let parsed = parser.parse(text, appBundleID: app)
        let route = await parser.refine(parsed, appBundleID: app, retrieval: retrieval)
        let layer: String? = route.isDeterministic ? (route == parsed ? "fuzzy" : "retrieval") : nil
        guard case .deterministic(let m, let request) = route else {
            return .init(entry: expected, text: text, paraphrase: paraphrase, outcome: .fellThrough, routedTo: nil, layer: nil)
        }
        let same = m.entry.id == expected || catalog.entry(id: expected).map {
            // Two catalogue entries that resolve to the identical action ("press ok" → `mac.click {ok}`
            // is `mac.click_ok`): same kind, same parameters (case-folded, `argSlot` ignored).
            let templated = $0.phrasings.contains { $0.hasSuffix("{arg}") }
            let want = ActionRequest($0, argument: templated ? m.argument : nil)
            func folded(_ p: [String: String]) -> [String: String] {
                var p = p.filter { $0.key != "argSlot" }
                // The executor reads `target ?? name` for the same subject (an app, a control).
                if p["name"] == nil, let t = p.removeValue(forKey: "target") { p["name"] = t }
                return p.mapValues { FuzzyMatch.normalize($0) }
            }
            return want.kind == request.kind && folded(want.params) == folded(request.params)
        } ?? false
        guard same else {
            return .init(entry: expected, text: text, paraphrase: paraphrase, outcome: .misfire, routedTo: m.entry.id, layer: layer)
        }
        let system = ActCatalogEvalDesktop.make(catalog: catalog, front: app)
        let result = ActionExecutor(system: system).run(request)
        return .init(entry: expected, text: text, paraphrase: paraphrase,
                     outcome: result.outcome.isSuccess ? .hit : .executionFailed, routedTo: m.entry.id, layer: layer)
    }
}

/// The CU6 desktop: 15 running apps whose front windows expose the catalogue's own control names
/// (what a real AX tree of that app kind shows), a focused body text area, two windows each.
public enum ActCatalogEvalDesktop {
    public static let apps: [(name: String, bundle: String, kind: ActionCategory)] = [
        ("Finder", "com.apple.finder", .files), ("Preview", "com.apple.Preview", .mac), ("System Settings", "com.apple.systempreferences", .mac),
        ("Safari", "com.apple.Safari", .browser), ("Google Chrome", "com.google.Chrome", .browser), ("Arc", "company.thebrowser.Browser", .browser),
        ("Visual Studio Code", "com.microsoft.VSCode", .editor), ("Xcode", "com.apple.dt.Xcode", .editor), ("Cursor", "com.todesktop.cursor", .editor),
        ("Slack", "com.tinyspeck.slackmacgap", .chat), ("Discord", "com.hnc.Discord", .chat), ("Messages", "com.apple.MobileSMS", .chat),
        ("Mail", "com.apple.mail", .mail), ("Microsoft Outlook", "com.microsoft.Outlook", .mail), ("Notes", "com.apple.Notes", .mac),
    ]

    public static func make(catalog: ActionCatalog, front: String) -> MockActionSystem {
        let sys = MockActionSystem()
        var nextID = 1
        for (i, a) in apps.enumerated() {
            let w1 = 100 + i * 10, w2 = w1 + 1
            var els: [ElementRef] = []
            func add(_ role: String, _ title: String, selected: Bool = false) {
                els.append(ElementRef(id: nextID, windowID: w1, role: role, title: title, isSelected: selected)); nextID += 1
            }
            add("AXTextArea", "Body")
            var tabs = ["Overview"]
            for e in catalog.entries where e.applies(to: a.kind) {
                switch e.kind {
                case .click: if let n = e.params["name"] { add("AXButton", n) }
                case .fillField: add("AXTextField", e.params["name"] ?? "Field")
                case .focusTab: if let t = e.params["target"], t != "next", t != "previous", !tabs.contains(t) { tabs.append(t) }
                default: break
                }
            }
            for n in ["OK", "Cancel", "Toolbar", "Merge pull request", "Zoom", "Sidebar"] where !els.contains(where: { $0.title == n }) { add("AXButton", n) }
            for (k, t) in tabs.enumerated() { add("AXTab", t, selected: k == 0) }
            let ref = AppRef(name: a.name, bundleID: a.bundle)
            sys.add(.init(ref: ref, kind: a.kind,
                          windows: [WindowRef(id: w1, appBundleID: a.bundle, title: "\(a.name) — Main"),
                                    WindowRef(id: w2, appBundleID: a.bundle, title: "Second")],
                          elements: [w1: els, w2: [ElementRef(id: nextID, windowID: w2, role: "AXButton", title: "OK")]]))
            nextID += 1
        }
        sys.bringToFront(front)
        if let body = sys.snapshot().focusedWindow.flatMap({ sys.elements(in: $0).first { $0.title == "Body" } }) { try? sys.focus(body) }
        return sys
    }
}
