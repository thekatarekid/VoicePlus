import Foundation

// V5 M23 — a small JSON value for the MCP server's JSON-RPC messages (no dependency, Codable).

public enum MCPJSON: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MCPJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MCPJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> MCPJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var object: [String: MCPJSON]? { if case .object(let o) = self { return o }; return nil }

    public static func encode(_ value: MCPJSON) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(value)) ?? Data("null".utf8)
    }

    public static func decode(_ data: Data) -> MCPJSON? { try? JSONDecoder().decode(MCPJSON.self, from: data) }
}

extension MCPJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                   ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: MCPJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MCPJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { a, _ in a }))
    }
}
