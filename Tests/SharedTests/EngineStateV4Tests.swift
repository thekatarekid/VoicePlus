import Foundation
import Testing
@testable import Shared

/// G0.4 — the V4 turn-lifecycle cases on `EngineState` are additive: they round-trip, they have
/// stable names, and every pre-V4 encoding still decodes to the same value.
@Suite("EngineState V4 cases (G0.4)")
struct EngineStateV4Tests {
    /// One value per case. `exhaustiveName` below has no `default`, so a case added later without
    /// being listed here stops this file compiling instead of silently escaping the tests.
    static let everyCase: [EngineState] = [
        .idle, .prewarming, .listening(level: 0.4), .previewing(text: "hi"), .finalizing, .landed,
        .warning(MicQuality(snr: 9.5, clipping: 0.02, lowLevel: false, verdict: .poor)), .error("boom"),
        .unavailable("No speech model installed"), .starting, .finishing, .cancelled,
    ]

    private static func exhaustiveName(_ state: EngineState) -> String {
        switch state {
        case .idle: return "idle"
        case .prewarming: return "prewarming"
        case .listening: return "listening"
        case .previewing: return "previewing"
        case .finalizing: return "finalizing"
        case .landed: return "landed"
        case .warning: return "warning"
        case .error: return "error"
        case .unavailable: return "unavailable"
        case .starting: return "starting"
        case .finishing: return "finishing"
        case .cancelled: return "cancelled"
        }
    }

    @Test func newCasesRoundTripAlone() throws {
        for state in [EngineState.starting, .finishing, .cancelled] {
            let data = try JSONEncoder().encode(state)
            #expect(try JSONDecoder().decode(EngineState.self, from: data) == state)
        }
    }

    @Test func everyCaseRoundTripsInOneArray() throws {
        let data = try JSONEncoder().encode(Self.everyCase)
        #expect(try JSONDecoder().decode([EngineState].self, from: data) == Self.everyCase)
    }

    @Test func caseNamesAreStableAndUnique() {
        let names = Self.everyCase.map(\.caseName)
        #expect(names == Self.everyCase.map(Self.exhaustiveName))
        #expect(Set(names).count == Self.everyCase.count)
        #expect(EngineState.starting.caseName == "starting")
        #expect(EngineState.finishing.caseName == "finishing")
        #expect(EngineState.cancelled.caseName == "cancelled")
    }

    @Test func startingAndFinishingAreActiveCancelledIsTerminal() {
        #expect(EngineState.starting.isActive)
        #expect(EngineState.finishing.isActive)
        #expect(!EngineState.cancelled.isActive)
        // Unchanged pre-V4 answers.
        #expect(!EngineState.idle.isActive)
        #expect(!EngineState.landed.isActive)
        #expect(!EngineState.error("x").isActive)
        #expect(!EngineState.unavailable("x").isActive)
        #expect(EngineState.prewarming.isActive)
        #expect(EngineState.finalizing.isActive)
    }

    /// Adding cases must not change how the old ones are written: what a 1.10 build encoded still
    /// decodes, and the old cases still encode to the same keys.
    @Test func preV4EncodingsStillDecode() throws {
        let table: [(String, EngineState)] = [
            (#"{"idle":{}}"#, .idle),
            (#"{"prewarming":{}}"#, .prewarming),
            (#"{"listening":{"level":0.5}}"#, .listening(level: 0.5)),
            (#"{"previewing":{"text":"hello"}}"#, .previewing(text: "hello")),
            (#"{"finalizing":{}}"#, .finalizing),
            (#"{"landed":{}}"#, .landed),
            (#"{"error":{"_0":"boom"}}"#, .error("boom")),
            (#"{"unavailable":{"_0":"No model"}}"#, .unavailable("No model")),
        ]
        for (json, expected) in table {
            #expect(try JSONDecoder().decode(EngineState.self, from: Data(json.utf8)) == expected, "\(json)")
            let encoded = try JSONEncoder().encode(expected)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(Array(object.keys) == [expected.caseName])
        }
    }
}
