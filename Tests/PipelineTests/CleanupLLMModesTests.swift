import Foundation
import Testing
import Shared
@testable import Pipeline

// X4 — four independent LLM modes gate the cleanup stage: fast path only (default), per-app Polish,
// automatic polish when unsure, LLM on every dictation (longer deadline).

private func words(_ s: String) -> [TranscriptSpan] {
    s.split(separator: " ").enumerated().map { i, w in
        TranscriptSpan(text: String(w), confidence: 0.95, audioRange: Double(i)...Double(i) + 0.9, provenance: [.asr])
    }
}

final class CallCounter: CleanupGenerating, @unchecked Sendable {
    let promptStyle: CleanupPromptStyle = .delimited
    private let lock = NSLock()
    private var n = 0
    var calls: Int { lock.withLock { n } }
    func cleanup(_ prompt: CleanupPrompt, context: StageContext) async throws -> String {
        lock.withLock { n += 1 }
        return "Ship it on Friday."
    }
}

private func stage(_ gen: CallCounter, modes: LLMModes) -> CleanupStage {
    var s = CleanupStage(generator: gen, mode: { .automatic }, outputGuard: { CleanupGuard(entityGuard: nil) })
    s.modeResolver = { modes.cleanupMode(bundleID: $0.appBundleID) }
    s.deadlineForMode = { modes.deadline(for: $0) }
    return s
}

@Suite struct CleanupLLMModesTests {
    @Test func defaultsAreFastPathOnly() {
        let m = LLMModes.default
        #expect(m.fastPathOnly)
        #expect(!m.perAppPolish && !m.autoPolishWhenUnsure && !m.everyDictation)
        #expect(m.cleanupMode(bundleID: "com.apple.mail") == .off)
    }

    @Test func modesResolvePerApp() {
        var m = LLMModes(perAppPolish: true, polishApps: ["com.apple.mail"])
        #expect(m.cleanupMode(bundleID: "com.apple.mail") == .always)
        #expect(m.cleanupMode(bundleID: "com.tinyspeck.slackmacgap") == .off)
        m.autoPolishWhenUnsure = true
        #expect(m.cleanupMode(bundleID: "com.tinyspeck.slackmacgap") == .automatic)
        m.everyDictation = true
        #expect(m.cleanupMode(bundleID: nil) == .always)
        #expect(!m.fastPathOnly)
        m.setFastPathOnly(true)
        #expect(m == LLMModes(perAppPolish: false, polishApps: ["com.apple.mail"]))   // the app list is kept
        #expect(m.fastPathOnly)
    }

    @Test func everyDictationGetsTheLongerDeadline() {
        #expect(LLMModes.default.deadline(for: .always) == 2.5)
        #expect(LLMModes.default.deadline(for: .automatic) == CleanupStage.defaultDeadline)
    }

    @Test func roundTripsThroughSettingsJSON() {
        let m = LLMModes(perAppPolish: true, polishApps: ["a", "b"], autoPolishWhenUnsure: true)
        #expect(LLMModes.decode(m.encoded) == m)
        #expect(LLMModes.decode(nil) == nil)
    }

    @Test func fastPathNeverCallsTheModel() async throws {
        let gen = CallCounter()
        _ = try await stage(gen, modes: .default).process(words("ship it thursday no friday"), context: StageContext(register: .prose))
        #expect(gen.calls == 0)
    }

    @Test func perAppPolishRunsOnlyInListedApps() async throws {
        let gen = CallCounter()
        let s = stage(gen, modes: LLMModes(perAppPolish: true, polishApps: ["com.apple.mail"]))
        _ = try await s.process(words("ship it on friday"), context: StageContext(register: .prose, appBundleID: "com.apple.Notes"))
        #expect(gen.calls == 0)
        _ = try await s.process(words("ship it on friday"), context: StageContext(register: .prose, appBundleID: "com.apple.mail"))
        #expect(gen.calls == 1)
    }

    @Test func unsureModeNeedsACue() async throws {
        let gen = CallCounter()
        let s = stage(gen, modes: LLMModes(autoPolishWhenUnsure: true))
        _ = try await s.process(words("see you soon"), context: StageContext(register: .prose))
        #expect(gen.calls == 0)
        _ = try await s.process(words("ship it thursday no friday"), context: StageContext(register: .prose))
        #expect(gen.calls == 1)
    }

    @Test func everyDictationRunsWithoutACueButNeverInCode() async throws {
        let gen = CallCounter()
        let s = stage(gen, modes: LLMModes(everyDictation: true))
        _ = try await s.process(words("see you soon"), context: StageContext(register: .prose))
        #expect(gen.calls == 1)
        _ = try await s.process(words("see you soon"), context: StageContext(register: .code))
        #expect(gen.calls == 1)
    }

    @Test func aContextOverrideStillWins() async throws {
        let gen = CallCounter()
        let s = stage(gen, modes: LLMModes(everyDictation: true))
        _ = try await s.process(words("see you soon"), context: StageContext(register: .prose, extra: [CleanupMode.contextKey: "off"]))
        #expect(gen.calls == 0)
    }
}
