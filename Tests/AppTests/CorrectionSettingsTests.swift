import Foundation
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// Context Writer §5 — Settings › Models "Correction": defaults, per-app override, encode/decode,
/// the data-sent line from the network log, and "Test with last dictation" (no injection).
@Suite("Context Writer correction settings")
@MainActor
struct CorrectionSettingsTests {
    typealias S = ContextCorrectionSettings

    @Test func defaults() {
        let store = InMemorySettingsStore()
        #expect(S.mode(store) == .off)
        #expect(S.mode(nil) == .off)
        #expect(S.cloudModel(store) == "deepseek/deepseek-v4.1-flash")
        #expect(S.cloudFallbacks(store) == ["google/gemma-4-26b-a4b-it", "openai/gpt-6-luna"])
        #expect(S.providerOrder(store) == [])
        #expect(S.sendsAudio(store) == false)
        #expect(S.overrides(store).isEmpty)
        #expect(S.snapshot(store) == .defaults)
        let config = S.cloudConfig(store)
        #expect(config.model == CloudWriterConfig.defaultModel && config.timeout == 2.5 && config.maxTokens == 400)
        #expect(S.Mode.allCases.map(\.title) == ["Off", "On this Mac", "Cloud"])
    }

    @Test func writesPersistUnderTheCorrectionKeys() {
        let store = InMemorySettingsStore()
        S.setMode(.cloud, store: store)
        S.setCloudModel("  mistralai/mistral-small-2603 ", store: store)
        S.setCloudFallbacks(["a/b", "a/b", " c/d "], store: store)
        S.setProviderOrder(["together"], store: store)
        S.setSendsAudio(true, store: store)
        #expect(store.string("correction.mode") == "cloud")
        #expect(store.string("correction.cloudModel") == "mistralai/mistral-small-2603")
        #expect(store.string("correction.cloudFallbacks") == #"["a/b","c/d"]"#)
        #expect(store.string("correction.providerOrder") == #"["together"]"#)
        #expect(store.bool("correction.sendAudio") == true)
        #expect(S.cloudConfig(store) == CloudWriterConfig(model: "mistralai/mistral-small-2603", fallbackModels: ["a/b", "c/d"],
                                                          providerOrder: ["together"]))
        // Back to defaults clears the keys rather than pinning the default id. An explicit Off is a
        // choice (stored); Automatic (nil) clears the key.
        S.setCloudModel("", store: store)
        S.setCloudFallbacks(CloudWriterConfig.defaultFallbacks, store: store)
        S.setMode(.off, store: store)
        #expect(store.string("correction.mode") == "off")
        S.setMode(nil, store: store)
        #expect(store.string("correction.cloudModel") == nil && store.string("correction.cloudFallbacks") == nil
                && store.string("correction.mode") == nil)
    }

    @Test func perAppOverride() {
        let store = InMemorySettingsStore()
        S.setMode(.cloud, store: store)
        #expect(S.mode(for: "com.apple.mail", store: store) == .cloud)      // no override: global
        S.setOverride(.off, for: "com.apple.mail", store: store)
        S.setOverride(.local, for: "com.apple.Terminal", store: store)
        #expect(S.mode(for: "com.apple.mail", store: store) == .off)
        #expect(S.mode(for: "com.apple.Terminal", store: store) == .local)
        #expect(S.mode(for: "com.apple.Notes", store: store) == .cloud)
        #expect(S.mode(for: nil, store: store) == .cloud)
        #expect(store.string("correction.perApp") == #"{"com.apple.Terminal":"local","com.apple.mail":"off"}"#)
        S.setOverride(nil, for: "com.apple.mail", store: store)
        #expect(S.mode(for: "com.apple.mail", store: store) == .cloud)
        S.setOverride(nil, for: "com.apple.Terminal", store: store)
        #expect(store.string("correction.perApp") == nil)
        S.setOverride(.off, for: "   ", store: store)                       // blank ids are ignored
        #expect(S.overrides(store).isEmpty)
    }

    @Test func snapshotEncodeDecodeRoundTrip() {
        let s = S.Snapshot(mode: .cloud, cloudModel: "m/x", cloudFallbacks: ["m/y"], providerOrder: ["p"],
                           sendAudio: true, perApp: ["com.a": .off, "com.b": .local])
        let json = s.encoded()
        #expect(json.contains("\"mode\":\"cloud\"") && json.contains("\"sendAudio\":true"))
        #expect(S.Snapshot.decode(json) == s)
        #expect(S.Snapshot.decode("not json") == nil)
        #expect(S.Snapshot.decode(nil) == nil)
        // Through the store and back.
        let store = InMemorySettingsStore()
        S.write(s, store: store)
        #expect(S.snapshot(store) == s)
        S.write(.defaults, store: store)
        #expect(S.snapshot(store) == .defaults)
        #expect(store.string("correction.perApp") == nil)
    }

    @Test func parseListSplitsOnCommasAndSpaces() {
        #expect(S.parseList("a/b, c/d  e/f\n a/b") == ["a/b", "c/d", "e/f"])
        #expect(S.parseList("   ") == [])
    }

    // MARK: Model

    static func model(_ store: InMemorySettingsStore = InMemorySettingsStore(), db: AppDatabase? = nil,
                      key: String? = "sk-or-test", writer: ContextCorrectionSettingsModel.Writer? = nil,
                      now: Date = Date()) -> ContextCorrectionSettingsModel {
        let secrets = InMemorySecretStore(key.map { [SecretKey.apiKey(APIEndpoint.openRouter.providerID): $0] } ?? [:])
        return ContextCorrectionSettingsModel(store: store, database: db, secrets: secrets, writer: writer, now: { now })
    }

    @Test func modelMirrorsTheStoreAndItsOverrides() {
        let store = InMemorySettingsStore()
        let m = Self.model(store, key: nil)
        #expect(m.mode == .off && m.cloudModel == CloudWriterConfig.defaultModel)
        #expect(m.fallbacksText == "google/gemma-4-26b-a4b-it, openai/gpt-6-luna")
        #expect(m.providerLine == ContextCorrectionCopy.noKey)
        #expect(m.dataSentLine == ContextCorrectionCopy.nothingSent)
        m.mode = .cloud
        m.fallbacksText = "a/b, c/d"
        m.providerOrderText = "together baseten"
        m.sendAudio = true
        #expect(S.mode(store) == .cloud)
        #expect(S.cloudFallbacks(store) == ["a/b", "c/d"])
        #expect(S.providerOrder(store) == ["together", "baseten"])
        #expect(S.sendsAudio(store))
        m.newOverrideBundleID = " com.apple.mail "
        m.addOverride()
        #expect(m.overrides == [.init(bundleID: "com.apple.mail", mode: .cloud)])
        #expect(m.newOverrideBundleID.isEmpty)
        m.setOverride(.off, for: "com.apple.mail")
        #expect(S.mode(for: "com.apple.mail", store: store) == .off)
        m.removeOverride("com.apple.mail")
        #expect(m.overrides.isEmpty && S.overrides(store).isEmpty)
        #expect(Self.model(store, key: "k").providerLine == ContextCorrectionCopy.keyPresent)
    }

    @Test func dataSentLineSumsWriterBytesInTheLastHour() throws {
        let db = try AppDatabase.inMemory()
        let now = Date()
        try db.insert(NetworkLogRecord(timestamp: now.addingTimeInterval(-600), stage: "writer", provider: "api.openrouter",
                                       host: "openrouter.ai", bytesOut: 1500, bytesIn: 100, purpose: "writer"))
        try db.insert(NetworkLogRecord(timestamp: now.addingTimeInterval(-60), stage: "writer", provider: "api.openrouter",
                                       host: "openrouter.ai", bytesOut: 0, bytesIn: 48, purpose: "writer.prewarm"))
        try db.insert(NetworkLogRecord(timestamp: now.addingTimeInterval(-7200), stage: "writer", provider: "api.openrouter",
                                       host: "openrouter.ai", bytesOut: 9999, bytesIn: 0, purpose: "writer"))   // too old
        try db.insert(NetworkLogRecord(timestamp: now.addingTimeInterval(-30), stage: "style", provider: "api.openrouter",
                                       host: "openrouter.ai", bytesOut: 777, bytesIn: 0, purpose: "pipeline"))  // not the writer
        let m = Self.model(db: db, now: now)
        #expect(m.bytesLastHour == 1648)
        #expect(m.dataSentLine == ByteCountFormatter.string(fromByteCount: 1648, countStyle: .binary))
    }

    @Test func testWithLastDictationShowsTheResultAndInjectsNothing() async throws {
        let db = try AppDatabase.inMemory()
        try db.insert(DictationRecord(startedAt: Date().addingTimeInterval(-100), endedAt: Date().addingTimeInterval(-99), register: "chat",
                                      route: "local", appBundleID: "com.a", rawText: "older one", finalText: "Older one.", spansJSON: "[]"))
        try db.insert(DictationRecord(startedAt: Date(), endedAt: Date(), register: "chat", route: "local", appBundleID: "com.a",
                                      rawText: "hello kothari", finalText: "Hello kothari.", spansJSON: "[]"))
        let seen = Seen()
        let m = Self.model(db: db, writer: { system, user in
            seen.record(system: system, user: user)
            return " Hello Kothari. \n"
        })
        m.testWithLastDictation()
        #expect(m.testState == .running)
        try await Self.settle(m)
        #expect(m.testState == .done("Hello Kothari."))
        #expect(seen.user == "hello kothari")
        #expect(seen.system == ContextCorrectionSettingsModel.testSystemPrompt)
    }

    @Test func testWithoutDictationOrKeySaysSo() async throws {
        let empty = Self.model(db: try AppDatabase.inMemory())
        empty.testWithLastDictation()
        #expect(empty.testState == .noDictation)

        let db = try AppDatabase.inMemory()
        try db.insert(DictationRecord(startedAt: Date(), endedAt: Date(), register: "chat", route: "local", appBundleID: nil,
                                      rawText: "x", finalText: "x", spansJSON: "[]"))
        let noKey = Self.model(db: db, key: nil)
        noKey.testWithLastDictation()
        #expect(noKey.testState == .noKey)

        let failing = Self.model(db: db, writer: { _, _ in throw ProviderError.timeout })
        failing.testWithLastDictation()
        try await Self.settle(failing)
        #expect(failing.testState == .failed("timeout"))
    }

    private static func settle(_ m: ContextCorrectionSettingsModel) async throws {
        for _ in 0..<200 where m.testState == .running { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var system = ""
        private(set) var user = ""
        func record(system: String, user: String) { lock.lock(); self.system = system; self.user = user; lock.unlock() }
    }
}
