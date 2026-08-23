import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Router (T3)

@Suite struct MethodRouterTests {
    func store(_ outcomes: [(InjectionMethod, Bool)], app: String = "com.x") -> InMemoryOutcomeStore {
        let s = InMemoryOutcomeStore()
        for (m, ok) in outcomes {
            s.record(InjectionOutcomeRecord(utteranceID: nil, appBundleID: app, method: m.rawValue, succeeded: ok, latencyMs: 1))
        }
        return s
    }

    @Test func noHistoryKeepsAdapterOrder() {
        let router = MethodRouter(store: InMemoryOutcomeStore())
        #expect(router.order([.ax, .keystroke, .paste], for: "com.x") == [.ax, .keystroke, .paste])
    }

    @Test func failingMethodIsDemotedToEnd() {
        let router = MethodRouter(store: store([(.ax, false), (.ax, false), (.ax, false), (.keystroke, true)]))
        #expect(router.order([.ax, .keystroke, .paste], for: "com.x") == [.keystroke, .paste, .ax])
    }

    @Test func reliableMethodIsPromoted() {
        let router = MethodRouter(store: store([(.paste, true), (.paste, true), (.paste, true), (.paste, true)]))
        #expect(router.order([.ax, .keystroke, .paste], for: "com.x") == [.paste, .ax, .keystroke])
    }

    @Test func belowMinimumSamplesIsIgnored() {
        let router = MethodRouter(store: store([(.ax, false), (.ax, false)]))
        #expect(router.order([.ax, .keystroke], for: "com.x") == [.ax, .keystroke])
    }

    @Test func historyIsPerApp() {
        let router = MethodRouter(store: store([(.ax, false), (.ax, false), (.ax, false)], app: "com.other"))
        #expect(router.order([.ax, .keystroke], for: "com.x") == [.ax, .keystroke])
    }

    @Test func routerLearnsFromInjectorOutcomesEndToEnd() {
        let (injector, mock, store) = makeStack("com.example.Flaky")
        // AX lies three times → readback fails → router demotes AX; fourth run starts with keystrokes.
        final class Lying: MockSystemAccess { override func setFocusedSelectedText(_ text: String) throws {} }
        let lying = Lying(frontmost: focus("com.example.Flaky"))
        let learner = TextInjector(system: lying, store: store)
        for _ in 0..<3 { _ = learner.inject(InjectionRequest(text: "a")) }
        #expect(injector.router.order([.ax, .keystroke, .paste], for: "com.example.Flaky") == [.keystroke, .paste, .ax])
        _ = injector.inject(InjectionRequest(text: "b"))
        #expect(mock.journal.first?.hasPrefix("key.unicode") == true)
    }

    @Test func databaseStorePersistsAndReadsBack() throws {
        let db = try AppDatabase.inMemory()
        let store = DatabaseOutcomeStore(database: db)
        store.record(InjectionOutcomeRecord(utteranceID: "u", appBundleID: "com.db", method: "ax", succeeded: true, latencyMs: 3))
        store.record(InjectionOutcomeRecord(utteranceID: "u", appBundleID: "com.other", method: "paste", succeeded: false, latencyMs: 9))
        let rows = store.outcomes(appBundleID: "com.db", limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.method == "ax")
        #expect(MethodRouter(store: store).stats(for: "com.db")[.ax] == MethodRouter.Stats(samples: 1, successes: 1))
    }
}
