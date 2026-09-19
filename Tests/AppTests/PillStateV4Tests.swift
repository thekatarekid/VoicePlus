import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// The prototype's pill copy and state inventory (`node Scripts/spool_golden.mjs` →
/// `Fixtures/design/design_copy.json`). Only the parts G0.4 checks are decoded.
private struct DesignCopy: Decodable {
    struct Pill: Decodable {
        var status: String?
        var text: String?
        var strings: [String]?
        /// Every sentence the prototype draws for this state, status and `text` included.
        var all: [String] { [status, text].compactMap { $0 } + (strings ?? []) }
    }

    var pill: [String: Pill]
    /// `[key, id, name, description]`, e.g. `["starting", "C0", "Starting", "…"]`.
    var states: [[String]]

    static func load() throws -> DesignCopy {
        let dir = try #require(AppPaths.fixturesDirectory())
        let data = try Data(contentsOf: dir.appendingPathComponent("design/design_copy.json"))
        return try JSONDecoder().decode(DesignCopy.self, from: data)
    }
}

private let sampleQuality = MicQuality(snr: 8, clipping: 0.1, lowLevel: false, verdict: .poor)

/// One value per `PillState` case, plus the variants that draw a different design row.
/// `exhaustiveName` has no `default`: a case added without a sample stops this file compiling.
private let everyPillState: [PillState] = [
    .hidden, .idle, .listening(level: 0.4), .preview(text: "um can we"), .landing,
    .landed(LandedPillInfo(text: "Can we meet?", verified: true)),
    .landed(LandedPillInfo(text: "Can we meet?", verified: false)),
    .held(HeldPillInfo(text: "Can we meet?", destination: "Mail", reason: "destination changed")),
    .warning(sampleQuality), .unavailable(reason: "No speech model installed"), .error(message: "Text was not typed — Try again"),
    .transform(TransformPillInfo(editingWords: 18, stage: .editing)),
    .ready(hint: PillState.readyHint(key: "fn / 🌐")), .muted, .starting, .listeningQuiet,
    .latched(elapsed: 6), .cancelled, .finishing(elapsedWarning: false), .finishing(elapsedWarning: true),
    .finalPreview(FinalPreviewInfo(text: "Can we meet with Mira on Friday?", dwellRemaining: 0.9, destination: "Mail")),
    .finalPreview(FinalPreviewInfo(text: "Can we meet with Mira on Friday?", uncertainCount: 1,
                                   dwellRemaining: 1.8, destination: "Mail")),
    .inserting(text: "Can we meet with Mira on Friday?"), .landedPartial(text: "Can we meet with Mira on Friday?"),
    .correcting, .editing, .undoAvailable,
    .meeting(MeetingPillInfo(phase: .recording, elapsed: 724)),
    .meeting(MeetingPillInfo(phase: .paused, elapsed: 724)),
    .meeting(MeetingPillInfo(phase: .preparingNotes, elapsed: 724)),
]

private func exhaustiveName(_ state: PillState) -> String {
    switch state {
    case .hidden: return "hidden"
    case .idle: return "idle"
    case .listening: return "listening"
    case .preview: return "preview"
    case .landing: return "landing"
    case .landed(let info): return info.verified ? "landed" : "landedUnverified"
    case .held: return "held"
    case .warning: return "warning"
    case .unavailable: return "unavailable"
    case .error: return "error"
    case .transform: return "transform"
    case .ready: return "ready"
    case .muted: return "muted"
    case .starting: return "starting"
    case .listeningQuiet: return "listeningQuiet"
    case .latched: return "latched"
    case .cancelled: return "cancelled"
    case .finishing: return "finishing"
    case .finalPreview: return "finalPreview"
    case .inserting: return "inserting"
    case .landedPartial: return "landedPartial"
    case .correcting: return "correcting"
    case .editing: return "editing"
    case .undoAvailable: return "undoAvailable"
    case .meeting: return "meeting"
    }
}

private let v4States: [PillState] = everyPillState.filter {
    switch $0 {
    case .hidden, .idle, .listening, .preview, .landing, .landed, .held, .warning, .unavailable, .error, .transform:
        return false
    default: return true
    }
}

@Suite("Pill state V4 cases (G0.4)")
struct PillStateV4Tests {
    // MARK: Reducer

    @Test func reducerMapsTheNewEngineCasesOneToOne() {
        var r = PillStateReducer()
        #expect(r.reduce(.starting) == .starting)
        #expect(r.reduce(.listening(level: 0.3)) == .listening(level: 0.3))
        #expect(r.reduce(.finishing) == .finishing(elapsedWarning: false))
        #expect(r.reduce(.cancelled) == .cancelled)
        #expect(r.state.isVisible)
        #expect(r.reduce(.idle) == .hidden)
    }

    @Test func reducerStillMapsEveryPreV4EngineCaseAsBefore() {
        var r = PillStateReducer()
        #expect(r.reduce(.prewarming) == .idle)
        #expect(r.reduce(.listening(level: 0.4)) == .listening(level: 0.4))
        #expect(r.reduce(.previewing(text: "hello")) == .preview(text: "hello"))
        #expect(r.reduce(.finalizing) == .landing)
        #expect(r.reduce(.landed) == .landing)
        #expect(r.reduce(.warning(sampleQuality)) == .warning(sampleQuality))
        #expect(r.reduce(.error("boom")) == .error(message: "boom"))
        #expect(r.reduce(.unavailable("none")) == .unavailable(reason: "none"))
        #expect(r.reduce(.idle) == .hidden)
    }

    /// A live-capture warning belongs to the capture that raised it: a new turn (`starting`), a
    /// closed microphone (`finishing`) or a cancelled turn never keeps it sticky.
    @Test func newLifecycleCasesDropTheStickyWarning() {
        for boundary in [EngineState.starting, .finishing, .cancelled] {
            var r = PillStateReducer()
            r.reduce(.warning(sampleQuality))
            #expect(r.reduce(.listening(level: 0.5)) == .warning(sampleQuality))
            r.reduce(boundary)
            #expect(r.stickyWarning == nil, "\(boundary.caseName)")
            #expect(r.reduce(.listening(level: 0.5)) == .listening(level: 0.5), "\(boundary.caseName)")
        }
    }

    // MARK: Names

    @Test func caseNamesAreExtendedAndUnique() {
        #expect(everyPillState.map(\.caseName) == everyPillState.map(exhaustiveName))
        let distinct = Set(everyPillState.map(\.caseName))
        // Two finishing, two final-preview and three meeting samples share their case's name.
        #expect(distinct.count == everyPillState.count - 1 - 1 - 2)
        for state in v4States { #expect(state.isVisible, "\(state.caseName)") }
    }

    // MARK: Copy against the prototype

    @Test func newStatesDrawOnlyPrototypeSentences() throws {
        let copy = try DesignCopy.load()
        for state in v4States {
            let lines = state.messageLines
            #expect(!lines.isEmpty, "\(state.caseName) sizes to nothing")
            let pill = try #require(copy.pill[state.designStateKey], "\(state.designStateKey)")
            let allowed = Set(pill.all.map { PillState.withHotkey($0, key: "fn / 🌐") })
            for line in lines where !Self.isComposed(line) {
                #expect(allowed.contains(line), "\(state.caseName): “\(line)” is not prototype copy")
            }
        }
    }

    /// Sentences the prototype builds from a fixed part and a runtime value, checked by their own tests.
    private static func isComposed(_ line: String) -> Bool {
        line.hasPrefix("Ready for Mail · ") || line == PillCopy.finishingSlowStatus || line.hasPrefix("Microphone only")
    }

    @Test func readyHintIsThePrototypeHintWithTheConfiguredKey() throws {
        let copy = try DesignCopy.load()
        let prototype = try #require(copy.pill["ready"]?.text)
        #expect(PillState.readyHint(key: "Right Control") == prototype)
        // Owner decision: the default key is fn / 🌐 and only the key label changes.
        #expect(PillState.readyHint(key: "fn / 🌐") == "Hold or Double Tap fn / 🌐 to dictate")
        #expect(PillState.withHotkey(prototype, key: "fn / 🌐") == PillState.readyHint(key: "fn / 🌐"))
        // Latch off: design §5 — "the hint becomes “Hold <hotkey> to dictate”".
        #expect(PillState.readyHint(key: "fn / 🌐", latchEnabled: false) == "Hold fn / 🌐 to dictate")
        #expect(PillState.ready(hint: "Hold fn / 🌐 to dictate").messageLines == ["Hold fn / 🌐 to dictate"])
        #expect(PillState.withHotkey("Tap Right Control to finish", key: "fn / 🌐") == "Tap fn / 🌐 to finish")
    }

    @Test func finalPreviewStatusAndHelperFollowThePrototype() throws {
        let copy = try DesignCopy.load()
        let preview = try #require(copy.pill["preview"]).all
        let uncertain = try #require(copy.pill["uncertain"]).all

        let plain = FinalPreviewInfo(text: "x", dwellRemaining: 0.9, destination: "Mail")
        #expect(plain.status == "Ready for Mail")
        #expect(preview.contains(plain.status ?? ""))
        #expect(plain.helper == PillCopy.previewHelperAuto && preview.contains(plain.helper))
        var manual = plain
        manual.manual = true
        #expect(manual.helper == PillCopy.previewHelperManual && preview.contains(manual.helper))

        let review = FinalPreviewInfo(text: "x", uncertainCount: 1, dwellRemaining: 1.8, destination: "Mail")
        // The prototype builds this status as "Ready for Mail · " + "1 word to review".
        #expect(review.status == "Ready for Mail · 1 word to review")
        #expect(uncertain.contains("Ready for Mail · ") && uncertain.contains("1 word to review"))
        #expect(uncertain.contains(review.helper))
        var reviewManual = review
        reviewManual.manual = true
        #expect(uncertain.contains(reviewManual.helper))
        #expect(FinalPreviewInfo(text: "x", uncertainCount: 3, dwellRemaining: 1.8, destination: "Mail").status
                == "Ready for Mail · 3 words to review")

        // No destination name: no invented status, only the helper is sized.
        let anonymous = FinalPreviewInfo(text: "x", dwellRemaining: 0.9)
        #expect(anonymous.status == nil)
        #expect(PillState.finalPreview(anonymous).messageLines == [PillCopy.previewHelperAuto])
        #expect(FinalPreviewInfo(text: "x", dwellRemaining: 0.9, destination: "  ").status == nil)
    }

    @Test func finalPreviewCarriesItsDwellFields() {
        let info = FinalPreviewInfo(text: "Hello", uncertainCount: 2, dwellRemaining: 1.2, paused: true, manual: false)
        #expect(info.text == "Hello" && info.uncertainCount == 2 && info.dwellRemaining == 1.2)
        #expect(info.paused && !info.manual && info.needsReview)
        #expect(FinalPreviewInfo(text: "", uncertainCount: -1, dwellRemaining: -3).uncertainCount == 0)
        #expect(FinalPreviewInfo(text: "", uncertainCount: -1, dwellRemaining: -3).dwellRemaining == 0)
    }

    @Test func slowFinishingSaysWhatTheDesignSays() throws {
        let dir = try #require(AppPaths.fixturesDirectory())
        let spec = try String(contentsOf: dir.deletingLastPathComponent().appendingPathComponent("design/design_v1.md"),
                              encoding: .utf8)
        #expect(spec.contains("After 2 s of finalization say “\(PillCopy.finishingSlowStatus)”"))
        #expect(PillState.finishingWarningDelay == 2)
        #expect(PillState.finishing(elapsedWarning: true).messageLines.first == PillCopy.finishingSlowStatus)
        #expect(PillState.finishing(elapsedWarning: false).messageLines.first == PillCopy.finishingStatus)
    }

    @Test func meetingRowsReadAsThePrototype() throws {
        let copy = try DesignCopy.load()
        for phase in MeetingPillInfo.Phase.allCases {
            let info = MeetingPillInfo(phase: phase, elapsed: 724)
            let prototype = try #require(copy.pill[phase.designStateKey]?.strings)
            #expect([info.headline, info.detail, info.helper] == Array(prototype.prefix(3)), "\(phase)")
        }
        // Design §8.2: system-audio denial is a visible missing track, never "Microphone + system audio".
        let micOnly = MeetingPillInfo(phase: .recording, elapsed: 6, capturesSystemAudio: false)
        #expect(micOnly.detail == "Microphone only · 0:06")
    }

    @Test func pillTimerFormatsLikeThePrototype() {
        #expect(PillTimer.text(elapsed: 6) == "0:06")
        #expect(PillTimer.text(elapsed: 6.9) == "0:06")
        #expect(PillTimer.text(elapsed: 724) == "12:04")
        #expect(PillTimer.text(elapsed: 3723) == "1:02:03")
        #expect(PillTimer.text(elapsed: -4) == "0:00")
        #expect(PillTimer.text(elapsed: .nan) == "0:00")
        #expect(PillTimer.text(elapsed: .infinity) == "0:00")
    }

    // MARK: Landed family

    @Test func landedGainsPartial() {
        for outcome in LandedOutcome.allCases {
            let state = PillState.landed(text: "Can we meet?", outcome: outcome)
            #expect(state.landedOutcome == outcome)
        }
        #expect(PillState.landed(text: "a", outcome: .verified) == .landed(LandedPillInfo(text: "a", verified: true)))
        #expect(PillState.landed(text: "a", outcome: .unverified) == .landed(LandedPillInfo(text: "a", verified: false)))
        #expect(PillState.landed(text: "a", outcome: .partial) == .landedPartial(text: "a"))
        #expect(PillState.landedPartial(text: "a").messageLines == [PillCopy.partialStatus, PillCopy.partialHelper])
        #expect(PillState.inserting(text: "a").landedOutcome == nil)
        #expect(PillState.held(HeldPillInfo(text: "a", destination: "", reason: "x")).landedOutcome == nil)
    }

    // MARK: Consumers that switch exhaustively (compiler-forced additions, G0.4)

    @Test func dwellClassesOfTheNewStates() {
        for state in [PillState.ready(hint: "h"), .starting, .listeningQuiet, .latched(elapsed: 1),
                      .finishing(elapsedWarning: true), .finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 1)),
                      .inserting(text: "x"), .correcting, .editing,
                      .meeting(MeetingPillInfo(phase: .recording, elapsed: 1))] {
            #expect(PillDwell.minimum(for: state) == 0, "\(state.caseName)")
        }
        // S2 owns this table now (design §6, §10): cancelled 800 ms, the safe-undo window 5 s, and a
        // partial insertion stays until the user acts.
        #expect(PillDwell.minimum(for: .cancelled) == PillDwell.cancelled)
        #expect(PillDwell.minimum(for: .undoAvailable) == PillDwell.undoWindow)
        #expect(PillDwell.isNotice(.landedPartial(text: "x")))
        // I2: muted leaves only on an explicit Unmute.
        #expect(PillDwell.staysUntilAction(.muted))
    }

    @Test func presenceReadsTheNewEngineCases() {
        #expect(PresenceStateReducer.substance(PresenceInputs(engine: .starting)) == .processing)
        #expect(PresenceStateReducer.substance(PresenceInputs(engine: .finishing)) == .processing)
        #expect(PresenceStateReducer.substance(PresenceInputs(engine: .cancelled)) == .ready)
        #expect(PresenceStateReducer.substance(PresenceInputs(ambientProcessing: true, engine: .cancelled)) == .processing)
    }

    // MARK: Design inventory

    @Test func everyDesignStateHasAPillState() throws {
        let copy = try DesignCopy.load()
        let designKeys = Set(copy.states.compactMap(\.first))
        #expect(designKeys.count == 26)
        let produced = Set(everyPillState.map(\.designStateKey))
        #expect(produced.isSubset(of: designKeys), "unknown keys: \(produced.subtracting(designKeys))")
        // E1 "blocked" is a named blocker routed by the recovery catalogue (S9), not a case of its own.
        #expect(designKeys.subtracting(produced) == ["blocked"])
        #expect(Set(copy.pill.keys) == designKeys)
    }

    @Test func designKeysOfTheNewCases() {
        #expect(PillState.starting.designStateKey == "starting")
        #expect(PillState.listeningQuiet.designStateKey == "quiet")
        #expect(PillState.latched(elapsed: 0).designStateKey == "latched")
        #expect(PillState.finishing(elapsedWarning: true).designStateKey == "finishing")
        #expect(PillState.finalPreview(FinalPreviewInfo(text: "", dwellRemaining: 0)).designStateKey == "preview")
        #expect(PillState.finalPreview(FinalPreviewInfo(text: "", uncertainCount: 1, dwellRemaining: 0)).designStateKey
                == "uncertain")
        #expect(PillState.landedPartial(text: "").designStateKey == "partial")
        #expect(PillState.undoAvailable.designStateKey == "undo")
        #expect(PillState.meeting(MeetingPillInfo(phase: .preparingNotes, elapsed: 0)).designStateKey == "notes")
    }
}
