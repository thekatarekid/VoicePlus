import Foundation

// V5 M-d — what happens after a meeting ends, per Settings › Meetings: auto-export the record to a
// folder (Markdown or JSON) and run the user's post-meeting hook with a JSON record on stdin.
// Lives beside the detector because the settings page owns both; M20 (export UI) reuses
// `MeetingAutoExporter` for its "Export" button.

public enum MeetingExportFormat: String, Codable, Sendable, CaseIterable {
    case markdown, json
    public var fileExtension: String { self == .markdown ? "md" : "json" }
}

public struct MeetingAutoExport: Codable, Equatable, Sendable {
    public var folder: URL
    public var format: MeetingExportFormat
    public init(folder: URL, format: MeetingExportFormat = .markdown) { self.folder = folder; self.format = format }
}

public enum MeetingAutoExporter {
    /// Writes the record into `config.folder` as `yyyy-MM-dd HHmm <title>.<ext>`; never overwrites
    /// (adds " 2", " 3"…). Returns the file written.
    @discardableResult
    public static func export(_ record: MeetingRecord, to config: MeetingAutoExport,
                              fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: config.folder, withIntermediateDirectories: true)
        let base = fileName(for: record)
        var url = config.folder.appendingPathComponent("\(base).\(config.format.fileExtension)")
        var n = 2
        while fileManager.fileExists(atPath: url.path) {
            url = config.folder.appendingPathComponent("\(base) \(n).\(config.format.fileExtension)"); n += 1
        }
        let data: Data
        switch config.format {
        case .markdown: data = Data(record.markdown.utf8)
        case .json: data = try PostMeetingHookPayload.encoder.encode(record)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func fileName(for record: MeetingRecord) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HHmm"
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let title = record.title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).prefix(80)
        return "\(f.string(from: record.startedAt)) \(title.isEmpty ? "Meeting" : String(title))"
    }
}

/// The JSON the hook reads on stdin. `schema` is versioned so scripts can check it.
public struct PostMeetingHookPayload: Codable, Equatable, Sendable {
    public static let schemaID = "voiceplus.meeting/1"
    public var schema: String
    public var record: MeetingRecord
    public var markdown: String
    /// The auto-exported file, when auto-export ran first.
    public var exportedFile: String?

    public init(record: MeetingRecord, exportedFile: URL? = nil) {
        self.schema = Self.schemaID; self.record = record; self.markdown = record.markdown
        self.exportedFile = exportedFile?.path
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

public struct PostMeetingHookConfig: Codable, Equatable, Sendable {
    public static let defaultTimeout: TimeInterval = 30
    public static let timeoutRange: ClosedRange<TimeInterval> = 1...600
    /// An executable file. Run directly (no shell), with the payload on stdin.
    public var path: String
    public var timeout: TimeInterval
    public init(path: String, timeout: TimeInterval = PostMeetingHookConfig.defaultTimeout) {
        self.path = path
        self.timeout = min(Self.timeoutRange.upperBound, max(Self.timeoutRange.lowerBound, timeout))
    }
}

public enum PostMeetingHookResult: Equatable, Sendable {
    case notExecutable(String)
    case finished(status: Int32)
    case timedOut
    case failed(String)
}

/// Runs the user's post-meeting hook: the file at `path`, no shell, no arguments, JSON payload on
/// stdin, stdout/stderr discarded, terminated (then killed) after `timeout`. Never throws; the
/// result is for the log.
public enum PostMeetingHook {
    public static func run(_ config: PostMeetingHookConfig, payload: PostMeetingHookPayload) async -> PostMeetingHookResult {
        let path = (config.path as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { return .notExecutable(path) }
        let data: Data
        do { data = try PostMeetingHookPayload.encoder.encode(payload) } catch { return .failed("encode: \(error)") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let state = HookState()
        return await withCheckedContinuation { (cont: CheckedContinuation<PostMeetingHookResult, Never>) in
            state.continuation = cont
            process.terminationHandler = { p in
                state.finish(state.didTimeOut ? .timedOut : .finished(status: p.terminationStatus))
            }
            do { try process.run() } catch {
                state.finish(.failed("launch: \(error.localizedDescription)")); return
            }
            // Write on a background queue: a payload larger than the pipe buffer blocks until the
            // hook reads it. A hook that exits without reading must not SIGPIPE us.
            let fd = stdin.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                try? stdin.fileHandleForWriting.write(contentsOf: data)
                try? stdin.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + config.timeout) {
                guard process.isRunning else { return }
                state.didTimeOut = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private final class HookState: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<PostMeetingHookResult, Never>?
        private var _timedOut = false
        var didTimeOut: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _timedOut }
            set { lock.lock(); _timedOut = newValue; lock.unlock() }
        }
        func finish(_ result: PostMeetingHookResult) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.resume(returning: result)
        }
    }
}
