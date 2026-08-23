import Foundation
import Shared

/// Request from the keyboard extension to the companion app: run the heavy pipeline on
/// on-device ASR output. Versioned JSON so both sides can evolve independently.
public struct KeyboardProxyRequest: Codable, Equatable, Sendable {
    public static let codecVersion = 1
    public var version = KeyboardProxyRequest.codecVersion
    public var requestID: Int
    public var spans: [TranscriptSpan]
    public var persona: String?
    public var sentAt: Date
    public init(requestID: Int, spans: [TranscriptSpan], persona: String? = nil, sentAt: Date = Date()) {
        self.requestID = requestID; self.spans = spans; self.persona = persona; self.sentAt = sentAt
    }
}

public struct KeyboardProxyResponse: Codable, Equatable, Sendable {
    public var version = KeyboardProxyRequest.codecVersion
    public var requestID: Int
    public var spans: [TranscriptSpan]
    public var error: String?
    public init(requestID: Int, spans: [TranscriptSpan], error: String? = nil) {
        self.requestID = requestID; self.spans = spans; self.error = error
    }
}

public enum KeyboardProxyCodecError: Error, Equatable { case versionMismatch(Int) }

/// Envelope codec. Rejects unknown major versions instead of silently decoding garbage.
public enum KeyboardProxyCodec {
    private struct Header: Decodable { let version: Int }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        return try e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let v = try d.decode(Header.self, from: data).version
        guard v == KeyboardProxyRequest.codecVersion else { throw KeyboardProxyCodecError.versionMismatch(v) }
        return try d.decode(type, from: data)
    }
}

/// Well-known names shared by both processes.
public enum KeyboardProxyNames {
    public static let appGroup = "group.in.adityakatare.voiceplus"
    public static let requestNotification = "in.adityakatare.voiceplus.keyboard.request"
    public static let responseNotification = "in.adityakatare.voiceplus.keyboard.response"
    public static let personasKey = "keyboard.personas"
    public static let mailboxDirectory = "KeyboardMailbox"
    /// How long the keyboard waits for the app before landing raw ASR text.
    public static let responseTimeout: TimeInterval = 1.5
}

/// Transport abstraction: App Group container files + Darwin notification as the doorbell.
public protocol KeyboardMailbox: Sendable {
    func post(_ request: KeyboardProxyRequest) throws
    func takeRequest() throws -> KeyboardProxyRequest?
    func post(_ response: KeyboardProxyResponse) throws
    func takeResponse() throws -> KeyboardProxyResponse?
}

/// File-backed mailbox inside a directory (the App Group container on iOS; a temp dir in tests).
/// One slot per direction; writes are atomic so a half-written file is never read.
public struct FileKeyboardMailbox: KeyboardMailbox {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    var requestURL: URL { directory.appendingPathComponent("request.json") }
    var responseURL: URL { directory.appendingPathComponent("response.json") }

    public func post(_ request: KeyboardProxyRequest) throws { try KeyboardProxyCodec.encode(request).write(to: requestURL, options: .atomic) }
    public func post(_ response: KeyboardProxyResponse) throws { try KeyboardProxyCodec.encode(response).write(to: responseURL, options: .atomic) }
    public func takeRequest() throws -> KeyboardProxyRequest? { try take(requestURL) }
    public func takeResponse() throws -> KeyboardProxyResponse? { try take(responseURL) }

    private func take<T: Decodable>(_ url: URL) throws -> T? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try KeyboardProxyCodec.decode(T.self, from: data)
    }
}

/// Doorbell between processes. Live impl wraps `CFNotificationCenterGetDarwinNotifyCenter`.
public protocol KeyboardDoorbell: AnyObject {
    func ring(_ name: String)
    func listen(_ name: String, handler: @escaping @Sendable () -> Void)
}

/// In-process doorbell for tests / simulators without App Groups.
public final class LoopbackDoorbell: KeyboardDoorbell, @unchecked Sendable {
    private var handlers: [String: [@Sendable () -> Void]] = [:]
    private let lock = NSLock()
    public init() {}
    public func ring(_ name: String) { lock.lock(); let h = handlers[name] ?? []; lock.unlock(); h.forEach { $0() } }
    public func listen(_ name: String, handler: @escaping @Sendable () -> Void) { lock.lock(); handlers[name, default: []].append(handler); lock.unlock() }
}

#if canImport(CoreFoundation) && !os(Linux)
import CoreFoundation
/// Darwin notifications cross the extension/app boundary; payloads go through the mailbox.
public final class DarwinDoorbell: KeyboardDoorbell, @unchecked Sendable {
    private var handlers: [String: [@Sendable () -> Void]] = [:]
    private let lock = NSLock()
    public init() {}
    public func ring(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
    public func listen(_ name: String, handler: @escaping @Sendable () -> Void) {
        lock.lock(); let first = handlers[name] == nil; handlers[name, default: []].append(handler); lock.unlock()
        guard first else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let bell = Unmanaged<DarwinDoorbell>.fromOpaque(observer).takeUnretainedValue()
            bell.fire(name.rawValue as String)
        }, name as CFString, nil, .deliverImmediately)
    }
    private func fire(_ name: String) { lock.lock(); let h = handlers[name] ?? []; lock.unlock(); h.forEach { $0() } }
    deinit { CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque()) }
}
#endif

/// Keyboard-side client: post + ring, then wait for the response doorbell (or time out).
public final class KeyboardProxyClient: @unchecked Sendable {
    let mailbox: any KeyboardMailbox
    let doorbell: any KeyboardDoorbell
    public init(mailbox: any KeyboardMailbox, doorbell: any KeyboardDoorbell) { self.mailbox = mailbox; self.doorbell = doorbell }

    public func send(_ request: KeyboardProxyRequest, timeout: TimeInterval = KeyboardProxyNames.responseTimeout) async -> KeyboardProxyResponse? {
        try? mailbox.post(request)
        doorbell.ring(KeyboardProxyNames.requestNotification)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = try? mailbox.takeResponse(), r.requestID == request.requestID { return r }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

/// App-side server: on doorbell, take the request, run `handler`, post the response, ring back.
public final class KeyboardProxyServer: @unchecked Sendable {
    public typealias Handler = @Sendable (KeyboardProxyRequest) async -> [TranscriptSpan]
    let mailbox: any KeyboardMailbox
    let doorbell: any KeyboardDoorbell
    let handler: Handler
    public init(mailbox: any KeyboardMailbox, doorbell: any KeyboardDoorbell, handler: @escaping Handler) {
        self.mailbox = mailbox; self.doorbell = doorbell; self.handler = handler
    }
    public func start() {
        doorbell.listen(KeyboardProxyNames.requestNotification) { [weak self] in self?.serviceOnce() }
    }
    public func serviceOnce() {
        guard let req = try? mailbox.takeRequest() else { return }
        Task { [self] in
            let spans = await handler(req)
            try? mailbox.post(KeyboardProxyResponse(requestID: req.requestID, spans: spans))
            doorbell.ring(KeyboardProxyNames.responseNotification)
        }
    }
}
