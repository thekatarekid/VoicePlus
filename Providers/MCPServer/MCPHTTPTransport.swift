import Foundation
import Network
import Security

// V5 M23 — loopback HTTP transport (MCP "Streamable HTTP", JSON responses only, no SSE stream):
// `POST /mcp` on 127.0.0.1. Guards, because any local process or web page can reach loopback:
// - bound to the loopback interface only, never the network;
// - `Authorization: Bearer <token>` required (the token is shown in the config snippet and kept in
//   the Keychain by the app);
// - `Host` must be 127.0.0.1/localhost and an `Origin`, when present, must be a loopback origin
//   (DNS-rebinding defence, as the MCP spec asks);
// - bodies over 1 MB are refused. One request per connection (`Connection: close`).

public struct MCPHTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // lower-cased names
    public var body: Data
}

public struct MCPHTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public var contentType: String?

    public var serialized: Data {
        let reason: String = switch status {
        case 200: "OK"; case 202: "Accepted"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"
        case 404: "Not Found"; case 405: "Method Not Allowed"; case 413: "Payload Too Large"; default: "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        if status == 405 { head += "Allow: POST\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

public enum MCPHTTPParser {
    public static let maxBody = 1 << 20

    public enum Parse: Equatable { case incomplete, tooLarge, invalid, request(MCPHTTPRequest) }

    public static func parse(_ data: Data) -> Parse {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 * 1024 ? .tooLarge : .incomplete }
        guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        guard length <= maxBody else { return .tooLarge }
        let body = data[split.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .request(MCPHTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(length))))
    }
}

public final class MCPHTTPTransport: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47_613
    public static let path = "/mcp"

    public let server: MCPServer
    public let token: String
    public private(set) var port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "voiceplus.mcp.http")

    public init(server: MCPServer, token: String, port: UInt16 = MCPHTTPTransport.defaultPort) {
        self.server = server; self.token = token; self.port = port
    }

    public var isRunning: Bool { queue.sync { listener != nil } }

    public var url: URL { URL(string: "http://127.0.0.1:\(port)\(Self.path)")! }

    /// Starts listening on 127.0.0.1; returns once the listener is ready (or failed). Port 0 picks
    /// a free port (tests); `port` then holds the real one.
    public func start() async throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = listener.port?.rawValue { self?.port = p }
                    if !once.done { once.done = true; cont.resume() }
                case .failed(let e):
                    if !once.done { once.done = true; cont.resume(throwing: e) }
                default: break
                }
            }
            queue.sync { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch MCPHTTPParser.parse(buffer) {
            case .incomplete:
                if complete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            case .tooLarge:
                self.send(MCPHTTPResponse(status: 413, body: Data()), on: connection)
            case .invalid:
                self.send(MCPHTTPResponse(status: 400, body: Data()), on: connection)
            case .request(let request):
                Task {
                    let response = await self.respond(to: request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// The HTTP rules, separate from the socket so they can be tested directly.
    public func respond(to request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard Self.isLoopbackHost(request.headers["host"]) else { return MCPHTTPResponse(status: 403, body: Data()) }
        if let origin = request.headers["origin"], !Self.isLoopbackOrigin(origin) { return MCPHTTPResponse(status: 403, body: Data()) }
        guard !token.isEmpty, Self.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return MCPHTTPResponse(status: 401, body: Data())
        }
        guard request.path.split(separator: "?").first.map(String.init) == Self.path else { return MCPHTTPResponse(status: 404, body: Data()) }
        guard request.method == "POST" else { return MCPHTTPResponse(status: 405, body: Data()) }
        guard let out = await server.handle(request.body) else { return MCPHTTPResponse(status: 202, body: Data()) }
        return MCPHTTPResponse(status: 200, body: out, contentType: "application/json")
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host else { return false }
        let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(name.lowercased())
    }

    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }

    /// 32 random bytes, hex.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
