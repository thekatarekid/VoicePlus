import Foundation

// V5 M23 — stdio transport: newline-delimited JSON-RPC on stdin/stdout, as MCP clients (Claude
// Code, Codex) speak to a server they launch. Diagnostics go to stderr only; stdout carries
// nothing but responses.

public struct MCPStdioTransport: Sendable {
    public let server: MCPServer

    public init(server: MCPServer) { self.server = server }

    /// Serves until `lines` ends (the client closed stdin). `write` receives each response line
    /// without its trailing newline.
    public func serve<Lines: AsyncSequence>(_ lines: Lines, write: (String) -> Void) async throws where Lines.Element == String {
        for try await line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let out = await server.handle(Data(trimmed.utf8)), let s = String(data: out, encoding: .utf8) {
                write(s)
            }
        }
    }

    /// Serves the process's stdin/stdout until stdin closes.
    public func run() async {
        let out = FileHandle.standardOutput
        do {
            try await serve(FileHandle.standardInput.bytes.lines) { line in
                out.write(Data((line + "\n").utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("voiceplus mcp: \(error)\n".utf8))
        }
    }
}
