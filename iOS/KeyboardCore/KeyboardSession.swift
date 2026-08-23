import Foundation
import Shared

/// Side effects the keyboard view controller must perform (maps 1:1 onto UITextDocumentProxy
/// and UIInputViewController calls). Pure data so the reducer is testable.
public enum KeyboardEffect: Equatable, Sendable {
    case startASR
    case stopASR
    case insertText(String)
    case deleteBackward(Int)
    case sendToProxy(KeyboardProxyRequest)
    /// `advanceToNextInputMode()` — jump back to the user's previous keyboard instantly.
    case returnToPreviousKeyboard
    case haptic(KeyboardHaptic)
}

public enum KeyboardHaptic: Equatable, Sendable { case start, land, error }

public enum KeyboardEvent: Equatable, Sendable {
    case pressDown
    case pressUp
    case partial(String)
    case final([TranscriptSpan])
    case proxyResponse(KeyboardProxyResponse)
    case proxyTimeout
    case pickAlternate(number: Int)
    case dismissFanout
    case error(String)
    case cancel
}

/// Hold-to-talk state machine. `committedText` is what the session has typed into the host
/// field so far (so fan-out picks can replace a word in place).
public struct KeyboardSession: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case listening(partial: String)
        /// ASR finished; waiting on the companion app for the heavy pipeline.
        case proxying(spans: [TranscriptSpan])
        /// Text typed; fan-out may be visible.
        case landed(spans: [TranscriptSpan], fanout: KeyboardRepairFanout?)
        case error(String)
    }

    public private(set) var state: State = .idle
    public private(set) var committedText = ""
    public var persona: String?
    public var useProxy: Bool
    public var autoReturn: Bool
    public var requestCounter = 0

    public init(useProxy: Bool = true, autoReturn: Bool = true, persona: String? = nil) {
        self.useProxy = useProxy; self.autoReturn = autoReturn; self.persona = persona
    }

    @discardableResult
    public mutating func handle(_ event: KeyboardEvent) -> [KeyboardEffect] {
        switch (state, event) {
        case (.idle, .pressDown), (.landed, .pressDown), (.error, .pressDown):
            state = .listening(partial: ""); committedText = ""
            return [.haptic(.start), .startASR]
        case (.listening, .partial(let t)):
            state = .listening(partial: t); return []
        case (.listening, .pressUp):
            return [.stopASR]
        case (.listening, .final(let spans)):
            return land(spans, fromProxy: false)
        case (.proxying(let spans), .proxyResponse(let r)):
            return r.requestID == requestCounter ? land(r.spans, fromProxy: true) : []
        case (.proxying(let spans), .proxyTimeout):
            return land(spans, fromProxy: true)
        case (.landed(let spans, .some(let fan)), .pickAlternate(let n)):
            guard let idx = fan.alternateIndex(forNumber: n) else { return [] }
            var s = spans; s[fan.spanIndex].text = fan.items[idx].text
            s[fan.spanIndex].confidence = 1; s[fan.spanIndex].provenance.append(.repair)
            let new = s.joinedText + " "
            let ops = TextReplacer.ops(from: committedText, to: new)
            committedText = new
            state = .landed(spans: s, fanout: nil)
            return ops + [.haptic(.land)]
        case (.landed(let spans, _), .dismissFanout):
            state = .landed(spans: spans, fanout: nil); return []
        case (_, .error(let m)):
            state = .error(m); return [.stopASR, .haptic(.error)]
        case (_, .cancel):
            state = .idle; return [.stopASR]
        default:
            return []
        }
    }

    private mutating func land(_ spans: [TranscriptSpan], fromProxy: Bool) -> [KeyboardEffect] {
        if useProxy, !fromProxy {
            requestCounter += 1
            state = .proxying(spans: spans)
            return [.sendToProxy(KeyboardProxyRequest(requestID: requestCounter, spans: spans, persona: persona))]
        }
        let fan = KeyboardRepairFanout.lowestConfidence(in: spans)
        state = .landed(spans: spans, fanout: fan)
        committedText = spans.joinedText
        var fx: [KeyboardEffect] = [.insertText(committedText + " "), .haptic(.land)]
        committedText += " "
        if autoReturn, fan == nil { fx.append(.returnToPreviousKeyboard) }
        return fx
    }

    public var isListening: Bool { if case .listening = state { return true }; return false }
}

/// Minimal edit: delete the trailing differing suffix and retype it (UITextDocumentProxy has
/// no replace-range API for committed text).
public enum TextReplacer {
    public static func ops(from old: String, to new: String) -> [KeyboardEffect] {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var fx: [KeyboardEffect] = []
        if o.count - p > 0 { fx.append(.deleteBackward(o.count - p)) }
        if n.count - p > 0 { fx.append(.insertText(String(n[p...]))) }
        return fx
    }
}
