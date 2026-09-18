import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// G0.4 verify — the pill reducer as one table (build doc G0.4 "reducer table for every case").
///
/// `expected(_:sticky:)` is the oracle: for every `EngineState` case it names the pill state and the
/// sticky warning left behind, given the sticky warning the previous event left. It switches without
/// a `default`, so an engine case added later without a row stops this file compiling. The table is
/// then checked for every *pair* of engine events, so no case's mapping depends on what came before
/// it except through the sticky warning.
@Suite("Pill reducer table (G0.4 verify)")
struct PillStateReducerTableTests {
    private static let poor = MicQuality(snr: 8, clipping: 0.1, lowLevel: false, verdict: .poor)
    private static let quiet = MicQuality(snr: 20, clipping: 0, lowLevel: true, verdict: .bad)

    /// One value per `EngineState` case (associated values chosen to be distinguishable).
    private static let everyEngineState: [EngineState] = [
        .idle, .prewarming, .listening(level: 0.42), .previewing(text: "can we meet"), .finalizing, .landed,
        .warning(quiet), .error("Text was not typed — Try again"), .unavailable("No speech model installed"),
        .starting, .finishing, .cancelled,
    ]

    private static func expected(_ engine: EngineState, sticky: MicQuality?) -> (state: PillState, sticky: MicQuality?) {
        switch engine {
        case .idle: return (.hidden, nil)
        case .prewarming: return (.idle, sticky)
        case .listening(let level): return (sticky.map { .warning($0) } ?? .listening(level: level), sticky)
        case .previewing(let text): return (.preview(text: text), nil)
        case .finalizing, .landed: return (.landing, nil)
        case .warning(let quality): return (.warning(quality), quality)
        case .error(let message): return (.error(message: message), nil)
        case .unavailable(let reason): return (.unavailable(reason: reason), nil)
        // The V4 lifecycle, 1:1 — and none of them carries a live-capture warning forward.
        case .starting: return (.starting, nil)
        case .finishing: return (.finishing(elapsedWarning: false), nil)
        case .cancelled: return (.cancelled, nil)
        }
    }

    @Test func everyEngineCaseFromAFreshReducer() {
        for engine in Self.everyEngineState {
            var reducer = PillStateReducer()
            let want = Self.expected(engine, sticky: nil)
            #expect(reducer.reduce(engine) == want.state, "\(engine.caseName)")
            #expect(reducer.state == want.state, "\(engine.caseName)")
            #expect(reducer.stickyWarning == want.sticky, "\(engine.caseName)")
        }
    }

    @Test func everyEngineCaseWithAStickyWarningInPlace() {
        for engine in Self.everyEngineState {
            var reducer = PillStateReducer()
            reducer.reduce(.warning(Self.poor))
            let want = Self.expected(engine, sticky: Self.poor)
            #expect(reducer.reduce(engine) == want.state, "\(engine.caseName)")
            #expect(reducer.stickyWarning == want.sticky, "\(engine.caseName)")
        }
    }

    @Test func everyPairOfEngineEventsFollowsTheTable() {
        for first in Self.everyEngineState {
            for second in Self.everyEngineState {
                var reducer = PillStateReducer()
                reducer.reduce(first)
                let afterFirst = Self.expected(first, sticky: nil)
                let want = Self.expected(second, sticky: afterFirst.sticky)
                #expect(reducer.reduce(second) == want.state, "\(first.caseName) → \(second.caseName)")
                #expect(reducer.stickyWarning == want.sticky, "\(first.caseName) → \(second.caseName)")
            }
        }
    }

    /// "1:1": each new engine case has its own pill state, which no pre-V4 engine case produces.
    @Test func theNewEngineCasesMapOneToOneOntoTheirOwnPillStates() {
        let v4: [EngineState] = [.starting, .finishing, .cancelled]
        let old = Self.everyEngineState.filter { !v4.contains($0) }
        let v4States = v4.map { Self.expected($0, sticky: nil).state }
        #expect(Set(v4States.map(\.caseName)).count == v4.count)
        let oldStates = old.map { Self.expected($0, sticky: nil).state } + old.map { Self.expected($0, sticky: Self.poor).state }
        for state in v4States { #expect(!oldStates.contains(state), "\(state.caseName)") }
    }

    /// "Nothing else changes": the reducer only ever yields the engine-driven states. Every other V4
    /// state (ready, muted, quiet, latched, final preview, inserting, the landed family, review,
    /// meeting, a slow finishing) is presented by its own driver, never inferred from engine state.
    @Test func theReducerNeverProducesADriverOwnedState() {
        let engineDriven: Set<String> = [
            "hidden", "idle", "listening", "preview", "landing", "warning", "error", "unavailable",
            "starting", "finishing", "cancelled",
        ]
        for first in Self.everyEngineState {
            for second in Self.everyEngineState {
                var reducer = PillStateReducer()
                reducer.reduce(first)
                let state = reducer.reduce(second)
                #expect(engineDriven.contains(state.caseName), "\(first.caseName) → \(second.caseName)")
                #expect(state != .finishing(elapsedWarning: true))
            }
        }
    }

    // MARK: App path — the pill's view model is the reducer's only production caller.

    /// A whole V4 turn through `PillViewModel.apply(_:)` (what `bind(engineState:)` feeds): the new
    /// states are drawn immediately, and "Cancelled" survives the engine's `.idle` for its
    /// acknowledgement dwell instead of flashing past.
    @Test func aCancelledTurnThroughThePillViewModel() {
        let model = PillViewModel()
        var clock = Date(timeIntervalSince1970: 5_000)
        model.now = { clock }
        var seen: [EngineState] = []
        model.onEngineState = { seen.append($0) }

        model.apply(.starting)
        #expect(model.state == .starting)
        model.apply(.listening(level: 0.3))
        #expect(model.state == .listening(level: 0.3))
        model.apply(.cancelled)
        #expect(model.state == .cancelled)
        model.apply(.idle)
        #expect(model.state == .cancelled, "Cancelled must be legible before the pill retracts")
        clock = clock.addingTimeInterval(PillDwell.acknowledgement + 0.05)
        model.flushPillHold()
        #expect(model.state == .hidden)
        #expect(seen.map(\.caseName) == ["starting", "listening", "cancelled", "idle"])
    }

    @Test func aFinishingTurnThroughThePillViewModel() {
        let model = PillViewModel()
        let clock = Date(timeIntervalSince1970: 6_000)
        model.now = { clock }
        model.apply(.warning(Self.poor))
        model.apply(.listening(level: 0.5))
        #expect(model.state == .warning(Self.poor))
        model.apply(.finishing)
        #expect(model.state == .finishing(elapsedWarning: false))
        // A new turn replaces a live state at once; the closed microphone left no warning behind.
        model.apply(.starting)
        #expect(model.state == .starting)
        model.apply(.listening(level: 0.2))
        #expect(model.state == .listening(level: 0.2))
    }
}
