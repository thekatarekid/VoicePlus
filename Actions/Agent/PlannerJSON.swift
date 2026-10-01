import Foundation

// MARK: - V5 CU8 · strict-JSON StepPlan contract, parsed with repair
//
// Small local models (Qwen3.5-2B/4B through llama.cpp) are asked for exactly one JSON object. They
// do not always deliver one: code fences, a `<think>` block, a trailing comma, single quotes, bare
// keys or a reply cut off at the token cap are all common. `PlannerJSON.parse` repairs those, and
// anything it still cannot read is a give-up — never a guessed action.

public enum PlannerJSON {
    /// The reply contract appended to the planner system prompt.
    public static let contract = """
    Reply with ONE JSON object and nothing else — no prose, no code fence:
    {"status":"plan","rationale":"<one line>","steps":[{"tool":"<tool>","params":{"<param>":"<value>"}}]}
    or {"status":"done","summary":"<what is now true>"}
    or {"status":"giveup","reason":"<why>"}
    Use only the tools listed, with their parameter names; at most 12 steps.
    """

    /// The decoded turn, or nil when the reply holds no JSON object at all (the caller may then try
    /// the legacy line format).
    public static func parse(_ reply: String, goal: String) -> PlannerTurn? {
        guard let object = decodeObject(reply) else { return nil }
        return turn(from: object, goal: goal)
    }

    // MARK: Decoding

    /// The first JSON value in `reply`, repaired as needed. Top-level arrays are read as a step list.
    static func decodeObject(_ reply: String) -> [String: Any]? {
        guard let candidate = extractJSON(from: stripNoise(reply)) else { return nil }
        for text in repairs(of: candidate) {
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            if let dict = value as? [String: Any] { return dict }
            if let array = value as? [Any] { return ["status": "plan", "steps": array] }
        }
        return nil
    }

    static func turn(from object: [String: Any], goal: String) -> PlannerTurn {
        let status = (string(object["status"]) ?? string(object["type"]) ?? "")
            .lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        switch status {
        case "done", "complete", "completed", "finished":
            return .done(summary: string(object["summary"]) ?? string(object["message"]) ?? "")
        case "giveup", "fail", "failed", "cannot", "impossible":
            return .giveUp(reason: string(object["reason"]) ?? string(object["message"]) ?? "planner gave up")
        default:
            break
        }
        let rawSteps = (object["steps"] as? [Any]) ?? (object["plan"] as? [Any]) ?? (object["actions"] as? [Any]) ?? []
        let steps = rawSteps.compactMap { step(from: $0) }
        guard !steps.isEmpty else { return .giveUp(reason: "planner reply had no parseable steps") }
        return .plan(StepPlan(goal: goal, steps: steps, rationale: string(object["rationale"]) ?? ""))
    }

    static func step(from value: Any) -> PlanStep? {
        guard let dict = value as? [String: Any],
              let tool = string(dict["tool"]) ?? string(dict["action"]) ?? string(dict["kind"]) ?? string(dict["name"]),
              let kind = kind(named: tool) else { return nil }
        let rawParams = (dict["params"] as? [String: Any]) ?? (dict["args"] as? [String: Any])
            ?? (dict["arguments"] as? [String: Any]) ?? (dict["parameters"] as? [String: Any]) ?? [:]
        var params: [String: String] = [:]
        for (k, v) in rawParams { if let s = string(v) { params[k] = s } }
        let title = string(dict["title"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(kind.rawValue) \(params.keys.sorted().first.flatMap { params[$0] } ?? "")".trimmingCharacters(in: .whitespaces)
        return PlanStep(title: title, request: ActionRequest(kind: kind, params: params))
    }

    /// Tool names are matched exactly first, then case- and separator-insensitively (`fill_field`).
    static func kind(named raw: String) -> ActionKind? {
        if let k = ActionKind(rawValue: raw) { return k }
        let norm = raw.lowercased().filter { $0.isLetter }
        let all: [ActionKind] = [.click, .fillField, .focusApp, .focusWindow, .focusTab, .windowOp, .switchSpace,
                                 .scroll, .shortcut, .typeText, .openURL, .openFile]
        return all.first { $0.rawValue.lowercased() == norm }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default: return nil
        }
    }

    // MARK: Repair

    /// Drop `<think>…</think>` blocks and code fences.
    static func stripNoise(_ reply: String) -> String {
        var s = reply
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
        return s.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    /// The first balanced `{…}` / `[…]` (string-aware). A truncated value is closed: an open string
    /// is terminated and every open bracket is closed in order.
    static func extractJSON(from text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        var stack: [Character] = []
        var inString = false
        var quote: Character = "\""
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == quote { inString = false }
            } else {
                switch c {
                case "\"", "'": inString = true; quote = c
                case "{": stack.append("}")
                case "[": stack.append("]")
                case "}", "]":
                    if !stack.isEmpty { stack.removeLast() }
                    if stack.isEmpty { return String(chars[start...i]) }
                default: break
                }
            }
            i += 1
        }
        // Truncated: close what is open.
        var out = String(chars[start...])
        if inString { out.append(quote) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix(",") { out.removeLast() }
        if out.hasSuffix(":") { out += "null" }
        for closer in stack.reversed() { out.append(closer) }
        return out
    }

    /// Candidate texts, mildest repair first.
    static func repairs(of json: String) -> [String] {
        var out = [json]
        var s = removingTrailingCommas(json)
        out.append(s)
        if !s.contains("\"") || s.filter({ $0 == "'" }).count > s.filter({ $0 == "\"" }).count {
            s = s.replacingOccurrences(of: "'", with: "\"")
            out.append(s)
        }
        s = quotingBareKeys(s)
        out.append(s)
        // A key left dangling by truncation: `"a": }` → `"a": null}`.
        out.append(s.replacingOccurrences(of: #":\s*([}\]])"#, with: ": null$1", options: .regularExpression))
        // A truncated last element: drop it.
        out.append(droppingIncompleteTail(s))
        return out
    }

    static func removingTrailingCommas(_ s: String) -> String {
        s.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
    }

    static func quotingBareKeys(_ s: String) -> String {
        s.replacingOccurrences(of: #"([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: "$1\"$2\":", options: .regularExpression)
    }

    /// `{"steps":[{…},{"tool":"cli"}]}` cut inside the last step → keep the complete steps only.
    static func droppingIncompleteTail(_ s: String) -> String {
        guard let lastComplete = s.range(of: "},", options: .backwards) else { return s }
        let head = String(s[..<lastComplete.upperBound]).dropLast()
        guard let fixed = extractJSON(from: String(head)) else { return s }
        return removingTrailingCommas(fixed)
    }
}
