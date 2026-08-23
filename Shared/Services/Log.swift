import Foundation
import os

/// One captured log line, kept in the ring buffer for the Data Panel and the Lab.
public struct LogEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Level: String, Codable, Sendable, Comparable {
        case debug, info, notice, warning, error, fault
        private var rank: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .notice: return 2
            case .warning: return 3
            case .error: return 4
            case .fault: return 5
            }
        }
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public var id: UUID
    public var timestamp: Date
    public var level: Level
    public var category: String
    public var message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Thread-safe in-memory ring buffer of recent log entries.
public final class LogBuffer: @unchecked Sendable {
    public static let shared = LogBuffer(capacity: 2000)

    private let lock = NSLock()
    private var entries: [LogEntry] = []
    public let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public func append(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// Newest last.
    public func snapshot(minimumLevel: LogEntry.Level = .debug, category: String? = nil) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.level >= minimumLevel && (category == nil || $0.category == category) }
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

/// `os.Logger` wrapper that also feeds `LogBuffer`. No telemetry, no network.
/// Usage: `Log.engine.info("model loaded")` or `Log(category: "mystage").debug(...)`.
public struct Log: Sendable {
    public static let subsystem = "in.adityakatare.voiceplus"

    public let category: String
    private let logger: Logger
    private let buffer: LogBuffer

    public init(category: String, buffer: LogBuffer = .shared) {
        self.category = category
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        self.buffer = buffer
    }

    public static let app = Log(category: "app")
    public static let engine = Log(category: "engine")
    public static let pipeline = Log(category: "pipeline")
    public static let injection = Log(category: "injection")
    public static let providers = Log(category: "providers")
    public static let lab = Log(category: "lab")
    public static let actions = Log(category: "actions")
    public static let db = Log(category: "db")
    /// Every byte leaving the machine is logged here (and in `network_log`).
    public static let network = Log(category: "network")

    public func debug(_ message: String) { emit(.debug, message) }
    public func info(_ message: String) { emit(.info, message) }
    public func notice(_ message: String) { emit(.notice, message) }
    public func warning(_ message: String) { emit(.warning, message) }
    public func error(_ message: String) { emit(.error, message) }
    public func fault(_ message: String) { emit(.fault, message) }

    private func emit(_ level: LogEntry.Level, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
        buffer.append(LogEntry(level: level, category: category, message: message))
    }
}
