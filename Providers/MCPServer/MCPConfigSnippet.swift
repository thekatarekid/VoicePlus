import Foundation

// V5 M23 — the config snippets Settings › Providers prints for Claude Code and Codex. Stdio is the
// primary form (the client launches the app binary with `--mcp-stdio`; works whether or not the
// app is open); HTTP is offered while the app runs, with its bearer token.

public enum MCPConfigSnippet {
    public static let serverKey = MCPServer.serverName
    public static let stdioFlag = "--mcp-stdio"

    static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func tomlQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func jsonQuoted(_ s: String) -> String {
        String(data: MCPJSON.encode(.string(s)), encoding: .utf8) ?? "\"\""
    }

    /// `claude mcp add` for the stdio server (user scope: every project).
    public static func claudeCode(executable: String) -> String {
        "claude mcp add --scope user \(serverKey) -- \(shellQuoted(executable)) \(stdioFlag)"
    }

    /// `claude mcp add` for the loopback HTTP server.
    public static func claudeCodeHTTP(url: URL, token: String) -> String {
        "claude mcp add --scope user --transport http \(serverKey) \(url.absoluteString) --header \(shellQuoted("Authorization: Bearer \(token)"))"
    }

    /// `~/.codex/config.toml`.
    public static func codex(executable: String) -> String {
        "[mcp_servers.\(serverKey)]\ncommand = \(tomlQuoted(executable))\nargs = [\(tomlQuoted(stdioFlag))]"
    }

    /// The generic `mcpServers` JSON most clients accept (`.mcp.json`, Claude Desktop…).
    public static func json(executable: String) -> String {
        """
        {
          "mcpServers": {
            "\(serverKey)": {
              "command": \(jsonQuoted(executable)),
              "args": [\(jsonQuoted(stdioFlag))]
            }
          }
        }
        """
    }
}
