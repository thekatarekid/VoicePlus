import Foundation
import Testing
import Shared
@testable import Pipeline

/// Scripted provider: maps (kind, selection) → output. Records every call.
final class ScriptedTransformProvider: PipelineProviderRouting, @unchecked Sendable {
    var enabled = true
    var script: [String: String] = [:]          // key: "\(instruction)|\(selection)"
    var failNext = false
    private(set) var calls: [(prompt: String, input: String, preference: String?)] = []

    func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { enabled && stage == .transform }

    func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String {
        calls.append((prompt, input, context.extra[TransformPreference.contextKey]))
        if failNext { failNext = false; throw ProviderRoutingError.unavailable }
        let instruction = prompt.components(separatedBy: "INSTRUCTION: ").last ?? ""
        guard let out = script["\(instruction)|\(input)"] else { throw ProviderRoutingError.unavailable }
        return out
    }
}

/// Mock injector: one text field with an AX-style UTF-16 value + selection, same safety
/// semantics as Injection's `ReplaceRangeEditor` (replace only when the region still matches).
final class MockReplaceInjector: TransformReplaceSink, @unchecked Sendable {
    var value: String
    var selection: Range<Int>
    var available = true
    var verifyWrites = true
    private(set) var journal: [TransformReplaceRequest] = []

    init(value: String, selection: Range<Int>? = nil) {
        self.value = value
        self.selection = selection ?? 0..<value.utf16.count
    }

    var snapshot: SelectionSnapshot? { SelectionSnapshot.from(value: value, selectedRange: selection, bundleID: "com.apple.mail", elementToken: "el-1") }

    func replace(_ request: TransformReplaceRequest) -> TransformReplaceOutcome {
        journal.append(request)
        guard available else { return .unavailable(reason: "AX not settable") }
        var units = Array(value.utf16)
        guard request.range.lowerBound >= 0, request.range.upperBound <= units.count else { return .mismatch(actual: nil) }
        let actual = String(decoding: units[request.range], as: UTF16.self)
        guard actual == request.expected else { return .mismatch(actual: actual) }
        units.replaceSubrange(request.range, with: Array(request.replacement.utf16))
        value = String(decoding: units, as: UTF16.self)
        selection = request.resultingRange
        return .replaced(verified: verifyWrites)
    }
}

func spans(_ text: String, confidence: Float = 0.95, lowWords: Set<String> = []) -> [TranscriptSpan] {
    text.split(separator: " ").enumerated().map { i, w in
        TranscriptSpan(text: String(w), confidence: lowWords.contains(String(w)) ? 0.3 : confidence,
                       audioRange: Double(i) * 0.3...Double(i + 1) * 0.3, provenance: [.asr])
    }
}
