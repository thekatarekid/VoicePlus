import Foundation

// R8.1 — the proof that ambient speech cannot reach an injection path.
//
// V3 §8: "Ambient enabled → transcript into Timeline only; never type or act from ambient speech."
// The build item says to *test* it, and a test that merely observes "nothing was typed in this run"
// proves nothing about the next change. So the property is structural, in three independent layers,
// each of which fails on its own:
//
// 1. **Behaviour.** `LatchRuntime.run(segment:spans:generation:)` returns at `source == .ambient`
//    before `LatchDelivering` is consulted. `AmbientNeverInjectsTests` drives the real runtime with
//    a delivery spy and asserts the spy was never called at all — not `deliver`, not `hold`.
// 2. **Type.** An `AmbientEntry` is not anything the delivery path accepts. `auditEntryShape()`
//    walks it and rejects a field that is, or contains, an utterance / span / injection request.
// 3. **Source.** `auditSources()` reads this checkout and rejects (a) any file under `App/Ambient`
//    that names a way to put characters somewhere, and (b) any file under an injection directory
//    that names an ambient-capture type. (b) is the one that matters: wiring ambient output into the
//    injector means naming `AmbientEntry` or `AmbientTranscriptSink` somewhere on that path, and
//    there is no way to do it that this does not see.
//
// The source layer needs the checkout, which a shipped app does not have. It therefore returns nil
// rather than an empty list when it cannot read the sources, and the test `#require`s a non-nil
// result — an audit that silently found nothing to audit would be the worst possible pass.

/// The three audits that keep ambient transcript out of every injection path.
public enum AmbientInjectionAudit {
    /// One thing that must not be there.
    public struct Violation: Equatable, Sendable, CustomStringConvertible {
        /// Path relative to the package root.
        public var file: String
        public var line: Int
        /// The text that tripped the rule.
        public var symbol: String
        /// Which of the two source rules was broken.
        public var rule: String

        public var description: String { "\(file):\(line): \(rule) — “\(symbol)”" }
    }

    // MARK: What the rules are

    /// Ambient capture's own directory.
    public static let ambientDirectory = "App/Ambient"

    /// The directories that can put characters in a field or run an action. Ambient transcript types
    /// are forbidden in all of them.
    public static let injectionDirectories = ["Injection", "Actions", "Pipeline", "App/Services"]

    /// Names that mean "this code can deliver text somewhere". None of them may appear in
    /// `App/Ambient`. `import Injection` is first because it is the shortest route.
    public static let deliverySymbols = [
        "import Injection",
        "Injector", "InjectionRequest", "InjectionOutcome", "TextInjector", "InjectionPolicy",
        "CommitQueue", "ClipboardPaster", "MethodRouter", "AppAdapter", "ReplaceRange",
        "UtteranceLander", "LatchDelivering", "LanderLatchDelivery", "FocusGuard",
        "CGEvent", "NSPasteboard", "Pasteboard", "insertText", "AXUIElement",
        "ActStack", "ActionRunner", "ActRunner",
    ]

    /// The ambient-capture vocabulary. A file on an injection path that names one of these is, by
    /// construction, a file that has got hold of ambient speech.
    ///
    /// Deliberately only the *capture and transcript* types. `AmbientStateModel`, `MuteController`
    /// and `PresenceState` are the microphone-presence glyph — older, unrelated, and legitimately
    /// referenced from `App/Services` (`LatchController.ambientModel`). Listing them would make this
    /// audit fail for a reason that has nothing to do with ambient speech, and an audit that cries
    /// wolf gets deleted.
    public static let ambientCaptureSymbols = [
        "AmbientEntry", "AmbientTranscriptSink", "AmbientTranscriptStore", "AmbientTimelineReading",
        "AmbientCaptureGate", "AmbientCaptureDecision", "AmbientDiscardReason",
        "AmbientCaptureSettings", "AmbientRetentionPolicy", "AmbientSweepResult",
    ]

    // MARK: 3 — the source audit

    /// The checkout root, or nil in a shipped bundle where there are no sources to read.
    public static func packageRoot(file: String = #filePath) -> URL? {
        var url = URL(fileURLWithPath: file)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // App/Ambient/<this file> → root
        let manifest = url.appendingPathComponent("Package.swift")
        return FileManager.default.fileExists(atPath: manifest.path) ? url : nil
    }

    /// Both source rules, over the whole checkout. **nil** means the sources could not be read —
    /// never confuse that with "clean".
    public static func auditSources(root: URL? = packageRoot()) -> [Violation]? {
        guard let root else { return nil }
        var violations: [Violation] = []

        // (a) Ambient must not name a way to deliver text.
        for file in swiftFiles(under: root.appendingPathComponent(ambientDirectory)) {
            violations += scan(file, root: root, for: deliverySymbols,
                               rule: "App/Ambient must not reach a delivery path")
        }
        // (b) No delivery path may name an ambient-capture type.
        for directory in injectionDirectories {
            for file in swiftFiles(under: root.appendingPathComponent(directory)) {
                violations += scan(file, root: root, for: ambientCaptureSymbols,
                                   rule: "\(directory) must not name an ambient-capture type")
            }
        }
        return violations
    }

    /// How many files the audit actually read. A test asserts this is not zero, so a wrong root
    /// cannot masquerade as a pass.
    public static func auditedFileCount(root: URL? = packageRoot()) -> Int {
        guard let root else { return 0 }
        return ([ambientDirectory] + injectionDirectories)
            .map { swiftFiles(under: root.appendingPathComponent($0)).count }
            .reduce(0, +)
    }

    static func swiftFiles(under directory: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    static func scan(_ file: URL, root: URL, for symbols: [String], rule: String) -> [Violation] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        // Symlinks resolved on both sides: the enumerator can hand back /private/var for a /var root,
        // and a violation whose path did not start with its directory would be filtered away unseen.
        let base = root.resolvingSymlinksInPath().path
        let relative = file.resolvingSymlinksInPath().path
            .replacingOccurrences(of: base + "/", with: "")
        var out: [Violation] = []
        for (index, raw) in code(in: text).enumerated() {
            for symbol in symbols where raw.contains(symbol) {
                out.append(Violation(file: relative, line: index + 1, symbol: symbol, rule: rule))
            }
        }
        return out
    }

    /// The lines with comments **and string literals** removed, so *writing about* the rule never
    /// breaks it. Two files need this: the header of `AmbientTranscriptStore.swift` names `Injector`
    /// in prose, and this file has to hold every forbidden name as a literal in order to look for it.
    /// A real breach is neither — `import Injection` in code is not `"import Injection"` in quotes.
    static func code(in text: String) -> [String] {
        var inBlock = false
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            let chars = Array(line)
            var kept = ""
            var inString = false
            var i = 0
            while i < chars.count {
                let c = chars[i]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if inBlock {
                    if c == "*", next == "/" { inBlock = false; i += 2 } else { i += 1 }
                    continue
                }
                if inString {
                    if c == "\\" { i += 2; continue }            // escape: skip what it escapes
                    if c == "\"" { inString = false }
                    i += 1
                    continue
                }
                if c == "/", next == "/" { break }               // line comment: the rest is prose
                if c == "/", next == "*" { inBlock = true; i += 2; continue }
                if c == "\"" { inString = true; i += 1; continue }
                kept.append(c)
                i += 1
            }
            out.append(kept)
        }
        return out
    }

    // MARK: 2 — the type audit

    /// Type names an ambient entry may not contain, directly or nested: every one of them is
    /// something the delivery path knows how to insert.
    public static let forbiddenEntryTypeNames = [
        "Injection", "Injector", "Utterance", "TranscriptSpan", "Span",
        "FocusSnapshot", "Pasteboard", "AXUIElement", "CGEvent",
    ]

    /// Field names that would mean an entry is carrying a destination or a delivery instruction.
    public static let forbiddenEntryFieldNames = ["inject", "deliver", "target", "destination", "paste", "insert"]

    /// Walks a fully-populated `AmbientEntry` and reports anything that looks insertable. Same shape
    /// as `SyncPayload.audit()`, for the same reason: the guarantee is about the type, so the check
    /// has to be about the type and not about one value.
    public static func auditEntryShape(_ entry: AmbientEntry = AmbientEntry.auditShape) -> [String] {
        var violations: [String] = []
        func walk(_ value: Any, path: String, depth: Int) {
            guard depth < 6 else { return }
            let name = String(describing: type(of: value))
            if forbiddenEntryTypeNames.contains(where: { name.contains($0) }) {
                violations.append("\(path): type \(name)")
            }
            for child in Mirror(reflecting: value).children {
                let label = child.label ?? "[]"
                if forbiddenEntryFieldNames.contains(where: { label.lowercased().contains($0) }) {
                    violations.append("\(path).\(label)")
                }
                walk(child.value, path: "\(path).\(label)", depth: depth + 1)
            }
        }
        walk(entry, path: "AmbientEntry", depth: 0)
        return violations
    }
}

public extension AmbientEntry {
    /// Every field populated, so `auditEntryShape()` sees the whole shape rather than a nil.
    static var auditShape: AmbientEntry {
        AmbientEntry(speaker: .others(2), text: "shape", capturedAt: Date(timeIntervalSince1970: 0),
                     duration: 1, confidence: 0.5)
    }
}
