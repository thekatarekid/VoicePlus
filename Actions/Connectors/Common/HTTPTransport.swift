import Foundation

/// Single seam between connectors and the network. Live impl is URLSession; tests use `MockHTTPTransport`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw ConnectorError.malformedResponse("non-HTTP response") }
        return (data, http)
    }
}

/// Records every request and replays scripted responses (FIFO; last one repeats).
public final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Response: Sendable {
        public var status: Int; public var body: Data
        public init(status: Int = 200, json: String = "{}") { self.status = status; body = Data(json.utf8) }
    }
    private let lock = NSLock()
    private var queue: [Response]
    public private(set) var requests: [URLRequest] = []

    public init(_ responses: [Response] = [Response()]) { queue = responses }

    public func enqueue(_ r: Response) { lock.lock(); queue.append(r); lock.unlock() }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let r = queue.count > 1 ? queue.removeFirst() : (queue.first ?? Response())
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (r.body, http)
    }

    /// Decoded JSON body of request `i` (for assertions on request shaping).
    public func jsonBody(_ i: Int) -> [String: Any] {
        guard i < requests.count, let d = requests[i].httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

public enum ConnectorError: Error, Equatable, Sendable {
    case notSignedIn
    case unauthorized
    case http(Int, String)
    case malformedResponse(String)
    case unsupported(String)
    case timeout
}
