import Foundation

// S7f — Privacy › Diagnostics › export (design §8.5, §12: "Diagnostics omit transcript/audio by
// default and preview any data included in an export"). The export is built once as data; the
// preview shows exactly that data and `write` writes exactly that data — the preview can never be a
// summary of something else. Dictated text and audio join only by an explicit switch each.

public struct DiagnosticsOptions: Equatable, Sendable {
    public var includeTranscripts: Bool
    public var includeAudio: Bool

    public init(includeTranscripts: Bool = false, includeAudio: Bool = false) {
        self.includeTranscripts = includeTranscripts
        self.includeAudio = includeAudio
    }

    /// Redacted: no dictated text, no audio.
    public static let redacted = DiagnosticsOptions()
}

/// One dictation's text, offered only when the user opts in.
public struct DiagnosticsTranscript: Equatable, Sendable {
    public var time: Date
    public var app: String?
    public var text: String

    public init(time: Date, app: String?, text: String) {
        self.time = time
        self.app = app
        self.text = text
    }
}

/// One file in the export folder.
public struct DiagnosticsFile: Equatable, Sendable {
    /// Path inside the export folder ("report.txt", "audio/…").
    public var name: String
    public var bytes: Int64
    /// Where the bytes come from; nil for the report, which is written from `report`.
    public var source: URL?

    public init(name: String, bytes: Int64, source: URL? = nil) {
        self.name = name
        self.bytes = bytes
        self.source = source
    }
}

/// Everything a report may be built from. Transcripts and audio are listed here only when the
/// caller read them; the builder still drops them unless the options include them.
public struct DiagnosticsFacts: Equatable, Sendable {
    public var generatedAt: Date
    public var appVersion: String
    public var osVersion: String
    public var permissions: [String]
    public var settings: [String]
    public var kept: [String]
    public var network: [String]
    public var flags: [String]
    public var transcripts: [DiagnosticsTranscript]
    public var audio: [DiagnosticsFile]

    public init(generatedAt: Date, appVersion: String, osVersion: String, permissions: [String] = [],
                settings: [String] = [], kept: [String] = [], network: [String] = [], flags: [String] = [],
                transcripts: [DiagnosticsTranscript] = [], audio: [DiagnosticsFile] = []) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.permissions = permissions
        self.settings = settings
        self.kept = kept
        self.network = network
        self.flags = flags
        self.transcripts = transcripts
        self.audio = audio
    }
}

/// The export: the report's exact text and the exact file list.
public struct DiagnosticsExport: Equatable, Sendable {
    public static let reportName = "report.txt"
    public static let audioFolder = "audio"

    public var report: String
    public var files: [DiagnosticsFile]
    public var includesTranscripts: Bool
    public var includesAudio: Bool

    /// What the preview shows: the report verbatim, then every file the export will contain.
    public var preview: String {
        let list = files.map { "• \($0.name) — \(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file))" }
        return report + "\n\nFiles in this export\n" + list.joined(separator: "\n")
    }
}

/// Removes what identifies the person from the parts of a report that are not their words: the home
/// folder path and the account name.
public struct DiagnosticsRedactor: Sendable {
    public var home: String
    public var user: String

    public init(home: String, user: String) {
        self.home = home
        self.user = user
    }

    public static var current: DiagnosticsRedactor {
        DiagnosticsRedactor(home: FileManager.default.homeDirectoryForCurrentUser.path, user: NSUserName())
    }

    public func callAsFunction(_ text: String) -> String {
        var out = text
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        if user.count >= 3 { out = out.replacingOccurrences(of: user, with: "‹user›") }
        return out
    }
}

public enum PrivacyDiagnostics {
    /// Builds the export. With `.redacted` options the report carries no dictated text and the
    /// export no audio, whatever `facts` holds.
    public static func export(_ facts: DiagnosticsFacts, options: DiagnosticsOptions,
                              redactor: DiagnosticsRedactor = .current) -> DiagnosticsExport {
        let transcripts = options.includeTranscripts ? facts.transcripts : []
        let audio = options.includeAudio ? facts.audio : []
        var lines: [String] = [
            "VoicePlus diagnostics",
            "Generated \(facts.generatedAt.formatted(.iso8601))",
            "VoicePlus \(facts.appVersion) · \(facts.osVersion)",
            "",
            "Included: settings, permission states and counts" + (transcripts.isEmpty ? "" : ", the text of recent dictations")
                + (audio.isEmpty ? "" : ", saved recordings") + ".",
            "Not included: " + notIncluded(transcripts: !transcripts.isEmpty, audio: !audio.isEmpty) + ".",
        ]
        func section(_ title: String, _ body: [String]) {
            guard !body.isEmpty else { return }
            lines += ["", "[\(title)]"] + body.map(redactor.callAsFunction)
        }
        section("Permissions", facts.permissions)
        section("Settings", facts.settings)
        section("Kept on this Mac", facts.kept)
        section("Network, last 30 days", facts.network)
        section("Feature flags", facts.flags)
        if !transcripts.isEmpty {
            lines += ["", "[Dictated text — included because you turned it on]"]
            lines += transcripts.map { t in
                "\(t.time.formatted(.iso8601))\(t.app.map { " · \($0)" } ?? ""): \(t.text)"
            }
        }
        var files = [DiagnosticsFile(name: DiagnosticsExport.reportName, bytes: 0)]
        if !audio.isEmpty {
            let bytes = audio.reduce(Int64(0)) { $0 + $1.bytes }
            lines += ["", "[Audio — included because you turned it on]",
                      "\(audio.count) file\(audio.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), in the \(DiagnosticsExport.audioFolder) folder of this export."]
            files += audio.map { DiagnosticsFile(name: "\(DiagnosticsExport.audioFolder)/\($0.name)", bytes: $0.bytes, source: $0.source) }
        }
        let report = lines.joined(separator: "\n") + "\n"
        files[0].bytes = Int64(report.utf8.count)
        return DiagnosticsExport(report: report, files: files,
                                 includesTranscripts: !transcripts.isEmpty, includesAudio: !audio.isEmpty)
    }

    static func notIncluded(transcripts: Bool, audio: Bool) -> String {
        var parts: [String] = []
        if !transcripts { parts.append("dictated text") }
        if !audio { parts.append("audio") }
        parts += ["screen images", "your home folder path"]
        return parts.joined(separator: ", ")
    }

    /// Writes the export as a new folder inside `parent` and returns it. Exactly `export.files` are
    /// written; if any copy fails the folder is removed, so a half export is never left behind.
    @discardableResult
    public static func write(_ export: DiagnosticsExport, into parent: URL, folderName: String,
                             fileManager: FileManager = .default) throws -> URL {
        let folder = parent.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in export.files {
                let target = folder.appendingPathComponent(file.name)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let source = file.source {
                    try fileManager.copyItem(at: source, to: target)
                } else {
                    try Data(export.report.utf8).write(to: target)
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// "VoicePlus Diagnostics 2026-09-19 1042".
    public static func folderName(at date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "VoicePlus Diagnostics \(f.string(from: date))"
    }
}
